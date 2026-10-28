use crate::app::{App, Command, Drawer, FormKind, items, text};
use serde_json::{Value, json};
use std::collections::HashMap;

pub fn path_key(path: &str) -> String {
    let windows = path.starts_with("\\\\") || path.as_bytes().get(1) == Some(&b':');
    if !windows {
        return path.trim_end_matches('/').to_owned();
    }
    let path = path.replace('/', "\\");
    let path = if path.to_ascii_lowercase().starts_with("\\\\?\\unc\\") {
        format!("\\\\{}", &path[8..])
    } else {
        path.strip_prefix("\\\\?\\").unwrap_or(&path).to_owned()
    };
    path.trim_end_matches('\\').to_lowercase()
}

/// Old duplicate IDs remain usable by their sessions. The picker presents
/// each directory once, retaining the current session's binding when present.
pub fn unique(a: &App) -> Vec<Value> {
    let mut seen = HashMap::<String, usize>::new();
    let mut rows = Vec::new();
    for workspace in items(&a.snapshot, "workspaces") {
        let path = text(workspace, "path");
        let key = if path.is_empty() {
            format!("id:{}", text(workspace, "id"))
        } else {
            path_key(path)
        };
        if let Some(&index) = seen.get(&key) {
            if workspace["id"] == a.snapshot["session"]["workspace_id"] {
                rows[index] = workspace.clone();
            }
        } else {
            seen.insert(key, rows.len());
            rows.push(workspace.clone());
        }
    }
    rows
}

pub fn display_path(path: &str) -> String {
    if path.to_ascii_lowercase().starts_with("\\\\?\\unc\\") {
        format!("\\\\{}", &path[8..])
    } else {
        path.strip_prefix("\\\\?\\").unwrap_or(path).to_owned()
    }
}

pub fn access_label(access: &str) -> &str {
    match access {
        "read-only" => "只读",
        "read-write" => "读写",
        "deny" => "拒绝访问",
        _ => "远程",
    }
}

impl App {
    pub fn open_workspace_permissions(&mut self) -> Vec<Command> {
        let list = self.drawer_items();
        let Some(workspace) = list.get(self.selected % list.len().max(1)) else {
            return vec![];
        };
        if workspace["remote"] == true {
            self.notice = "远程目录权限由服务器管理".into();
            return vec![];
        }
        let id = workspace["id"].clone();
        let mut commands = self.terminal_query("workspace.permissions");
        commands[0].params["workspace_id"] = id;
        commands
    }

    pub(crate) fn show_workspace_permissions(&mut self, workspace: &Value) {
        let mut fields = vec![];
        for (index, scope) in items(workspace, "scopes").iter().enumerate() {
            let name = text(scope, "name");
            fields.push(Self::field(
                &format!("scope:{index}"),
                &format!(
                    "{} · {}",
                    if name == "root" { "根目录" } else { name },
                    access_label(text(scope, "access"))
                ),
                &display_path(text(scope, "path")),
                false,
                false,
            ));
        }
        fields.push(Self::field("__back", "返回工作区列表", "", false, false));
        self.extra_form(
            FormKind::WorkspacePermissions,
            &format!("{} · 目录权限", text(workspace, "name")),
            fields,
            workspace.clone(),
        );
    }

    pub(crate) fn workspace_permission_action(&mut self) -> Option<Vec<Command>> {
        let form = self.form.as_ref()?;
        if !matches!(
            form.kind,
            FormKind::WorkspacePermissions | FormKind::WorkspaceScope
        ) {
            return None;
        }
        let field = form.fields.get(form.selected)?;
        if field.editable {
            return None;
        }
        let data = form.items.first()?.clone();
        let key = field.key.clone();
        if form.kind == FormKind::WorkspacePermissions {
            if key == "__back" {
                self.form = None;
                self.open(Drawer::Workspace);
                return Some(vec![]);
            }
            let index = key.strip_prefix("scope:")?.parse::<usize>().ok()?;
            let scope = items(&data, "scopes").get(index)?.clone();
            self.extra_form(
                FormKind::WorkspaceScope,
                "编辑目录权限",
                vec![
                    Self::field("workspace", "工作区", text(&data, "name"), false, false),
                    Self::field(
                        "path",
                        "目录",
                        &display_path(text(&scope, "path")),
                        false,
                        false,
                    ),
                    Self::choice(
                        "access",
                        "访问权限",
                        text(&scope, "access"),
                        &[
                            ("read-only", "只读"),
                            ("read-write", "读写"),
                            ("deny", "拒绝访问"),
                        ],
                    ),
                    Self::field("__save", "保存目录权限", "", false, false),
                    Self::field("__back", "返回目录列表", "", false, false),
                ],
                json!({"workspace":data,"scope":scope}),
            );
            return Some(vec![]);
        }
        if key == "__back" {
            self.show_workspace_permissions(&data["workspace"]);
            return Some(vec![]);
        }
        if key != "__save" {
            return Some(vec![]);
        }
        let access = form
            .fields
            .iter()
            .find(|f| f.key == "access")?
            .value
            .clone();
        let label = access_label(&access);
        if !self.confirm_extra("__save", &format!("将此目录改为{label}，再次 Enter 保存"))
        {
            return Some(vec![]);
        }
        let command = self.command(
            "terminal.action",
            json!({
                "action":"workspace.permission.set",
                "workspace_id":data["workspace"]["id"], "name":data["scope"]["name"],
                "expected_path":data["scope"]["path"], "expected_access":data["scope"]["access"],
                "access":access, "confirmed":true,
            }),
        );
        Some(self.submit_extra(command))
    }
}
