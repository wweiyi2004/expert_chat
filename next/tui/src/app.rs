use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StartupPhase {
    Connecting,
    Workspace,
    Session,
}

#[derive(Debug, Clone, Default)]
pub struct Draft {
    pub text: String,
    pub cursor: usize,
    pub attachments: Vec<Value>,
    pub agent_id: Option<String>,
    pub collapsed: bool,
}
#[derive(Debug, Clone)]
pub struct PendingInput {
    pub command: Command,
    pub draft: Draft,
    pub question_state: Option<(usize, serde_json::Map<String, Value>)>,
}
#[derive(Debug, Clone)]
pub struct TextSelection {
    pub start: (u16, u16),
    pub end: (u16, u16),
    pub buffer: ratatui::buffer::Buffer,
    pub dragging: bool,
    pub revision: u64,
}
impl TextSelection {
    pub fn contains(&self, x: u16, y: u16) -> bool {
        use unicode_width::UnicodeWidthStr;
        let (a, b) = if (self.start.1, self.start.0) <= (self.end.1, self.end.0) {
            (self.start, self.end)
        } else {
            (self.end, self.start)
        };
        if !self
            .buffer
            .area
            .contains(ratatui::layout::Position::new(x, y))
        {
            return false;
        }
        let cell = &self.buffer[(x, y)];
        let width = match cell.diff_option {
            ratatui::buffer::CellDiffOption::ForcedWidth(w) => w.get(),
            _ => cell.symbol().width().max(1) as u16,
        };
        (y, x.saturating_add(width.saturating_sub(1))) >= (a.1, a.0) && (y, x) <= (b.1, b.0)
    }
    pub fn text(&self) -> String {
        use unicode_width::UnicodeWidthStr;
        let (mut a, mut b) = (self.start, self.end);
        if (a.1, a.0) > (b.1, b.0) {
            std::mem::swap(&mut a, &mut b);
        }
        let mut lines = vec![];
        for y in a.1..=b.1.min(self.buffer.area.bottom().saturating_sub(1)) {
            let left = if y == a.1 { a.0 } else { self.buffer.area.x };
            let right = if y == b.1 {
                b.0
            } else {
                self.buffer.area.right().saturating_sub(1)
            };
            let mut row = String::new();
            let mut x = self.buffer.area.x;
            while x < self.buffer.area.right() {
                let cell = &self.buffer[(x, y)];
                let width = match cell.diff_option {
                    ratatui::buffer::CellDiffOption::ForcedWidth(w) => usize::from(w.get()),
                    _ => cell.symbol().width().max(1),
                } as u16;
                if x <= right
                    && x.saturating_add(width) > left
                    && cell.diff_option != ratatui::buffer::CellDiffOption::Skip
                {
                    row.push_str(cell.symbol());
                }
                x = x.saturating_add(width.max(1));
            }
            lines.push(row.trim_end().to_owned());
        }
        lines.join("\n")
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormKind {
    Workbench,
    ImportSessions,
    ImportReview,
    ContextContents,
    SearchAll,
    Management,
    Quota,
    Settings,
    Provider,
    Mcp,
    Skin,
    Asr,
    Context,
    Memory,
    Skills,
    Skill,
    Hooks,
    Hook,
    AddDir,
    WorkspacePermissions,
    WorkspaceScope,
    Login,
    LoginProgress,
}
#[derive(Clone)]
pub struct FormField {
    pub key: String,
    pub label: String,
    pub value: String,
    pub secret: bool,
    pub editable: bool,
    /// Closed option sets render as a selector and cycle with ←/→ or Space.
    pub choices: &'static [(&'static str, &'static str)],
}
impl std::fmt::Debug for FormField {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FormField")
            .field("key", &self.key)
            .field("value", &if self.secret { "[masked]" } else { &self.value })
            .finish()
    }
}
#[derive(Debug, Clone)]
pub struct TerminalForm {
    pub kind: FormKind,
    pub title: String,
    pub fields: Vec<FormField>,
    pub original_fields: Vec<FormField>,
    pub cursor: usize,
    pub selected: usize,
    pub editing: bool,
    pub notice: String,
    pub items: Vec<Value>,
    pub item_selected: usize,
}
#[derive(Debug, Clone, Copy)]
pub struct CommandSpec {
    pub name: &'static str,
    pub description: &'static str,
    pub usage: &'static str,
}

pub const ENABLED_CHOICES: &[(&str, &str)] = &[("true", "开启"), ("false", "关闭")];
pub const API_FORMAT_CHOICES: &[(&str, &str)] = &[
    ("auto", "自动"),
    ("openAiCompatible", "OpenAI 兼容"),
    ("openAiResponses", "Responses"),
    ("anthropicMessages", "Anthropic"),
    ("geminiNative", "Gemini"),
];
pub const AUTH_CHOICES: &[(&str, &str)] = &[("apiKey", "API Key"), ("none", "无需认证")];
pub const TRANSPORT_CHOICES: &[(&str, &str)] = &[("stdio", "本地程序"), ("http", "远程 HTTP")];

pub fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
pub fn items<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v[key].as_array().map(Vec::as_slice).unwrap_or(&[])
}
pub fn model_source_key(model: &Value) -> &str {
    if text(model, "source") == "路由组" || text(model, "source_id").is_empty() {
        text(model, "source")
    } else {
        text(model, "source_id")
    }
}
pub fn current_model(model: &Value, session: &Value) -> bool {
    if !session["model_choice"].is_null() && model["choice"] == session["model_choice"] {
        return true;
    }
    if text(session, "model_choice").starts_with("__") {
        return false;
    }
    text(model, "id") == text(session, "model")
        && (text(session, "model_source_id").is_empty()
            || model["source_id"] == session["model_source_id"])
}
#[derive(Clone, PartialEq)]
pub struct Command {
    pub method: String,
    pub params: Value,
}
impl std::fmt::Debug for Command {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut params = self.params.clone();
        if let Some(map) = params.as_object_mut() {
            for key in ["api_key", "token", "headers", "env"] {
                if map.contains_key(key) {
                    map.insert(key.into(), json!("[masked]"));
                }
            }
        }
        f.debug_struct("Command")
            .field("method", &self.method)
            .field("params", &params)
            .finish()
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum View {
    Chat,
    Changes,
    Agents,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Drawer {
    Shell,
    Editor,
    ToolDetail,
    Info,
    Usage,
    Diff,
    Attachments,
    Steps,
    Rounds,
    Plan,
    Tasks,
    Checkpoints,
    CheckpointReview,
    Model,
    Permissions,
    Sessions,
    Workspace,
    Help,
    History,
    Messages,
    Login,
    Effort,
    Library,
}
#[derive(Debug, Clone)]
pub struct ReadingAnchor {
    pub message_id: Option<String>,
    pub line: usize,
}
#[derive(Debug)]
pub struct App {
    pub side_panel: Option<crate::workbench::SidePanel>,
    pub side_cache: HashMap<String,crate::workbench::SidePanel>,
    pub wb_job: Option<String>,
    pub wb_poll_pending: bool,
    pub wb_epoch: u64,
    pub wb_action_pending: Option<u64>,
    pub shell_state: Value,
    pub shell_output: String,
    pub shell_start: Option<Command>,
    pub shell_poll_pending: bool,
    pub shell_follow: bool,
    pub search_target: Option<Value>,
    pub native_editor: Option<crate::native_editor::NativeEditor>,
    pub tool_detail: Value,
    pub tool_section: usize,
    pub settings_page: u8,
    /// Library contents from the host, the active tab, and a pending delete.
    pub library: Value,
    pub library_sets: bool,
    pub library_confirm: Option<String>,
    /// First-visit folder awaiting a trust decision; nothing else renders.
    pub trust_prompt: Option<String>,
    pub trust_choice: usize,
    /// Transient startup state; never persisted in a session snapshot.
    pub startup_phase: Option<StartupPhase>,
    /// Workspace still being checked or registered.
    pub workspace_pending: bool,
    /// Settings list kept visible behind a stacked add/edit dialog.
    pub form_backdrop: Option<TerminalForm>,
    pub connect_after_save: bool,
    pub info_title: String,
    pub info_lines: Vec<String>,
    pub usage_detail: Value,
    pub usage_expanded: bool,
    pub diff_detail: Value,
    pub extra_generation: u64,
    pub failures_only: bool,
    pub expanded_steps: HashSet<String>,
    pub steps_message: Option<String>,
    pub steps_round: Option<String>,
    pub snapshot: Value,
    pub snapshot_cursor: u64,
    pub thinking_updated_at: Option<(String, Instant)>,
    pub reviewed_plan: Value,
    pub checkpoint_points: Vec<Value>,
    pub checkpoint_review: Value,
    pub input: String,
    pub notice: String,
    pub drawer: Option<Drawer>,
    pub view: View,
    pub selected: usize,
    pub scroll: u16,
    pub expanded: bool,
    pub sidebar: bool,
    pub approval_collapsed: bool,
    pub approval_focus: Option<(String, usize)>,
    pub approval_pending: Option<String>,
    pub rejection: bool,
    pub exit: bool,
    pub history: Vec<String>,
    pub history_index: usize,
    pub cursor: usize,
    pub esc_at: Option<Instant>,
    pub exit_at: Option<Instant>,
    pub full_confirm: bool,
    pub ascii: bool,
    pub no_color: bool,
    pub truecolor: bool,
    pub color256: bool,
    pub light: bool,
    pub terminal_light: Option<bool>,
    pub reduce_motion: bool,
    pub ambiguous_width: u8,
    pub pet: crate::pet::Pet,
    pub completion_closed: bool,
    pub files: Vec<String>,
    pub search: String,
    pub model_source_filter: Option<String>,
    pub login_provider_editor: bool,
    pub effort_index: usize,
    pub thinking: bool,
    pub retry: Option<Value>,
    pub tick: u64,
    pub clipboard_requested: bool,
    pub attachments: Vec<Value>,
    pub question_index: usize,
    pub question_ui: crate::questions::QuestionUi,
    pub question_answers: serde_json::Map<String, Value>,
    pub pending_draft: Option<(String, Vec<Value>)>,
    pub welcome_seen: bool,
    pub suppress_welcome: bool,
    pub agent_message_id: Option<String>,
    pub agent_detail_id: Option<String>,
    pub config_warning: Option<String>,
    pub snapshot_stale: bool,
    pub snapshot_error: Option<String>,
    pub paste_collapsed: bool,
    pub long_input_expanded: bool,
    pub redraw_requested: bool,
    pub rejection_draft: Option<Draft>,
    pub session_drafts: HashMap<String, Draft>,
    pub pending_inputs: Vec<PendingInput>,
    pub pending_withdrawals: Vec<Command>,
    pub withdrawal_drafts: Vec<(Command, Draft)>,
    pub answered_questions: HashSet<(String, String)>,
    pub history_draft: Option<Draft>,
    pub history_remote: Vec<String>,
    pub history_local: Vec<String>,
    pub search_cursor: usize,
    pub recovered_inputs: Vec<PendingInput>,
    pub preferred_column: Option<usize>,
    pub pending_compactions: Vec<Command>,
    pub viewport: (u16, u16),
    pub form: Option<TerminalForm>,
    pub recent_selected: Option<usize>,
    pub recent_confirm: Option<String>,
    pub outbox: Vec<Command>,
    pub attachment_targets: Vec<(Command, Option<String>)>,
    pub file_picker_requested: bool,
    pub editor_requested: bool,
    pub skin: String,
    pub background: Option<String>,
    pub accent: Option<String>,
    pub code_style: String,
    pub form_confirm: Option<String>,
    pub form_revision: u64,
    pub pending_form: Option<(u64, Command)>,
    pub pending_form_values: Vec<FormField>,
    pub login_job: Option<String>,
    pub login_poll_pending: bool,
    pub uncertain_form_revision: Option<u64>,
    pub selection: Option<TextSelection>,
    pub selection_revision: u64,
    pub copy_requested: Option<String>,
    pub binding_ready: bool,
    pub send_after_binding: bool,
    pub deferred_paths: Vec<std::path::PathBuf>,
    pub cancel_attachments_requested: bool,
    pub reading_anchor: Option<ReadingAnchor>,
    pub unseen_output: bool,
    pub transcript_query: String,
    pub transcript_match: Option<String>,
}
impl Default for App {
    fn default() -> Self {
        Self {
            side_panel: None, side_cache: HashMap::new(), wb_job: None, wb_poll_pending: false, wb_epoch: 0, wb_action_pending: None,
            shell_state: Value::Null,
            shell_output: String::new(),
            shell_start: None,
            shell_poll_pending: false,
            shell_follow: true,
            search_target: None,
            native_editor: None,
            tool_detail: Value::Null,
            tool_section: 0,
            settings_page: 0,
            library: Value::Null,
            library_sets: false,
            library_confirm: None,
            trust_prompt: None,
            trust_choice: 0,
            startup_phase: None,
            workspace_pending: false,
            form_backdrop: None,
            connect_after_save: false,
            info_title: String::new(),
            info_lines: vec![],
            extra_generation: 0,
            failures_only: false,
            expanded_steps: HashSet::new(),
            steps_message: None,
            steps_round: None,
            usage_detail: Value::Null,
            usage_expanded: false,
            diff_detail: Value::Null,
            snapshot: json!({}),
            snapshot_cursor: 0,
            thinking_updated_at: None,
            reviewed_plan: Value::Null,
            checkpoint_points: vec![],
            checkpoint_review: Value::Null,
            input: String::new(),
            notice: String::new(),
            drawer: None,
            view: View::Chat,
            selected: 0,
            scroll: 0,
            expanded: false,
            sidebar: false,
            approval_collapsed: false,
            approval_focus: None,
            approval_pending: None,
            rejection: false,
            exit: false,
            history: vec![],
            history_index: 0,
            cursor: 0,
            esc_at: None,
            exit_at: None,
            full_confirm: false,
            ascii: false,
            no_color: false,
            truecolor: false,
            color256: false,
            light: false,
            terminal_light: None,
            reduce_motion: false,
            ambiguous_width: 1,
            pet: Default::default(),
            completion_closed: false,
            files: vec![],
            search: String::new(),
            model_source_filter: None,
            login_provider_editor: false,
            effort_index: 0,
            thinking: true,
            retry: None,
            tick: 0,
            clipboard_requested: false,
            attachments: vec![],
            question_index: 0,
            question_ui: crate::questions::QuestionUi::default(),
            question_answers: serde_json::Map::new(),
            pending_draft: None,
            welcome_seen: false,
            suppress_welcome: false,
            agent_message_id: None,
            agent_detail_id: None,
            config_warning: None,
            snapshot_stale: false,
            snapshot_error: None,
            paste_collapsed: false,
            long_input_expanded: false,
            redraw_requested: false,
            rejection_draft: None,
            session_drafts: HashMap::new(),
            pending_inputs: vec![],
            pending_withdrawals: vec![],
            withdrawal_drafts: vec![],
            answered_questions: HashSet::new(),
            history_draft: None,
            history_remote: vec![],
            history_local: vec![],
            search_cursor: 0,
            recovered_inputs: vec![],
            preferred_column: None,
            pending_compactions: vec![],
            viewport: (80, 24),
            form: None,
            recent_selected: None,
            recent_confirm: None,
            outbox: vec![],
            attachment_targets: vec![],
            file_picker_requested: false,
            editor_requested: false,
            skin: "terminal".into(),
            form_confirm: None,
            form_revision: 0,
            pending_form: None,
            pending_form_values: vec![],
            login_job: None,
            login_poll_pending: false,
            uncertain_form_revision: None,
            selection: None,
            selection_revision: 0,
            copy_requested: None,
            binding_ready: true,
            send_after_binding: false,
            deferred_paths: vec![],
            cancel_attachments_requested: false,
            reading_anchor: None,
            unseen_output: false,
            transcript_query: String::new(),
            transcript_match: None,
            background: None,
            accent: None,
            code_style: "auto".into(),
        }
    }
}
impl App {
    pub fn start_selection(&mut self, buffer: ratatui::buffer::Buffer, x: u16, y: u16) {
        self.selection_revision = self.selection_revision.wrapping_add(1);
        self.selection = Some(TextSelection {
            start: (x, y),
            end: (x, y),
            buffer,
            dragging: true,
            revision: self.selection_revision,
        });
    }
    pub fn update_selection(&mut self, x: u16, y: u16, dragging: bool) {
        if let Some(selection) = self.selection.as_mut() {
            selection.end = (
                x.min(selection.buffer.area.right().saturating_sub(1)),
                y.min(selection.buffer.area.bottom().saturating_sub(2)),
            );
            selection.dragging = dragging;
        }
    }
    pub fn selection_contains(&self, x: u16, y: u16) -> bool {
        self.selection.as_ref().is_some_and(|s| s.contains(x, y))
    }
    pub fn recent_sessions(&self) -> Vec<Value> {
        items(&self.snapshot, "sessions")
            .iter()
            .filter(|s| {
                s["id"] != self.snapshot["session"]["id"]
                    && s["empty"] != true
                    && (self.snapshot["session"]["workspace_id"].is_null()
                        || s["workspace_id"] == self.snapshot["session"]["workspace_id"])
            })
            .take(3)
            .cloned()
            .collect()
    }
    fn move_recent(&mut self, direction: i32) {
        let len = self.recent_sessions().len();
        if len == 0 {
            return;
        }
        self.recent_selected = Some(match self.recent_selected {
            None => {
                if direction < 0 {
                    len - 1
                } else {
                    0
                }
            }
            Some(i) => {
                if direction < 0 {
                    i.saturating_sub(1)
                } else {
                    (i + 1).min(len - 1)
                }
            }
        });
        self.recent_confirm = None;
    }
    fn activate_recent(&mut self) -> Vec<Command> {
        let Some(item) = self
            .recent_selected
            .and_then(|i| self.recent_sessions().get(i).cloned())
        else {
            return vec![];
        };
        let id = text(&item, "id").to_owned();
        if self.recent_confirm.as_deref() == Some(&id) {
            self.recent_confirm = None;
            return vec![Command {
                method: "session.open".into(),
                params: json!({"session_id":id}),
            }];
        }
        self.recent_confirm = Some(id);
        self.notice = "再次按 Enter 或再次点击该会话确认进入；Esc 取消".into();
        vec![]
    }
    pub fn click_recent(&mut self, index: usize) -> Vec<Command> {
        if self.recent_selected != Some(index) {
            self.recent_selected = Some(index);
            self.recent_confirm = None;
        }
        self.activate_recent()
    }
    pub fn import_paths(&mut self, paths: Vec<std::path::PathBuf>) -> Vec<Command> {
        if !self.binding_ready {
            self.deferred_paths.extend(paths);
            self.notice = "正在创建工作会话，附件将在会话就绪后导入".into();
            return vec![];
        }
        let mut commands = vec![];
        for path in paths {
            match crate::attachment::import_params(&path) {
                Ok(params) => {
                    let mut c = self.command("attachment.import", params);
                    self.begin_attachment_import(&mut c, self.agent_message_id.clone());
                    commands.push(c);
                }
                Err(error) => self.notice = format!("无法附加文件：{error}"),
            }
        }
        if !commands.is_empty() {
            self.notice = format!("正在导入 {} 个附件…", commands.len());
        }
        commands
    }
    pub(crate) fn field(
        key: &str,
        label: &str,
        value: &str,
        secret: bool,
        editable: bool,
    ) -> FormField {
        FormField {
            key: key.into(),
            label: label.into(),
            value: value.into(),
            secret,
            editable,
            choices: &[],
        }
    }
    pub(crate) fn choice(
        key: &str,
        label: &str,
        value: &str,
        choices: &'static [(&'static str, &'static str)],
    ) -> FormField {
        FormField {
            choices,
            ..Self::field(key, label, value, false, true)
        }
    }
    pub fn panel_rows(&self) -> Vec<String> {
        self.form
            .as_ref()
            .map(|f| f.fields.iter().map(|field| field.label.clone()).collect())
            .unwrap_or_default()
    }
    pub fn open_settings(&mut self) -> Vec<Command> {
        self.settings_page = 0;
        self.drawer = None;
        self.view = View::Chat;
        self.rebuild_settings();
        vec![self.command("settings.get", json!({}))]
    }
    pub(crate) fn rebuild_settings(&mut self) {
        let mut fields = vec![Self::field(
            "provider.new",
            "＋ 添加模型来源",
            "",
            false,
            false,
        )];
        fields.insert(
            0,
            Self::field(
                "subscriptions",
                "订阅服务 · 登录账号或连接套餐 Key",
                "",
                false,
                false,
            ),
        );
        for (i, p) in items(&self.snapshot["settings"], "providers")
            .iter()
            .enumerate()
        {
            let models = items(p, "models").len();
            let state = if p["enabled"] == false {
                "已停用".to_owned()
            } else if models > 0 {
                format!("{models} 个模型")
            } else {
                "未发现模型".to_owned()
            };
            fields.push(Self::field(
                &format!("provider.{i}"),
                &format!("模型来源 · {}", text(p, "name")),
                &state,
                false,
                false,
            ));
        }
        fields.push(Self::field("mcp.new", "＋ 添加 MCP 服务", "", false, false));
        for (i, m) in items(&self.snapshot["settings"], "mcp").iter().enumerate() {
            let state = if m["enabled"] == false {
                "已停用".to_owned()
            } else {
                let tools = items(m, "tools").len();
                let transport = if text(m, "transport") == "http" {
                    "HTTP"
                } else {
                    "stdio"
                };
                if tools > 0 {
                    format!("{transport} · {tools} 个工具")
                } else {
                    transport.to_owned()
                }
            };
            fields.push(Self::field(
                &format!("mcp.{i}"),
                &format!("MCP · {}", text(m, "name")),
                &state,
                false,
                false,
            ));
        }
        let skin = crate::theme::SKINS
            .iter()
            .find(|(id, _)| *id == self.skin)
            .map_or(self.skin.as_str(), |(_, label)| label);
        fields.push(Self::field("skin", "终端皮肤", skin, false, false));
        fields.push(Self::field(
            "context",
            "模型上下文窗口与输出预算",
            "当前模型",
            false,
            false,
        ));
        let asr = &self.snapshot["settings"]["asr"];
        fields.push(Self::field(
            "asr",
            "语音识别 · 音频附件转写",
            if asr["enabled"] == true {
                text(asr, "model")
            } else {
                "未启用"
            },
            false,
            false,
        ));
        fields.push(Self::field(
            "attach",
            "添加文件、图片、视频或音频",
            "",
            false,
            false,
        ));
        self.form_revision = self.form_revision.wrapping_add(1);
        self.form_backdrop = None;
        if self.settings_page == 1 {
            fields.retain(|f| f.key.starts_with("provider."));
        }
        if self.settings_page == 2 {
            fields.retain(|f| f.key.starts_with("mcp."));
        }
        self.form = Some(TerminalForm {
            kind: FormKind::Settings,
            title: match self.settings_page {
                1 => "连接提供商",
                2 => "MCP 服务",
                _ => "终端设置",
            }
            .into(),
            original_fields: fields.clone(),
            cursor: fields.first().map_or(0, |field| field.value.len()),
            fields,
            selected: 0,
            editing: false,
            notice: String::new(),
            items: vec![],
            item_selected: 0,
        });
    }
    pub(crate) fn edit_provider(&mut self, item: Value) {
        self.login_provider_editor = false;
        self.connect_after_save = self.settings_page == 1 && text(&item, "id").is_empty();
        let models = items(&item, "models")
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(",");
        let mut fields = vec![
            Self::field("id", "来源 ID", text(&item, "id"), false, false),
            Self::field("name", "名称", text(&item, "name"), false, true),
            Self::choice(
                "api_format",
                "协议",
                item["api_format"].as_str().unwrap_or("auto"),
                API_FORMAT_CHOICES,
            ),
            Self::choice(
                "auth_mode",
                "认证",
                item["auth_mode"].as_str().unwrap_or("apiKey"),
                AUTH_CHOICES,
            ),
            Self::field("base_url", "API 地址", text(&item, "base_url"), false, true),
            Self::field("models", "模型 ID（逗号分隔）", &models, false, true),
            Self::field(
                "chat_model",
                "默认模型",
                text(&item, "chat_model"),
                false,
                true,
            ),
            Self::field(
                "reasoner_model",
                "推理模型",
                text(&item, "reasoner_model"),
                false,
                true,
            ),
            Self::field("api_key", "API Key", "", true, true),
            Self::choice(
                "enabled",
                "启用",
                if item["enabled"] == false {
                    "false"
                } else {
                    "true"
                },
                ENABLED_CHOICES,
            ),
            Self::field("__save", "保存来源", "", false, false),
            Self::field("__scan", "发现模型（保存后可用）", "", false, false),
            Self::field("__remove", "删除来源（需二次确认）", "", false, false),
        ];
        if matches!(text(&item, "auth_mode"), "chatgpt" | "kimiCode") {
            for field in &mut fields {
                if ["auth_mode", "base_url", "api_key", "clear_key"].contains(&field.key.as_str()) {
                    field.editable = false;
                    field.choices = &[];
                    if field.key == "api_key" {
                        field.label = "账号授权（无需填写 Key）".into();
                    }
                }
            }
        }
        let new = text(&item, "id").is_empty();
        self.stack_dialog();
        self.form_revision = self.form_revision.wrapping_add(1);
        self.form = Some(TerminalForm {
            kind: FormKind::Provider,
            title: if self.connect_after_save {
                "连接新提供商"
            } else if new {
                "添加模型来源"
            } else {
                "编辑模型来源"
            }
            .into(),
            original_fields: fields.clone(),
            cursor: fields.get(1).map_or(0, |field| field.value.len()),
            fields,
            selected: 1,
            editing: true,
            notice: String::new(),
            items: vec![item],
            item_selected: 0,
        });
    }
    pub(crate) fn edit_mcp(&mut self, item: Value) {
        let args = items(&item, "args")
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join("\n");
        let fields = vec![
            Self::field("id", "服务 ID", text(&item, "id"), false, false),
            Self::field("name", "名称", text(&item, "name"), false, true),
            Self::choice(
                "transport",
                "传输",
                item["transport"].as_str().unwrap_or("stdio"),
                TRANSPORT_CHOICES,
            ),
            Self::field("command", "程序", text(&item, "command"), false, true),
            Self::field("args", "参数（每行一个）", &args, false, true),
            Self::field(
                "working_directory",
                "工作目录",
                text(&item, "working_directory"),
                false,
                true,
            ),
            Self::field(
                "base_url",
                "HTTP 地址",
                text(&item, "base_url"),
                false,
                true,
            ),
            Self::field("env", "环境变量 JSON", "", true, true),
            Self::field("headers", "HTTP 头 JSON", "", true, true),
            Self::field("token", "访问令牌", "", true, true),
            Self::choice(
                "enabled",
                "启用",
                if item["enabled"] == false {
                    "false"
                } else {
                    "true"
                },
                ENABLED_CHOICES,
            ),
            Self::field("__save", "保存 MCP 服务", "", false, false),
            Self::field("__connect", "连接并发现工具（需确认）", "", false, false),
            Self::field("__disconnect", "断开并停用（需确认）", "", false, false),
            Self::field("__tools", "查看已发现工具", "", false, false),
            Self::choice(
                "selected",
                "本会话使用",
                if item["selected"] == true {
                    "true"
                } else {
                    "false"
                },
                ENABLED_CHOICES,
            ),
            Self::field("__bind", "应用本会话选用（需确认）", "", false, false),
            Self::field("__scan", "连接并发现工具（需确认）", "", false, false),
            Self::field("__remove", "删除 MCP 服务（需二次确认）", "", false, false),
        ];
        let new = text(&item, "id").is_empty();
        self.stack_dialog();
        self.form_revision = self.form_revision.wrapping_add(1);
        self.form = Some(TerminalForm {
            kind: FormKind::Mcp,
            title: if new {
                "添加 MCP 服务"
            } else {
                "编辑 MCP 服务"
            }
            .into(),
            original_fields: fields.clone(),
            cursor: fields.get(1).map_or(0, |field| field.value.len()),
            fields,
            selected: 1,
            editing: true,
            notice: String::new(),
            items: vec![item],
            item_selected: 0,
        });
    }
    /// Opening an editor from the settings list layers it above that list.
    fn stack_dialog(&mut self) {
        match self.form.take() {
            Some(form) if form.kind == FormKind::Settings => self.form_backdrop = Some(form),
            None => self.form_backdrop = None,
            Some(_) => {}
        }
    }
    pub fn open_skin(&mut self) {
        self.drawer = None;
        self.view = View::Chat;
        let mut fields = crate::theme::SKINS
            .iter()
            .map(|(id, label)| Self::field(id, label, "", false, false))
            .collect::<Vec<_>>();
        fields.push(Self::field(
            "__custom",
            "自定义背景、强调色与代码配色",
            "",
            false,
            false,
        ));
        self.form_revision = self.form_revision.wrapping_add(1);
        self.form = Some(TerminalForm {
            kind: FormKind::Skin,
            title: "终端皮肤".into(),
            original_fields: fields.clone(),
            cursor: fields.first().map_or(0, |field| field.value.len()),
            fields,
            selected: crate::theme::SKINS
                .iter()
                .position(|(id, _)| *id == self.skin)
                .unwrap_or(0),
            editing: false,
            notice: "方向键或点击预览 · Enter 应用并保存 · Esc 返回".into(),
            items: vec![],
            item_selected: 0,
        });
    }
    fn edit_asr(&mut self) {
        let item = &self.snapshot["settings"]["asr"];
        let fields = vec![
            Self::field(
                "base_url",
                "音频服务 API 地址",
                text(item, "base_url"),
                false,
                true,
            ),
            Self::field(
                "model",
                "语音模型（如 whisper-1 或 mimo）",
                text(item, "model"),
                false,
                true,
            ),
            Self::field("api_key", "API Key", "", true, true),
            Self::choice(
                "enabled",
                "启用",
                if item["enabled"] == true {
                    "true"
                } else {
                    "false"
                },
                ENABLED_CHOICES,
            ),
            Self::field("__save", "保存语音识别配置", "", false, false),
        ];
        self.stack_dialog();
        self.form_revision = self.form_revision.wrapping_add(1);
        self.form = Some(TerminalForm {
            kind: FormKind::Asr,
            title: "语音识别".into(),
            original_fields: fields.clone(),
            cursor: fields.first().map_or(0, |field| field.value.len()),
            fields,
            selected: 0,
            editing: true,
            notice: "支持 OpenAI 转写与 MiMo 音频识别".into(),
            items: vec![],
            item_selected: 0,
        });
    }
    fn sync_appearance(&mut self, config: crate::config::Config) {
        self.config_warning = None;
        self.skin = config.skin;
        self.background = config.background;
        self.accent = config.accent;
        self.code_style = config.code_style;
        self.light = crate::theme::appearance_is_light(
            &self.skin,
            self.background.as_deref(),
            self.terminal_light
                .unwrap_or_else(|| crate::theme::light(None)),
        );
        self.truecolor = true;
        self.redraw_requested = true;
    }
    fn apply_skin(&mut self, name: &str) {
        let name = crate::theme::SKINS
            .iter()
            .find(|(id, label)| *id == name || *label == name)
            .map_or(name, |(id, _)| *id);
        match crate::config::save_skin(name) {
            Ok(config) => {
                self.sync_appearance(config);
                self.notice = format!("已应用皮肤：{name}");
                self.form = None;
            }
            Err(error) => {
                self.notice = format!("无法保存皮肤：{error}");
                if let Some(form) = self.form.as_mut() {
                    form.notice = self.notice.clone();
                }
            }
        }
    }
    pub fn close_popup(&mut self) {
        if self.drawer == Some(Drawer::Editor) {
            let commands = self.finish_native_editor(false);
            self.outbox.extend(commands);
            return;
        }
        if self
            .form
            .as_ref()
            .is_some_and(|f| f.kind == FormKind::Management)
        {
            let commands = self.management_cancel();
            self.outbox.extend(commands);
        }
        if self.question_popup_visible() {
            self.hide_questions();
            return;
        }
        if self.form.is_some() && !self.confirm_form_close() {
            return;
        }
        self.form = None;
        self.form_backdrop = None;
        self.drawer = None;
        self.form_confirm = None;
        self.full_confirm = false;
        self.form_revision = self.form_revision.wrapping_add(1);
    }
    fn confirm_form_close(&mut self) -> bool {
        let Some(form) = &mut self.form else {
            return true;
        };
        let dirty = form.fields.iter().any(|field| {
            field.editable
                && form
                    .original_fields
                    .iter()
                    .find(|v| v.key == field.key)
                    .is_none_or(|original| original.value != field.value)
        });
        if dirty {
            let marker = format!("discard:{}", self.form_revision);
            if self.form_confirm.as_ref() != Some(&marker) {
                self.form_confirm = Some(marker);
                form.notice = "有未保存修改；再次关闭或按 Esc 放弃，继续编辑则保留。".into();
                return false;
            }
        }
        true
    }
    pub fn click_form_field(&mut self, index: usize) -> Vec<Command> {
        let Some(form) = self.form.as_mut() else {
            return vec![];
        };
        let Some(field) = form.fields.get(index) else {
            return vec![];
        };
        if form.selected != index {
            self.form_confirm = None;
        }
        form.selected = index;
        form.editing = field.editable;
        form.cursor = field.value.len();
        if field.editable && !field.choices.is_empty() {
            self.form_key(KeyEvent::from(KeyCode::Right))
        } else if field.editable {
            vec![]
        } else {
            self.form_activate()
        }
    }
    fn form_key(&mut self, key: KeyEvent) -> Vec<Command> {
        if crate::palette::is_picker(self) && key.modifiers.is_empty() {
            let cols = crate::palette::layout(self, self.viewport.0, self.viewport.1).columns;
            let form = self.form.as_mut().unwrap();
            let count = form.fields.len();
            match key.code {
                KeyCode::Left => form.selected = form.selected.saturating_sub(1),
                KeyCode::Right | KeyCode::Tab => form.selected = (form.selected + 1) % count,
                KeyCode::Up => form.selected = form.selected.saturating_sub(cols),
                KeyCode::Down => form.selected = (form.selected + cols).min(count - 1),
                KeyCode::Home => form.selected = 0,
                KeyCode::End => form.selected = count - 1,
                KeyCode::Enter => return self.form_activate(),
                KeyCode::Esc => {
                    self.form = None;
                    return vec![];
                }
                _ => return vec![],
            }
            return vec![];
        }
        if key.code == KeyCode::Esc
            && self
                .form
                .as_ref()
                .is_some_and(|f| f.kind == FormKind::Management)
        {
            let commands = self.management_cancel();
            if !commands.is_empty() {
                self.form = None;
                self.form_revision = self.form_revision.wrapping_add(1);
                return commands;
            }
        }
        if key.code == KeyCode::Esc
            && self
                .form
                .as_ref()
                .is_some_and(|f| f.kind == FormKind::LoginProgress)
        {
            let commands = self.cancel_login();
            self.form = None;
            self.form_revision = self.form_revision.wrapping_add(1);
            return commands;
        }
        if key.code == KeyCode::Esc {
            if self.form.as_ref().unwrap().editing {
                self.form.as_mut().unwrap().editing = false;
                return vec![];
            }
            if !self.confirm_form_close() {
                return vec![];
            }
            let kind = self.form.as_ref().unwrap().kind;
            self.form = None;
            self.form_confirm = None;
            if kind == FormKind::Provider && self.login_provider_editor {
                self.login_provider_editor = false;
                return self.open_login();
            }
            if matches!(kind, FormKind::Provider | FormKind::Mcp | FormKind::Asr) {
                self.rebuild_settings();
            }
            return vec![];
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl && key.code == KeyCode::Char('c') && self.active() {
            return vec![self.command("task.stop", json!({}))];
        }
        if key.code == KeyCode::Char('v')
            && key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            self.clipboard_requested = true;
            return vec![];
        }
        if (ctrl && key.code == KeyCode::Char('j'))
            || (key.modifiers.contains(KeyModifiers::ALT) && key.code == KeyCode::Char('j'))
            || (key.code == KeyCode::Enter
                && key
                    .modifiers
                    .intersects(KeyModifiers::SHIFT | KeyModifiers::ALT | KeyModifiers::CONTROL))
        {
            if let Some(form) = self.form.as_mut()
                && let Some(field) = form.fields.get_mut(form.selected)
                && field.editable
                && matches!(
                    field.key.as_str(),
                    "args"
                        | "env"
                        | "headers"
                        | "prompt"
                        | "user_pins"
                        | "command"
                        | "remote_forward"
                )
            {
                form.cursor = text_cursor(&field.value, form.cursor);
                field.value.insert(form.cursor, '\n');
                form.cursor += 1;
            }
            return vec![];
        }
        if ctrl && key.code == KeyCode::Char('l') {
            self.redraw_requested = true;
            return vec![];
        }
        let form = self.form.as_mut().unwrap();
        let len = form.fields.len();
        if len == 0 {
            return vec![];
        }
        let choices = form.fields[form.selected].choices;
        if !choices.is_empty()
            && matches!(
                key.code,
                KeyCode::Left | KeyCode::Right | KeyCode::Char(' ')
            )
        {
            let field = &mut form.fields[form.selected];
            let current = choices
                .iter()
                .position(|(v, _)| *v == field.value)
                .unwrap_or(0);
            let next = if key.code == KeyCode::Left {
                current.checked_sub(1).unwrap_or(choices.len() - 1)
            } else {
                (current + 1) % choices.len()
            };
            field.value = choices[next].0.into();
            form.cursor = field.value.len();
            self.form_confirm = None;
            // A context preset fills the window field it stands for.
            if form.kind == FormKind::Context
                && form.fields[form.selected].key == "preset"
                && form.fields[form.selected].value != "custom"
            {
                let preset = form.fields[form.selected].value.clone();
                if let Some(window) = form.fields.iter_mut().find(|f| f.key == "window") {
                    window.value = preset;
                }
            }
            if form.kind == FormKind::Context && form.fields[form.selected].key == "output_mode" {
                self.sync_context_output();
            }
            return vec![];
        }
        let typed = choices.is_empty();
        match key.code {
            KeyCode::Tab | KeyCode::Down => {
                form.selected = (form.selected + 1) % len;
                form.cursor = form.fields[form.selected].value.len();
                form.editing = form.fields[form.selected].editable;
                self.form_confirm = None;
            }
            KeyCode::BackTab | KeyCode::Up => {
                form.selected = form.selected.checked_sub(1).unwrap_or(len - 1);
                form.cursor = form.fields[form.selected].value.len();
                form.editing = form.fields[form.selected].editable;
                self.form_confirm = None;
            }
            KeyCode::Backspace => {
                if form.fields[form.selected].editable && typed {
                    let value = &mut form.fields[form.selected].value;
                    form.cursor = text_cursor(value, form.cursor);
                    let previous = value[..form.cursor]
                        .char_indices()
                        .next_back()
                        .map_or(0, |(i, _)| i);
                    value.drain(previous..form.cursor);
                    form.cursor = previous;
                }
            }
            KeyCode::Left => {
                let value = &form.fields[form.selected].value;
                form.cursor = value[..text_cursor(value, form.cursor)]
                    .char_indices()
                    .next_back()
                    .map_or(0, |(i, _)| i);
            }
            KeyCode::Right => {
                let value = &form.fields[form.selected].value;
                if let Some(c) = value[text_cursor(value, form.cursor)..].chars().next() {
                    form.cursor += c.len_utf8();
                }
            }
            KeyCode::Home => form.cursor = 0,
            KeyCode::End => form.cursor = form.fields[form.selected].value.len(),
            KeyCode::Delete if form.fields[form.selected].editable && typed => {
                let value = &mut form.fields[form.selected].value;
                if let Some(c) = value[text_cursor(value, form.cursor)..].chars().next() {
                    value.drain(form.cursor..form.cursor + c.len_utf8());
                }
            }
            KeyCode::Char('u') if ctrl && form.fields[form.selected].editable && typed => {
                form.fields[form.selected].value.clear();
                form.cursor = 0;
            }
            KeyCode::Char(c) if !ctrl => {
                if form.fields[form.selected].editable && typed {
                    let value = &mut form.fields[form.selected].value;
                    form.cursor = text_cursor(value, form.cursor);
                    value.insert(form.cursor, c);
                    form.cursor += c.len_utf8();
                    form.editing = true;
                    self.form_confirm = None;
                }
            }
            KeyCode::Enter => return self.form_activate(),
            _ => {}
        }
        if let Some(form) = self.form.as_mut()
            && form.kind == FormKind::Context
            && form
                .fields
                .get(form.selected)
                .is_some_and(|f| f.key == "window")
        {
            let preset = crate::commands::context_preset(&form.fields[form.selected].value);
            if let Some(field) = form.fields.iter_mut().find(|f| f.key == "preset") {
                field.value = preset;
            }
        }
        vec![]
    }
    fn form_activate(&mut self) -> Vec<Command> {
        if let Some(commands) = self.extra_form_action() {
            return commands;
        }
        let form = self.form.as_ref().unwrap().clone();
        let field = &form.fields[form.selected];
        if field.key.starts_with("__") && self.uncertain_form_revision == Some(self.form_revision) {
            self.form.as_mut().unwrap().notice =
                "上次操作结果未知；请返回设置，核对最新来源/服务后重新打开。未自动重发。".into();
            return vec![];
        }
        if field.key.starts_with("__") && self.pending_form.is_some() {
            self.form.as_mut().unwrap().notice = "上一项操作仍在处理中，请等待响应".into();
            return vec![];
        }
        if form.kind == FormKind::Settings {
            match field.key.as_str() {
                "subscriptions" => return self.open_login(),
                "provider.new" => self.edit_provider(json!({})),
                "mcp.new" => self.edit_mcp(json!({})),
                "attach" => {
                    self.form = None;
                    self.form_revision = self.form_revision.wrapping_add(1);
                    self.clipboard_requested = true;
                }
                "skin" => self.open_skin(),
                "context" => return self.open_context_settings(),
                "asr" => self.edit_asr(),
                key if key.starts_with("provider.") => {
                    if let Ok(i) = key[9..].parse::<usize>() {
                        self.edit_provider(self.snapshot["settings"]["providers"][i].clone());
                    }
                }
                key if key.starts_with("mcp.") => {
                    if let Ok(i) = key[4..].parse::<usize>() {
                        self.edit_mcp(self.snapshot["settings"]["mcp"][i].clone());
                    }
                }
                _ => {}
            }
            return vec![];
        }
        if form.kind == FormKind::Skin {
            if field.key == "__custom" {
                let styles = crate::theme::CODE_STYLES
                    .iter()
                    .map(|(id, _)| *id)
                    .collect::<Vec<_>>()
                    .join("/");
                let fields = vec![
                    Self::field(
                        "background",
                        "背景色 #RRGGBB（空白跟随皮肤）",
                        self.background.as_deref().unwrap_or(""),
                        false,
                        true,
                    ),
                    Self::field(
                        "accent",
                        "强调色 #RRGGBB（空白跟随皮肤）",
                        self.accent.as_deref().unwrap_or(""),
                        false,
                        true,
                    ),
                    Self::field(
                        "code_style",
                        &format!("代码配色 {styles}"),
                        &self.code_style,
                        false,
                        true,
                    ),
                    Self::field("__apply", "应用并保存自定义外观", "", false, false),
                ];
                self.form_revision = self.form_revision.wrapping_add(1);
                self.form = Some(TerminalForm {
                    kind: FormKind::Skin,
                    title: "自定义终端外观".into(),
                    original_fields: fields.clone(),
                    cursor: fields.first().map_or(0, |field| field.value.len()),
                    fields,
                    selected: 0,
                    editing: true,
                    notice: "Tab 切字段 · Ctrl+U 清空 · Enter 下一项/应用".into(),
                    items: vec![],
                    item_selected: 0,
                });
            } else if field.editable {
                self.form.as_mut().unwrap().selected = (form.selected + 1) % form.fields.len();
            } else if field.key == "__apply" {
                let value = |name: &str| {
                    form.fields
                        .iter()
                        .find(|f| f.key == name)
                        .map(|f| f.value.as_str())
                        .unwrap_or("")
                };
                match crate::config::save_appearance(
                    &self.skin,
                    (!value("background").is_empty()).then(|| value("background")),
                    (!value("accent").is_empty()).then(|| value("accent")),
                    value("code_style"),
                ) {
                    Ok(config) => {
                        self.sync_appearance(config);
                        self.form = None;
                        self.notice = "自定义外观已保存".into();
                    }
                    Err(error) => self.form.as_mut().unwrap().notice = error.to_string(),
                }
            } else {
                self.apply_skin(&field.key);
            }
            return vec![];
        }
        if field.editable {
            let current = self.form.as_mut().unwrap();
            if !current.editing {
                current.editing = true;
            } else {
                current.selected = (form.selected + 1) % form.fields.len();
                current.cursor = current.fields[current.selected].value.len();
                current.editing = current.fields[current.selected].editable;
            }
            return vec![];
        }
        let get = |key: &str| {
            form.fields
                .iter()
                .find(|f| f.key == key)
                .map(|f| f.value.clone())
                .unwrap_or_default()
        };
        let prefix = if form.kind == FormKind::Asr {
            "asr"
        } else if form.kind == FormKind::Provider {
            "provider"
        } else {
            "mcp"
        };
        // Identity belongs to the opened object, never to editable field data.
        let id = form
            .items
            .first()
            .map(|item| text(item, "id"))
            .unwrap_or("")
            .to_owned();
        if field.key == "__remove"
            || field.key == "__bind"
            || (field.key == "__scan" && form.kind == FormKind::Mcp)
        {
            let confirmation = format!("{prefix}:{}:{id}", field.key);
            if self.form_confirm.as_ref() != Some(&confirmation) {
                self.form_confirm = Some(confirmation);
                self.form.as_mut().unwrap().notice =
                    if field.key == "__scan" && get("transport") == "stdio" {
                        "将启动 MCP 程序并发现工具；再次 Enter 确认，Esc 取消"
                    } else if field.key == "__bind" {
                        "将改变当前会话可用工具；再次 Enter 确认，Esc 取消"
                    } else {
                        "再次按 Enter 确认此操作；Esc 取消"
                    }
                    .into();
                return vec![];
            }
        }
        if field.key == "__remove" || field.key == "__scan" || field.key == "__bind" {
            if id.is_empty() {
                self.form.as_mut().unwrap().notice = "请先保存，再执行此操作".into();
                return vec![];
            }
            self.form_confirm = None;
            let command = self.command(
                &format!(
                    "{prefix}.{}",
                    if field.key == "__bind" {
                        "bind"
                    } else if field.key == "__remove" {
                        "remove"
                    } else {
                        "scan"
                    }
                ),
                json!({"id":id,"confirmed":true,"selected":get("selected")=="true"}),
            );
            self.pending_form = Some((self.form_revision, command.clone()));
            return vec![command];
        }
        if field.key != "__save" {
            return vec![];
        }
        let mut params = json!({"name":get("name"),"enabled":get("enabled")!="false"});
        if !id.is_empty() {
            params["id"] = json!(id);
        }
        if form.kind == FormKind::Asr {
            params = json!({"base_url":get("base_url"),"model":get("model"),"enabled":get("enabled")=="true"});
            if !get("api_key").is_empty() {
                params["api_key"] = json!(get("api_key"));
            }
        } else if form.kind == FormKind::Provider {
            for name in [
                "api_format",
                "auth_mode",
                "base_url",
                "chat_model",
                "reasoner_model",
            ] {
                params[name] = json!(get(name));
            }
            params["models"] = json!(
                get("models")
                    .split([',', '\n'])
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
            );
            if !get("api_key").is_empty() {
                params["api_key"] = json!(get("api_key"));
            }
        } else {
            for name in ["transport", "command", "working_directory", "base_url"] {
                params[name] = json!(get(name));
            }
            params["args"] = json!(
                get("args")
                    .lines()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
            );
            for name in ["env", "headers"] {
                let raw = get(name);
                if !raw.trim().is_empty() {
                    match serde_json::from_str::<Value>(&raw) {
                        Ok(value) if value.is_object() => params[name] = value,
                        _ => {
                            self.form.as_mut().unwrap().notice = format!("{name} 必须是 JSON 对象");
                            return vec![];
                        }
                    }
                }
            }
            if !get("token").is_empty() {
                params["token"] = json!(get("token"));
            }
        }
        self.form.as_mut().unwrap().notice = "正在保存…".into();
        self.pending_form_values = self.form.as_ref().unwrap().fields.clone();
        let command = self.command(&format!("{prefix}.save"), params);
        self.pending_form = Some((self.form_revision, command.clone()));
        vec![command]
    }
    pub fn apply_event(&mut self, envelope: &Value) -> anyhow::Result<()> {
        anyhow::ensure!(envelope["v"] == 1, "unsupported protocol version");
        let d = &envelope["data"];
        if self.reading_anchor.is_some()
            && matches!(
                text(envelope, "event"),
                "assistant.delta" | "step.started" | "step.updated" | "step.ended"
            )
        {
            self.unseen_output = true;
        }
        match text(envelope, "event") {
            "snapshot" => {
                self.apply_snapshot(d.clone());
                self.snapshot_cursor = envelope["cursor"].as_u64().unwrap_or(0);
            }
            "snapshot.patch" => {
                let next = if d["base"].as_u64() == Some(self.snapshot_cursor)
                    && self.snapshot_cursor != 0
                {
                    crate::snapshot_patch::apply(&self.snapshot, d).ok()
                } else {
                    None
                };
                if let Some(next) = next {
                    self.apply_snapshot(next);
                    self.snapshot_cursor = d["cursor"].as_u64().unwrap_or(0);
                } else {
                    self.set_snapshot_error("状态增量不连续，正在重新读取完整快照");
                    self.outbox.push(self.command("snapshot.get", json!({})));
                }
            }
            "assistant.delta" => {
                let id = text(d, "message_id");
                if !self.snapshot["messages"].is_array() {
                    self.snapshot["messages"] = json!([]);
                }
                let messages = self.snapshot["messages"].as_array_mut().unwrap();
                if let Some(m) = messages.iter_mut().find(|m| text(m, "id") == id) {
                    m["text"] = json!(format!("{}{}", text(m, "text"), text(d, "text")));
                } else {
                    messages.push(json!({"id":id,"role":"assistant","text":text(d,"text")}));
                }
            }
            "step.started" | "step.updated" | "step.ended" => self.upsert("steps", d),
            "agent.updated" => self.upsert("agents", d),
            "approval.requested" => {
                let previous = self.snapshot["approvals"][0]["id"].clone();
                self.upsert("approvals", d);
                if previous != self.snapshot["approvals"][0]["id"] {
                    self.approval_focus = None;
                    self.approval_pending = None;
                }
                self.approval_collapsed = false;
            }
            "changes.updated" => self.snapshot["changes"] = d["changes"].clone(),
            "round.started" | "round.ended" => {
                for k in ["round", "round_limit", "status"] {
                    if !d[k].is_null() {
                        self.snapshot["session"][k] = d[k].clone();
                    }
                }
            }
            "usage.updated" => {
                self.snapshot["session"]["usage"] = d["usage"].clone();
            }
            "context.updated" => {
                self.snapshot["session"]["context_percent"] = d["context_percent"].clone()
            }
            "request.retry" => {
                self.retry = if d["active"] == false {
                    None
                } else {
                    Some(d.clone())
                }
            }
            "request.error" => {
                if d["scope"] == "snapshot" {
                    self.set_snapshot_error(text(d, "message"));
                    return Ok(());
                }
                self.notice = text(d, "message").to_owned();
                self.retry = None;
            }
            "thinking.started" | "thinking.ended" => {}
            other => anyhow::bail!("unsupported event: {other}"),
        }
        Ok(())
    }
    fn upsert(&mut self, key: &str, d: &Value) {
        if !self.snapshot[key].is_array() {
            self.snapshot[key] = json!([]);
        }
        let list = self.snapshot[key].as_array_mut().unwrap();
        if let Some(old) = list.iter_mut().find(|x| x["id"] == d["id"]) {
            *old = d.clone();
        } else {
            list.push(d.clone());
        }
    }
    pub fn apply_snapshot(&mut self, snapshot: Value) {
        self.before_question_snapshot(&snapshot);
        let latest = items(&snapshot, "messages").last();
        if let Some(message) =
            latest.filter(|m| m["role"] == "assistant" && !text(m, "thinking").is_empty())
        {
            let id = text(message, "id");
            let previous = items(&self.snapshot, "messages").last();
            if self.snapshot["session"]["id"] != snapshot["session"]["id"]
                || self
                    .thinking_updated_at
                    .as_ref()
                    .is_none_or(|(old, _)| old != id)
                || previous.is_none_or(|old| old["thinking"] != message["thinking"])
            {
                self.thinking_updated_at = Some((id.to_owned(), Instant::now()));
            }
        } else {
            self.thinking_updated_at = None;
        }
        self.snapshot_cursor = 0;
        self.snapshot_stale = false;
        self.snapshot_error = None;
        if self.reading_anchor.is_some()
            && (self.snapshot["messages"] != snapshot["messages"]
                || self.snapshot["steps"] != snapshot["steps"])
        {
            self.unseen_output = true;
        }
        let selected_agent = if self.view == View::Agents {
            let agents = items(&self.snapshot, "agents");
            agents
                .get(self.selected % agents.len().max(1))
                .map(|a| a["id"].clone())
        } else {
            None
        };
        if self.snapshot["session"]["id"] != snapshot["session"]["id"] {
            self.cancel_rejection();
            let carry = (!self.binding_ready).then(|| self.current_draft());
            if carry.is_none()
                && let Some(id) = self.session_id().map(str::to_owned)
            {
                let draft = self.current_draft();
                self.session_drafts.insert(id, draft);
            }
            let mut draft = snapshot["session"]["id"]
                .as_str()
                .and_then(|id| self.session_drafts.remove(id))
                .unwrap_or_default();
            if let Some(carry) = carry {
                if draft.text.is_empty() && draft.attachments.is_empty() {
                    draft = carry;
                } else if !carry.text.is_empty() || !carry.attachments.is_empty() {
                    self.recovered_inputs.push(PendingInput {
                        command: Command {
                            method: "draft.restore".into(),
                            params: json!({"session_id":snapshot["session"]["id"]}),
                        },
                        draft: carry,
                        question_state: None,
                    });
                    self.send_after_binding = false;
                }
            }
            self.load_draft(draft);
            self.selection = None;
            self.drawer = None;
            self.view = View::Chat;
            self.agent_detail_id = None;
            self.scroll = 0;
            self.reading_anchor = None;
            self.unseen_output = false;
            self.transcript_query.clear();
            self.transcript_match = None;
            self.selected = 0;
            self.esc_at = None;
            self.exit_at = None;
            self.notice.clear();
            self.welcome_seen = false;
            self.history.clear();
            self.history_remote.clear();
            self.history_local.clear();
            self.history_draft = None;
        }
        let remote: Vec<String> = items(&snapshot, "messages")
            .iter()
            .filter(|m| m["role"] == "user")
            .map(|m| text(m, "text").to_owned())
            .collect();
        if remote != self.history_remote {
            let browsing = self.history_index < self.history.len();
            let selected = self.history.get(self.history_index).cloned();
            for message in remote.iter().skip(self.history_remote.len()) {
                if let Some(i) = self.history_local.iter().position(|s| s == message) {
                    self.history_local.remove(i);
                }
            }
            self.history_remote = remote;
            self.history = self
                .history_remote
                .iter()
                .chain(&self.history_local)
                .cloned()
                .collect();
            self.history_index = if browsing {
                selected
                    .and_then(|s| self.history.iter().position(|v| v == &s))
                    .unwrap_or(self.history.len())
            } else {
                self.history.len()
            };
        }
        if items(&snapshot, "messages").is_empty() {
            self.welcome_seen = true;
        }
        if self.snapshot["questions"][0]["id"] != snapshot["questions"][0]["id"] {
            self.question_index = 0;
            self.question_answers.clear();
        }
        let old = items(&self.snapshot, "approvals")
            .first()
            .map(|x| x["id"].clone());
        let new = items(&snapshot, "approvals")
            .first()
            .map(|x| x["id"].clone());
        if old != new {
            self.approval_focus = None;
            self.approval_pending = None;
            self.cancel_rejection();
            self.approval_collapsed = false;
            self.rejection = false;
        }
        if let Some(id) = selected_agent
            && let Some(index) = items(&snapshot, "agents")
                .iter()
                .position(|a| a["id"] == id)
        {
            self.selected = index;
        }
        self.snapshot = snapshot;
        if self.notice == "已排队 · 等待工具边界" && items(&self.snapshot, "queued").is_empty() {
            self.notice.clear();
        }
        self.after_question_snapshot();
        self.retry = self.snapshot["session"]["retry"]
            .as_object()
            .filter(|_| {
                self.snapshot["session"]["retry"]["active"] == true
                    || (self.snapshot["session"]["retry"]["active"].is_null()
                        && self.snapshot["session"]["status"] == "retrying")
            })
            .map(|_| self.snapshot["session"]["retry"].clone());
        if self
            .recovered_inputs
            .iter()
            .any(|p| p.command.params["session_id"] == self.snapshot["session"]["id"])
        {
            self.notice = "有失败草稿待恢复；/recover 恢复原文与发送目标".into();
        }
        self.sync_pending_draft();
        self.finish_archive_search_navigation();
    }
    pub fn session_id(&self) -> Option<&str> {
        self.snapshot["session"]["id"].as_str()
    }
    pub fn status(&self) -> &str {
        if !items(&self.snapshot, "approvals").is_empty() {
            "approval"
        } else if self.retry.is_some() {
            "retrying"
        } else {
            text(&self.snapshot["session"], "status")
        }
    }
    pub fn active(&self) -> bool {
        matches!(self.status(), "running" | "approval" | "retrying")
    }
    pub fn reviewing_proposed_write(&self) -> bool {
        self.view == View::Changes && self.snapshot["approvals"][0]["tool"] == "coding_write_file"
    }
    pub fn command(&self, method: &str, mut params: Value) -> Command {
        if let Some(id) = self.session_id() {
            params["session_id"] = json!(id);
        }
        Command {
            method: method.into(),
            params,
        }
    }
    pub fn completion(&self) -> Vec<String> {
        if self.input.trim_start().starts_with('!') {
            return vec![];
        }
        if self.completion_closed || self.drawer.is_some() || self.question_popup_visible() {
            return vec![];
        }
        if self.input.starts_with('/') && !self.input.contains(' ') {
            // Dictionary order, so a command is always found in the same place.
            let mut names: Vec<String> = COMMANDS
                .iter()
                .chain(crate::commands::EXTRA_COMMANDS.iter())
                .filter(|s| crate::commands::is_primary_command(s))
                .filter(|s| s.starts_with(&self.input))
                .map(|s| s.to_string())
                .collect();
            names.sort();
            names.dedup();
            return names;
        }
        if let Some((_, q)) = self.input.rsplit_once('@') {
            return self.files.iter().filter(|s| fuzzy(s, q)).cloned().collect();
        }
        vec![]
    }
    /// Native library view; contents load from the host.
    pub fn open_library(&mut self) -> Vec<Command> {
        let tab = self.library_sets;
        if self.drawer != Some(Drawer::Library) {
            self.open(Drawer::Library);
        }
        self.library_sets = tab;
        self.library_confirm = None;
        self.extra_generation = self.extra_generation.wrapping_add(1);
        vec![self.command(
            "terminal.query",
            json!({"topic":"library","ui_generation":self.extra_generation}),
        )]
    }
    fn attach_library_item(&mut self, item: &Value) -> Vec<Command> {
        if !self.binding_ready {
            self.notice = "会话尚未就绪，稍后再加入附件".into();
            return vec![];
        }
        let mut command = self.command(
            "attachment.import",
            json!({"path":item["path"],"confirmed":true,"display_name":item["name"]}),
        );
        self.begin_attachment_import(&mut command, self.agent_message_id.clone());
        self.notice = format!("已加入草稿附件：{}", text(item, "name"));
        vec![command]
    }
    /// Drawers whose first row is a live search field.
    pub fn drawer_has_search(&self) -> bool {
        matches!(
            self.drawer,
            Some(
                Drawer::Model
                    | Drawer::Sessions
                    | Drawer::Workspace
                    | Drawer::History
                    | Drawer::Messages
                    | Drawer::Rounds
                    | Drawer::Steps
                    | Drawer::Tasks
                    | Drawer::Checkpoints
                    | Drawer::Library
            )
        )
    }
    pub fn current_model_value(&self) -> Option<Value> {
        let session = &self.snapshot["session"];
        items(&self.snapshot, "models")
            .iter()
            .find(|m| current_model(m, session))
            .cloned()
    }
    pub(crate) fn current_efforts(&self) -> Vec<Value> {
        self.current_model_value()
            .map(|m| items(&m, "efforts").to_vec())
            .unwrap_or_default()
    }
    /// Effort and thinking change on the current model; the choice stays put.
    pub(crate) fn set_effort(&mut self, effort: Value, thinking: bool) -> Vec<Command> {
        let Some(model) = self.current_model_value() else {
            self.notice = "尚未选择模型；先用 /model 选择".into();
            return vec![];
        };
        if self.active() {
            self.notice = "当前任务结束后才能调整思考强度".into();
            return vec![];
        }
        vec![self.command(
            "model.set",
            json!({"choice":model["choice"],"thinking":thinking,"effort":effort}),
        )]
    }
    pub fn open(&mut self, d: Drawer) {
        self.extra_generation = self.extra_generation.wrapping_add(1);
        if d == Drawer::Plan {
            self.reviewed_plan = self.snapshot["plan"].clone();
        }
        self.form = None;
        self.form_confirm = None;
        if self.view != View::Chat {
            self.scroll = 0;
        }
        self.view = View::Chat;
        self.agent_detail_id = None;
        self.drawer = Some(d);
        self.selected = 0;
        self.search.clear();
        self.search_cursor = 0;
        self.model_source_filter = None;
        self.full_confirm = false;
        if d == Drawer::Effort {
            let current = &self.snapshot["session"]["effort"];
            self.effort_index = self
                .current_efforts()
                .iter()
                .position(|e| e == current)
                .unwrap_or(0);
            self.thinking = self.snapshot["session"]["thinking"] != false;
        }
        if d == Drawer::Model {
            let models = self.drawer_items();
            let session = &self.snapshot["session"];
            let choice = text(session, "model_choice");
            if let Some(i) = models
                .iter()
                .position(|m| !choice.is_empty() && text(m, "choice") == choice)
                .or_else(|| {
                    models.iter().position(|m| {
                        !choice.is_empty()
                            && text(m, "id") == choice
                            && (text(session, "model_source_id").is_empty()
                                || m["source_id"] == session["model_source_id"])
                    })
                })
                .or_else(|| models.iter().position(|m| current_model(m, session)))
            {
                self.selected = i;
                let efforts = items(&models[i], "efforts");
                self.effort_index = efforts
                    .iter()
                    .position(|e| e == &self.snapshot["session"]["effort"])
                    .unwrap_or(0);
            }
            self.thinking = self.snapshot["session"]["thinking"] != false;
        }
    }
    pub fn key(&mut self, key: KeyEvent, now: Instant, width: u16) -> Vec<Command> {
        if let Some(commands)=self.side_key(key){return commands;}
        if self.drawer == Some(Drawer::Shell) {
            return self.shell_key(key);
        }
        if self.drawer == Some(Drawer::Editor) {
            self.viewport.0 = width;
            return self.native_editor_key(key);
        }
        if self.drawer == Some(Drawer::ToolDetail) {
            return self.tool_detail_key(key);
        }
        if key.modifiers.contains(KeyModifiers::ALT)
            && key.code == KeyCode::Char('e')
            && self.form.is_none()
            && self.drawer.is_none()
        {
            self.open_native_editor();
            return vec![];
        }
        self.viewport.0 = width;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl
            && key.code == KeyCode::Char('c')
            && let Some(selection) = &self.selection
        {
            let text = selection.text();
            if !text.is_empty() {
                self.copy_requested = Some(text);
            } else {
                self.notice = "选区没有可复制文字".into();
            }
            return vec![];
        }
        self.selection = None;
        if self.form.is_some() {
            return self.form_key(key);
        }
        if self.drawer.is_none()
            && key.modifiers.contains(KeyModifiers::ALT)
            && matches!(key.code, KeyCode::Up | KeyCode::Down)
        {
            crate::ui::jump_user_turn(self, if key.code == KeyCode::Up { -1 } else { 1 });
            return vec![];
        }
        if let Some(commands) = self.question_key(key) {
            return commands;
        }
        if key.modifiers.contains(KeyModifiers::ALT) && key.code == KeyCode::Char('v') {
            self.clipboard_requested = true;
            return vec![];
        }
        if key.modifiers.contains(KeyModifiers::ALT) && key.code == KeyCode::Char('j') {
            self.insert("\n");
            return vec![];
        }
        if matches!(key.code, KeyCode::Char('\n' | '\r')) && !ctrl {
            self.insert("\n");
            return vec![];
        }
        if ctrl && key.code == KeyCode::End && self.drawer.is_none() {
            self.latest_output();
            return vec![];
        }
        if !(ctrl && key.code == KeyCode::Char('c')) {
            self.exit_at = None;
        }
        if key.code != KeyCode::Esc {
            self.esc_at = None;
        }
        if key.code == KeyCode::Esc {
            if self.recent_confirm.take().is_some() || self.recent_selected.take().is_some() {
                return vec![];
            }
            if self.drawer.take().is_some() {
                self.full_confirm = false;
                if self.notice == "完全访问：再次按 enter 确认" {
                    self.notice.clear();
                }
                return vec![];
            }
            if self.agent_detail_id.take().is_some() {
                self.scroll = 0;
                return vec![];
            }
            if self.view != View::Chat {
                self.view = View::Chat;
                self.scroll = 0;
                return vec![];
            }
            if !self.completion().is_empty() {
                self.completion_closed = true;
                return vec![];
            }
            if self.agent_message_id.take().is_some() {
                self.notice = "已取消给助手发送补充要求".into();
                return vec![];
            }
            if self.status() == "approval" && !self.approval_collapsed {
                self.cancel_rejection();
                self.approval_collapsed = true;
                return vec![];
            }
            if self.active() {
                if self
                    .esc_at
                    .is_some_and(|t| now.duration_since(t) < Duration::from_millis(1500))
                {
                    self.esc_at = None;
                    return vec![self.command("task.stop", json!({}))];
                }
                self.esc_at = Some(now);
            }
            return vec![];
        }
        if ctrl {
            match key.code {
                KeyCode::Char('l') => {
                    self.redraw_requested = true;
                    return vec![];
                }
                KeyCode::Char('g') => {
                    self.drawer = None;
                    self.agent_detail_id = None;
                    self.view = View::Changes;
                    self.selected = 0;
                    self.scroll = 0;
                    return if !self.reviewing_proposed_write() {
                        items(&self.snapshot, "changes")
                            .first()
                            .map(|c| vec![self.command("changes.diff", json!({"id":c["id"]}))])
                            .unwrap_or_default()
                    } else {
                        vec![]
                    };
                }
                KeyCode::Char('t') => {
                    self.drawer = None;
                    self.agent_detail_id = None;
                    self.view = View::Agents;
                    self.selected = 0;
                    self.scroll = 0;
                    return vec![];
                }
                KeyCode::Char('r') => {
                    self.open(Drawer::History);
                    return vec![];
                }
                KeyCode::Char('y') => {
                    self.drawer = None;
                    self.view = View::Chat;
                    self.agent_detail_id = None;
                    self.approval_collapsed = false;
                    return vec![];
                }
                KeyCode::Char('o') => {
                    self.expanded = !self.expanded;
                    return vec![];
                }
                _ => {}
            }
        }
        if self.view != View::Chat && ctrl && key.code == KeyCode::Char('c') {
            if self.active() {
                return vec![self.command("task.stop", json!({}))];
            }
            if self
                .exit_at
                .is_some_and(|t| now.duration_since(t) < Duration::from_millis(1500))
            {
                self.exit = true;
            } else {
                self.exit_at = Some(now);
                self.notice = "再按一次退出".into();
            }
            return vec![];
        }
        if self.view != View::Chat {
            return self.view_key(key);
        }
        if self.drawer.is_some() {
            return self.drawer_key(key);
        }
        if ctrl {
            if self.status() == "approval" && !self.approval_collapsed && !self.rejection {
                return if key.code == KeyCode::Char('c') {
                    vec![self.command("task.stop", json!({}))]
                } else {
                    vec![]
                };
            }
            match key.code {
                KeyCode::Char('c') => {
                    self.send_after_binding = false;
                    self.agent_message_id = None;
                    if !self.input.is_empty() || !self.attachments.is_empty() {
                        self.input.clear();
                        self.cursor = 0;
                        self.attachments.clear();
                        self.paste_collapsed = false;
                    } else if self.active() {
                        return vec![self.command("task.stop", json!({}))];
                    } else if self
                        .exit_at
                        .is_some_and(|t| now.duration_since(t) < Duration::from_millis(1500))
                    {
                        self.exit = true;
                    } else {
                        self.exit_at = Some(now);
                        self.notice = "再按一次退出".into();
                    }
                }
                KeyCode::Enter => self.insert("\n"),
                KeyCode::Char('j')
                    if self.status() != "approval" || self.rejection || self.approval_collapsed =>
                {
                    self.insert("\n")
                }
                KeyCode::Char('v') if self.status() != "approval" || self.approval_collapsed => {
                    self.clipboard_requested = true
                }
                KeyCode::Char('b') if self.input.is_empty() && width >= 140 => {
                    self.sidebar = !self.sidebar
                }
                KeyCode::Char('n') if !self.completion().is_empty() => {
                    self.selected = self.selected.saturating_add(1)
                }
                KeyCode::Char('p') if !self.completion().is_empty() => {
                    self.selected = self.selected.saturating_sub(1)
                }
                _ => {
                    self.edit_key(key);
                }
            }
            return vec![];
        }
        if self.status() == "approval" && !self.approval_collapsed && !self.rejection {
            let id = text(&self.snapshot["approvals"][0], "id").to_owned();
            match key.code {
                KeyCode::Left | KeyCode::Right | KeyCode::Tab | KeyCode::BackTab => {
                    let backwards = matches!(key.code, KeyCode::Left | KeyCode::BackTab);
                    let previous = self
                        .approval_focus
                        .as_ref()
                        .filter(|(v, _)| v == &id)
                        .map(|(_, i)| *i);
                    let choice = previous.map_or(if backwards { 3 } else { 0 }, |i| {
                        if backwards { (i + 3) % 4 } else { (i + 1) % 4 }
                    });
                    self.approval_focus = Some((id, choice));
                }
                KeyCode::Enter => {
                    if let Some((expected, index)) = self.approval_focus.clone() {
                        return self.choose_approval(&expected, index);
                    }
                }
                KeyCode::Char(c) => {
                    if let Some(index) = ['y', 'a', 'n', 'e'].iter().position(|v| *v == c) {
                        return self.choose_approval(&id, index);
                    }
                }
                _ => {}
            }
            return vec![];
        }
        match key.code {
            KeyCode::BackTab => {
                return vec![self.command(
                    "mode.set",
                    json!({"mode":if self.snapshot["session"]["mode"]=="plan"{"work"}else{"plan"}}),
                )];
            }
            KeyCode::Enter
                if key.modifiers.intersects(
                    KeyModifiers::SHIFT | KeyModifiers::ALT | KeyModifiers::CONTROL,
                ) =>
            {
                self.insert("\n")
            }
            KeyCode::Enter => {
                if self.input.is_empty()
                    && self.recent_selected.is_some()
                    && crate::ui::welcome(self)
                {
                    return self.activate_recent();
                }
                let completion = self.completion();
                if !completion.is_empty() && !Self::is_control_command(&self.input) {
                    let value = completion[self.selected % completion.len()].clone();
                    if self.input.starts_with('/') {
                        self.input = value;
                    } else if let Some(pos) = self.input.rfind('@') {
                        self.input.replace_range(pos + 1.., &value);
                        self.cursor = self.input.len();
                        self.completion_closed = true;
                        return vec![];
                    }
                    self.cursor = self.input.len();
                    self.completion_closed = true;
                }
                if self.rejection {
                    let id = text(&self.snapshot["approvals"][0], "id").to_owned();
                    if self.approval_pending.as_deref() == Some(&id) {
                        return vec![];
                    }
                    self.approval_pending = Some(id);
                    let c=self.command("approval.decide",json!({"id":self.snapshot["approvals"][0]["id"],"decision":"reject_reason","reason":self.input}));
                    self.cancel_rejection();
                    return vec![c];
                }
                if self.input.trim_start().starts_with('!') {
                    return self.submit();
                }
                if self.input.trim_start().starts_with('/')
                    && (items(&self.snapshot, "questions").is_empty()
                        || Self::is_control_command(&self.input))
                {
                    return self.submit();
                }
                if !items(&self.snapshot, "questions").is_empty() {
                    return self.answer_question();
                }
                return self.submit();
            }
            KeyCode::Tab => {
                let completion = self.completion();
                if !completion.is_empty() {
                    let value = &completion[self.selected % completion.len()];
                    if self.input.starts_with('/') {
                        self.input = value.clone();
                    } else if let Some(pos) = self.input.rfind('@') {
                        self.input.replace_range(pos + 1.., value);
                    }
                    self.cursor = self.input.len();
                    self.completion_closed = true;
                }
            }
            KeyCode::Up if !self.completion().is_empty() => {
                self.selected = self.selected.saturating_sub(1)
            }
            KeyCode::Down if !self.completion().is_empty() => {
                self.selected = self.selected.saturating_add(1)
            }
            KeyCode::Up => {
                if self.input.is_empty()
                    && crate::ui::welcome(self)
                    && !self.recent_sessions().is_empty()
                {
                    self.move_recent(-1);
                    return vec![];
                }
                let historical = self
                    .history
                    .get(self.history_index)
                    .is_some_and(|s| s == &self.input);
                if self.input.is_empty() || historical {
                    if let Some(q) = items(&self.snapshot, "queued")
                        .iter()
                        .rev()
                        .find(|q| q["status"] == "queued")
                    {
                        let c = self.command("queue.remove", json!({"id":q["id"]}));
                        if !self
                            .pending_withdrawals
                            .iter()
                            .any(|p| p.params["session_id"] == c.params["session_id"])
                        {
                            self.pending_withdrawals.push(c.clone());
                            self.withdrawal_drafts.push((
                                c.clone(),
                                Draft {
                                    text: text(q, "text").into(),
                                    cursor: text(q, "text").len(),
                                    ..Default::default()
                                },
                            ));
                            return vec![c];
                        }
                    } else if !self.history.is_empty() {
                        if self.history_index == self.history.len() {
                            self.history_draft = Some(self.current_draft());
                        }
                        self.history_index = self.history_index.saturating_sub(1);
                        self.input = self.history[self.history_index].clone();
                        self.cursor = self.input.len();
                    }
                } else {
                    self.vertical(-1, width);
                }
            }
            KeyCode::Down => {
                if self.input.is_empty()
                    && crate::ui::welcome(self)
                    && !self.recent_sessions().is_empty()
                {
                    self.move_recent(1);
                    return vec![];
                }
                if self.history_index < self.history.len()
                    && self
                        .history
                        .get(self.history_index)
                        .is_some_and(|s| s == &self.input)
                {
                    self.history_index += 1;
                    if self.history_index == self.history.len() {
                        let draft = self.history_draft.take().unwrap_or_default();
                        self.load_draft(draft);
                    } else {
                        self.input = self.history[self.history_index].clone();
                        self.cursor = self.input.len();
                    }
                } else {
                    self.vertical(1, width);
                }
            }
            KeyCode::PageUp => self.scroll_by(-8),
            KeyCode::PageDown => self.scroll_by(8),
            KeyCode::Char('?') if self.input.is_empty() => self.open(Drawer::Help),
            KeyCode::Char(c) => {
                self.insert(&c.to_string());
                self.completion_closed = false;
                if c == '@' {
                    return vec![self.command("files.list", json!({"query":""}))];
                }
                if c == '/'
                    && let Some((_, query)) = self.input.rsplit_once('@')
                    && !query.chars().any(char::is_whitespace)
                {
                    self.files.clear();
                    return vec![self.command("files.list", json!({"query":query}))];
                }
            }
            _ => {
                self.edit_key(key);
            }
        }
        vec![]
    }
    pub fn insert(&mut self, s: &str) {
        if self.input.is_empty() {
            self.paste_collapsed = false;
            self.long_input_expanded = false;
        }
        self.preferred_column = None;
        self.cursor = text_cursor(&self.input, self.cursor);
        if let Some((start, end)) = self.mark_at(self.cursor, false)
            && self.cursor > start
        {
            self.cursor = end;
        }
        self.input.insert_str(self.cursor, s);
        self.cursor += s.len();
        // Windows terminals can deliver a paste as ordinary character events.
        if !self.long_input_expanded
            && !self.paste_collapsed
            && self.input.chars().take(301).count() > 300
        {
            self.paste_collapsed = true;
        }
    }
    pub fn paste(&mut self, s: &str) {
        if let Some(p)=self.side_panel.as_mut().filter(|p|p.focused){p.input.insert_str(p.cursor,s);p.cursor+=s.len();return;}

        if self.drawer == Some(Drawer::Editor) {
            if let Some(editor) = self.native_editor.as_mut() {
                editor.insert(&s.replace("\r\n", "\n").replace('\r', "\n"));
            }
            return;
        }
        if self.question_popup_visible() {
            if self.question_pending() && !s.trim_start().starts_with('/') {
                self.notice = "答案已提交，等待服务器确认".into();
                return;
            }
            self.question_ui.editing = true;
            self.insert(&s.replace("\r\n", "\n").replace('\r', "\n"));
            self.paste_collapsed = false;
            return;
        }
        if let Some(form) = self.form.as_mut() {
            if let Some(field) = form.fields.get_mut(form.selected)
                && field.editable
            {
                form.cursor = text_cursor(&field.value, form.cursor);
                let pasted = s.trim_end_matches(['\r', '\n']);
                field.value.insert_str(form.cursor, pasted);
                form.cursor += pasted.len();
                form.editing = true;
                self.form_confirm = None;
            }
            return;
        }
        if self.view != View::Chat {
            return;
        }
        let s = s.replace("\r\n", "\n").replace('\r', "\n");
        if self.drawer.is_some() {
            if !matches!(
                self.drawer,
                Some(
                    Drawer::Model
                        | Drawer::Sessions
                        | Drawer::Workspace
                        | Drawer::History
                        | Drawer::Messages
                        | Drawer::Rounds
                        | Drawer::Steps
                )
            ) {
                return;
            }
            self.search_cursor = text_cursor(&self.search, self.search_cursor);
            let query = s.replace('\n', " ");
            self.search.insert_str(self.search_cursor, &query);
            self.search_cursor += query.len();
            self.selected = 0;
        } else if self.status() != "approval" || self.approval_collapsed || self.rejection {
            if let Some(paths) = crate::attachment::paths(&s) {
                let commands = self.import_paths(paths);
                self.outbox.extend(commands);
                return;
            }
            self.insert(&s);
            self.long_input_expanded = false;
            self.paste_collapsed =
                self.paste_collapsed || s.chars().count() > 300 || s.lines().count() > 5;
            self.completion_closed = true;
        }
    }
    fn line_start(&self) -> usize {
        self.input[..self.cursor].rfind('\n').map_or(0, |i| i + 1)
    }
    fn line_end(&self) -> usize {
        self.input[self.cursor..]
            .find('\n')
            .map_or(self.input.len(), |i| self.cursor + i)
    }
    pub(crate) fn edit_key(&mut self, key: KeyEvent) -> bool {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Left => self.left(),
            KeyCode::Right => self.right(),
            KeyCode::Home => self.cursor = self.line_start(),
            KeyCode::End => self.cursor = self.line_end(),
            KeyCode::Backspace => self.backspace(),
            KeyCode::Delete => self.delete(),
            KeyCode::Char('b') if ctrl => self.left(),
            KeyCode::Char('f') if ctrl => self.right(),
            KeyCode::Char('a') if ctrl => self.cursor = self.line_start(),
            KeyCode::Char('e') if ctrl => self.cursor = self.line_end(),
            KeyCode::Char('h') if ctrl => self.backspace(),
            KeyCode::Char('d') if ctrl => self.delete(),
            KeyCode::Char('u') if ctrl => {
                let start = self.line_start();
                self.input.drain(start..self.cursor);
                self.cursor = start;
            }
            KeyCode::Char('k') if ctrl => {
                let end = self.line_end();
                self.input.drain(self.cursor..end);
            }
            KeyCode::Char('w') if ctrl => {
                while self.cursor > 0 && self.input[..self.cursor].ends_with(char::is_whitespace) {
                    self.backspace();
                }
                while self.cursor > 0 && !self.input[..self.cursor].ends_with(char::is_whitespace) {
                    self.backspace();
                }
            }
            _ => return false,
        }
        self.paste_collapsed = false;
        self.preferred_column = None;
        self.long_input_expanded = true;
        self.sync_attachment_marks();
        true
    }
    fn vertical(&mut self, direction: i32, terminal_width: u16) {
        self.paste_collapsed = false;
        self.long_input_expanded = true;
        let (current_row, current_col) =
            crate::ui::input_visual_position(self, usize::from(terminal_width));
        let target = if direction < 0 {
            let Some(row) = current_row.checked_sub(1) else {
                return;
            };
            row
        } else {
            current_row + 1
        };
        let desired = *self.preferred_column.get_or_insert(current_col);
        let available = usize::from(terminal_width).saturating_sub(5).max(1);
        let (mut row, mut col) = (0usize, 0usize);
        let mut best = None;
        let mut distance = usize::MAX;
        for (index, ch) in std::iter::once((0, None)).chain(
            self.input
                .char_indices()
                .map(|(i, c)| (i + c.len_utf8(), Some(c))),
        ) {
            if let Some(c) = ch {
                if c == '\n' {
                    row += 1;
                    col = 0;
                } else {
                    let cw =
                        crate::ui::width(&crate::ui::clean(&c.to_string()), self.ambiguous_width);
                    if col + cw > available && col > 0 {
                        row += 1;
                        col = 0;
                    }
                    col += cw;
                }
            }
            let (visual_row, visual_col) = if col >= available {
                (row + 1, 0)
            } else {
                (row, col)
            };
            if visual_row == target {
                let delta = visual_col.abs_diff(desired);
                if delta < distance {
                    distance = delta;
                    best = Some(index);
                }
            }
        }
        if let Some(cursor) = best {
            self.cursor = cursor;
        }
    }
    pub fn scroll_by(&mut self, lines: i32) {
        if self.view == View::Chat && !crate::ui::welcome(self) {
            crate::ui::scroll_transcript(self, lines);
            return;
        }
        let forward = if self.view == View::Chat && !crate::ui::welcome(self) {
            -lines
        } else {
            lines
        };
        if forward >= 0 {
            self.scroll = self
                .scroll
                .saturating_add(forward.min(i32::from(u16::MAX)) as u16);
        } else {
            self.scroll = self
                .scroll
                .saturating_sub((-forward).min(i32::from(u16::MAX)) as u16);
        }
        if self.view == View::Chat {
            self.scroll = self.scroll.min(crate::ui::record_scroll_limit(
                self,
                self.viewport.0,
                self.viewport.1,
            ));
        }
    }
    pub fn current_draft(&self) -> Draft {
        Draft {
            text: self.input.clone(),
            cursor: self.cursor,
            attachments: self.attachments.clone(),
            agent_id: self.agent_message_id.clone(),
            collapsed: self.paste_collapsed,
        }
    }
    pub(crate) fn load_draft(&mut self, draft: Draft) {
        self.preferred_column = None;
        self.input = draft.text;
        self.cursor = text_cursor(&self.input, draft.cursor);
        self.attachments = draft.attachments;
        self.restore_attachment_marks();
        self.agent_message_id = draft.agent_id;
        self.paste_collapsed = draft.collapsed;
        self.long_input_expanded = !draft.collapsed && self.input.chars().count() > 300;
    }
    pub fn choose_approval(&mut self, expected: &str, index: usize) -> Vec<Command> {
        let id = text(&self.snapshot["approvals"][0], "id").to_owned();
        if id.is_empty()
            || id != expected
            || self.status() != "approval"
            || self.snapshot_stale
            || self.approval_collapsed
            || self.rejection
            || self.approval_pending.as_deref() == Some(&id)
            || index > 3
        {
            return vec![];
        }
        self.approval_focus = Some((id.clone(), index));
        if index == 3 {
            self.rejection_draft = Some(self.current_draft());
            self.rejection = true;
            self.input.clear();
            self.cursor = 0;
            self.attachments.clear();
            self.paste_collapsed = false;
            return vec![];
        }
        self.approval_pending = Some(id.clone());
        vec![self.command(
            "approval.decide",
            json!({"id":id,"decision":(["once","session","reject"][index])}),
        )]
    }
    fn cancel_rejection(&mut self) {
        if let Some(draft) = self.rejection_draft.take() {
            self.load_draft(draft);
        }
        self.rejection = false;
    }
    pub fn set_snapshot_error(&mut self, message: &str) {
        self.snapshot_stale = true;
        self.snapshot_error = Some(message.into());
    }
    fn sync_pending_draft(&mut self) {
        self.pending_draft = self
            .pending_inputs
            .iter()
            .find(|p| p.command.params["session_id"] == self.snapshot["session"]["id"])
            .map(|p| (p.draft.text.clone(), p.draft.attachments.clone()));
    }
    pub(crate) fn track_input(
        &mut self,
        command: Command,
        draft: Draft,
        question_state: Option<(usize, serde_json::Map<String, Value>)>,
    ) -> Vec<Command> {
        if command.method == "queue.add" {
            self.notice = "正在提交补充要求…".into();
        }
        self.pending_inputs.push(PendingInput {
            command: command.clone(),
            draft,
            question_state,
        });
        self.sync_pending_draft();
        vec![command]
    }
    fn restore_pending(&mut self, pending: PendingInput) {
        let session = text(&pending.command.params, "session_id").to_owned();
        let current_session = self.session_id() == Some(session.as_str());
        let newer = if current_session {
            self.rejection_draft
                .clone()
                .unwrap_or_else(|| self.current_draft())
        } else {
            self.session_drafts
                .get(&session)
                .cloned()
                .unwrap_or_default()
        };
        let has_newer = !newer.text.is_empty() || !newer.attachments.is_empty();
        let wrong_question = pending.question_state.is_some()
            && current_session
            && pending.command.params["id"] != self.snapshot["questions"][0]["id"];
        let question_owns_input = current_session
            && self.rejection_draft.is_none()
            && !items(&self.snapshot, "questions").is_empty()
            && pending.question_state.is_none();
        if (pending.question_state.is_some() && !current_session)
            || wrong_question
            || question_owns_input
            || (has_newer
                && (newer.agent_id != pending.draft.agent_id || pending.question_state.is_some()))
        {
            self.recovered_inputs.push(pending);
            if current_session {
                self.notice =
                    "失败请求的原目标与草稿已保留；/recover 恢复，当前编辑不会被覆盖".into();
            }
            return;
        }
        let PendingInput {
            mut draft,
            question_state,
            command: _,
        } = pending;
        if !newer.text.is_empty() {
            draft.text.push('\n');
            draft.text.push_str(&newer.text);
        }
        draft.cursor = draft.text.len();
        draft.attachments.extend(newer.attachments);
        if current_session {
            if self.rejection_draft.is_some() {
                self.rejection_draft = Some(draft);
            } else {
                self.load_draft(draft);
            }
            if let Some((index, answers)) = question_state {
                self.question_index = index;
                self.question_answers = answers;
            }
        } else {
            self.session_drafts.insert(session, draft);
        }
    }
    /// Restore explicitly; this never sends a request. Existing text keeps its destination.
    pub fn recover_draft(&mut self) {
        let answering =
            !items(&self.snapshot, "questions").is_empty() && self.rejection_draft.is_none();
        let Some(index) = self.recovered_inputs.iter().rposition(|p| {
            p.command.params["session_id"] == self.snapshot["session"]["id"]
                && (!answering
                    || (p.question_state.is_some()
                        && p.command.params["id"] == self.snapshot["questions"][0]["id"]))
        }) else {
            self.notice = if answering {
                "请先回答当前问题，再 /recover 恢复消息草稿"
            } else {
                "当前会话没有待恢复的草稿"
            }
            .into();
            return;
        };
        let pending = self.recovered_inputs.remove(index);
        if pending.question_state.is_none()
            && !items(&self.snapshot, "questions").is_empty()
            && self.rejection_draft.is_none()
        {
            self.recovered_inputs.insert(index, pending);
            self.notice = "请先回答当前问题，再 /recover 恢复消息草稿".into();
            return;
        }
        let current = self
            .rejection_draft
            .clone()
            .unwrap_or_else(|| self.current_draft());
        if !current.text.is_empty() || !current.attachments.is_empty() {
            let command = self.command(
                "draft.restore",
                if answering {
                    json!({"id":self.snapshot["questions"][0]["id"]})
                } else {
                    json!({})
                },
            );
            let question_state = answering.then(|| {
                (
                    self.question_index.min(
                        items(&self.snapshot["questions"][0], "questions")
                            .len()
                            .saturating_sub(1),
                    ),
                    self.question_answers.clone(),
                )
            });
            self.recovered_inputs.insert(
                0,
                PendingInput {
                    command,
                    draft: current,
                    question_state,
                },
            );
        }
        if self.rejection_draft.is_some() {
            self.rejection_draft = Some(pending.draft);
        } else {
            self.load_draft(pending.draft);
        }
        if let Some((index, answers)) = pending.question_state {
            if pending.command.params["id"] == self.snapshot["questions"][0]["id"] {
                self.question_index = index;
                self.question_answers = answers;
            } else {
                self.notice = "原问题已结束，已恢复答案原文；再次发送将作为新消息".into();
                return;
            }
        }
        self.notice = "已恢复草稿与原发送目标；其他草稿可再次 /recover 切换".into();
    }
    pub fn command_response(&mut self, command: &Command, result: &Value) {
        if self.workbench_response(command,result) { return; }
        if self.shell_response(command, result) {
            return;
        }
        if self.session_import_response(command, result) {
            return;
        }
        if self.quota_response(command, result) {
            return;
        }
        if self.context_search_response(command, result) {
            return;
        }
        if self.management_response(command, result) {
            return;
        }
        if self.tool_detail_response(command, result) {
            return;
        }
        if self.login_response(command, result) {
            return;
        }
        if self.extra_response(command, result) {
            return;
        }
        if command.method == "permission.set" {
            self.full_confirm = false;
            if self.notice == "完全访问：再次按 enter 确认" {
                self.notice.clear();
            }
        }
        if command.method.starts_with("checkpoint.") {
            if command.params["session_id"] != self.snapshot["session"]["id"] {
                return;
            }
            match command.method.as_str() {
                "checkpoint.list" => {
                    self.checkpoint_points =
                        items(result, "checkpoints").iter().rev().cloned().collect();
                    self.open(Drawer::Checkpoints);
                }
                "checkpoint.preview" => {
                    self.checkpoint_review = result.clone();
                    self.open(Drawer::CheckpointReview);
                }
                "checkpoint.restore" => {
                    self.checkpoint_review = Value::Null;
                    self.notice = format!(
                        "已回退 {} 条文件记录；{} · 命令和外部副作用需另行核对",
                        items(result, "restored_files").len(),
                        if result["complete"] != true {
                            "部分回退未完成，请查看改动面板"
                        } else if result["conversation_restored"] == true {
                            "会话位置已恢复"
                        } else {
                            "会话位置保持不变"
                        }
                    );
                    if result["branch_created"] == true {
                        self.outbox.push(Command {
                            method: "session.open".into(),
                            params: json!({"session_id":result["session_id"]}),
                        });
                    }
                }
                _ => {}
            }
            return;
        }
        let form_origin = self
            .pending_form
            .as_ref()
            .is_some_and(|(revision, c)| c == command && *revision == self.form_revision);
        if self
            .pending_form
            .as_ref()
            .is_some_and(|(_, c)| c == command)
        {
            self.pending_form = None;
        }

        if matches!(
            command.method.as_str(),
            "asr.save"
                | "provider.save"
                | "provider.remove"
                | "provider.scan"
                | "mcp.save"
                | "mcp.remove"
                | "mcp.scan"
                | "mcp.bind"
        ) && result["providers"].is_array()
        {
            self.snapshot["settings"] = result.clone();
        }
        if command.method == "settings.get" {
            self.snapshot["settings"] = result.clone();
            if self
                .form
                .as_ref()
                .is_some_and(|f| f.kind == FormKind::Settings)
            {
                self.rebuild_settings();
            }
        }
        if matches!(
            command.method.as_str(),
            "provider.save" | "provider.remove" | "mcp.save" | "mcp.remove" | "asr.save"
        ) && form_origin
        {
            if let Some(form) = self.form.as_mut() {
                form.notice = "已保存；设置已更新".into();
                if command.method.ends_with(".save") {
                    form.original_fields = self.pending_form_values.clone();
                    for field in &mut form.original_fields {
                        if field.secret {
                            field.value.clear();
                        }
                    }
                    for field in &mut form.fields {
                        // Do not erase a newer edit while an earlier save was pending.
                        let submitted = command.params.get(&field.key);
                        if field.secret
                            && submitted.is_some_and(|value| {
                                value.as_str() == Some(field.value.as_str())
                                    || (value.is_object()
                                        && serde_json::from_str::<Value>(&field.value)
                                            .ok()
                                            .as_ref()
                                            == Some(value))
                            })
                        {
                            field.value.clear();
                        }
                    }
                }
            }
            if command.method.ends_with(".save")
                && let Some(id) = result["id"].as_str()
                && let Some(form) = self.form.as_mut()
                && let Some(field) = form.fields.iter_mut().find(|f| f.key == "id")
            {
                field.value = id.into();
                if form.items.is_empty() {
                    form.items.push(json!({"id":id}));
                } else {
                    form.items[0]["id"] = json!(id);
                }
            }
            if command.method == "provider.save" && form_origin {
                let saved = items(result, "providers")
                    .iter()
                    .find(|p| p["id"] == result["id"]);
                if let (Some(saved), Some(form)) = (saved, self.form.as_mut()) {
                    if let Some(field) = form.fields.iter_mut().find(|f| f.key == "base_url")
                        && command.params["base_url"].as_str() == Some(field.value.as_str())
                    {
                        field.value = text(saved, "base_url").to_owned();
                    }
                    for field in &mut form.original_fields {
                        if field.key == "base_url" {
                            field.value = text(saved, "base_url").to_owned();
                        }
                    }
                }
            }
            if command.method == "provider.save" && form_origin && self.connect_after_save {
                self.connect_after_save = false;
                let scan = self.command("provider.scan", json!({"id":result["id"]}));
                self.pending_form = Some((self.form_revision, scan.clone()));
                self.outbox.push(scan);
            }
            self.outbox.push(self.command("settings.get", json!({})));
            self.outbox.push(self.command("models.list", json!({})));
            if command.method.ends_with(".remove") {
                if command.method == "provider.remove" && self.login_provider_editor {
                    self.login_provider_editor = false;
                    let commands = self.open_login();
                    self.outbox.extend(commands);
                } else {
                    self.rebuild_settings();
                }
            }
        }
        if command.method == "provider.scan" && form_origin {
            let models = items(result, "models")
                .iter()
                .filter_map(|m| m.as_str().or_else(|| m["id"].as_str()))
                .collect::<Vec<_>>()
                .join(",");
            if let Some(form) = self.form.as_mut() {
                if let Some(field) = form.fields.iter_mut().find(|f| f.key == "models") {
                    field.value = models;
                }
                let selected = items(result, "providers")
                    .iter()
                    .find(|p| p["id"] == command.params["id"]);
                if let Some(provider) = selected {
                    for key in ["chat_model", "reasoner_model"] {
                        if let Some(field) = form.fields.iter_mut().find(|f| f.key == key) {
                            field.value = text(provider, key).into();
                        }
                    }
                    form.items = vec![provider.clone()];
                }
                form.original_fields = form.fields.clone();
                form.notice = format!("已完整获取并保存 {} 个模型", items(result, "models").len());
                self.outbox.push(self.command("models.list", json!({})));
            }
        }
        if command.method == "mcp.bind"
            && form_origin
            && let Some(form) = self.form.as_mut()
        {
            form.notice = "本会话 MCP 工具选用已更新".into();
        }
        if command.method == "mcp.scan"
            && form_origin
            && let Some(form) = self.form.as_mut()
        {
            form.notice = format!("已连接 · 发现 {} 个工具", items(result, "tools").len());
            if let Some(item) = form.items.first_mut() {
                item["tools"] = result["tools"].clone();
            }
        }
        if command.method == "attachment.import"
            && let Some(index) = self
                .attachment_targets
                .iter()
                .position(|(c, _)| c == command)
        {
            let (_, agent) = self.attachment_targets.remove(index);
            let attachment = result.get("attachment").unwrap_or(result).clone();
            let warnings = items(&attachment, "warnings")
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("；");
            if !self.finish_attachment_import(command, Some(attachment.clone()), "") {
                self.add_attachment(
                    command.params["session_id"].as_str(),
                    agent.as_deref(),
                    attachment,
                );
            }
            if !warnings.is_empty() {
                self.notice = format!("{} · {warnings}", self.notice);
            }
        }
        if command.method == "context.compact"
            && let Some(index) = self.pending_compactions.iter().position(|c| c == command)
        {
            self.pending_compactions.remove(index);
            if command.params["session_id"] == self.snapshot["session"]["id"] {
                let summary = result
                    .get("result")
                    .and_then(|v| v.as_str().or_else(|| v["summary"].as_str()))
                    .unwrap_or("公开上下文已整理");
                self.notice = format!("整理完成 · {summary}");
            }
        }
        if let Some(index) = self
            .pending_inputs
            .iter()
            .position(|p| p.command == *command)
        {
            self.pending_inputs.remove(index);
            if command.method == "question.answer" {
                self.answered_questions.insert((
                    text(&command.params, "session_id").into(),
                    text(&command.params, "id").into(),
                ));
            }
            if command.params["session_id"] == self.snapshot["session"]["id"] {
                if command.method == "queue.add" {
                    let receipt = items(&self.snapshot, "steering").iter()
                        .find(|entry| entry["id"] == result["id"])
                        .unwrap_or(&result["steering"]);
                    self.notice = if receipt.is_object() {
                        crate::ui::steering_label(receipt)
                    } else {
                        "已排队 · 等待工具边界".into()
                    };
                } else {
                    self.notice.clear();
                }
            }
        }
        if command.method == "queue.remove"
            && let Some(index) = self.pending_withdrawals.iter().position(|p| p == command)
        {
            self.pending_withdrawals.remove(index);
            self.withdrawal_drafts.retain(|(c, _)| c != command);
            let draft = Draft {
                text: text(result, "text").into(),
                cursor: text(result, "text").len(),
                ..Default::default()
            };
            self.restore_pending(PendingInput {
                command: command.clone(),
                draft,
                question_state: None,
            });
        }
        self.sync_pending_draft();
        if self
            .recovered_inputs
            .iter()
            .any(|p| p.command.params["session_id"] == self.snapshot["session"]["id"])
        {
            self.notice = "有失败草稿待恢复；/recover 恢复原文与发送目标".into();
        }
    }
    pub fn command_unknown(&mut self, command: &Command, message: &str) {
        let origin = self
            .pending_form
            .as_ref()
            .is_some_and(|(revision, pending)| {
                *revision == self.form_revision && pending == command
            });
        self.command_error(command, message);
        if origin {
            self.uncertain_form_revision = Some(self.form_revision);
            if let Some(form) = self.form.as_mut() {
                form.notice = "操作结果未知；请返回设置核对后重开，未自动重发。".into();
            }
            self.outbox.push(self.command("settings.get", json!({})));
        }
    }
    pub fn command_error(&mut self, command: &Command, message: &str) {
        if self.workbench_error(command,message) { return; }
        if self.session_import_error(command, message) {
            return;
        }
        if command.method == "approval.decide"
            && self.approval_pending.as_deref() == command.params["id"].as_str()
        {
            self.approval_pending = None;
        }
        if self.shell_error(command, message) {
            return;
        }
        if command.method == "attachment.import" {
            self.finish_attachment_import(command, None, message);
        }
        if command.method.starts_with("provider.login.") {
            self.login_poll_pending = false;
            if command.method == "provider.login.status" {
                self.login_job = None;
            }
            if let Some(form) = self.form.as_mut() {
                form.notice = message.into();
            }
        }
        let form_origin = self
            .pending_form
            .as_ref()
            .is_some_and(|(revision, c)| c == command && *revision == self.form_revision);
        if self
            .pending_form
            .as_ref()
            .is_some_and(|(_, c)| c == command)
        {
            self.pending_form = None;
        }

        self.attachment_targets.retain(|(c, _)| c != command);
        if matches!(
            command.method.as_str(),
            "asr.save"
                | "provider.save"
                | "provider.remove"
                | "provider.scan"
                | "mcp.save"
                | "mcp.remove"
                | "mcp.scan"
                | "mcp.bind"
                | "settings.get"
                | "terminal.action"
                | "terminal.query"
        ) && (form_origin || command.method == "settings.get")
            && let Some(form) = self.form.as_mut()
        {
            form.notice = message.into();
        }
        let recoveries = self.recovered_inputs.len();
        if let Some(index) = self
            .pending_inputs
            .iter()
            .position(|p| p.command == *command)
        {
            let pending = self.pending_inputs.remove(index);
            self.restore_pending(pending);
        }
        self.pending_withdrawals.retain(|p| p != command);
        if let Some(index) = self
            .withdrawal_drafts
            .iter()
            .position(|(c, _)| c == command)
        {
            let (command, draft) = self.withdrawal_drafts.remove(index);
            if !draft.text.is_empty() {
                self.recovered_inputs.push(PendingInput {
                    command,
                    draft,
                    question_state: None,
                });
            }
        }
        self.pending_compactions.retain(|p| p != command);
        self.sync_pending_draft();
        if command.params["session_id"].is_null()
            || command.params["session_id"] == self.snapshot["session"]["id"]
        {
            self.notice = if self.recovered_inputs.len() > recoveries {
                format!("{message} · 原文已保留，核对服务器状态后可 /recover 恢复")
            } else {
                message.into()
            };
        }
    }
    pub fn add_attachment(
        &mut self,
        session: Option<&str>,
        agent: Option<&str>,
        attachment: Value,
    ) {
        if session == self.session_id() && agent == self.agent_message_id.as_deref() {
            self.recent_selected = None;
            self.recent_confirm = None;
            let name = text(&attachment, "name").to_owned();
            self.insert_attachment_mark(attachment);
            self.notice = format!("已添加附件：{name}");
        } else if let Some(session) = session {
            self.recovered_inputs.push(PendingInput {
                command: Command {
                    method: "draft.restore".into(),
                    params: json!({"session_id":session}),
                },
                draft: Draft {
                    attachments: vec![attachment],
                    agent_id: agent.map(str::to_owned),
                    ..Default::default()
                },
                question_state: None,
            });
            self.notice = "剪贴板图片已保留到原会话与目标；/recover 恢复".into();
        }
    }
    fn left(&mut self) {
        if let Some((start, _)) = self.mark_at(self.cursor, true) {
            self.cursor = start;
            return;
        }
        self.cursor = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map_or(0, |(i, _)| i);
    }
    fn right(&mut self) {
        if let Some((_, end)) = self.mark_at(self.cursor, false) {
            self.cursor = end;
            return;
        }
        if let Some(c) = self.input[self.cursor..].chars().next() {
            self.cursor += c.len_utf8();
        }
    }
    fn backspace(&mut self) {
        let end = self.cursor;
        self.left();
        self.input.drain(self.cursor..end);
    }
    fn delete(&mut self) {
        if let Some((start, end)) = self.mark_at(self.cursor, false) {
            self.input.drain(start..end);
            self.cursor = start;
            return;
        }
        if let Some(c) = self.input[self.cursor..].chars().next() {
            self.input.drain(self.cursor..self.cursor + c.len_utf8());
        }
    }
    pub(crate) fn submit(&mut self) -> Vec<Command> {
        if let Some(commands) = self.try_shell_submit() {
            return commands;
        }
        let trimmed = self.input.trim();
        if trimmed.starts_with('/') && !self.paste_collapsed {
            if !Self::is_control_command(trimmed) {
                self.notice = "未知命令；输入已保留，/help 查看命令".into();
                return vec![];
            }
            let (cmd, arg) = trimmed
                .split_once(char::is_whitespace)
                .unwrap_or((trimmed, ""));
            let cmd = cmd.to_owned();
            let arg = arg.trim().to_owned();
            self.input.clear();
            self.cursor = 0;
            self.completion_closed = true;
            match cmd.as_str() {
                value if crate::commands::EXTRA_COMMANDS.contains(&value) => {
                    return self.extra_command(&cmd, &arg);
                }
                "/model" => self.open(Drawer::Model),
                "/questions" => {
                    self.open_questions();
                    if items(&self.snapshot, "questions").is_empty() {
                        self.notice = "当前没有待回答的问题".into();
                    }
                }
                "/permissions" => self.open(Drawer::Permissions),
                "/workspace" => self.open(Drawer::Workspace),
                "/sessions" | "/session" => {
                    self.open(Drawer::Sessions);
                    // The snapshot list can be stale; titles and times come from the host.
                    let refresh = self.command("session.list", json!({}));
                    self.outbox.push(refresh);
                }
                "/help" if arg == "commands" => {
                    self.show_info("主入口与快捷命令", crate::commands::command_help_lines())
                }
                "/help" => self.open(Drawer::Help),
                "/editor" => {
                    if arg == "external" {
                        self.editor_requested = true;
                    } else {
                        self.open_native_editor();
                        if !arg.is_empty()
                            && let Some(editor) = self.native_editor.as_mut()
                        {
                            editor.language = if arg == "code" {
                                "rust".into()
                            } else {
                                arg.to_lowercase()
                            };
                        }
                    }
                }
                "/tasks" => self.open(Drawer::Tasks),
                "/rewind" => {
                    if arg.is_empty() {
                        return vec![self.command("checkpoint.list", json!({}))];
                    }
                    if ["conversation", "files", "both", "branch"].contains(&arg.as_str()) {
                        let review = &self.checkpoint_review;
                        if self.snapshot_stale
                            || review.is_null()
                            || review["session_id"] != self.snapshot["session"]["id"]
                        {
                            self.notice = "先 /rewind 选择并查看检查点，连接恢复后再操作".into();
                        } else {
                            return vec![self.command("checkpoint.restore",json!({
                                "message_id":review["message_id"],"fingerprint":review["fingerprint"],"mode":arg,"confirmed":true}))];
                        }
                    } else {
                        return vec![self.command("checkpoint.preview", json!({"message_id":arg}))];
                    }
                }
                "/plan" | "/todo" => {
                    if arg.is_empty() {
                        self.open(Drawer::Plan);
                    } else {
                        let mut words = arg.splitn(3, ' ');
                        let action = words.next().unwrap_or("");
                        let revision = words.next().and_then(|v| v.parse::<u64>().ok());
                        let comment = words.next().unwrap_or("");
                        let plan = &self.snapshot["plan"];
                        if plan.is_null() || revision != plan["revision"].as_u64() {
                            self.notice =
                                "计划不存在或版本已改变；请先 /plan 查看，再指定版本".into();
                        } else if action == "approve" {
                            if self.reviewed_plan["id"] != plan["id"]
                                || self.reviewed_plan["revision"] != plan["revision"]
                                || self.reviewed_plan["content_hash"] != plan["content_hash"]
                            {
                                self.notice = "请先 /plan 查看当前版本，再批准".into();
                            } else {
                                return vec![self.command(
                                    "plan.approve",
                                    json!({
                                    "revision":revision,"content_hash":plan["content_hash"]}),
                                )];
                            }
                        } else if action == "cancel" {
                            return vec![self.command("plan.cancel", json!({"revision":revision}))];
                        } else if action == "comment" && !comment.trim().is_empty() {
                            return vec![self.command(
                                "plan.comment",
                                json!({"revision":revision,"text":comment}),
                            )];
                        } else {
                            self.notice =
                                "用法：/plan [approve 版本|cancel 版本|comment 版本 意见]".into();
                        }
                    }
                }
                "/find" => {
                    if arg.is_empty() {
                        self.notice =
                            "用法：/find 关键词；/next 下一处，/prev 上一处，/latest 返回最新"
                                .into();
                    } else {
                        self.transcript_query = arg;
                        self.transcript_match = None;
                        crate::ui::find_transcript(self, false);
                    }
                }
                "/next" => crate::ui::find_transcript(self, false),
                "/prev" => crate::ui::find_transcript(self, true),
                "/latest" => {
                    self.scroll = 0;
                    self.reading_anchor = None;
                    self.unseen_output = false;
                    self.notice.clear();
                }
                "/jump" => crate::ui::jump_transcript(self, &arg),
                "/resume" => {
                    if !arg.is_empty() {
                        return vec![Command {
                            method: "session.open".into(),
                            params: json!({"session_id":arg}),
                        }];
                    }
                    if let Some(recent) = items(&self.snapshot, "sessions").iter().find(|s| {
                        s["id"] != self.snapshot["session"]["id"]
                            && s["empty"] != true
                            && (self.snapshot["session"]["workspace_id"].is_null()
                                || s["workspace_id"] == self.snapshot["session"]["workspace_id"])
                    }) {
                        return vec![Command {
                            method: "session.open".into(),
                            params: json!({"session_id":recent["id"]}),
                        }];
                    }
                    self.open(Drawer::Sessions);
                }
                "/pet" => {
                    if !["", "on", "off"].contains(&arg.as_str()) {
                        self.notice = "用法：/pet [on|off]".into();
                        return vec![];
                    }
                    let enabled = arg != "off";
                    self.pet.enabled = enabled;
                    if let Err(error) = crate::config::save_pet(enabled) {
                        self.notice = error.to_string();
                    }
                    if enabled && arg.is_empty() {
                        self.pet.click(Instant::now(), self.reduce_motion);
                    }
                }
                "/mode" => {
                    let mode = match arg.as_str() {
                        "chat" => "chat",
                        "work" => "work",
                        "plan" => "plan",
                        "" => {
                            if self.snapshot["session"]["mode"] == "plan" {
                                "work"
                            } else {
                                "plan"
                            }
                        }
                        _ => {
                            self.notice = "用法：/mode [work|plan]".into();
                            return vec![];
                        }
                    };
                    return vec![self.command("mode.set", json!({"mode":mode}))];
                }
                "/accept" => {
                    self.notice = "已取消手动验收步骤；任务正常结束后直接完成".into();
                    return vec![];
                }
                "/stop" => return vec![self.command("task.stop", json!({}))],
                "/new" => {
                    return vec![Command {
                        method: "session.new".into(),
                        params: json!({"workspace_id":self.snapshot["session"]["workspace_id"]}),
                    }];
                }
                "/quit" | "/exit" => self.exit = true,
                "/settings" if arg == "context" => return self.open_context_settings(),
                "/login" | "/settings" | "/doctor" | "/mcp" | "/provider" => {
                    return self.open_settings();
                }
                "/attach" => {
                    if arg == "cancel" {
                        self.cancel_attachments_requested = true;
                        for attachment in &mut self.attachments {
                            if attachment["_state"] == "loading" {
                                attachment["_state"] = json!("error");
                                attachment["_error"] = json!("已取消导入");
                            }
                        }
                        self.deferred_paths.clear();
                        let session = self.snapshot["session"]["id"].clone();
                        self.attachment_targets
                            .retain(|(command, _)| command.params["session_id"] != session);
                        self.notice = "已请求取消附件处理；迟到结果不会附加到草稿".into();
                        return vec![self.command("attachment.cancel", json!({}))];
                    }
                    if arg.is_empty() {
                        self.clipboard_requested = true;
                        return vec![];
                    }
                    if let Some(paths) = crate::attachment::paths(&arg) {
                        return self.import_paths(paths);
                    }
                    self.notice = "文件不存在；含空格的路径请用双引号包围".into();
                }
                "/copy" => {
                    let messages = items(&self.snapshot, "messages");
                    let content = if arg == "session" {
                        self.session_id().unwrap_or("").to_owned()
                    } else if arg == "all" {
                        messages
                            .iter()
                            .filter(|m| matches!(text(m, "role"), "user" | "assistant"))
                            .map(|m| {
                                format!(
                                    "{}\n{}",
                                    if m["role"] == "user" {
                                        "用户"
                                    } else {
                                        "助手"
                                    },
                                    text(m, "text")
                                )
                            })
                            .collect::<Vec<_>>()
                            .join("\n\n")
                    } else {
                        messages
                            .iter()
                            .rev()
                            .find(|m| m["role"] == "assistant")
                            .map(|m| text(m, "text").to_owned())
                            .unwrap_or_default()
                    };
                    if content.is_empty() {
                        self.notice = "没有可复制的对话正文".into();
                    } else {
                        self.copy_requested = Some(content);
                    }
                    return vec![];
                }
                "/detach" => {
                    if arg.is_empty() || arg == "all" {
                        self.attachments.clear();
                    } else if let Ok(i) = arg.parse::<usize>()
                        && i > 0
                        && i <= self.attachments.len()
                    {
                        self.remove_attachment(i - 1);
                    } else {
                        self.notice = "用法：/detach [编号|all]".into();
                    }
                }
                "/skin" => {
                    if arg.is_empty() {
                        self.open_skin();
                    } else {
                        self.apply_skin(&arg);
                    }
                }
                "/library" => {
                    return if arg == "manage" {
                        self.open_management("library")
                    } else {
                        self.open_library()
                    };
                }
                "/media" => return vec![self.command("gui.open", json!({"page":"media"}))],
                "/gui" => return vec![self.command("gui.open", json!({"page":"session"}))],
                "/bridge" if arg == "off" => return vec![self.command("bridge.stop", json!({}))],
                "/bridge" => self.notice = "使用 /bridge off 关闭桥接；后台任务继续运行".into(),
                "/compact" => {
                    let c = self.command("context.compact", json!({}));
                    if self
                        .pending_compactions
                        .iter()
                        .any(|p| p.params["session_id"] == c.params["session_id"])
                    {
                        self.notice = "正在整理公开上下文，请等待完成".into();
                        return vec![];
                    }
                    self.pending_compactions.push(c.clone());
                    self.notice = "正在整理公开上下文…".into();
                    return vec![c];
                }
                "/recover" => self.recover_draft(),
                _ => self.notice = format!("未知命令：{cmd} · /help"),
            }
            return vec![];
        }
        if self.snapshot["session"]["mode"]=="chat" {
            self.notice="历史对话仅供查看；/mode work 转为工作会话，或 /new 新建".into();
            return vec![];
        }
        if !self.binding_ready {
            self.send_after_binding = true;
            self.notice = "正在创建工作会话，就绪后发送此草稿".into();
            return vec![];
        }
        if self
            .attachment_targets
            .iter()
            .any(|(command, _)| command.params["session_id"] == self.snapshot["session"]["id"])
        {
            self.notice = "附件正在处理；可 /attach cancel".into();
            return vec![];
        }
        if self.attachments.iter().any(|a| {
            a["token"].is_null()
                && !(a["reference"] == true && !text(a, "path").is_empty())
        }) {
            self.notice = "附件尚未就绪或导入失败；/attachments 查看状态、Delete 移除".into();
            return vec![];
        }
        if self.pending_draft.is_some()
            || self
                .pending_inputs
                .iter()
                .any(|p| p.command.params["session_id"] == self.snapshot["session"]["id"])
        {
            self.notice = "上一条消息仍待服务器确认".into();
            return vec![];
        }
        if self.agent_message_id.is_some() && !self.attachments.is_empty() {
            self.notice = "助手补充暂不支持附件；请移除附件或取消助手补充后发送".into();
            return vec![];
        }
        if self.active() && !self.attachments.is_empty() {
            self.notice = "任务运行中只支持文字补充；请在本轮结束后发送附件".into();
            return vec![];
        }
        if self.input.trim().is_empty() && self.attachments.is_empty() {
            return if self.status() == "stopped" {
                vec![self.command("task.resume", json!({}))]
            } else {
                vec![]
            };
        }
        if self.agent_message_id.is_none() && items(&self.snapshot, "models").is_empty() {
            return self.open_login();
        }
        let draft = self.current_draft();
        let command = if let Some(id) = &self.agent_message_id {
            self.command("agent.message", json!({"id":id,"text":self.input}))
        } else {
            self.command(
                if self.active() {
                    "queue.add"
                } else {
                    "message.send"
                },
                json!({"text":self.input,"attachments":self.attachments}),
            )
        };
        self.history.push(self.input.clone());
        self.history_local.push(self.input.clone());
        self.history_index = self.history.len();
        self.history_draft = None;
        self.input.clear();
        self.cursor = 0;
        self.attachments.clear();
        self.agent_message_id = None;
        self.paste_collapsed = false;
        self.completion_closed = true;
        self.track_input(command, draft, None)
    }
    pub(crate) fn is_control_command(input: &str) -> bool {
        let command = input.split_whitespace().next().unwrap_or("");
        COMMANDS.contains(&command)
            || crate::commands::EXTRA_COMMANDS.contains(&command)
            || matches!(command, "/exit" | "/settings" | "/session")
    }
    pub fn restore_draft(&mut self) {
        if let Some(index) = self
            .pending_inputs
            .iter()
            .position(|p| p.command.params["session_id"] == self.snapshot["session"]["id"])
        {
            let pending = self.pending_inputs.remove(index);
            self.restore_pending(pending);
            self.sync_pending_draft();
        } else if let Some((draft, attachments)) = self.pending_draft.take() {
            self.input = if self.input.is_empty() {
                draft
            } else {
                format!("{draft}\n{}", self.input)
            };
            self.cursor = self.input.len();
            self.attachments.extend(attachments);
        }
    }
    fn view_key(&mut self, key: KeyEvent) -> Vec<Command> {
        let mut out = vec![];
        if self.agent_detail_id.is_some() {
            if matches!(key.code, KeyCode::Char('m' | 'x')) {
                if let Some(index) = items(&self.snapshot, "agents")
                    .iter()
                    .position(|a| Some(text(a, "id")) == self.agent_detail_id.as_deref())
                {
                    self.selected = index;
                }
                self.agent_detail_id = None;
                self.scroll = 0;
                return self.view_key(key);
            }
            match key.code {
                KeyCode::Char('q') => {
                    self.agent_detail_id = None;
                    self.scroll = 0;
                }
                KeyCode::Char('j') | KeyCode::Down => self.scroll_by(1),
                KeyCode::Char('k') | KeyCode::Up => self.scroll_by(-1),
                KeyCode::Char(' ') | KeyCode::PageDown => self.scroll_by(8),
                KeyCode::PageUp => self.scroll_by(-8),
                _ => {}
            }
            return out;
        }
        if self.reviewing_proposed_write() {
            match key.code {
                KeyCode::Char('q') => self.view = View::Chat,
                KeyCode::Char(' ') | KeyCode::PageDown => {
                    self.scroll = self.scroll.saturating_add(8)
                }
                KeyCode::PageUp => self.scroll = self.scroll.saturating_sub(8),
                KeyCode::Char('j') | KeyCode::Down => self.scroll = self.scroll.saturating_add(1),
                KeyCode::Char('k') | KeyCode::Up => self.scroll = self.scroll.saturating_sub(1),
                _ => {}
            }
            return out;
        }
        let before = self.selected;
        match key.code {
            KeyCode::Char('q') => self.view = View::Chat,
            KeyCode::Char('j') | KeyCode::Down => self.selected = self.selected.saturating_add(1),
            KeyCode::Char('k') | KeyCode::Up => self.selected = self.selected.saturating_sub(1),
            KeyCode::Char(' ') => self.scroll = self.scroll.saturating_add(8),
            KeyCode::PageDown => self.scroll_by(8),
            KeyCode::PageUp => self.scroll_by(-8),
            KeyCode::Char('a') if self.view == View::Changes => {
                out.push(self.command("task.accept", json!({})))
            }
            KeyCode::Char('r') if self.view == View::Changes => {
                let list = items(&self.snapshot, "changes");
                if !list.is_empty() {
                    self.input =
                        format!("修改 {}：", text(&list[self.selected % list.len()], "path"));
                    self.cursor = self.input.len();
                    self.view = View::Chat;
                }
            }
            KeyCode::Enter | KeyCode::Char('o') if self.view == View::Changes => {
                let list = items(&self.snapshot, "changes");
                if !list.is_empty() {
                    let id = text(&list[self.selected % list.len()], "id").to_owned();
                    self.view = View::Chat;
                    self.open_diff_card(&id);
                    out.push(self.command("changes.diff", json!({"id":id})));
                }
            }
            KeyCode::Char('x') if self.view == View::Agents => {
                let list = items(&self.snapshot, "agents");
                if !list.is_empty() {
                    out.push(self.command(
                        "agent.stop",
                        json!({"id":list[self.selected%list.len()]["id"]}),
                    ));
                }
            }
            KeyCode::Enter if self.view == View::Agents => {
                let list = items(&self.snapshot, "agents");
                if !list.is_empty() {
                    let agent = &list[self.selected % list.len()];
                    let id=text(agent,"id").to_owned();
                    return self.open_agent_window(&id);
                }
            }
            KeyCode::Char('m') if self.view == View::Agents => {
                let agents = items(&self.snapshot, "agents");
                if !agents.is_empty() {
                    let agent = &agents[self.selected % agents.len()];
                    self.agent_message_id = Some(text(agent, "id").to_owned());
                    self.notice = format!("给 {} 发送补充要求", text(agent, "name"));
                    self.view = View::Chat;
                }
            }
            _ => {}
        }
        if self.view == View::Changes && before != self.selected {
            self.scroll = 0;
            let changes = items(&self.snapshot, "changes");
            if !changes.is_empty() {
                out.push(self.command(
                    "changes.diff",
                    json!({"id":changes[self.selected%changes.len()]["id"]}),
                ));
            }
        }
        out
    }
    pub fn drawer_items(&self) -> Vec<Value> {
        match self.drawer {
            Some(Drawer::Messages) => items(&self.snapshot, "messages").iter()
                .filter(|m| text(m,"role") == "user")
                .enumerate()
                .map(|(i,m)| {
                    let body = text(m,"text").split_whitespace().collect::<Vec<_>>().join(" ");
                    json!({"id":m["id"],"title":format!("{}. {}",i+1,if body.is_empty(){"[附件消息]"}else{&body})})
                })
                .filter(|m| fuzzy(text(m,"title"), &self.search)).collect(),
            Some(Drawer::Attachments) => self.attachments.iter().enumerate().map(|(i,v)|json!({"index":i,"title":format!("{} {} · {} · {} bytes",i+1,text(v,"_tag"),text(v,"name"),v["size"])})).collect(),
            Some(Drawer::Steps) => self.tool_step_items(),
            Some(Drawer::Rounds) => self.round_items(),
            Some(Drawer::Tasks) => items(&self.snapshot, "tasks")
                .iter()
                .filter(|t| {
                    fuzzy(
                        &format!(
                            "{} {} {}",
                            text(t, "title"),
                            text(t, "execution"),
                            text(t, "acceptance")
                        ),
                        &self.search,
                    )
                })
                .cloned()
                .collect(),
            Some(Drawer::Checkpoints) => self
                .checkpoint_points
                .iter()
                .filter(|p| fuzzy(text(p, "title"), &self.search))
                .cloned()
                .collect(),
            Some(Drawer::Model) => {
                let mut list: Vec<Value> = items(&self.snapshot, "models")
                    .iter()
                    .filter(|m| self.model_source_filter.as_deref().is_none_or(|id| text(m, "source_id") == id))
                    .filter(|m| {
                        format!(
                                "{} {} {}",
                                text(m, "id"),
                                text(m, "source"),
                                text(m, "source_host")
                        )
                        .to_lowercase().contains(&self.search.trim().to_lowercase())
                    })
                    .cloned()
                    .collect();
                let mut sources = vec![];
                for model in &list {
                    let source = model_source_key(model).to_owned();
                    if !sources.contains(&source) {
                        sources.push(source);
                    }
                }
                list.sort_by_key(|m| {
                    sources
                        .iter()
                        .position(|s| s == model_source_key(m))
                        .unwrap_or(0)
                });
                list
            }
            Some(Drawer::Library) => {
                let key = if self.library_sets { "sets" } else { "assets" };
                let mut list: Vec<(u8, Value)> = items(&self.library, key)
                    .iter()
                    .filter_map(|m| search_rank(text(m, "name"), &self.search).map(|r| (r, m.clone())))
                    .collect();
                list.sort_by_key(|(rank, _)| *rank);
                list.into_iter().map(|(_, m)| m).collect()
            }
            Some(Drawer::Sessions) => {
                let mut list: Vec<(u8, Value)> = items(&self.snapshot, "sessions")
                    .iter()
                    .filter_map(|m| {
                        search_rank(&format!("{} {}", text(m, "title"), text(m, "id")), &self.search)
                            .map(|rank| (rank, m.clone()))
                    })
                    .collect();
                // Best match first, then most recently updated (ISO-8601 sorts as text).
                list.sort_by(|(ra, a), (rb, b)| {
                    ra.cmp(rb).then_with(|| text(b, "updated_at").cmp(text(a, "updated_at")))
                });
                list.into_iter().map(|(_, m)| m).collect()
            }
            Some(Drawer::Workspace) => crate::workspaces::unique(self)
                .into_iter()
                .filter(|w| {
                    fuzzy(
                        &format!("{} {}", text(w, "name"), text(w, "path")),
                        &self.search,
                    )
                })
                .collect(),
            Some(Drawer::History) => self
                .history
                .iter()
                .filter(|x| fuzzy(x, &self.search))
                .map(|x| json!({"title":x}))
                .collect(),
            _ => vec![],
        }
    }
    fn drawer_key(&mut self, key: KeyEvent) -> Vec<Command> {
        let mut out = vec![];
        if self.drawer == Some(Drawer::Diff) {
            if let Some(bar) = crate::ui::diff_scrollbar(self, self.viewport.0, self.viewport.1) {
                self.selected = match key.code {
                    KeyCode::Up => bar.position.saturating_sub(1),
                    KeyCode::Down => bar.position.saturating_add(1).min(bar.maximum),
                    KeyCode::Left | KeyCode::PageUp => bar.position.saturating_sub(bar.page),
                    KeyCode::Right | KeyCode::PageDown => {
                        bar.position.saturating_add(bar.page).min(bar.maximum)
                    }
                    KeyCode::Home => 0,
                    KeyCode::End => bar.maximum,
                    KeyCode::Enter | KeyCode::Esc => {
                        self.drawer = None;
                        return out;
                    }
                    _ => bar.position,
                };
            }
            return out;
        }
        if self.drawer == Some(Drawer::Usage)
            && matches!(key.code, KeyCode::Enter | KeyCode::Char('d'))
        {
            self.usage_expanded = !self.usage_expanded;
            self.selected = 0;
            return out;
        }
        if matches!(
            self.drawer,
            Some(
                Drawer::Plan
                    | Drawer::CheckpointReview
                    | Drawer::Info
                    | Drawer::Usage
                    | Drawer::Diff
            )
        ) {
            match key.code {
                KeyCode::Down => self.selected = self.selected.saturating_add(1),
                KeyCode::Up => self.selected = self.selected.saturating_sub(1),
                KeyCode::PageDown => self.selected = self.selected.saturating_add(10),
                KeyCode::PageUp => self.selected = self.selected.saturating_sub(10),
                KeyCode::Home => self.selected = 0,
                KeyCode::Enter | KeyCode::Esc => self.drawer = None,
                _ => {}
            }
            return out;
        }
        if key.modifiers.contains(KeyModifiers::CONTROL) {
            match key.code {
                KeyCode::Char('n') => {
                    self.selected = self.selected.saturating_add(1);
                    self.full_confirm = false;
                }
                KeyCode::Char('p') => {
                    self.selected = self.selected.saturating_sub(1);
                    self.full_confirm = false;
                }
                KeyCode::Char('c') => {
                    self.search.clear();
                    self.search_cursor = 0;
                    self.selected = 0;
                }
                _ => {
                    let input = std::mem::take(&mut self.input);
                    let cursor = self.cursor;
                    let collapsed = self.paste_collapsed;
                    self.input = std::mem::take(&mut self.search);
                    self.cursor = text_cursor(&self.input, self.search_cursor);
                    self.edit_key(key);
                    self.search = std::mem::replace(&mut self.input, input);
                    self.search_cursor = self.cursor;
                    self.cursor = cursor;
                    self.paste_collapsed = collapsed;
                    self.selected = 0;
                }
            }
            return out;
        }
        let list = self.drawer_items();
        if key.code != KeyCode::Delete && self.library_confirm.take().is_some() {
            self.notice.clear();
        }
        if self.drawer == Some(Drawer::Attachments)
            && matches!(key.code, KeyCode::Delete)
            && !list.is_empty()
        {
            self.remove_attachment(self.selected % list.len());
            return vec![];
        }
        match key.code {
            KeyCode::Up | KeyCode::Left if self.drawer == Some(Drawer::Effort) => {
                let n = self.current_efforts().len().max(1);
                self.effort_index = (self.effort_index % n + n - 1) % n;
            }
            KeyCode::Down | KeyCode::Right if self.drawer == Some(Drawer::Effort) => {
                let n = self.current_efforts().len().max(1);
                self.effort_index = (self.effort_index % n + 1) % n;
            }
            KeyCode::Char(' ') | KeyCode::Tab if self.drawer == Some(Drawer::Effort) => {
                self.thinking = !self.thinking
            }
            KeyCode::Tab if self.drawer == Some(Drawer::Library) => {
                self.library_sets = !self.library_sets;
                self.selected = 0;
                self.library_confirm = None;
            }
            KeyCode::F(2) if self.drawer == Some(Drawer::Library) => {
                return self.open_management("library");
            }
            KeyCode::F(2) if self.drawer == Some(Drawer::Workspace) => {
                return self.open_workspace_permissions();
            }
            KeyCode::Delete if self.drawer == Some(Drawer::Library) => {
                if self.library_sets || list.is_empty() {
                    return out;
                }
                let item = &list[self.selected % list.len()];
                let id = text(item, "id").to_owned();
                if self.library_confirm.as_deref() != Some(id.as_str()) {
                    self.library_confirm = Some(id);
                    self.notice = format!(
                        "再按 Delete 从资料库删除「{}」；其他键取消",
                        text(item, "name")
                    );
                    return out;
                }
                self.library_confirm = None;
                let delete = self.command(
                    "terminal.action",
                    json!({"action":"library.delete","item_id":id,"confirmed":true}),
                );
                out.push(delete);
                out.extend(self.open_library());
                return out;
            }
            KeyCode::Left if self.drawer_has_search() => {
                let at = text_cursor(&self.search, self.search_cursor);
                self.search_cursor = self.search[..at]
                    .char_indices()
                    .next_back()
                    .map_or(0, |(i, _)| i);
            }
            KeyCode::Right if self.drawer_has_search() => {
                let at = text_cursor(&self.search, self.search_cursor);
                if let Some(c) = self.search[at..].chars().next() {
                    self.search_cursor = at + c.len_utf8();
                }
            }
            KeyCode::Home if self.drawer_has_search() => self.search_cursor = 0,
            KeyCode::End if self.drawer_has_search() => self.search_cursor = self.search.len(),
            KeyCode::Delete if self.drawer_has_search() => {
                let at = text_cursor(&self.search, self.search_cursor);
                if let Some(c) = self.search[at..].chars().next() {
                    self.search.drain(at..at + c.len_utf8());
                    self.selected = 0;
                }
            }
            KeyCode::Up => self.selected = self.selected.saturating_sub(1),
            KeyCode::Down => {
                self.selected = self.selected.saturating_add(1);
                self.full_confirm = false;
            }
            KeyCode::Enter => {
                match self.drawer {
                    Some(Drawer::Rounds) if !list.is_empty() => {
                        self.steps_round =
                            Some(text(&list[self.selected % list.len()], "id").into());
                        self.open(Drawer::Steps);
                        return vec![];
                    }
                    Some(Drawer::Attachments) if !list.is_empty() => {
                        return self.preview_attachment(
                            list[self.selected % list.len()]["index"]
                                .as_u64()
                                .unwrap_or(0) as usize,
                        );
                    }
                    Some(Drawer::Steps) if !list.is_empty() => {
                        let i = list[self.selected % list.len()]["index"]
                            .as_u64()
                            .unwrap_or(0) as usize;
                        let value = items(&self.snapshot, "steps")[i].clone();
                        return self.open_tool_detail(value);
                    }
                    Some(Drawer::Checkpoints) if !list.is_empty() => {
                        out.push(self.command(
                            "checkpoint.preview",
                            json!({"message_id":list[self.selected%list.len()]["id"]}),
                        ));
                    }
                    Some(Drawer::Tasks) if !list.is_empty() => {
                        out.push(Command {
                            method: "session.open".into(),
                            params: json!({"session_id":list[self.selected%list.len()]["id"]}),
                        });
                    }
                    Some(Drawer::Permissions) => {
                        let p = ["request", "assisted", "full"][self.selected % 3];
                        if p == "full" && !self.full_confirm {
                            self.full_confirm = true;
                            self.notice = "完全访问：再次按 enter 确认".into();
                            return out;
                        }
                        out.push(self.command(
                            "permission.set",
                            json!({"permission":p,"confirmed":p=="full"}),
                        ));
                    }
                    Some(Drawer::Model) if !list.is_empty() => {
                        let m = &list[self.selected % list.len()];
                        let efforts = items(m, "efforts");
                        out.push(self.command("model.set",json!({"choice":m["choice"],"thinking":self.thinking,"effort":efforts.get(self.effort_index%efforts.len().max(1)).cloned().unwrap_or(Value::Null)})));
                    }
                    Some(Drawer::Sessions) if !list.is_empty() => out.push(Command {
                        method: "session.open".into(),
                        params: json!({"session_id":list[self.selected%list.len()]["id"]}),
                    }),
                    Some(Drawer::Workspace) if self.active() => {
                        self.notice = "当前任务结束后才能切换".into();
                        return out;
                    }
                    Some(Drawer::Workspace) if !list.is_empty() => out.push(self.command(
                        "workspace.set",
                        json!({"workspace_id":list[self.selected%list.len()]["id"]}),
                    )),
                    Some(Drawer::History) if !list.is_empty() => {
                        self.input = text(&list[self.selected % list.len()], "title").into();
                        self.cursor = self.input.len();
                    }
                    Some(Drawer::Messages) if !list.is_empty() => {
                        crate::ui::focus_message(
                            self,
                            text(&list[self.selected % list.len()], "id"),
                        );
                    }
                    Some(Drawer::Login) => {
                        return self.open_login();
                    }
                    Some(Drawer::Library) if !list.is_empty() => {
                        let item = list[self.selected % list.len()].clone();
                        if self.library_sets {
                            self.show_info("正在加载…", vec![]);
                            self.extra_generation = self.extra_generation.wrapping_add(1);
                            let query = self.command(
                                "terminal.query",
                                json!({"topic":"library.set","set_id":item["id"],"ui_generation":self.extra_generation}),
                            );
                            out.push(query);
                            return out;
                        }
                        out.extend(self.attach_library_item(&item));
                    }
                    Some(Drawer::Effort) => {
                        let efforts = self.current_efforts();
                        let effort = efforts
                            .get(self.effort_index % efforts.len().max(1))
                            .cloned()
                            .unwrap_or(Value::Null);
                        let thinking = self.thinking;
                        out.extend(self.set_effort(effort, thinking));
                    }
                    _ => {}
                }
                self.drawer = None;
            }
            KeyCode::Backspace => {
                self.search_cursor = text_cursor(&self.search, self.search_cursor);
                if let Some((index, _)) =
                    self.search[..self.search_cursor].char_indices().next_back()
                {
                    self.search.drain(index..self.search_cursor);
                    self.search_cursor = index;
                }
                self.selected = 0;
            }
            KeyCode::Char(c) => {
                self.search_cursor = text_cursor(&self.search, self.search_cursor);
                self.search.insert(self.search_cursor, c);
                self.search_cursor += c.len_utf8();
                self.selected = 0;
            }
            _ => {}
        }
        out
    }

    pub fn click_popup_action(&mut self, action: crate::ui::PopupAction) -> Vec<Command> {
        use crate::ui::PopupAction;
        match action {
            PopupAction::ShellCopy => self.copy_requested = Some(self.shell_output.clone()),
            PopupAction::ShellCancel => return self.cancel_shell(),
            PopupAction::ShellRefresh => return self.open_shell(),
            PopupAction::ToolSection(index) => {
                self.tool_section = index;
                self.selected = 0;
            }
            PopupAction::ToolCopy => {
                self.copy_requested = Some(crate::tool_view::detail_text(
                    &self.tool_detail,
                    self.tool_section,
                ))
            }
            PopupAction::ToolRefresh => return self.refresh_tool_detail(),
            PopupAction::LibraryManage => return self.open_management("library"),
            PopupAction::WorkspacePermissions => return self.open_workspace_permissions(),
            PopupAction::EditorButton(index) => return self.native_editor_button(index),
            PopupAction::EditorCursor(x, y) => self.native_editor_click(x, y),
            PopupAction::UsageDetails => {
                self.usage_expanded = !self.usage_expanded;
                self.selected = 0;
            }
            PopupAction::SkinSelect(index) => {
                if let Some(form) = self.form.as_mut() {
                    form.selected = index;
                }
            }
            PopupAction::SkinApply => return self.form_activate(),
            PopupAction::SkinCustom => {
                if let Some(form) = self.form.as_mut() {
                    form.selected = crate::theme::SKINS.len();
                }
                return self.form_activate();
            }
            PopupAction::Question(index) => self.switch_question(index),
            PopupAction::AnswerOption(index) => self.choose_question_option(index),
            PopupAction::AnswerText => self.question_ui.editing = true,
            PopupAction::AnswerNext => self.switch_question(
                (self.question_index + 1).min(
                    items(&self.snapshot["questions"][0], "questions")
                        .len()
                        .saturating_sub(1),
                ),
            ),
            PopupAction::AnswerSubmit => return self.submit_question_answers(),
            PopupAction::Thinking => self.thinking = !self.thinking,
            PopupAction::Apply => return self.drawer_key(KeyEvent::from(KeyCode::Enter)),
            PopupAction::LibraryTab(sets) => {
                self.library_sets = sets;
                self.selected = 0;
                self.library_confirm = None;
            }
            PopupAction::Item(index) => {
                if self.drawer == Some(Drawer::Effort) {
                    self.effort_index = index;
                } else {
                    if self.selected != index {
                        self.full_confirm = false;
                    }
                    self.selected = index;
                }
                return self.drawer_key(KeyEvent::from(KeyCode::Enter));
            }
        }
        vec![]
    }

    pub fn open_message_history(&mut self, id: &str) {
        self.selection = None;
        self.open(Drawer::Messages);
        let list = self.drawer_items();
        self.selected = list
            .iter()
            .position(|m| text(m, "id") == id)
            .unwrap_or(list.len().saturating_sub(1));
    }
    pub fn open_diff_card(&mut self, id: &str) {
        if let Some(change) = items(&self.snapshot, "changes")
            .iter()
            .find(|c| text(c, "id") == id)
            .cloned()
        {
            self.selection = None;
            self.open(Drawer::Diff);
            self.diff_detail = change;
        }
    }
}
macro_rules! commands {
    ($(($name:literal,$description:literal,$usage:literal)),* $(,)?)=>{
        pub const COMMANDS:&[&str]=&[$($name),*];
        pub const COMMAND_SPECS:&[CommandSpec]=&[$(CommandSpec{name:$name,description:$description,usage:$usage}),*];
    }
}
commands![
    ("/todo", "查看任务待办清单", "/todo"),
    ("/questions", "打开待回答的问题", "/questions"),
    (
        "/editor",
        "终端内编辑草稿（Alt+E）；external 打开外部编辑器",
        "/editor [external]"
    ),
    ("/tasks", "跨会话任务总览", "/tasks"),
    (
        "/rewind",
        "查看检查点并选择回退范围",
        "/rewind [消息ID|conversation|files|both|branch]"
    ),
    (
        "/plan",
        "查看、评论或批准指定版本计划",
        "/plan [approve 版本|cancel 版本|comment 版本 意见]"
    ),
    ("/find", "搜索会话正文", "/find 关键词"),
    ("/next", "下一处正文匹配", "/next"),
    ("/prev", "上一处正文匹配", "/prev"),
    ("/latest", "回到最新输出并继续跟随", "/latest"),
    (
        "/jump",
        "跳到上一条用户消息或失败步骤",
        "/jump user|failure"
    ),
    (
        "/copy",
        "复制回复、整段正文或会话编号",
        "/copy [all|session]"
    ),
    ("/model", "切换模型与思考强度", "/model"),
    ("/mode", "工作或计划模式", "/mode [work|plan]"),
    ("/permissions", "选择工具权限", "/permissions"),
    ("/settings", "终端内设置", "/settings"),
    ("/provider", "管理模型来源与API密钥", "/provider"),
    ("/mcp", "管理MCP服务与工具", "/mcp"),
    (
        "/attach",
        "添加文件、图片、视频或音频",
        "/attach [文件路径|cancel]"
    ),
    ("/detach", "移除草稿附件", "/detach [编号|all]"),
    ("/skin", "切换终端皮肤", "/skin [皮肤名]"),
    ("/sessions", "选择历史会话", "/sessions"),
    ("/resume", "继续最近或指定会话", "/resume [会话ID]"),
    ("/workspace", "切换工作区与管理目录权限", "/workspace"),
    ("/new", "新建工作会话", "/new"),
    ("/stop", "立即中断任务", "/stop"),
    ("/compact", "整理公开上下文", "/compact"),
    ("/recover", "恢复失败草稿与发送目标", "/recover"),
    ("/pet", "宠物动作及开关", "/pet [on|off]"),
    ("/login", "添加模型登录来源", "/login"),
    ("/doctor", "查看终端设置与配置", "/doctor"),
    ("/help", "快捷键与命令说明", "/help [commands]"),
    ("/gui", "在图形界面定位当前会话", "/gui"),
    ("/library", "资料库：素材与资料集", "/library"),
    ("/media", "打开媒体工作区", "/media"),
    ("/bridge", "关闭桥接且保留后台任务", "/bridge off"),
    ("/quit", "退出终端，后台任务继续", "/quit")
];
pub fn command_metadata(command: &str) -> (&'static str, &'static str) {
    if let Some(value) = crate::commands::metadata(command) {
        return value;
    }
    COMMAND_SPECS
        .iter()
        .find(|c| c.name == command)
        .map(|c| (c.description, c.usage))
        .unwrap_or(("终端命令", ""))
}
/// Search rank, lower is better: prefix, substring, all words, then a loose
/// subsequence only for ASCII queries (CJK subsequences match nearly anything).
pub fn search_rank(value: &str, query: &str) -> Option<u8> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Some(0);
    }
    let value = value.to_lowercase();
    if value.starts_with(&query) {
        return Some(0);
    }
    if value.contains(&query) {
        return Some(1);
    }
    if query.split_whitespace().all(|word| value.contains(word)) {
        return Some(2);
    }
    (query.is_ascii() && fuzzy(&value, &query)).then_some(3)
}
fn fuzzy(value: &str, query: &str) -> bool {
    let lower = value.to_lowercase();
    let mut chars = lower.chars();
    query
        .to_lowercase()
        .chars()
        .all(|q| chars.by_ref().any(|c| c == q))
}

fn text_cursor(value: &str, cursor: usize) -> usize {
    let mut cursor = cursor.min(value.len());
    while !value.is_char_boundary(cursor) {
        cursor = cursor.saturating_sub(1);
    }
    cursor
}
