use crate::app::{App, Command, FormKind, items, text};
use serde_json::{Value, json};

pub fn usage_lines(data: &Value, ascii: bool) -> Vec<String> {
    let budget = data["input_budget"].as_u64().unwrap_or(0);
    let count = |key: &str| {
        data[key]
            .as_u64()
            .map(|n| n.to_string())
            .unwrap_or_else(|| "尚无统计".into())
    };
    let mut out = vec![
        format!("输入预算  {} tokens", count("input_budget")),
        String::new(),
    ];
    for (label, value) in [
        ("历史与附件", data["history_estimate"].as_u64()),
        ("已选工具结果", data["tool_estimate"].as_u64()),
        ("最近请求", data["last_request_tokens"].as_u64()),
    ] {
        out.push(format!(
            "{label}  {}",
            value
                .map(|n| format!("{n} tokens"))
                .unwrap_or_else(|| "尚无统计".into())
        ));
        let filled = value
            .filter(|_| budget > 0)
            .map(|n| ((n as f64 / budget as f64) * 24.0).ceil().clamp(0.0, 24.0) as usize)
            .unwrap_or(0);
        out.push(format!(
            "  {}{}",
            if ascii { "#" } else { "▰" }.repeat(filled),
            if ascii { "." } else { "▱" }.repeat(24 - filled)
        ));
    }
    out.push(String::new());
    out.push("各条以输入预算为满格，历史与工具统计为估算。".into());
    out.push("/context contents 选择内容 · /settings context 设置窗口".into());
    out
}

impl App {
    pub fn open_context_settings(&mut self) -> Vec<Command> {
        let mut commands = self.terminal_query("context");
        for command in &mut commands {
            command.params["view"] = json!("settings");
        }
        commands
    }
    pub fn open_context_contents(&mut self) -> Vec<Command> {
        self.extra_form(
            FormKind::ContextContents,
            "上下文内容选择",
            vec![],
            json!({}),
        );
        vec![self.command(
            "terminal.query",
            json!({"topic":"context.contents","ui_revision":self.form_revision}),
        )]
    }
    pub fn open_archive_search(&mut self, query: &str) -> Vec<Command> {
        self.show_archive_results(json!({"query":query,"hits":[],"offset":0}));
        if query.trim().is_empty() {
            vec![]
        } else {
            self.archive_search_request(query, 0)
        }
    }
    fn archive_search_request(&mut self, query: &str, offset: u64) -> Vec<Command> {
        if let Some(form) = self.form.as_mut() {
            form.notice = "正在搜索历史正文、附件与工具结果…".into();
        }
        vec![self.command("terminal.query",json!({"topic":"search.all","query":query,"offset":offset,"ui_revision":self.form_revision}))]
    }
    fn show_archive_results(&mut self, data: Value) {
        let mut fields = vec![
            Self::field("query", "关键词", text(&data, "query"), false, true),
            Self::field("__search", "搜索全部会话", "", false, false),
        ];
        for (index, hit) in items(&data, "hits").iter().enumerate() {
            fields.push(Self::field(
                &format!("hit:{index}"),
                &format!(
                    "{} · {} · {}",
                    text(hit, "title"),
                    text(hit, "kind"),
                    text(hit, "snippet")
                ),
                "",
                false,
                false,
            ));
        }
        if data["offset"].as_u64().unwrap_or(0) > 0 {
            fields.push(Self::field("__prev", "上一页", "", false, false));
        }
        if data["has_more"] == true {
            fields.push(Self::field("__next", "下一页", "", false, false));
        }
        self.extra_form(FormKind::SearchAll, "跨会话全文搜索", fields, data.clone());
        let form = self.form.as_mut().unwrap();
        form.selected = if items(&data, "hits").is_empty() {
            0
        } else {
            2
        };
        form.notice = format!(
            "本页 {} 项 · Enter/点击定位 · 其他分支只读预览{}",
            items(&data, "hits").len(),
            if data["skipped_sessions"].as_u64().unwrap_or(0) > 0 {
                format!(" · {} 个会话读取失败", data["skipped_sessions"])
            } else {
                String::new()
            }
        );
    }
    fn show_context_contents(&mut self, data: Value, selected_key: Option<&str>) {
        let mut fields = vec![];
        for entry in items(&data, "entries") {
            let mark = if entry["enabled"] == true {
                "☑"
            } else {
                "☐"
            };
            let cost = entry["estimated_tokens"]
                .as_u64()
                .map(|v| format!(" · 约 {v} tokens"))
                .unwrap_or_default();
            let parent = if entry["parent_enabled"] == false {
                " · 所属轮已排除"
            } else {
                ""
            };
            let locked = if entry["locked"] == true {
                " · 最新用户轮，不能排除"
            } else {
                ""
            };
            fields.push(Self::field(
                text(entry, "key"),
                &format!("{mark} {}{cost}{parent}{locked}", text(entry, "name")),
                "",
                false,
                false,
            ));
        }
        fields.push(Self::field(
            "__detail",
            "查看占用明细与说明",
            "",
            false,
            false,
        ));
        fields.push(Self::field("__refresh", "刷新内容列表", "", false, false));
        self.extra_form(
            FormKind::ContextContents,
            &format!(
                "上下文内容 · 已选约 {} / {} tokens",
                data["selected_estimate"], data["input_budget"]
            ),
            fields,
            data.clone(),
        );
        let form = self.form.as_mut().unwrap();
        if let Some(key) = selected_key {
            form.selected = form.fields.iter().position(|f| f.key == key).unwrap_or(0);
        }
        form.notice = "Enter/点击切换 · 按轮保留对话 · 工具结果按需选入 · 只影响下次生成".into();
    }
    pub fn context_search_form_action(&mut self) -> Option<Vec<Command>> {
        let form = self.form.as_ref()?;
        if !matches!(form.kind, FormKind::ContextContents | FormKind::SearchAll) {
            return None;
        }
        let field = form.fields.get(form.selected)?;
        if field.editable {
            return None;
        }
        let key = field.key.clone();
        let data = form.items.first()?.clone();
        if form.kind == FormKind::ContextContents {
            if key == "__refresh" {
                return Some(self.open_context_contents());
            }
            if key == "__detail" {
                self.show_info("上下文占用", usage_lines(&data, self.ascii));
                return Some(vec![]);
            }
            let entry = items(&data, "entries")
                .iter()
                .find(|e| text(e, "key") == key)?;
            if entry["locked"] == true {
                self.form.as_mut()?.notice = "最新用户轮始终保留，不能排除".into();
                return Some(vec![]);
            }
            if self.active() {
                self.form.as_mut()?.notice = "当前任务结束后可调整上下文内容".into();
                return Some(vec![]);
            }
            let params = json!({"action":"context.selection.set","key":key,"enabled":entry["enabled"]!=true,"ui_revision":self.form_revision});
            self.form.as_mut()?.notice = "正在保存上下文选择…".into();
            return Some(vec![self.command("terminal.action", params)]);
        }
        let query = form
            .fields
            .iter()
            .find(|f| f.key == "query")
            .map(|f| f.value.clone())
            .unwrap_or_default();
        if key == "__search" {
            return Some(self.archive_search_request(&query, 0));
        }
        let offset = data["offset"].as_u64().unwrap_or(0);
        let page = data["page_size"].as_u64().unwrap_or(40);
        if key == "__next" {
            return Some(self.archive_search_request(&query, offset + page));
        }
        if key == "__prev" {
            return Some(self.archive_search_request(&query, offset.saturating_sub(page)));
        }
        if let Some(index) = key
            .strip_prefix("hit:")
            .and_then(|v| v.parse::<usize>().ok())
        {
            let hit = items(&data, "hits").get(index)?.clone();
            if hit["active_branch"] == false {
                self.show_info(
                    &format!("{} · 其他分支（只读）", text(&hit, "title")),
                    vec![text(&hit, "preview").into()],
                );
                return Some(vec![]);
            }
            self.form = None;
            self.search_target = Some(hit.clone());
            if hit["session_id"] == self.snapshot["session"]["id"] {
                self.finish_archive_search_navigation();
                return Some(vec![]);
            }
            return Some(vec![Command {
                method: "session.open".into(),
                params: json!({"session_id":hit["session_id"]}),
            }]);
        }
        Some(vec![])
    }
    pub fn context_search_response(&mut self, command: &Command, result: &Value) -> bool {
        let topic = command.params[if command.method == "terminal.query" {
            "topic"
        } else {
            "action"
        }]
        .as_str()
        .unwrap_or("");
        if !matches!(
            command.method.as_str(),
            "terminal.query" | "terminal.action"
        ) || !matches!(
            topic,
            "context.contents" | "context.selection.set" | "search.all"
        ) {
            return false;
        }
        if command.params["ui_revision"].as_u64() != Some(self.form_revision) {
            return true;
        }
        if topic == "search.all" {
            if self
                .form
                .as_ref()
                .is_some_and(|f| f.kind == FormKind::SearchAll)
            {
                self.show_archive_results(result.clone());
            }
        } else if self
            .form
            .as_ref()
            .is_some_and(|f| f.kind == FormKind::ContextContents)
        {
            self.show_context_contents(result.clone(), command.params["key"].as_str());
        }
        true
    }
    pub fn finish_archive_search_navigation(&mut self) {
        let Some(hit) = self.search_target.clone() else {
            return;
        };
        if hit["session_id"] != self.snapshot["session"]["id"] {
            return;
        }
        self.search_target = None;
        let id = text(&hit, "message_id");
        if !id.is_empty() {
            crate::ui::focus_message(self, id);
        }
        self.notice = "已定位搜索结果 · /search 继续搜索".into();
        if text(&hit, "kind") != "正文" && text(&hit, "kind") != "会话标题" {
            self.show_info(
                &format!("{} · {}", text(&hit, "title"), text(&hit, "kind")),
                vec![text(&hit, "preview").into()],
            );
        }
    }
}
