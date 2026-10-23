use crate::files::WorkspaceFiles;
use rmcp::{
    ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerConfig},
    schemars, tool, tool_handler, tool_router,
};
use serde::Deserialize;

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct FileRequest {
    /// Scope name from coding_workspace_info, e.g. root. This is not a host path.
    pub scope: String,
    /// Relative file/directory path. Use '.' to list the scope root.
    pub path: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct ReadRequest {
    pub scope: String,
    pub path: String,
    /// Omit for UTF-8 text. Use base64 for image previews (maximum 8 MiB).
    pub encoding: Option<String>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct WriteRequest {
    pub scope: String,
    pub path: String,
    /// Complete new UTF-8 content, up to 1 MiB.
    pub content: String,
    /// sha256 returned by coding_read_file, or 'new' for a new file.
    pub expected_sha256: String,
}

#[derive(Clone)]
pub struct CodingServer {
    files: WorkspaceFiles,
    tool_router: ToolRouter<Self>,
}

impl CodingServer {
    pub fn new(files: WorkspaceFiles) -> Self {
        Self {
            files,
            tool_router: Self::tool_router(),
        }
    }
}

fn reply(result: anyhow::Result<impl serde::Serialize>) -> CallToolResult {
    match result.and_then(|value| Ok(serde_json::to_string(&value)?)) {
        Ok(json) => CallToolResult::success(vec![ContentBlock::text(json)]),
        Err(error) => CallToolResult::error(vec![ContentBlock::text(format!("{error:#}"))]),
    }
}

#[tool_router]
impl CodingServer {
    #[tool(
        description = "Show the bound coding workspace and its current directory permissions. These are enforced by the server. Shell execution and permission changes are not available through this server."
    )]
    fn coding_workspace_info(&self) -> CallToolResult {
        reply(
            self.files
                .store
                .get(&self.files.workspace_id)
                .map(|workspace| {
                    serde_json::json!({
                        "workspace": workspace,
                        "commands": "not_provided_by_file_service",
                        "command_note": "This file service has no shell executor. The app's work_run_command and background process tools have separate approval and workspace checks; their availability is determined by the current tool list.",
                        "network_tools": "unavailable",
                        "policy_changes": "local_cli_only",
                        "file_limit_bytes": crate::files::MAX_FILE_BYTES,
                        "symlinks": "not_followed",
                    })
                }),
        )
    }

    #[tool(
        description = "List a directory within an authorized scope. Denied entries are omitted; links cannot be followed. At most 1000 entries are returned, with a truncation flag."
    )]
    fn coding_list_directory(
        &self,
        Parameters(request): Parameters<FileRequest>,
    ) -> CallToolResult {
        reply(self.files.list(&request.scope, &request.path))
    }

    #[tool(
        description = "Read a UTF-8 source file within an authorized scope, at most 1 MiB. Returns its content and sha256 revision for subsequent edits."
    )]
    fn coding_read_file(&self, Parameters(request): Parameters<ReadRequest>) -> CallToolResult {
        match request.encoding.as_deref() {
            Some("base64") => reply(self.files.read_binary(&request.scope, &request.path)),
            None | Some("utf8") | Some("utf-8") => {
                reply(self.files.read(&request.scope, &request.path))
            }
            Some(_) => {
                CallToolResult::error(vec![ContentBlock::text("encoding must be utf8 or base64")])
            }
        }
    }

    #[tool(
        description = "Create or replace a UTF-8 file only in a read-write scope. Existing files require the exact sha256 from a recent read; use 'new' only for a new path. Permissions are checked on every call."
    )]
    fn coding_write_file(&self, Parameters(request): Parameters<WriteRequest>) -> CallToolResult {
        reply(self.files.write(
            &request.scope,
            &request.path,
            &request.content,
            &request.expected_sha256,
        ))
    }

    #[tool(
        description = "Create one directory in a read-write scope. The parent must exist; this does not grant any new permissions."
    )]
    fn coding_create_directory(
        &self,
        Parameters(request): Parameters<FileRequest>,
    ) -> CallToolResult {
        reply(
            self.files
                .create_directory(&request.scope, &request.path)
                .map(|()| serde_json::json!({"created":true})),
        )
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for CodingServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("expert-desktop", env!("CARGO_PKG_VERSION")))
            .with_instructions("Use coding_workspace_info to inspect access. File paths are relative to named directory scopes. Rules are rechecked per operation; do not infer shell access or OS sandboxing. The user manages permissions using the local CLI.")
    }
}
