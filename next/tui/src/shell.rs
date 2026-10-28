use crate::app::{App, Command, Draft, Drawer, PendingInput, text};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};

pub fn status(value: &Value) -> String {
    if value["starting"] == true {
        return "正在启动命令…".into();
    }
    if value["stopping"] == true {
        return "正在中断命令…".into();
    }
    if !text(value, "error").is_empty() {
        return text(value, "error").into();
    }
    let elapsed = value["elapsed_ms"].as_u64().unwrap_or(0) as f64 / 1000.0;
    if value["cancelled"] == true {
        return if value["remote"] == true {
            format!("SSH 通道已关闭，远端进程状态待核验 · {elapsed:.1}s")
        } else {
            format!("已中断 · {elapsed:.1}s")
        };
    }
    if value["timed_out"] == true {
        return if value["remote"] == true {
            format!("SSH 命令超时，远端进程状态待核验 · {elapsed:.1}s")
        } else {
            format!("命令超时 · {elapsed:.1}s")
        };
    }
    if value["done"] != true {
        return format!("执行中 · {elapsed:.1}s");
    }
    value["exit_code"]
        .as_i64()
        .map(|code| format!("退出码 {code} · {elapsed:.1}s"))
        .unwrap_or_else(|| format!("已结束 · 退出码未报告 · {elapsed:.1}s"))
}
impl App {
    pub fn try_shell_submit(&mut self) -> Option<Vec<Command>> {
        let command = self
            .input
            .trim_start()
            .strip_prefix('!')?
            .trim_start()
            .to_owned();
        if command.trim().is_empty() {
            self.notice = "用法：!命令，例如 !git status；/shell 查看执行结果".into();
            return Some(vec![]);
        }
        if !self.binding_ready || self.session_id().is_none() {
            self.send_after_binding = true;
            self.notice = "工作会话就绪后执行此命令".into();
            return Some(vec![]);
        }
        if self.shell_start.is_some() {
            self.notice = "上一条命令正在启动，稍后可用 /shell 查看".into();
            return Some(vec![]);
        }
        if self.shell_state["session_id"] == self.snapshot["session"]["id"]
            && self.shell_state["done"] == false
        {
            self.open(Drawer::Shell);
            self.notice = "已有命令执行中；Ctrl+C 中断后可输入新命令".into();
            return Some(vec![]);
        }
        let request=self.command("terminal.action",json!({"action":"shell.start","explicit":true,"command":command,
            "workspace_id":self.snapshot["session"]["workspace_id"],"cwd":self.snapshot["session"]["workspace_path"],"_shell":true}));
        self.shell_start = Some(request.clone());
        self.shell_state = json!({"command":command,"target":self.snapshot["session"]["workspace_path"],"session_id":self.snapshot["session"]["id"],"starting":true,"done":false});
        self.shell_output.clear();
        self.shell_poll_pending = false;
        self.shell_follow = true;
        self.history.push(self.input.clone());
        self.history_local.push(self.input.clone());
        self.history_index = self.history.len();
        self.history_draft = None;
        self.input.clear();
        self.cursor = 0;
        self.paste_collapsed = false;
        self.send_after_binding = false;
        self.completion_closed = true;
        self.open(Drawer::Shell);
        Some(vec![request])
    }
    pub fn open_shell(&mut self) -> Vec<Command> {
        self.open(Drawer::Shell);
        self.shell_follow = true;
        if self.shell_start.is_some() {
            return vec![];
        }
        if self.shell_state["session_id"] == self.snapshot["session"]["id"]
            && !text(&self.shell_state, "job_id").is_empty()
        {
            if self.shell_poll_pending {
                return vec![];
            }
            self.shell_poll_pending = true;
            return vec![Command {
                method: "terminal.query".into(),
                params: json!({"topic":"shell.status","job_id":self.shell_state["job_id"],"session_id":self.shell_state["session_id"],"cursor":self.shell_state["cursor"],"generation":self.shell_state["generation"],"_shell":true}),
            }];
        }
        self.shell_poll_pending = true;
        vec![self.command(
            "terminal.query",
            json!({"topic":"shell.latest","_shell":true}),
        )]
    }
    pub fn shell_poll_command(&mut self) -> Option<Command> {
        if self.shell_poll_pending
            || (self.shell_state["done"] == true && self.shell_state["has_more"] != true)
            || text(&self.shell_state, "job_id").is_empty()
        {
            return None;
        }
        self.shell_poll_pending = true;
        Some(Command {
            method: "terminal.query".into(),
            params: json!({"topic":"shell.status","job_id":self.shell_state["job_id"],
            "session_id":self.shell_state["session_id"],"cursor":self.shell_state["cursor"],"generation":self.shell_state["generation"],"_shell":true}),
        })
    }
    pub fn cancel_shell(&self) -> Vec<Command> {
        if self.shell_state["done"] == true || text(&self.shell_state, "job_id").is_empty() {
            return vec![];
        }
        vec![Command {
            method: "terminal.action".into(),
            params: json!({"action":"shell.cancel","job_id":self.shell_state["job_id"],
            "session_id":self.shell_state["session_id"],"cursor":self.shell_state["cursor"],"generation":self.shell_state["generation"],"_shell":true}),
        }]
    }
    pub fn shell_response(&mut self, command: &Command, result: &Value) -> bool {
        if command.params["_shell"] != true {
            return false;
        }
        let start = command.params["action"] == "shell.start";
        if start {
            if self.shell_start.as_ref() != Some(command) {
                return true;
            }
            self.shell_start = None;
        } else if command.params["topic"] == "shell.latest" {
            if command.params["session_id"] != self.snapshot["session"]["id"] {
                return true;
            }
        } else if command.params["job_id"] != self.shell_state["job_id"] {
            return true;
        }
        if command.params["action"] == "shell.cancel" {
            self.shell_state["stopping"] = json!(result["done"] != true);
            return true;
        }
        self.shell_poll_pending = false;
        if start || command.params["topic"] == "shell.latest" || result["reset"] == true {
            self.shell_output.clear();
        }
        self.shell_output.push_str(text(result, "text"));
        if self.shell_output.len() > 2 * 1024 * 1024 {
            let mut begin = self.shell_output.len() - 2 * 1024 * 1024;
            while !self.shell_output.is_char_boundary(begin) {
                begin += 1;
            }
            self.shell_output.drain(..begin);
        }
        let finished = result["done"] == true && self.shell_state["done"] != true;
        self.shell_state = result.clone();
        if finished && result["session_id"] == self.snapshot["session"]["id"] {
            self.outbox.push(self.command("snapshot.get", json!({})));
        }
        if result["done"] == true {
            self.notice = status(result);
        }
        true
    }
    pub fn shell_error(&mut self, command: &Command, message: &str) -> bool {
        if command.params["_shell"] != true {
            return false;
        }
        if command.params["action"] == "shell.start" && self.shell_start.as_ref() == Some(command) {
            self.shell_start = None;
            let draft = Draft {
                text: format!("!{}", text(&command.params, "command")),
                ..Default::default()
            };
            if command.params["session_id"] == self.snapshot["session"]["id"]
                && self.input.is_empty()
            {
                self.input = draft.text;
                self.cursor = self.input.len();
            } else {
                self.recovered_inputs.push(PendingInput {
                    command: command.clone(),
                    draft,
                    question_state: None,
                });
            }
        }
        self.shell_poll_pending = false;
        self.shell_state["done"] = json!(true);
        self.shell_state["starting"] = json!(false);
        self.shell_state["error"] = json!(message);
        self.notice = message.into();
        true
    }
    pub fn shell_key(&mut self, key: KeyEvent) -> Vec<Command> {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if self.shell_follow
            && matches!(
                key.code,
                KeyCode::Up | KeyCode::PageUp | KeyCode::Down | KeyCode::PageDown
            )
        {
            self.selected = crate::ui::shell_max_scroll(self);
        }
        match key.code {
            KeyCode::Char('c') if ctrl => return self.cancel_shell(),
            KeyCode::Char('c') => self.copy_requested = Some(self.shell_output.clone()),
            KeyCode::Char('r') => return self.open_shell(),
            KeyCode::Esc => self.drawer = None,
            KeyCode::Up | KeyCode::PageUp => {
                self.shell_follow = false;
                self.selected = self
                    .selected
                    .saturating_sub(if key.code == KeyCode::PageUp { 10 } else { 1 });
            }
            KeyCode::Down | KeyCode::PageDown => {
                self.shell_follow = false;
                self.selected = self
                    .selected
                    .saturating_add(if key.code == KeyCode::PageDown { 10 } else { 1 });
            }
            KeyCode::Home => {
                self.shell_follow = false;
                self.selected = 0;
            }
            KeyCode::End => self.shell_follow = true,
            _ => {}
        };
        vec![]
    }
}
