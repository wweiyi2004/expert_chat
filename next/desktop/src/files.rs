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
}

impl WorkspaceFiles {
    pub fn new(store: WorkspaceStore, workspace_id: String) -> Result<Self> {
        store.get(&workspace_id)?;
        Ok(Self {
            store,
            workspace_id,
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
            if expected == "new" {
                // create_new is the no-clobber commit for new files, even if an
                // external editor creates the destination after the check.
                let mut options = cap_std::fs::OpenOptions::new();
                options.write(true).create_new(true);
                let mut file = parent.open_with(name, &options)?;
                file.write_all(content.as_bytes())?;
                file.sync_all()?;
            } else {
                let mut temporary = cap_tempfile::TempFile::new(&parent)?;
                temporary.as_file_mut().write_all(content.as_bytes())?;
                if let Some(permissions) = previous {
                    temporary.as_file().set_permissions(permissions)?;
                }
                temporary.as_file().sync_all()?;
                temporary.replace(name)?;
            }
            Ok(WriteReceipt {
                scope: scope.into(),
                path: path.into(),
                sha256: hash(content.as_bytes()),
                bytes: content.len(),
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
