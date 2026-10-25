use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

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
            "request.retry" => self.retry = Some(d.clone()),
            "request.error" => {
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
        let selected_agent = if self.view == View::Agents {
            let agents = items(&self.snapshot, "agents");
            agents
                .get(self.selected % agents.len().max(1))
                .map(|a| a["id"].clone())
        } else {
            None
        };
        if self.snapshot["session"]["id"] != snapshot["session"]["id"] {
            self.welcome_seen = false;
            self.history.clear();
        }
        if self.history.is_empty() {
            self.history = items(&snapshot, "messages")
                .iter()
                .filter(|m| m["role"] == "user")
                .map(|m| text(m, "text").to_owned())
                .collect();
            self.history_index = self.history.len();
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
        self.retry = None;
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
        self.drawer = Some(d);
        self.selected = 0;
        self.search.clear();
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
        let mut out = vec![];
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if key.code == KeyCode::Esc {
            if self.drawer.take().is_some() {
                self.full_confirm = false;
                return out;
            }
            if self.view != View::Chat {
                self.view = View::Chat;
                return out;
            }
            if !self.completion().is_empty() {
                self.completion_closed = true;
                return out;
            }
            if self.status() == "approval" && !self.approval_collapsed {
                self.approval_collapsed = true;
                self.rejection = false;
                return out;
            }
            if self.active() {
                if self
                    .esc_at
                    .is_some_and(|t| now.duration_since(t) < Duration::from_millis(1500))
                {
                    out.push(self.command("task.stop", json!({})));
                    self.esc_at = None;
                } else {
                    self.esc_at = Some(now);
                }
            }
            return out;
        }
        if ctrl {
            match key.code {
                KeyCode::Char('c') => {
                    if !self.input.is_empty() {
                        self.input.clear();
                        self.cursor = 0;
                    } else if self.active() {
                        out.push(self.command("task.stop", json!({})));
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
                KeyCode::Char('j') => self.insert("\n"),
                KeyCode::Char('o') => self.expanded = !self.expanded,
                KeyCode::Char('g') => {
                    self.view = View::Changes;
                    self.selected = 0;
                    self.scroll = 0;
                    if !self.reviewing_proposed_write()
                        && let Some(change) = items(&self.snapshot, "changes").first()
                    {
                        out.push(self.command("changes.diff", json!({"id":change["id"]})));
                    }
                }
                KeyCode::Char('t') => {
                    self.view = View::Agents;
                    self.selected = 0;
                }
                KeyCode::Char('y') => {
                    self.approval_collapsed = false;
                    self.view = View::Chat;
                }
                KeyCode::Char('r') => self.open(Drawer::History),
                KeyCode::Char('b') if self.input.is_empty() && width >= 140 => {
                    self.sidebar = !self.sidebar
                }
                KeyCode::Char('b') => self.left(),
                KeyCode::Char('f') => self.right(),
                KeyCode::Char('a') => self.cursor = 0,
                KeyCode::Char('e') => self.cursor = self.input.len(),
                KeyCode::Char('u') => {
                    self.input.drain(..self.cursor);
                    self.cursor = 0;
                }
                KeyCode::Char('k') => {
                    self.input.truncate(self.cursor);
                }
                KeyCode::Char('w') => {
                    while self.cursor > 0
                        && self.input[..self.cursor].ends_with(char::is_whitespace)
                    {
                        self.backspace();
                    }
                    while self.cursor > 0
                        && !self.input[..self.cursor].ends_with(char::is_whitespace)
                    {
                        self.backspace();
                    }
                }
                KeyCode::Char('h') => self.backspace(),
                KeyCode::Char('d') => self.delete(),
                KeyCode::Char('v') => self.clipboard_requested = true,
                KeyCode::Char('n') => self.selected = self.selected.saturating_add(1),
                KeyCode::Char('p') => self.selected = self.selected.saturating_sub(1),
                _ => {}
            }
            return out;
        }
        if self.view != View::Chat {
            return self.view_key(key);
        }
        if self.drawer.is_some() {
            return self.drawer_key(key);
        }
        if self.status() == "approval" && !self.approval_collapsed && !self.rejection {
            if let KeyCode::Char(c) = key.code {
                if c == 'e' {
                    self.rejection = true;
                    self.input.clear();
                    self.cursor = 0;
                } else if let Some(decision) = match c {
                    'y' => Some("once"),
                    'a' => Some("session"),
                    'n' => Some("reject"),
                    _ => None,
                } {
                    let id = &self.snapshot["approvals"][0]["id"];
                    out.push(self.command("approval.decide", json!({"id":id,"decision":decision})));
                }
            }
            return out;
        }
        match key.code {
            KeyCode::BackTab => out.push(self.command(
                "mode.set",
                json!({"mode":if self.snapshot["session"]["mode"]=="plan"{"work"}else{"plan"}}),
            )),
            KeyCode::Enter if key.modifiers.contains(KeyModifiers::SHIFT) => self.insert("\n"),
            KeyCode::Enter => {
                let completion = self.completion();
                if !completion.is_empty() {
                    let value = completion[self.selected % completion.len()].clone();
                    if self.input.starts_with('/') {
                        self.input = value;
                        self.cursor = self.input.len();
                        self.completion_closed = true;
                    } else if let Some(pos) = self.input.rfind('@') {
                        self.input.replace_range(pos + 1.., &value);
                        self.cursor = self.input.len();
                        self.completion_closed = true;
                        return out;
                    }
                }
                if self.rejection {
                    out.push(self.command("approval.decide",json!({"id":self.snapshot["approvals"][0]["id"],"decision":"reject_reason","reason":self.input})));
                    self.rejection = false;
                    self.input.clear();
                    self.cursor = 0;
                } else if !items(&self.snapshot, "questions").is_empty() {
                    out.extend(self.answer_question());
                } else {
                    out.extend(self.submit());
                }
            }
            KeyCode::Tab => {
                let c = self.completion();
                if !c.is_empty() {
                    let value = &c[self.selected % c.len()];
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
            KeyCode::Up
                if self.input.is_empty()
                    || self
                        .history
                        .get(self.history_index)
                        .is_some_and(|s| s == &self.input) =>
            {
                if let Some(q) = items(&self.snapshot, "queued")
                    .iter()
                    .rev()
                    .find(|q| q["status"] == "queued")
                {
                    out.push(self.command("queue.remove", json!({"id":q["id"]})));
                } else if !self.history.is_empty() {
                    self.history_index = self.history_index.saturating_sub(1);
                    self.input = self.history[self.history_index].clone();
                    self.cursor = self.input.len();
                }
            }
            KeyCode::Down if self.history_index < self.history.len() => {
                self.history_index += 1;
                self.input = self
                    .history
                    .get(self.history_index)
                    .cloned()
                    .unwrap_or_default();
                self.cursor = self.input.len();
            }
            KeyCode::Left => self.left(),
            KeyCode::Right => self.right(),
            KeyCode::Home => self.cursor = 0,
            KeyCode::End => self.cursor = self.input.len(),
            KeyCode::Backspace => self.backspace(),
            KeyCode::Delete => self.delete(),
            KeyCode::PageUp => self.scroll = self.scroll.saturating_add(8),
            KeyCode::PageDown => self.scroll = self.scroll.saturating_sub(8),
            KeyCode::Char('?') if self.input.is_empty() => self.open(Drawer::Help),
            KeyCode::Char(c) => {
                self.insert(&c.to_string());
                self.completion_closed = false;
                if c == '@' {
                    out.push(self.command("files.list", json!({"query":""})));
                } else if c == '/'
                    && let Some((_, query)) = self.input.rsplit_once('@')
                    && !query.chars().any(char::is_whitespace)
                {
                    self.files.clear();
                    out.push(self.command("files.list", json!({"query":query})));
                }
            }
            _ => {}
        }
        out
    }
    pub fn insert(&mut self, s: &str) {
        self.input.insert_str(self.cursor, s);
        self.cursor += s.len();
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
        let questions = items(request, "questions");
        let Some(q) = questions.get(self.question_index) else {
            return vec![];
        };
        let input = self.input.trim();
        let options = items(q, "options");
        let selected: Vec<Value> = input
            .split(',')
            .filter_map(|n| n.trim().parse::<usize>().ok())
            .filter_map(|n| n.checked_sub(1).and_then(|i| options.get(i)))
            .cloned()
            .collect();
        if q["multiple"] != true && selected.len() > 1 {
            self.notice = "请选择一个选项".into();
            return vec![];
        }
        let free_text = if selected.is_empty() { input } else { "" };
        if q["required"] == true && selected.is_empty() && free_text.is_empty() {
            self.notice = "请回答此必答问题".into();
            return vec![];
        }
        self.question_answers.insert(
            text(q, "id").into(),
            json!({"selected":selected,"text":free_text}),
        );
        self.input.clear();
        self.cursor = 0;
        self.question_index += 1;
        if self.question_index < questions.len() {
            return vec![];
        }
        let result = self.command(
            "question.answer",
            json!({"id":request["id"],"answers":self.question_answers}),
        );
        self.question_index = 0;
        vec![result]
    }
    fn submit(&mut self) -> Vec<Command> {
        if self.pending_draft.is_some() {
            self.notice = "上一条消息仍待服务器确认".into();
            return vec![];
        }
        if self.active() && !self.attachments.is_empty() {
            self.notice = "任务运行中只支持文字补充；请在本轮结束后发送附件".into();
            return vec![];
        }
        let input = std::mem::take(&mut self.input);
        self.cursor = 0;
        self.completion_closed = true;
        if input.trim().is_empty() && self.attachments.is_empty() {
            return if self.status() == "stopped" {
                vec![self.command("task.resume", json!({}))]
            } else {
                vec![]
            };
        }
        self.history.push(input.clone());
        self.history_index = self.history.len();
        if let Some(id) = self.agent_message_id.take() {
            self.pending_draft = Some((input.clone(), vec![]));
            return vec![self.command("agent.message", json!({"id":id,"text":input}))];
        }
        let mut split = input.splitn(2, ' ');
        let cmd = split.next().unwrap_or("");
        let arg = split.next().unwrap_or("");
        match cmd {
   "/model"=>self.open(Drawer::Model),"/permissions"=>self.open(Drawer::Permissions),"/workspace"=>self.open(Drawer::Workspace),"/sessions"=>self.open(Drawer::Sessions),"/help"=>self.open(Drawer::Help),
   "/resume"=>{if !arg.is_empty(){return vec![Command{method:"session.open".into(),params:json!({"session_id":arg})}];} else if let Some(s)=items(&self.snapshot,"sessions").first(){return vec![Command{method:"session.open".into(),params:json!({"session_id":s["id"]})}];}self.open(Drawer::Sessions);},
   "/pet"=>{if arg=="off"{self.pet.enabled=false;if let Err(e)=crate::config::save_pet(false){self.notice=e.to_string();}}else{self.pet.click(Instant::now(),self.reduce_motion);}},
   "/mode"=>return vec![self.command("mode.set",json!({"mode":if arg=="plan"||self.snapshot["session"]["mode"]!="plan"{"plan"}else{"work"}}))],
   "/accept"=>return vec![self.command("task.accept",json!({}))],"/stop"=>return vec![self.command("task.stop",json!({}))],
   "/new"=>return vec![Command{method:"session.new".into(),params:json!({"workspace_id":self.snapshot["session"]["workspace_id"]})}],
   "/quit"|"/exit"=>self.exit=true,
   "/login"|"/settings"|"/doctor"|"/mcp"=>return vec![self.command("gui.open",json!({"page":"settings"}))],
   "/library"=>return vec![self.command("gui.open",json!({"page":"library"}))],
   "/media"=>return vec![self.command("gui.open",json!({"page":"media"}))],
   "/bridge" if arg == "off" => return vec![self.command("bridge.stop", json!({}))],
   "/bridge" => self.notice = "使用 /bridge off 关闭桥接；后台任务继续运行".into(),
   "/compact"=>self.notice="请在 GUI 中整理上下文".into(),
   _ if cmd.starts_with('/')=>self.notice=format!("未知命令：{cmd} · /help"),
   _=>{if items(&self.snapshot,"models").is_empty(){self.input=input;self.cursor=self.input.len();self.open(Drawer::Login);}else{let attachments=std::mem::take(&mut self.attachments);self.pending_draft=Some((input.clone(),attachments.clone()));return vec![self.command(if self.active(){"queue.add"}else{"message.send"},json!({"text":input,"attachments":attachments}))];}}
  }
        vec![]
    }
    pub fn restore_draft(&mut self) {
        if let Some((draft, attachments)) = self.pending_draft.take() {
            if self.input.is_empty() {
                self.input = draft;
            } else {
                self.input = format!("{draft}\n{}", self.input);
            }
            self.cursor = self.input.len();
            self.attachments.extend(attachments);
        }
    }
    fn view_key(&mut self, key: KeyEvent) -> Vec<Command> {
        let mut out = vec![];
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
            Some(Drawer::Workspace) => items(&self.snapshot, "workspaces").to_vec(),
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
                self.search.pop();
                self.selected = 0;
            }
            KeyCode::Char(c) => {
                self.search.push(c);
                self.selected = 0;
            }
            _ => {}
        }
        out
    }
}
pub const COMMANDS: &[&str] = &[
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
