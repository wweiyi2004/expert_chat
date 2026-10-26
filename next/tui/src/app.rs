use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

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

pub fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
pub fn items<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    v[key].as_array().map(Vec::as_slice).unwrap_or(&[])
}
#[derive(Debug, Clone, PartialEq)]
pub struct Command {
    pub method: String,
    pub params: Value,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum View {
    Chat,
    Changes,
    Agents,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Drawer {
    Model,
    Permissions,
    Sessions,
    Workspace,
    Help,
    History,
    Login,
}
#[derive(Debug)]
pub struct App {
    pub snapshot: Value,
    pub input: String,
    pub notice: String,
    pub drawer: Option<Drawer>,
    pub view: View,
    pub selected: usize,
    pub scroll: u16,
    pub expanded: bool,
    pub sidebar: bool,
    pub approval_collapsed: bool,
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
    pub reduce_motion: bool,
    pub ambiguous_width: u8,
    pub pet: crate::pet::Pet,
    pub completion_closed: bool,
    pub files: Vec<String>,
    pub search: String,
    pub effort_index: usize,
    pub thinking: bool,
    pub model_effort_focus: bool,
    pub retry: Option<Value>,
    pub tick: u64,
    pub clipboard_requested: bool,
    pub attachments: Vec<Value>,
    pub question_index: usize,
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
}
impl Default for App {
    fn default() -> Self {
        Self {
            snapshot: json!({}),
            input: String::new(),
            notice: String::new(),
            drawer: None,
            view: View::Chat,
            selected: 0,
            scroll: 0,
            expanded: false,
            sidebar: false,
            approval_collapsed: false,
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
            reduce_motion: false,
            ambiguous_width: 1,
            pet: Default::default(),
            completion_closed: false,
            files: vec![],
            search: String::new(),
            effort_index: 0,
            thinking: true,
            model_effort_focus: false,
            retry: None,
            tick: 0,
            clipboard_requested: false,
            attachments: vec![],
            question_index: 0,
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
        }
    }
}
impl App {
    pub fn apply_event(&mut self, envelope: &Value) -> anyhow::Result<()> {
        anyhow::ensure!(envelope["v"] == 1, "unsupported protocol version");
        let d = &envelope["data"];
        match text(envelope, "event") {
            "snapshot" => self.apply_snapshot(d.clone()),
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
                self.upsert("approvals", d);
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
        self.snapshot_stale = false;
        self.snapshot_error = None;
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
            if let Some(id) = self.session_id().map(str::to_owned) {
                let draft = self.current_draft();
                self.session_drafts.insert(id, draft);
            }
            let draft = snapshot["session"]["id"]
                .as_str()
                .and_then(|id| self.session_drafts.remove(id))
                .unwrap_or_default();
            self.load_draft(draft);
            self.drawer = None;
            self.view = View::Chat;
            self.agent_detail_id = None;
            self.scroll = 0;
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
        if self.completion_closed || self.drawer.is_some() {
            return vec![];
        }
        if self.input.starts_with('/') && !self.input.contains(' ') {
            return COMMANDS
                .iter()
                .filter(|s| s.starts_with(&self.input))
                .map(|s| s.to_string())
                .collect();
        }
        if let Some((_, q)) = self.input.rsplit_once('@') {
            return self.files.iter().filter(|s| fuzzy(s, q)).cloned().collect();
        }
        vec![]
    }
    pub fn open(&mut self, d: Drawer) {
        if self.view != View::Chat {
            self.scroll = 0;
        }
        self.view = View::Chat;
        self.agent_detail_id = None;
        self.drawer = Some(d);
        self.selected = 0;
        self.search.clear();
        self.search_cursor = 0;
        self.full_confirm = false;
        self.model_effort_focus = false;
        if d == Drawer::Model {
            let models = items(&self.snapshot, "models");
            if let Some(i) = models
                .iter()
                .position(|m| m["choice"] == self.snapshot["session"]["model_choice"])
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
        self.viewport.0 = width;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if !(ctrl && key.code == KeyCode::Char('c')) {
            self.exit_at = None;
        }
        if key.code != KeyCode::Esc {
            self.esc_at = None;
        }
        if key.code == KeyCode::Esc {
            if self.drawer.take().is_some() {
                self.full_confirm = false;
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
            if let KeyCode::Char(c) = key.code {
                if c == 'e' {
                    self.rejection_draft = Some(self.current_draft());
                    self.rejection = true;
                    self.input.clear();
                    self.cursor = 0;
                    self.attachments.clear();
                    self.paste_collapsed = false;
                } else if let Some(decision) = match c {
                    'y' => Some("once"),
                    'a' => Some("session"),
                    'n' => Some("reject"),
                    _ => None,
                } {
                    return vec![self.command(
                        "approval.decide",
                        json!({"id":self.snapshot["approvals"][0]["id"],"decision":decision}),
                    )];
                }
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
            KeyCode::Enter if key.modifiers.contains(KeyModifiers::SHIFT) => self.insert("\n"),
            KeyCode::Enter => {
                let completion = self.completion();
                if !completion.is_empty() {
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
                    let c=self.command("approval.decide",json!({"id":self.snapshot["approvals"][0]["id"],"decision":"reject_reason","reason":self.input}));
                    self.cancel_rejection();
                    return vec![c];
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
        self.preferred_column = None;
        self.cursor = self.cursor.min(self.input.len());
        self.input.insert_str(self.cursor, s);
        self.cursor += s.len();
    }
    pub fn paste(&mut self, s: &str) {
        if self.view != View::Chat {
            return;
        }
        let s = s.replace("\r\n", "\n").replace('\r', "\n");
        if self.drawer.is_some() {
            if !matches!(
                self.drawer,
                Some(Drawer::Model | Drawer::Sessions | Drawer::Workspace | Drawer::History)
            ) {
                return;
            }
            self.search_cursor = self.search_cursor.min(self.search.len());
            let query = s.replace('\n', " ");
            self.search.insert_str(self.search_cursor, &query);
            self.search_cursor += query.len();
            self.selected = 0;
        } else if self.status() != "approval" || self.approval_collapsed || self.rejection {
            self.insert(&s);
            self.paste_collapsed = s.lines().count() > 5;
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
    fn edit_key(&mut self, key: KeyEvent) -> bool {
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
        true
    }
    fn vertical(&mut self, direction: i32, terminal_width: u16) {
        self.paste_collapsed = false;
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
    fn load_draft(&mut self, draft: Draft) {
        self.preferred_column = None;
        self.input = draft.text;
        self.cursor = draft.cursor.min(self.input.len());
        self.attachments = draft.attachments;
        self.agent_message_id = draft.agent_id;
        self.paste_collapsed = draft.collapsed;
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
    fn track_input(
        &mut self,
        command: Command,
        draft: Draft,
        question_state: Option<(usize, serde_json::Map<String, Value>)>,
    ) -> Vec<Command> {
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
                self.notice.clear();
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
    pub fn command_error(&mut self, command: &Command, message: &str) {
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
            self.attachments.push(attachment);
            self.notice = "已添加剪贴板图片".into();
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
        self.cursor = self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map_or(0, |(i, _)| i);
    }
    fn right(&mut self) {
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
        if let Some(c) = self.input[self.cursor..].chars().next() {
            self.input.drain(self.cursor..self.cursor + c.len_utf8());
        }
    }
    fn answer_question(&mut self) -> Vec<Command> {
        let request = &self.snapshot["questions"][0];
        let request_id = text(request, "id").to_owned();
        if self
            .answered_questions
            .contains(&(self.session_id().unwrap_or("").into(), request_id.clone()))
            || self.pending_inputs.iter().any(|p| {
                p.command.method == "question.answer"
                    && p.command.params["session_id"] == self.snapshot["session"]["id"]
                    && p.command.params["id"] == request_id
            })
        {
            self.notice = "答案已提交，等待服务器确认".into();
            return vec![];
        }
        let questions = items(request, "questions");
        let Some(q) = questions.get(self.question_index) else {
            return vec![];
        };
        let input = self.input.trim();
        let options = items(q, "options");
        let tokens: Vec<&str> = input.split(',').map(str::trim).collect();
        let has_numeric = !options.is_empty() && tokens.iter().any(|n| n.parse::<usize>().is_ok());
        let mut selected = vec![];
        if has_numeric {
            for token in tokens {
                let option = token
                    .parse::<usize>()
                    .ok()
                    .and_then(|n| n.checked_sub(1))
                    .and_then(|i| options.get(i));
                let Some(option) = option else {
                    self.notice = "选项编号无效；请只输入有效编号，或直接填写文字说明".into();
                    return vec![];
                };
                if !selected.contains(option) {
                    selected.push(option.clone());
                }
            }
        }
        if q["multiple"] != true && selected.len() > 1 {
            self.notice = "请选择一个选项".into();
            return vec![];
        }
        let free_text = if selected.is_empty() { input } else { "" };
        if q["required"] == true && selected.is_empty() && free_text.is_empty() {
            self.notice = "请回答此必答问题".into();
            return vec![];
        }
        let draft = self.current_draft();
        self.question_answers.insert(
            text(q, "id").into(),
            json!({"selected":selected,"text":free_text}),
        );
        self.input.clear();
        self.cursor = 0;
        self.paste_collapsed = false;
        self.question_index += 1;
        if self.question_index < questions.len() {
            return vec![];
        }
        let command = self.command(
            "question.answer",
            json!({"id":request_id,"answers":self.question_answers}),
        );
        let state = (self.question_index - 1, self.question_answers.clone());
        self.track_input(command, draft, Some(state))
    }
    fn submit(&mut self) -> Vec<Command> {
        let trimmed = self.input.trim();
        if trimmed.starts_with('/') {
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
                "/model" => self.open(Drawer::Model),
                "/permissions" => self.open(Drawer::Permissions),
                "/workspace" => self.open(Drawer::Workspace),
                "/sessions" => self.open(Drawer::Sessions),
                "/help" => self.open(Drawer::Help),
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
                "/accept" => return vec![self.command("task.accept", json!({}))],
                "/stop" => return vec![self.command("task.stop", json!({}))],
                "/new" => {
                    return vec![Command {
                        method: "session.new".into(),
                        params: json!({"workspace_id":self.snapshot["session"]["workspace_id"]}),
                    }];
                }
                "/quit" | "/exit" => self.exit = true,
                "/login" | "/settings" | "/doctor" | "/mcp" => {
                    return vec![self.command("gui.open", json!({"page":"settings"}))];
                }
                "/library" => return vec![self.command("gui.open", json!({"page":"library"}))],
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
            self.open(Drawer::Login);
            return vec![];
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
    fn is_control_command(input: &str) -> bool {
        let command = input.split_whitespace().next().unwrap_or("");
        COMMANDS.contains(&command) || matches!(command, "/exit" | "/settings")
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
                    out.push(self.command(
                        "gui.open",
                        json!({"change_id":list[self.selected%list.len()]["id"]}),
                    ));
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
                    self.agent_detail_id = Some(text(agent, "id").into());
                    self.scroll = 0;
                    let task = text(agent, "task");
                    self.notice = if task.is_empty() {
                        text(agent, "output").into()
                    } else {
                        format!("{task}\n{}", text(agent, "output"))
                    };
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
            Some(Drawer::Model) => items(&self.snapshot, "models")
                .iter()
                .filter(|m| fuzzy(text(m, "id"), &self.search))
                .cloned()
                .collect(),
            Some(Drawer::Sessions) => items(&self.snapshot, "sessions")
                .iter()
                .filter(|m| fuzzy(text(m, "title"), &self.search))
                .cloned()
                .collect(),
            Some(Drawer::Workspace) => items(&self.snapshot, "workspaces")
                .iter()
                .filter(|w| {
                    fuzzy(
                        &format!("{} {}", text(w, "name"), text(w, "path")),
                        &self.search,
                    )
                })
                .cloned()
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
                    self.cursor = self.search_cursor.min(self.input.len());
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
        match key.code {
            KeyCode::Up => self.selected = self.selected.saturating_sub(1),
            KeyCode::Down => {
                self.selected = self.selected.saturating_add(1);
                self.full_confirm = false;
            }
            KeyCode::Tab if self.drawer == Some(Drawer::Model) => {
                self.model_effort_focus = !self.model_effort_focus
            }
            KeyCode::Left if self.drawer == Some(Drawer::Model) => {
                self.effort_index = self.effort_index.saturating_sub(1)
            }
            KeyCode::Right if self.drawer == Some(Drawer::Model) => {
                self.effort_index = self.effort_index.saturating_add(1)
            }
            KeyCode::Char(' ') if self.drawer == Some(Drawer::Model) && self.model_effort_focus => {
                self.thinking = !self.thinking
            }
            KeyCode::Enter => {
                match self.drawer {
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
                    Some(Drawer::Login) => {
                        out.push(self.command("gui.open", json!({"page":"settings"})))
                    }
                    _ => {}
                }
                self.drawer = None;
            }
            KeyCode::Backspace => {
                self.search_cursor = self.search_cursor.min(self.search.len());
                if let Some((index, _)) =
                    self.search[..self.search_cursor].char_indices().next_back()
                {
                    self.search.drain(index..self.search_cursor);
                    self.search_cursor = index;
                }
                self.selected = 0;
            }
            KeyCode::Char(c) => {
                self.search_cursor = self.search_cursor.min(self.search.len());
                self.search.insert(self.search_cursor, c);
                self.search_cursor += c.len_utf8();
                self.selected = 0;
            }
            _ => {}
        }
        out
    }
}
pub const COMMANDS: &[&str] = &[
    "/gui",
    "/bridge",
    "/library",
    "/media",
    "/model",
    "/mode",
    "/permissions",
    "/sessions",
    "/resume",
    "/workspace",
    "/login",
    "/new",
    "/accept",
    "/stop",
    "/compact",
    "/recover",
    "/doctor",
    "/mcp",
    "/pet",
    "/help",
    "/quit",
];
fn fuzzy(value: &str, query: &str) -> bool {
    let lower = value.to_lowercase();
    let mut chars = lower.chars();
    query
        .to_lowercase()
        .chars()
        .all(|q| chars.by_ref().any(|c| c == q))
}
