use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use expert_desktop::{
    files::WorkspaceFiles,
    mcp::CodingServer,
    workspace::{Access, WorkspaceStore},
};
use rmcp::ServiceExt;
use std::{io::Read, path::PathBuf};

#[derive(Parser)]
#[command(
    version,
    about = "Manage desktop coding workspaces and enforce directory permissions"
)]
struct Cli {
    /// Private configuration directory. Must not overlap any authorized scope.
    #[arg(long, global = true)]
    data_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Add, inspect or remove a workspace. Removing never deletes source files.
    Workspace {
        #[command(subcommand)]
        action: WorkspaceCommand,
    },
    /// Set a directory access rule. The most specific rule wins.
    Scope {
        #[command(subcommand)]
        action: ScopeCommand,
    },
    /// Inspect or edit files using the same permissions as the MCP tools.
    File {
        #[command(subcommand)]
        action: FileCommand,
    },
    /// Run a stdio MCP server bound to exactly one workspace.
    Serve { workspace: String },
}

#[derive(Subcommand)]
enum WorkspaceCommand {
    /// Create or return the dedicated default workspace, preserving its permissions.
    Default,
    Add {
        id: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        path: PathBuf,
        #[arg(long, value_enum, default_value = "read-only")]
        access: Access,
    },
    List,
    Show {
        id: String,
    },
    Remove {
        id: String,
    },
}

#[derive(Subcommand)]
enum ScopeCommand {
    Set {
        workspace: String,
        name: String,
        #[arg(long)]
        path: PathBuf,
        #[arg(long, value_enum)]
        access: Access,
    },
    /// Remove a rule; inherited access applies afterwards. Use deny to block access.
    Remove { workspace: String, name: String },
}

#[derive(Subcommand)]
enum FileCommand {
    List {
        workspace: String,
        #[arg(long, default_value = "root")]
        scope: String,
        #[arg(default_value = ".")]
        path: String,
    },
    Read {
        workspace: String,
        #[arg(long, default_value = "root")]
        scope: String,
        path: String,
    },
    /// Read new content from stdin. Existing files need their current sha256.
    Write {
        workspace: String,
        #[arg(long, default_value = "root")]
        scope: String,
        path: String,
        #[arg(long)]
        expected: String,
    },
    Mkdir {
        workspace: String,
        #[arg(long, default_value = "root")]
        scope: String,
        path: String,
    },
}

fn print(value: impl serde::Serialize) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

fn default_data_dir() -> Result<PathBuf> {
    #[cfg(windows)]
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(not(windows))]
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".local/share")));
    Ok(base
        .context("Cannot locate application data; provide --data-dir")?
        .join("expert-chat/desktop"))
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let store = WorkspaceStore::open(match cli.data_dir {
        Some(path) => path,
        None => default_data_dir()?,
    })?;
    match cli.command {
        Command::Workspace { action } => match action {
            WorkspaceCommand::Add {
                id,
                name,
                path,
                access,
            } => print(store.add(&id, name.as_deref().unwrap_or(&id), &path, access)?)?,
            WorkspaceCommand::List => print(store.list()?)?,
            WorkspaceCommand::Default => print(store.default_workspace()?)?,
            WorkspaceCommand::Show { id } => print(store.get(&id)?)?,
            WorkspaceCommand::Remove { id } => {
                store.remove(&id)?;
                print(serde_json::json!({"removed":id,"source_files_deleted":false}))?;
            }
        },
        Command::Scope { action } => match action {
            ScopeCommand::Set {
                workspace,
                name,
                path,
                access,
            } => print(store.set_scope(&workspace, &name, &path, access)?)?,
            ScopeCommand::Remove { workspace, name } => {
                print(store.remove_scope(&workspace, &name)?)?
            }
        },
        Command::File { action } => match action {
            FileCommand::List {
                workspace,
                scope,
                path,
            } => print(WorkspaceFiles::new(store, workspace)?.list(&scope, &path)?)?,
            FileCommand::Read {
                workspace,
                scope,
                path,
            } => print(WorkspaceFiles::new(store, workspace)?.read(&scope, &path)?)?,
            FileCommand::Write {
                workspace,
                scope,
                path,
                expected,
            } => {
                let mut content = String::new();
                std::io::stdin()
                    .take(expert_desktop::files::MAX_FILE_BYTES + 1)
                    .read_to_string(&mut content)?;
                print(
                    WorkspaceFiles::new(store, workspace)?
                        .write(&scope, &path, &content, &expected)?,
                )?;
            }
            FileCommand::Mkdir {
                workspace,
                scope,
                path,
            } => {
                WorkspaceFiles::new(store, workspace)?.create_directory(&scope, &path)?;
                print(serde_json::json!({"created":true}))?;
            }
        },
        Command::Serve { workspace } => {
            let server = CodingServer::new(WorkspaceFiles::new(store, workspace)?);
            let service = server.serve(rmcp::transport::stdio()).await?;
            tokio::select! {
                result = service.waiting() => { result?; },
                result = tokio::signal::ctrl_c() => { result?; },
            }
        }
    }
    Ok(())
}
