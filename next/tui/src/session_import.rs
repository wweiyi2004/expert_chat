use crate::app::{App, Command, FormKind, items, text};
use serde_json::{Value, json};

impl App {
    pub fn scan_external_sessions(&mut self, startup: bool) -> Vec<Command> {
        if !startup {
            self.extra_form(
                FormKind::ImportSessions,
                "读取最近的外部会话",
                vec![Self::field(
                    "skip",
                    "不导入，继续当前会话",
                    "",
                    false,
                    false,
                )],
                json!({}),
            );
        }
        vec![self.command(
            "terminal.query",
            json!({"topic":"session.imports","startup":startup}),
        )]
    }
    pub fn session_import_response(&mut self, command: &Command, result: &Value) -> bool {
        let topic = text(
            &command.params,
            if command.method == "terminal.query" {
                "topic"
            } else {
                "action"
            },
        );
        if !topic.starts_with("session.import") {
            return false;
        }
        if command.params["session_id"] != self.snapshot["session"]["id"] {
            return true;
        }
        match topic {
            "session.imports" => {
                let startup = command.params["startup"] == true;
                if startup
                    && (self.form.is_some()
                        || self.drawer.is_some()
                        || !self.input.is_empty()
                        || !items(&self.snapshot, "messages").is_empty())
                {
                    return true;
                }
                let rows = items(result, "sessions");
                if rows.is_empty() {
                    if !startup {
                        self.notice = "没有找到可继承的会话".into();
                        self.form = None;
                    }
                    return true;
                }
                self.import_sources(result.clone());
            }
            "session.import.preview" => {
                if !self
                    .form
                    .as_ref()
                    .is_some_and(|f| f.kind == FormKind::ImportSessions)
                {
                    return true;
                }
                let mut fields = vec![
                    Self::field(
                        "summary",
                        &format!("{} · {}", text(result, "source"), text(result, "title")),
                        "",
                        false,
                        false,
                    ),
                    Self::field(
                        "count",
                        &format!("将导入 {} 条对话；以下为部分预览", result["messages"]),
                        "",
                        false,
                        false,
                    ),
                ];
                let columns = (self.viewport.0 as usize).saturating_sub(16).clamp(12, 96);
                let mut line = String::new();
                for c in text(result, "preview").chars() {
                    if c == '\n'
                        || crate::ui::width(&line, self.ambiguous_width)
                            + crate::ui::width(&c.to_string(), self.ambiguous_width)
                            > columns
                    {
                        fields.push(Self::field(
                            &format!("preview:{}", fields.len()),
                            &line,
                            "",
                            false,
                            false,
                        ));
                        line.clear();
                    }
                    if c != '\n' {
                        line.push(c);
                    }
                }
                if !line.is_empty() {
                    fields.push(Self::field("preview:last", &line, "", false, false));
                }
                fields.push(Self::field("import", "确认导入为新会话", "", false, false));
                fields.push(Self::field("skip", "取消导入", "", false, false));
                self.extra_form(
                    FormKind::ImportReview,
                    "确认继承会话",
                    fields,
                    result.clone(),
                );
                let form = self.form.as_mut().unwrap();
                // The preview rows are informational. Focus the actual action,
                // so Enter on the review screen confirms instead of doing nothing.
                form.selected = form.fields.iter().position(|f| f.key == "import").unwrap();
                form.notice = "Enter 确认导入 · Esc 取消；不继承密钥、权限或运行中任务。".into();
            }
            "session.import" => {
                if !self
                    .form
                    .as_ref()
                    .is_some_and(|f| f.kind == FormKind::ImportReview)
                {
                    return true;
                }
                self.form = None;
                self.outbox.push(Command {
                    method: "session.open".into(),
                    params: json!({"session_id":result["session_id"]}),
                });
                self.notice = text(result, "notice").into();
            }
            _ => {}
        }
        true
    }
    pub fn session_import_action(&mut self) -> Option<Vec<Command>> {
        let form = self.form.as_ref()?;
        if !matches!(form.kind, FormKind::ImportSessions | FormKind::ImportReview) {
            return None;
        }
        let key = form.fields.get(form.selected)?.key.clone();
        if key == "skip" {
            self.form = None;
            return Some(vec![]);
        }
        if key == "sources" {
            let data = form.items.first()?.clone();
            self.import_sources(data);
            return Some(vec![]);
        }
        if let Some(source) = key.strip_prefix("source:") {
            let data = form.items.first()?.clone();
            let mut fields = vec![Self::field("sources", "返回客户端列表", "", false, false)];
            for row in items(&data, "sessions")
                .iter()
                .filter(|r| text(r, "source") == source)
            {
                fields.push(Self::field(
                    &format!("pick:{}", text(row, "id")),
                    &format!("{} · {}", text(row, "title"), text(row, "cwd")),
                    text(row, "updated"),
                    false,
                    false,
                ));
            }
            self.extra_form(
                FormKind::ImportSessions,
                &format!("{source} · 选择要继承的会话"),
                fields,
                data,
            );
            self.form.as_mut().unwrap().notice = "↑↓ 选择会话 · Enter 预览 · Esc 取消".into();
            return Some(vec![]);
        }
        if let Some(id) = key.strip_prefix("pick:") {
            return Some(vec![self.command(
                "terminal.query",
                json!({"topic":"session.import.preview","id":id}),
            )]);
        }
        if key == "import" {
            let data = form.items.first()?.clone();
            if data["submitting"] == true {
                return Some(vec![]);
            }
            let form = self.form.as_mut().unwrap();
            form.items[0]["submitting"] = json!(true);
            form.notice = "正在导入，请稍候…".into();
            return Some(vec![self.command("terminal.action",json!({"action":"session.import","id":data["id"],"fingerprint":data["fingerprint"],"confirmed":true}))]);
        }
        Some(vec![])
    }

    pub fn session_import_error(&mut self, command: &Command, message: &str) -> bool {
        if command.method != "terminal.action" || command.params["action"] != "session.import" {
            return false;
        }
        if command.params["session_id"] == self.snapshot["session"]["id"]
            && let Some(form) = self.form.as_mut()
            && form.kind == FormKind::ImportReview
            && let Some(data) = form.items.first_mut()
            && data["id"] == command.params["id"]
        {
            data["submitting"] = json!(false);
            form.notice = message.into();
        }
        true
    }

    fn import_sources(&mut self, data: Value) {
        let mut fields = vec![Self::field("skip", "新建会话，不继承", "", false, false)];
        let mut sources = std::collections::BTreeMap::<String, usize>::new();
        for row in items(&data, "sessions") {
            *sources.entry(text(row, "source").to_owned()).or_default() += 1;
        }
        for (source, count) in sources {
            fields.push(Self::field(
                &format!("source:{source}"),
                &source,
                &format!("{count} 个最近会话"),
                false,
                false,
            ));
        }
        self.extra_form(
            FormKind::ImportSessions,
            "继承外部会话 · 先选择客户端",
            fields,
            data,
        );
        self.form.as_mut().unwrap().notice =
            "↑↓ 选择客户端 · Enter 查看会话；只导入对话文字，来源记录保留。".into();
    }
}
