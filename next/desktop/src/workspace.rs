use anyhow::{Context, Result, bail, ensure};
use clap::ValueEnum;
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

pub const DEFAULT_WORKSPACE_ID: &str = "builtin-default";

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum Access {
    Deny,
    ReadOnly,
    ReadWrite,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Scope {
    pub name: String,
    pub path: PathBuf,
    pub access: Access,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub root: PathBuf,
    pub scopes: BTreeMap<String, Scope>,
}

impl Workspace {
    pub fn access_at(&self, path: &Path) -> Access {
        // The most specific directory rule wins, including an explicit denial.
        self.scopes
            .values()
            .filter(|scope| contains(&scope.path, path))
            .max_by_key(|scope| scope.path.components().count())
            .map_or(Access::Deny, |scope| scope.access)
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct Registry {
    schema_version: u32,
    workspaces: BTreeMap<String, Workspace>,
}

impl Default for Registry {
    fn default() -> Self {
        Self {
            schema_version: 1,
            workspaces: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct WorkspaceStore {
    directory: PathBuf,
}

impl WorkspaceStore {
    pub fn open(directory: impl AsRef<Path>) -> Result<Self> {
        fs::create_dir_all(&directory).context("Cannot create desktop data directory")?;
        let directory = fs::canonicalize(directory)?;
        Ok(Self { directory })
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    fn locked<T>(&self, f: impl FnOnce(&mut Registry) -> Result<(T, bool)>) -> Result<T> {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(self.directory.join("workspaces.lock"))?;
        FileExt::lock_exclusive(&lock).context("Cannot lock workspace registry")?;
        let path = self.directory.join("workspaces.json");
        let mut registry: Registry = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .context("Invalid workspace registry; refusing to replace it")?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Registry::default(),
            Err(error) => return Err(error.into()),
        };
        ensure!(
            registry.schema_version == 1,
            "Unsupported workspace registry version"
        );
        let (result, changed) = f(&mut registry)?;
        if changed {
            let mut temporary = tempfile::NamedTempFile::new_in(&self.directory)?;
            serde_json::to_writer_pretty(&mut temporary, &registry)?;
            temporary.write_all(b"\n")?;
            temporary.as_file().sync_all()?;
            temporary
                .persist(&path)
                .context("Cannot save workspace registry")?;
        }
        Ok(result)
    }

    pub fn list(&self) -> Result<Vec<Workspace>> {
        self.locked(|r| Ok((r.workspaces.values().cloned().collect(), false)))
    }

    pub fn with_workspace<T>(
        &self,
        id: &str,
        f: impl FnOnce(&Workspace) -> Result<T>,
    ) -> Result<T> {
        self.locked(|r| {
            let workspace = r
                .workspaces
                .get(id)
                .context("Workspace not found or removed")?;
            Ok((f(workspace)?, false))
        })
    }

    pub fn get(&self, id: &str) -> Result<Workspace> {
        self.with_workspace(id, |w| Ok(w.clone()))
    }

    pub fn add(&self, id: &str, name: &str, path: &Path, access: Access) -> Result<Workspace> {
        validate_id(id)?;
        ensure!(
            id != DEFAULT_WORKSPACE_ID,
            "This ID is reserved for the default workspace"
        );
        ensure!(!name.trim().is_empty(), "Workspace name must not be empty");
        let root = self.scope_path(path)?;
        let workspace = Workspace {
            id: id.into(),
            name: name.trim().into(),
            root: root.clone(),
            scopes: BTreeMap::from([(
                "root".into(),
                Scope {
                    name: "root".into(),
                    path: root,
                    access,
                },
            )]),
        };
        self.locked(|r| {
            // Registration is idempotent by directory, even across processes.
            // Keep the existing ID and permission rules used by old sessions.
            if let Some(existing) = r
                .workspaces
                .values()
                .find(|w| same_path(&w.root, &workspace.root))
            {
                return Ok((existing.clone(), false));
            }
            ensure!(
                !r.workspaces.contains_key(id),
                "Workspace ID already exists"
            );
            r.workspaces.insert(id.into(), workspace.clone());
            Ok((workspace, true))
        })
    }

    pub fn set_scope(
        &self,
        id: &str,
        name: &str,
        path: &Path,
        access: Access,
    ) -> Result<Workspace> {
        validate_id(name)?;
        let path = self.scope_path(path)?;
        self.locked(|r| {
            let workspace = r.workspaces.get_mut(id).context("Workspace not found")?;
            if name == "root" {
                ensure!(
                    same_path(&workspace.root, &path),
                    "Root path cannot change; add a new workspace instead"
                );
            }
            ensure!(
                !workspace
                    .scopes
                    .values()
                    .any(|s| s.name != name && same_path(&s.path, &path)),
                "This directory already has a rule; update that rule by name"
            );
            workspace.scopes.insert(
                name.into(),
                Scope {
                    name: name.into(),
                    path,
                    access,
                },
            );
            Ok((workspace.clone(), true))
        })
    }

    pub fn remove_scope(&self, id: &str, name: &str) -> Result<Workspace> {
        ensure!(
            name != "root",
            "Set root access to deny instead of removing the root rule"
        );
        self.locked(|r| {
            let workspace = r.workspaces.get_mut(id).context("Workspace not found")?;
            ensure!(workspace.scopes.remove(name).is_some(), "Scope not found");
            Ok((workspace.clone(), true))
        })
    }

    pub fn remove(&self, id: &str) -> Result<()> {
        ensure!(
            id != DEFAULT_WORKSPACE_ID,
            "The default workspace cannot be removed; change its access rules instead"
        );
        self.locked(|r| {
            ensure!(r.workspaces.remove(id).is_some(), "Workspace not found");
            Ok(((), true))
        })
    }

    fn scope_path(&self, path: &Path) -> Result<PathBuf> {
        let path = fs::canonicalize(path).context("Scope directory must exist")?;
        ensure!(path.is_dir(), "Scope must be a directory");
        ensure!(
            !contains(&path, &self.directory) && !contains(&self.directory, &path),
            "Workspace scopes must not overlap the desktop configuration directory"
        );
        Ok(path)
    }

    pub fn default_workspace(&self) -> Result<Workspace> {
        self.locked(|registry| {
            if let Some(workspace) = registry.workspaces.get(DEFAULT_WORKSPACE_ID) {
                // Never recreate a deleted folder or widen a user's existing rule.
                return Ok((workspace.clone(), false));
            }
            let parent = self
                .directory
                .parent()
                .context("Configuration directory needs a parent")?;
            let mut sibling = self
                .directory
                .file_name()
                .context("Configuration directory needs a name")?
                .to_os_string();
            sibling.push("-workspaces");
            let root = parent.join(sibling).join("default");
            fs::create_dir_all(&root).context("Cannot create the default workspace")?;
            let root = self.scope_path(&root)?;
            let workspace = Workspace {
                id: DEFAULT_WORKSPACE_ID.into(),
                name: "默认工作区".into(),
                root: root.clone(),
                scopes: BTreeMap::from([(
                    "root".into(),
                    Scope {
                        name: "root".into(),
                        path: root,
                        access: Access::ReadWrite,
                    },
                )]),
            };
            registry
                .workspaces
                .insert(workspace.id.clone(), workspace.clone());
            Ok((workspace, true))
        })
    }
}

pub fn validate_id(value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        bail!("IDs use 1-64 ASCII letters, digits, hyphens or underscores");
    }
    Ok(())
}

fn comparison_path(path: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        PathBuf::from(path.as_os_str().to_string_lossy().to_lowercase())
    }
    #[cfg(not(windows))]
    {
        path.to_path_buf()
    }
}

pub fn contains(parent: &Path, path: &Path) -> bool {
    comparison_path(path).starts_with(comparison_path(parent))
}

fn same_path(a: &Path, b: &Path) -> bool {
    comparison_path(a) == comparison_path(b)
}
