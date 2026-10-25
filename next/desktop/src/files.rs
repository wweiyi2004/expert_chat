use crate::workspace::{Access, Scope, Workspace, WorkspaceStore, contains};
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use cap_std::{ambient_authority, fs::Dir};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    path::{Component, Path, PathBuf},
};

pub const MAX_FILE_BYTES: u64 = 1024 * 1024;
pub const MAX_DIRECTORY_ENTRIES: usize = 1000;

#[derive(Clone)]
pub struct WorkspaceFiles {
    pub store: WorkspaceStore,
    pub workspace_id: String,
}

#[derive(Debug, Serialize)]
pub struct FileContents {
    pub scope: String,
    pub path: String,
    pub sha256: String,
    pub content: String,
}

#[derive(Debug, Serialize)]
pub struct DirectoryEntry {
    pub name: String,
    pub kind: &'static str,
    pub access: Access,
}

#[derive(Debug, Serialize)]
pub struct DirectoryListing {
    pub entries: Vec<DirectoryEntry>,
    pub truncated: bool,
}

#[derive(Debug, Serialize)]
pub struct WriteReceipt {
    pub scope: String,
    pub path: String,
    pub sha256: String,
    pub bytes: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery_path: Option<String>,
}

impl WorkspaceFiles {
    pub fn new(store: WorkspaceStore, workspace_id: String) -> Result<Self> {
        store.get(&workspace_id)?;
        Ok(Self {
            store,
            workspace_id,
        })
    }

    /// Hash final artifacts in fixed-size chunks without returning their bytes.
    /// A directory manifest is complete or fails; denied/link entries and bounds
    /// cannot silently publish a partial final project.
    pub fn artifact_manifest(&self, scope: &str, path: &str) -> Result<serde_json::Value> {
        self.store.with_workspace(&self.workspace_id, |workspace| {
            let normalized:PathBuf=validate_relative(path)?.components().filter(|component|!matches!(component,Component::CurDir)).collect();
            let initial=if normalized.as_os_str().is_empty(){".".to_string()}else{normalized.to_string_lossy().into_owned()};
            let mut pending = vec![(initial, 0usize)];
            let mut entries = Vec::new();
            let mut total_bytes = 0u64;
            let mut root_kind = "file";
            let mut visited = 0usize;
            let mut excluded_managed = Vec::new();
            while let Some((current, depth)) = pending.pop() {
                visited += 1;
                ensure!(visited <= MAX_DIRECTORY_ENTRIES, "Artifact manifest exceeds 1000 entries");
                if depth > 0 && matches!(Path::new(&current).file_name().and_then(|s| s.to_str()), Some(".expert-agent-worktrees" | ".git")) {
                    excluded_managed.push(current);
                    continue;
                }
                ensure!(depth <= 32, "Artifact directory exceeds depth 32");
                let (directory, relative) = resolve(workspace, scope, &current, false)?;
                let metadata = directory.symlink_metadata(&relative)?;
                ensure!(!metadata.is_symlink(), "Artifact links are not publishable");
                if metadata.is_dir() {
                    if depth == 0 { root_kind = "directory"; }
                    let mut children = Vec::new();
                    for item in directory.read_dir(&relative)? {
                        let item = item?;
                        ensure!(children.len() < MAX_DIRECTORY_ENTRIES, "Artifact directory exceeds entry limit");
                        children.push(Path::new(&current).join(item.file_name()).to_string_lossy().into_owned());
                    }
                    children.sort();
                    pending.extend(children.into_iter().map(|child| (child, depth + 1)));
                    ensure!(pending.len() + entries.len() <= MAX_DIRECTORY_ENTRIES, "Artifact manifest exceeds 1000 files");
                    continue;
                }
                ensure!(metadata.is_file(), "Artifact is not a regular file");
                let mut file = open_review_handle(&directory, &relative)?;
                let stamp_before = file_stamp(&file.try_clone()?.into_std())?;
                let before = file.metadata()?;
                let mut digest = Sha256::new();
                let mut buffer = [0u8; 65536];
                let mut bytes = 0u64;
                loop {
                    let count = file.read(&mut buffer)?;
                    if count == 0 { break; }
                    digest.update(&buffer[..count]);
                    bytes += count as u64;
                }
                let after = file.metadata()?;
                let stamp_after = file_stamp(&file.try_clone()?.into_std())?;
                ensure!(stamp_before == stamp_after && file_stamp(&directory.open(&relative)?.into_std())? == stamp_after,
                    "Artifact identity changed while hashing");
                ensure!(bytes == before.len() && before.len() == after.len() && before.modified()? == after.modified()?,
                    "Artifact changed while hashing; register again after writes finish");
                total_bytes = total_bytes.checked_add(bytes).context("Artifact size overflow")?;
                entries.push(serde_json::json!({"path":current.replace('\\', "/"),"bytes":bytes,"sha256":format!("{:x}",digest.finalize()),"identity":stamp_identity(&stamp_after)}));
            }
            entries.sort_by(|a,b| a["path"].as_str().cmp(&b["path"].as_str()));
            let sha256 = if root_kind == "file" { entries[0]["sha256"].as_str().unwrap().to_owned() }
                else { hash(serde_json::to_string(&entries)?.as_bytes()) };
            Ok(serde_json::json!({"scope":scope,"path":path,"kind":root_kind,"sha256":sha256,
                "identity":if root_kind == "file" { entries[0]["identity"].clone() } else { serde_json::Value::Null },
                "bytes":total_bytes,"entries":entries,"content_loaded":false,"excluded_managed":excluded_managed}))
        })
    }

    /// Copy an observed file version without loading bytes into the client.
    /// The destination must be new; source changes fail before publication.
    pub fn copy_file(
        &self,
        scope: &str,
        source: &str,
        destination: &str,
        expected: &str,
    ) -> Result<WriteReceipt> {
        self.copy_file_with_destination(scope, source, destination, expected, None)
    }

    pub fn copy_file_with_destination(
        &self,
        scope: &str,
        source: &str,
        destination: &str,
        expected: &str,
        destination_expected: Option<&str>,
    ) -> Result<WriteReceipt> {
        self.copy_file_guarded(
            scope,
            source,
            destination,
            expected,
            destination_expected,
            None,
        )
    }

    pub fn copy_file_guarded(
        &self,
        scope: &str,
        source: &str,
        destination: &str,
        expected: &str,
        destination_expected: Option<&str>,
        destination_identity: Option<&str>,
    ) -> Result<WriteReceipt> {
        self.store.with_workspace(&self.workspace_id, |workspace| {
            let (src_dir, src_path) = resolve(workspace, scope, source, false)?;
            let (dst_dir, dst_path) = resolve(workspace, scope, destination, true)?;
            let mut input = open_review_handle(&src_dir, &src_path)?;
            let source_guard = input.try_clone()?.into_std();
            fs2::FileExt::try_lock_shared(&source_guard)
                .context("Source is being edited; copy refused")?;
            let source_stamp = file_stamp(&source_guard)?;
            ensure!(input.metadata()?.is_file(), "Source must be a regular file");
            let name = dst_path
                .file_name()
                .context("Destination file path required")?;
            let parent = dst_dir.open_dir(
                dst_path
                    .parent()
                    .filter(|p| !p.as_os_str().is_empty())
                    .unwrap_or(Path::new(".")),
            )?;
            if let Some(expected_destination) = destination_expected {
                ensure!(
                    hash_regular_file(&parent, Path::new(name))? == expected_destination,
                    "Copy destination changed since observation"
                );
            } else {
                ensure!(
                    parent
                        .symlink_metadata(name)
                        .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
                    "Copy destination already exists"
                );
            }
            let mut temporary = cap_tempfile::TempFile::new(&parent)?;
            let mut digest = Sha256::new();
            let mut buffer = [0u8; 65536];
            let mut bytes = 0usize;
            loop {
                let count = input.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                digest.update(&buffer[..count]);
                temporary.as_file_mut().write_all(&buffer[..count])?;
                bytes = bytes.checked_add(count).context("File size overflow")?;
            }
            ensure!(
                file_stamp(&source_guard)? == source_stamp && bytes as u64 == source_stamp.len,
                "Copy source changed while reading"
            );
            let actual = format!("{:x}", digest.finalize());
            ensure!(
                actual == expected,
                "Copy source changed since it was observed"
            );
            let source_review = StableFileHash {
                hash: actual.clone(),
                stamp: source_stamp,
                _locked: source_guard,
            };
            revalidate_stable_file(&src_dir, &src_path, &source_review)?;
            temporary.as_file().sync_all()?;
            temporary
                .as_file()
                .set_permissions(input.metadata()?.permissions())?;
            let recovery_path;
            if let Some(expected_destination) = destination_expected {
                let reviewed = stable_hash_regular_file(&parent, Path::new(name))?;
                if let Some(identity) = destination_identity {
                    ensure!(
                        stamp_identity(&reviewed.stamp) == identity,
                        "Copy destination identity changed since isolation baseline"
                    );
                }
                ensure!(
                    reviewed.hash == expected_destination,
                    "Copy destination changed during copy"
                );
                revalidate_stable_file(&parent, Path::new(name), &reviewed)?;
                temporary
                    .as_file()
                    .set_permissions(cap_std::fs::Permissions::from_std(
                        reviewed._locked.metadata()?.permissions(),
                    ))?;
                recovery_path = guarded_mutation(&parent, name, reviewed, Some(temporary))?;
            } else {
                recovery_path = publish_new_file(&parent, name, temporary)?;
            }
            Ok(WriteReceipt {
                scope: scope.into(),
                path: destination.into(),
                sha256: actual,
                bytes,
                recovery_path,
            })
        })
    }

    /// User-driven rollback primitive; not offered by the app's model catalog.
    pub fn delete_if_current(
        &self,
        scope: &str,
        path: &str,
        expected: &str,
    ) -> Result<serde_json::Value> {
        self.delete_if_current_with_absent_source(scope, path, expected, None)
    }

    pub fn delete_if_current_with_absent_source(
        &self,
        scope: &str,
        path: &str,
        expected: &str,
        source_absent: Option<&str>,
    ) -> Result<serde_json::Value> {
        self.delete_file_guarded(scope, path, expected, source_absent, None)
    }

    pub fn delete_file_guarded(
        &self,
        scope: &str,
        path: &str,
        expected: &str,
        source_absent: Option<&str>,
        expected_identity: Option<&str>,
    ) -> Result<serde_json::Value> {
        self.store.with_workspace(&self.workspace_id, |workspace| {
            let absent = if let Some(source) = source_absent {
                ensure!(source != path, "Deletion source cannot equal destination");
                let (directory, relative) = resolve(workspace, scope, source, true)?;
                ensure!(
                    directory
                        .symlink_metadata(&relative)
                        .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
                    "Child deletion changed since review"
                );
                Some((directory, relative))
            } else {
                None
            };
            let (directory, relative) = resolve(workspace, scope, path, true)?;
            let name = relative.file_name().context("File path required")?;
            let parent = directory.open_dir(
                relative
                    .parent()
                    .filter(|p| !p.as_os_str().is_empty())
                    .unwrap_or(Path::new(".")),
            )?;
            let reviewed = stable_hash_regular_file(&parent, Path::new(name))?;
            if let Some(identity) = expected_identity {
                ensure!(
                    stamp_identity(&reviewed.stamp) == identity,
                    "Deletion destination identity changed since baseline"
                );
            }
            ensure!(
                reviewed.hash == expected,
                "File changed since review; rollback refused"
            );
            revalidate_stable_file(&parent, Path::new(name), &reviewed)?;
            if let Some((source_dir, source_path)) = &absent {
                ensure!(
                    source_dir
                        .symlink_metadata(source_path)
                        .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
                    "Child deletion changed during review"
                );
            }
            let recovery_path = guarded_mutation(&parent, name, reviewed, None)?;
            Ok(
                serde_json::json!({"deleted":true,"scope":scope,"path":path,"sha256":expected,
                "recovery_path":recovery_path}),
            )
        })
    }

    pub fn read(&self, scope: &str, path: &str) -> Result<FileContents> {
        self.store.with_workspace(&self.workspace_id, |workspace| {
            let (directory, relative) = resolve(workspace, scope, path, false)?;
            let content = read_text(&directory, &relative)?;
            Ok(FileContents {
                scope: scope.into(),
                path: path.into(),
                sha256: hash(content.as_bytes()),
                content,
            })
        })
    }

    pub fn read_binary(&self, scope: &str, path: &str) -> Result<serde_json::Value> {
        self.store.with_workspace(&self.workspace_id, |workspace| {
            let (directory, relative) = resolve(workspace, scope, path, false)?;
            let file = directory.open(&relative)?;
            ensure!(file.metadata()?.is_file(), "Path is not a regular file");
            const LIMIT: u64 = 8 * 1024 * 1024;
            let mut bytes = Vec::new();
            file.take(LIMIT + 1).read_to_end(&mut bytes)?;
            ensure!(bytes.len() as u64 <= LIMIT, "Binary preview exceeds 8 MiB");
            let extension = relative.extension().and_then(|s| s.to_str()).unwrap_or("").to_ascii_lowercase();
            let mime = match extension.as_str() {
                "png" => "image/png", "jpg" | "jpeg" => "image/jpeg", "gif" => "image/gif",
                "webp" => "image/webp", "bmp" => "image/bmp", "svg" => "image/svg+xml",
                "ico" => "image/x-icon", _ => "application/octet-stream",
            };
            Ok(serde_json::json!({"scope": scope, "path": path, "encoding": "base64",
                "sha256": hash(&bytes), "bytes": bytes.len(), "mime_type": mime, "content": STANDARD.encode(&bytes)}))
        })
    }

    pub fn list(&self, scope: &str, path: &str) -> Result<DirectoryListing> {
        self.store.with_workspace(&self.workspace_id, |workspace| {
            let (directory, relative) = resolve(workspace, scope, path, false)?;
            let base = scope_by_name(workspace, scope)?.path.join(&relative);
            let mut entries = Vec::new();
            let mut truncated = false;
            for item in directory.read_dir(&relative)? {
                let item = item?;
                let name = item.file_name();
                let access = workspace.access_at(&base.join(&name));
                if access == Access::Deny {
                    continue;
                }
                if entries.len() == MAX_DIRECTORY_ENTRIES {
                    truncated = true;
                    break;
                }
                let ty = item.file_type()?;
                entries.push(DirectoryEntry {
                    name: name.to_string_lossy().into_owned(),
                    kind: if ty.is_symlink() {
                        "link-unavailable"
                    } else if ty.is_dir() {
                        "directory"
                    } else {
                        "file"
                    },
                    access,
                });
            }
            entries.sort_by(|a, b| a.name.cmp(&b.name));
            Ok(DirectoryListing { entries, truncated })
        })
    }

    /// Replaces the whole file only when the supplied revision still matches.
    /// "new" means the destination must not exist. No blind overwrite API.
    pub fn write(
        &self,
        scope: &str,
        path: &str,
        content: &str,
        expected: &str,
    ) -> Result<WriteReceipt> {
        ensure!(
            content.len() as u64 <= MAX_FILE_BYTES,
            "File exceeds the 1 MiB text-tool limit"
        );
        self.store.with_workspace(&self.workspace_id, |workspace| {
            let (directory, relative) = resolve(workspace, scope, path, true)?;
            let name = relative.file_name().context("A file path is required")?;
            let parent = directory.open_dir(
                relative
                    .parent()
                    .filter(|p| !p.as_os_str().is_empty())
                    .unwrap_or(Path::new(".")),
            )?;
            let mut reviewed_version = None;
            let previous = match parent.symlink_metadata(name) {
                Ok(metadata) => {
                    ensure!(
                        metadata.is_file() && !metadata.is_symlink(),
                        "Destination must be a regular file"
                    );
                    ensure!(
                        expected != "new",
                        "File already exists; read it and provide its sha256"
                    );
                    let current = read_text(&parent, Path::new(name))?;
                    ensure!(
                        hash(current.as_bytes()) == expected,
                        "File changed since it was read; read again before editing"
                    );
                    let reviewed = stable_hash_regular_file(&parent, Path::new(name))?;
                    ensure!(
                        reviewed.hash == expected,
                        "File changed before replacement; write refused"
                    );
                    reviewed_version = Some(reviewed);
                    Some(metadata.permissions())
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    ensure!(
                        expected == "new",
                        "File no longer exists; refusing to recreate it with a stale revision"
                    );
                    None
                }
                Err(error) => return Err(error.into()),
            };
            let recovery_path = if expected == "new" {
                let mut temporary = cap_tempfile::TempFile::new(&parent)?;
                temporary.as_file_mut().write_all(content.as_bytes())?;
                temporary.as_file().sync_all()?;
                publish_new_file(&parent, name, temporary)?
            } else {
                let mut temporary = cap_tempfile::TempFile::new(&parent)?;
                temporary.as_file_mut().write_all(content.as_bytes())?;
                if let Some(permissions) = previous {
                    temporary.as_file().set_permissions(permissions)?;
                }
                temporary.as_file().sync_all()?;
                if let Some(reviewed) = &reviewed_version {
                    revalidate_stable_file(&parent, Path::new(name), reviewed)?;
                }
                guarded_mutation(
                    &parent,
                    name,
                    reviewed_version
                        .take()
                        .context("Missing reviewed version")?,
                    Some(temporary),
                )?
            };
            Ok(WriteReceipt {
                scope: scope.into(),
                path: path.into(),
                sha256: hash(content.as_bytes()),
                bytes: content.len(),
                recovery_path,
            })
        })
    }

    pub fn create_directory(&self, scope: &str, path: &str) -> Result<()> {
        self.store.with_workspace(&self.workspace_id, |workspace| {
            let (directory, relative) = resolve(workspace, scope, path, true)?;
            // One directory at a time keeps parent checks and results explicit.
            directory.create_dir(relative)?;
            Ok(())
        })
    }
}

#[cfg(test)]
thread_local! { static HASH_REVIEW_TEST_HOOK:std::cell::RefCell<Option<Box<dyn FnOnce()>>>=std::cell::RefCell::new(None); }

#[derive(Clone, Debug, PartialEq, Eq)]
struct FileStamp {
    len: u64,
    modified: std::time::SystemTime,
    created: Option<std::time::SystemTime>,
    #[cfg(unix)]
    dev: u64,
    #[cfg(unix)]
    ino: u64,
    #[cfg(windows)]
    volume: Option<u32>,
    #[cfg(windows)]
    index: Option<u64>,
}
#[cfg(windows)]
#[repr(C)]
#[derive(Default)]
struct WindowsFileInformation {
    attributes: u32,
    created: [u32; 2],
    accessed: [u32; 2],
    modified: [u32; 2],
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
}
#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetFileInformationByHandle(
        handle: *mut std::ffi::c_void,
        information: *mut WindowsFileInformation,
    ) -> i32;
}
fn file_stamp(file: &std::fs::File) -> Result<FileStamp> {
    let metadata = file.metadata()?;
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;
    #[cfg(windows)]
    let identity = {
        use std::os::windows::io::AsRawHandle;
        let mut information = WindowsFileInformation::default();
        // The Win32 by-handle identity avoids unstable std windows_by_handle APIs.
        // https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle
        ensure!(
            unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut information) } != 0,
            "Cannot verify Windows file identity"
        );
        (
            information.volume,
            ((information.index_high as u64) << 32) | information.index_low as u64,
        )
    };
    Ok(FileStamp {
        len: metadata.len(),
        modified: metadata.modified()?,
        created: metadata.created().ok(),
        #[cfg(unix)]
        dev: metadata.dev(),
        #[cfg(unix)]
        ino: metadata.ino(),
        #[cfg(windows)]
        volume: Some(identity.0),
        #[cfg(windows)]
        index: Some(identity.1),
    })
}
fn stamp_identity(stamp: &FileStamp) -> String {
    hash(format!("{stamp:?}").as_bytes())
}

struct StableFileHash {
    hash: String,
    stamp: FileStamp,
    _locked: std::fs::File,
}
/// On Windows, reject any existing writer handles and prevent new ones for
/// the complete review/commit interval. Share-delete allows the guarded move;
/// directory-name races are handled by moving and checking the actual inode.
fn open_review_handle(directory: &Dir, path: &Path) -> Result<cap_std::fs::File> {
    let mut options = cap_std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use cap_std::fs::OpenOptionsExt;
        options.share_mode(0x1 | 0x4); // FILE_SHARE_READ | FILE_SHARE_DELETE
    }
    Ok(directory.open_with(path, &options)?)
}

#[cfg(test)]
thread_local! { static MUTATION_COMMIT_TEST_HOOK:std::cell::RefCell<Option<Box<dyn FnOnce()>>>=std::cell::RefCell::new(None); }

#[cfg(test)]
thread_local! { static NEW_FILE_PUBLISH_TEST_HOOK:std::cell::RefCell<Option<Box<dyn FnOnce()>>>=std::cell::RefCell::new(None); }

/// Publish fully staged bytes with an exclusive hard link. No byte is written
/// after the public name appears, so an editor cannot race a partially filled
/// create_new output. Filesystems without hardlinks fail without clobbering.
fn publish_new_file(
    parent: &Dir,
    name: &std::ffi::OsStr,
    temporary: cap_tempfile::TempFile<'_>,
) -> Result<Option<String>> {
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let staging = loop {
        let name = format!(
            ".expert-chat-staging-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos(),
            SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        match parent.create_dir(&name) {
            Ok(()) => break name,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.into()),
        }
    };
    let staged_path = format!("{staging}/proposed");
    temporary.replace(std::ffi::OsStr::new(&staged_path))?;
    let staging_dir = parent.open_dir(&staging)?;
    #[cfg(test)]
    NEW_FILE_PUBLISH_TEST_HOOK.with(|hook| {
        if let Some(run) = hook.borrow_mut().take() {
            run();
        }
    });
    staging_dir.hard_link("proposed", parent, name)
        .with_context(|| format!("New destination appeared or no-clobber publication unavailable; staged bytes retained in {staged_path}"))?;
    if staging_dir.remove_file("proposed").is_err() {
        // Read-only hardlinks cannot always be unlinked on Windows without
        // changing public file attributes. Keep and explicitly report them.
        return Ok(Some(staged_path));
    }
    drop(staging_dir);
    if parent.remove_dir(&staging).is_err() {
        return Ok(Some(staging));
    }
    Ok(None)
}

/// No overwrite rename is used to publish. The exact name found at commit is
/// moved into a private recovery directory, then checked against the reviewed
/// identity. A raced path or failed publication keeps both versions. Windows
/// deny-write handles permit cleanup of a successful reviewed backup; Unix
/// advisory locks cannot exclude external writers, so return a retained backup.
fn guarded_mutation(
    parent: &Dir,
    name: &std::ffi::OsStr,
    reviewed: StableFileHash,
    temporary: Option<cap_tempfile::TempFile<'_>>,
) -> Result<Option<String>> {
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let recovery = loop {
        let name = format!(
            ".expert-chat-recovery-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos(),
            SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        match parent.create_dir(&name) {
            Ok(()) => break name,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.into()),
        }
    };
    let backup_dir = parent.open_dir(&recovery)?;
    #[cfg(not(windows))]
    let old_path = format!("{recovery}/original");
    if let Some(temporary) = temporary {
        // Private directory, destination cannot be supplied by an editor.
        temporary.replace(std::ffi::OsStr::new(&format!("{recovery}/proposed")))?;
    }
    #[cfg(test)]
    MUTATION_COMMIT_TEST_HOOK.with(|hook| {
        if let Some(run) = hook.borrow_mut().take() {
            run();
        }
    });
    if let Err(error) = parent.rename(name, &backup_dir, "original") {
        bail!("Commit refused; staged version retained in {recovery}: {error}");
    }
    if let Err(error) = revalidate_stable_file(&backup_dir, Path::new("original"), &reviewed) {
        // hard_link is exclusive: never replace a user-created current name.
        let _ = backup_dir.hard_link("original", parent, name);
        bail!("File changed at commit; all versions retained in {recovery}: {error}");
    }
    if backup_dir.symlink_metadata("proposed").is_ok() {
        if let Err(error) = backup_dir.hard_link("proposed", parent, name) {
            let _ = backup_dir.hard_link("original", parent, name);
            bail!(
                "Destination changed at publication; all versions retained in {recovery}: {error}"
            );
        }
        backup_dir.remove_file("proposed").with_context(|| {
            format!("Published file preserved; staged link retained in {recovery}/proposed")
        })?;
    }
    #[cfg(windows)]
    {
        backup_dir.remove_file("original").with_context(|| {
            format!("Commit completed; original recovery retained in {recovery}/original")
        })?;
        drop(reviewed);
        drop(backup_dir);
        parent.remove_dir(&recovery).with_context(|| {
            format!("Commit completed; recovery directory could not be cleaned: {recovery}")
        })?;
        Ok(None)
    }
    #[cfg(not(windows))]
    {
        Ok(Some(old_path))
    }
}

fn stable_hash_regular_file(directory: &Dir, path: &Path) -> Result<StableFileHash> {
    use fs2::FileExt;
    let metadata = directory.symlink_metadata(path)?;
    ensure!(
        metadata.is_file() && !metadata.is_symlink(),
        "Copy destination must be a regular file"
    );
    let mut input = open_review_handle(directory, path)?.into_std();
    input
        .try_lock_exclusive()
        .context("File is being edited; version check refused")?;
    let before = file_stamp(&input)?;
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut bytes = 0u64;
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        #[cfg(test)]
        if bytes == 0 {
            HASH_REVIEW_TEST_HOOK.with(|hook| {
                if let Some(run) = hook.borrow_mut().take() {
                    run();
                }
            });
        }
        digest.update(&buffer[..count]);
        bytes += count as u64;
    }
    let after = file_stamp(&input)?;
    ensure!(
        before == after && bytes == before.len,
        "File changed while hashing; mutation refused"
    );
    let result = StableFileHash {
        hash: format!("{:x}", digest.finalize()),
        stamp: after,
        _locked: input,
    };
    revalidate_stable_file(directory, path, &result)?;
    Ok(result)
}
fn revalidate_stable_file(directory: &Dir, path: &Path, expected: &StableFileHash) -> Result<()> {
    let actual = directory.open(path)?.into_std();
    ensure!(
        directory.symlink_metadata(path)?.is_file()
            && !directory.symlink_metadata(path)?.is_symlink(),
        "Reviewed path is no longer a regular file"
    );
    ensure!(
        file_stamp(&actual)? == expected.stamp,
        "Reviewed file identity or metadata changed; mutation refused"
    );
    Ok(())
}
fn hash_regular_file(directory: &Dir, path: &Path) -> Result<String> {
    Ok(stable_hash_regular_file(directory, path)?.hash)
}

pub fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn read_text(directory: &Dir, relative: &Path) -> Result<String> {
    let file = directory.open(relative)?;
    ensure!(file.metadata()?.is_file(), "Path is not a regular file");
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_FILE_BYTES,
        "File exceeds the 1 MiB text-tool limit"
    );
    String::from_utf8(bytes).context("File is not UTF-8 text")
}

fn scope_by_name<'a>(workspace: &'a Workspace, name: &str) -> Result<&'a Scope> {
    workspace
        .scopes
        .get(name)
        .context("Unknown or revoked access scope")
}

fn resolve(
    workspace: &Workspace,
    scope_name: &str,
    path: &str,
    write: bool,
) -> Result<(Dir, PathBuf)> {
    let relative = validate_relative(path)?;
    let scope = scope_by_name(workspace, scope_name)?;
    let current_root = std::fs::canonicalize(&scope.path)?;
    ensure!(
        contains(&scope.path, &current_root) && contains(&current_root, &scope.path),
        "Authorized directory was redirected; update its rule before accessing it"
    );
    let directory = Dir::open_ambient_dir(&scope.path, ambient_authority())
        .context("Authorized scope directory is unavailable")?;
    // The registry lock covers authorization and the complete file operation.
    // The directory capability performs filesystem traversal beneath the root.
    // Linked entries are deliberately not exposed as a second access route.
    let mut traversed = PathBuf::new();
    let components: Vec<_> = relative.components().collect();
    for (index, component) in components.iter().enumerate() {
        traversed.push(component.as_os_str());
        match directory.symlink_metadata(&traversed) {
            Ok(metadata) => ensure!(
                !metadata.is_symlink(),
                "Symbolic links and junctions are not accessible; authorize the actual directory as a scope"
            ),
            Err(error)
                if write
                    && index + 1 == components.len()
                    && error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    // OS canonicalization also expands Windows short-name aliases before
    // choosing the most specific policy. A lexical prefix alone is insufficient.
    let full_path = scope.path.join(&relative);
    let resolved = match std::fs::canonicalize(&full_path) {
        Ok(path) => path,
        Err(error) if write && error.kind() == std::io::ErrorKind::NotFound => {
            let parent = full_path.parent().context("Missing parent directory")?;
            std::fs::canonicalize(parent)?.join(full_path.file_name().context("Missing file name")?)
        }
        Err(error) => return Err(error.into()),
    };
    ensure!(
        contains(&scope.path, &resolved),
        "Path escapes its authorized scope"
    );
    let effective = workspace.access_at(&resolved);
    ensure!(
        effective != Access::Deny,
        "Access denied by workspace directory policy"
    );
    ensure!(
        !write || effective == Access::ReadWrite,
        "Directory is read-only"
    );
    let normalized: PathBuf = resolved
        .components()
        .skip(scope.path.components().count())
        .collect();
    Ok((
        directory,
        if normalized.as_os_str().is_empty() {
            PathBuf::from(".")
        } else {
            normalized
        },
    ))
}

pub fn validate_relative(value: &str) -> Result<PathBuf> {
    ensure!(
        !value.is_empty() && !value.contains('\0') && !value.contains(':'),
        "Use a non-empty relative path without a drive, device path or alternate stream"
    );
    let path = PathBuf::from(value);
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(name) => {
                let name = name.to_string_lossy();
                ensure!(
                    !name.ends_with(['.', ' ']),
                    "Trailing dots and spaces are not allowed in path components"
                );
                let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
                ensure!(
                    !["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(&stem.as_str())
                        && !(stem.len() == 4
                            && (stem.starts_with("COM") || stem.starts_with("LPT"))
                            && stem.as_bytes()[3].is_ascii_digit()),
                    "Device names are not allowed"
                );
            }
            _ => bail!("Absolute paths and parent traversal are not allowed"),
        }
    }
    Ok(path)
}

#[cfg(test)]
mod stable_review_tests {
    use super::*;
    #[test]
    fn external_atomic_save_during_hash_prevents_delete_and_copy_replacement() {
        for deleting in [true, false] {
            let temporary = tempfile::tempdir().unwrap();
            let project = temporary.path().join("project");
            std::fs::create_dir(&project).unwrap();
            let target = project.join("target.txt");
            std::fs::write(&target, vec![b'a'; 2 * 1024 * 1024]).unwrap();
            std::fs::write(project.join("source.txt"), b"desired").unwrap();
            let expected = hash(&vec![b'a'; 2 * 1024 * 1024]);
            let store = WorkspaceStore::open(temporary.path().join("authority")).unwrap();
            store
                .add("test", "Test", &project, Access::ReadWrite)
                .unwrap();
            let files = WorkspaceFiles::new(store, "test".into()).unwrap();
            let edited = target.clone();
            let backup = project.join("before-editor.txt");
            HASH_REVIEW_TEST_HOOK.with(|hook| {
                *hook.borrow_mut() = Some(Box::new(move || {
                    std::fs::rename(&edited, backup).unwrap();
                    std::fs::write(&edited, b"external editor version").unwrap();
                }))
            });
            let result = if deleting {
                files
                    .delete_if_current("root", "target.txt", &expected)
                    .map(|_| ())
            } else {
                files
                    .copy_file_with_destination(
                        "root",
                        "source.txt",
                        "target.txt",
                        &hash(b"desired"),
                        Some(&expected),
                    )
                    .map(|_| ())
            };
            assert!(result.is_err());
            assert_eq!(std::fs::read(&target).unwrap(), b"external editor version");
        }
    }
    #[test]
    fn atomic_editor_save_at_commit_is_preserved_for_write_copy_and_delete() {
        for operation in ["write", "copy", "delete"] {
            let temp = tempfile::tempdir().unwrap();
            let project = temp.path().join("project");
            std::fs::create_dir(&project).unwrap();
            let target = project.join("target.txt");
            std::fs::write(&target, b"reviewed").unwrap();
            std::fs::write(project.join("source.bin"), [0, 255, 9]).unwrap();
            let store = WorkspaceStore::open(temp.path().join("authority")).unwrap();
            store
                .add("test", "Test", &project, Access::ReadWrite)
                .unwrap();
            let files = WorkspaceFiles::new(store, "test".into()).unwrap();
            let edited = target.clone();
            let editor_old = project.join("editor-old.txt");
            MUTATION_COMMIT_TEST_HOOK.with(|hook| {
                *hook.borrow_mut() = Some(Box::new(move || {
                    std::fs::rename(&edited, editor_old).unwrap();
                    std::fs::write(&edited, b"editor wins at commit").unwrap();
                }))
            });
            let expected = hash(b"reviewed");
            let result = match operation {
                "write" => files
                    .write("root", "target.txt", "proposed", &expected)
                    .map(|_| ()),
                "copy" => files
                    .copy_file_with_destination(
                        "root",
                        "source.bin",
                        "target.txt",
                        &hash(&[0, 255, 9]),
                        Some(&expected),
                    )
                    .map(|_| ()),
                _ => files
                    .delete_if_current("root", "target.txt", &expected)
                    .map(|_| ()),
            };
            let error = format!("{:#}", result.unwrap_err());
            assert!(error.contains("retained"), "{error}");
            assert_eq!(std::fs::read(&target).unwrap(), b"editor wins at commit");
            assert!(std::fs::read_dir(&project).unwrap().any(|e| {
                e.unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".expert-chat-recovery-")
            }));
        }
    }

    #[test]
    fn guarded_copy_preserves_destination_permissions_and_cleans_success_on_windows() {
        let temp = tempfile::tempdir().unwrap();
        let project = temp.path().join("project");
        std::fs::create_dir(&project).unwrap();
        std::fs::write(project.join("target.bin"), [0, 1]).unwrap();
        std::fs::write(project.join("source.bin"), [0, 255, 9]).unwrap();
        let permissions = std::fs::metadata(project.join("target.bin"))
            .unwrap()
            .permissions();
        let store = WorkspaceStore::open(temp.path().join("authority")).unwrap();
        store
            .add("test", "Test", &project, Access::ReadWrite)
            .unwrap();
        let files = WorkspaceFiles::new(store, "test".into()).unwrap();
        let receipt = files
            .copy_file_with_destination(
                "root",
                "source.bin",
                "target.bin",
                &hash(&[0, 255, 9]),
                Some(&hash(&[0, 1])),
            )
            .unwrap();
        assert_eq!(
            std::fs::read(project.join("target.bin")).unwrap(),
            [0, 255, 9]
        );
        assert_eq!(
            std::fs::metadata(project.join("target.bin"))
                .unwrap()
                .permissions(),
            permissions
        );
        #[cfg(windows)]
        {
            assert!(receipt.recovery_path.is_none());
            assert_eq!(std::fs::read_dir(&project).unwrap().count(), 2);
        }
        #[cfg(not(windows))]
        assert!(receipt.recovery_path.is_some());
    }

    #[test]
    fn deletion_integration_requires_child_absence_and_parent_version() {
        let temp = tempfile::tempdir().unwrap();
        let project = temp.path().join("project");
        std::fs::create_dir(&project).unwrap();
        std::fs::write(project.join("target.txt"), b"reviewed").unwrap();
        std::fs::write(project.join("child.txt"), b"reappeared").unwrap();
        let store = WorkspaceStore::open(temp.path().join("authority")).unwrap();
        store
            .add("test", "Test", &project, Access::ReadWrite)
            .unwrap();
        let files = WorkspaceFiles::new(store, "test".into()).unwrap();
        assert!(
            files
                .delete_if_current_with_absent_source(
                    "root",
                    "target.txt",
                    &hash(b"reviewed"),
                    Some("child.txt")
                )
                .is_err()
        );
        std::fs::remove_file(project.join("child.txt")).unwrap();
        files
            .delete_if_current_with_absent_source(
                "root",
                "target.txt",
                &hash(b"reviewed"),
                Some("child.txt"),
            )
            .unwrap();
        assert!(!project.join("target.txt").exists());
    }
    #[test]
    fn identical_bytes_from_new_inode_do_not_match_isolation_identity() {
        let temp = tempfile::tempdir().unwrap();
        let project = temp.path().join("project");
        std::fs::create_dir(&project).unwrap();
        std::fs::write(project.join("target.txt"), b"same bytes").unwrap();
        std::fs::write(project.join("source.txt"), b"desired").unwrap();
        let store = WorkspaceStore::open(temp.path().join("authority")).unwrap();
        store
            .add("test", "Test", &project, Access::ReadWrite)
            .unwrap();
        let files = WorkspaceFiles::new(store, "test".into()).unwrap();
        let manifest = files.artifact_manifest("root", "target.txt").unwrap();
        let identity = manifest["identity"].as_str().unwrap();
        std::fs::rename(project.join("target.txt"), project.join("old.txt")).unwrap();
        std::fs::write(project.join("target.txt"), b"same bytes").unwrap();
        assert!(
            files
                .copy_file_guarded(
                    "root",
                    "source.txt",
                    "target.txt",
                    &hash(b"desired"),
                    Some(&hash(b"same bytes")),
                    Some(identity)
                )
                .is_err()
        );
        assert!(
            files
                .delete_file_guarded(
                    "root",
                    "target.txt",
                    &hash(b"same bytes"),
                    None,
                    Some(identity)
                )
                .is_err()
        );
        assert_eq!(
            std::fs::read(project.join("target.txt")).unwrap(),
            b"same bytes"
        );
    }
    #[test]
    fn new_file_publication_is_complete_and_never_clobbers_raced_creation() {
        for copy in [false, true] {
            for race in [false, true] {
                let temp = tempfile::tempdir().unwrap();
                let project = temp.path().join("project");
                std::fs::create_dir(&project).unwrap();
                let desired = vec![42u8; 2 * 1024 * 1024];
                std::fs::write(project.join("source.bin"), &desired).unwrap();
                let store = WorkspaceStore::open(temp.path().join("authority")).unwrap();
                store
                    .add("test", "Test", &project, Access::ReadWrite)
                    .unwrap();
                let files = WorkspaceFiles::new(store, "test".into()).unwrap();
                let target = project.join("new.txt");
                if race {
                    let target = target.clone();
                    NEW_FILE_PUBLISH_TEST_HOOK.with(|hook| {
                        *hook.borrow_mut() = Some(Box::new(move || {
                            std::fs::write(target, b"concurrent user creation").unwrap();
                        }))
                    });
                }
                let result = if copy {
                    files.copy_file("root", "source.bin", "new.txt", &hash(&desired))
                } else {
                    files.write("root", "new.txt", "complete text", "new")
                };
                if race {
                    assert!(result.is_err());
                    assert_eq!(std::fs::read(target).unwrap(), b"concurrent user creation");
                } else {
                    result.unwrap();
                    assert_eq!(
                        std::fs::read(target).unwrap(),
                        if copy {
                            desired
                        } else {
                            b"complete text".to_vec()
                        }
                    );
                    assert_eq!(std::fs::read_dir(&project).unwrap().count(), 2);
                }
            }
        }
    }
}
