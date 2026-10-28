use crate::app::{App, Command, Drawer, FormField, FormKind, TerminalForm, items, text};
use serde_json::{Value, json};

pub const EXTRA_COMMANDS: &[&str] = &[
    "/jobs", "/btw", "/files", "/git", "/automation", "/backup", "/updates", "/voice", "/media", "/split",
    "/effort",
    "/fast",
    "/connect",
    "/mcp",
    "/doctor",
    "/status",
    "/context",
    "/cost",
    "/usage",
    "/rename",
    "/export",
    "/pause",
    "/continue",
    "/retry",
    "/memory",
    "/skills",
    "/hooks",
    "/init",
    "/add-dir",
    "/diff",
    "/agents",
    "/history",
    "/expand",
    "/collapse",
    "/steps",
    "/failures",
    "/attachments",
    "/preview",
    "/clear",
    "/price",
    "/login",
    "/ssh",
    "/search",
    "/shell",
    "/subagent",
    "/import",
];

/// Secondary shortcuts remain executable, but only their primary entry is
/// offered in completion. These groups do not change command semantics.
pub const COMMAND_SHORTCUTS: &[(&str, &str)] = &[
    ("/provider", "/settings"),
    ("/connect", "/settings"),
    ("/mcp", "/settings"),
    ("/fast", "/model"),
    ("/usage", "/cost"),
    ("/price", "/cost"),
    ("/clear", "/new"),
    ("/attach", "/attachments"),
    ("/detach", "/attachments"),
    ("/preview", "/attachments"),
    ("/doctor", "/status"),
    ("/expand", "/steps"),
    ("/collapse", "/steps"),
    ("/failures", "/steps"),
    ("/next", "/find"),
    ("/prev", "/find"),
    ("/jump", "/find"),
    ("/latest", "/find"),
    ("/add-dir", "/workspace"),
    ("/session", "/sessions"),
    ("/exit", "/quit"),
];

pub fn is_primary_command(command: &str) -> bool {
    !COMMAND_SHORTCUTS
        .iter()
        .any(|(shortcut, _)| *shortcut == command)
}

pub fn command_help_lines() -> Vec<String> {
    let mut commands: Vec<_> = crate::app::COMMANDS
        .iter()
        .chain(EXTRA_COMMANDS)
        .copied()
        .filter(|command| is_primary_command(command))
        .collect();
    commands.sort_unstable();
    commands.dedup();
    let mut lines = vec!["补全只显示主入口；快捷命令仍可直接输入，原有参数和行为保持不变。".into()];
    for command in commands {
        let (description, usage) = crate::app::command_metadata(command);
        lines.push(format!("{usage} · {description}"));
        for (shortcut, _) in COMMAND_SHORTCUTS
            .iter()
            .filter(|(_, primary)| *primary == command)
        {
            let (description, usage) = crate::app::command_metadata(shortcut);
            lines.push(if matches!(*shortcut, "/session" | "/exit") {
                format!("  {shortcut} · {command} 的别名")
            } else {
                format!("  {usage} · {description}")
            });
        }
    }
    lines
}
pub fn metadata(command: &str) -> Option<(&'static str, &'static str)> {
    Some(match command {
        "/btw" => ("独立旁问，主任务继续", "/btw [问题]"),
        "/files" => ("文件树、新建、编辑与运行", "/files"),
        "/git" => ("Git 状态、暂存、提交与分支", "/git"),
        "/split" => ("并排查看另一工作会话", "/split [会话ID]"),
        "/jobs" => ("查看后台操作与结果", "/jobs"),
        "/automation" => ("定时命令及远程自动化", "/automation"),
        "/backup" => ("完整备份与恢复预览", "/backup"),
        "/updates" => ("检查更新、版本切换与回退", "/updates"),
        "/voice" => ("录音、转写与朗读", "/voice"),
        "/media" => ("图片生成与创作历史", "/media"),
        "/login" => ("选择提供商并登录账号", "/login"),
        "/ssh" => ("管理并连接 SSH 服务器", "/ssh"),
        "/shell" => ("查看 !命令 的执行结果", "/shell"),
        "/search" => ("跨会话全文搜索", "/search [关键词]"),
        "/effort" => (
            "调整思考强度或开关思考",
            "/effort [low|medium|high|xhigh|max|on|off]",
        ),
        "/fast" => ("快速模式：优先处理，更快但更贵", "/fast [on|off]"),
        "/connect" => ("连接新的提供商", "/connect"),
        "/mcp" => ("独立 MCP 管理窗口", "/mcp"),
        "/doctor" => ("诊断本机配置与存储", "/doctor"),
        "/status" => ("查看 Host、模型和任务状态", "/status"),
        "/context" => ("上下文占用与内容选择", "/context [contents]"),
        "/cost" | "/usage" => ("请求、token 和费用统计", "/cost"),
        "/rename" => ("重命名当前会话", "/rename 新名称"),
        "/export" => ("导出当前会话 Markdown", "/export [文件.md]"),
        "/pause" => ("在完整工具轮边界暂停", "/pause"),
        "/continue" => ("继续当前任务", "/continue"),
        "/retry" => ("重试已记录的失败请求", "/retry"),
        "/memory" => ("管理当前任务的固定要求与记忆", "/memory"),
        "/skills" => ("查看与编辑技能", "/skills"),
        "/hooks" => ("查看与编辑自动化规则", "/hooks"),
        "/init" => ("初始化项目 AGENT.md", "/init [补充要求]"),
        "/add-dir" => ("追加工作区授权目录", "/add-dir [绝对路径]"),
        "/diff" => ("查看改动差异", "/diff"),
        "/agents" => ("查看代理任务树", "/agents"),
        "/subagent" => (
            "手动启动子代理",
            "/subagent [--write=文件,...] 模型 智力 提示词",
        ),
        "/import" => ("从其他客户端继承会话", "/import"),
        "/history" => ("输入历史或历史提问定位", "/history [messages]"),
        "/expand" => ("展开近期步骤或查看指定步骤详情", "/expand [步骤编号]"),
        "/collapse" => ("收起工具步骤", "/collapse [步骤编号]"),
        "/steps" => ("逐条查看工具步骤", "/steps"),
        "/failures" => ("只看失败步骤", "/failures [off]"),
        "/attachments" => ("附件列表、预览与删除", "/attachments"),
        "/preview" => ("预览指定草稿附件", "/preview [编号]"),
        "/price" => (
            "自定义模型单价（每百万 Token）",
            "/price 输入 输出 缓存 [USD]",
        ),
        "/clear" => ("新建会话，保留原会话", "/clear"),
        _ => return None,
    })
}

/// Common context window sizes; the provider's real limit still caps the result.
pub const CONTEXT_PRESETS: &[(&str, &str)] = &[
    ("custom", "自定义"),
    ("32k", "32k"),
    ("64k", "64k"),
    ("128k", "128k"),
    ("200k", "200k"),
    ("256k", "256k"),
    ("400k", "400k"),
    ("1m", "1M"),
];
pub fn context_preset(window: &str) -> String {
    let tokens = token_count(window);
    CONTEXT_PRESETS
        .iter()
        .skip(1)
        .find(|(v, _)| tokens.is_some() && token_count(v) == tokens)
        .map_or("custom", |(v, _)| v)
        .to_owned()
}
pub fn token_count(value: &str) -> Option<u64> {
    let v = value.trim().to_ascii_lowercase();
    let (number, multiplier) = if let Some(n) = v.strip_suffix('k') {
        (n, 1000)
    } else if let Some(n) = v.strip_suffix('m') {
        (n, 1000000)
    } else {
        (v.as_str(), 1)
    };
    number.parse::<u64>().ok()?.checked_mul(multiplier)
}
impl App {
    fn fast_command(&mut self, arg: &str) -> Vec<Command> {
        let session = &self.snapshot["session"];
        let enabled = match arg.trim().to_ascii_lowercase().as_str() {
            "" => session["fast"] != true,
            "on" | "开" | "开启" => true,
            "off" | "关" | "关闭" => false,
            _ => {
                self.notice = "用法：/fast [on|off]".into();
                return vec![];
            }
        };
        if enabled && session["fast_supported"] != true {
            self.notice="当前模型来源不支持快速模式；目前只支持 OpenAI 官方 API（api.openai.com）的优先处理".into();
            return vec![];
        }
        vec![self.terminal_action("fast.set", json!({"enabled":enabled}))]
    }
    fn effort_command(&mut self, arg: &str) -> Vec<Command> {
        let current = self.snapshot["session"]["effort"].clone();
        let level = match arg.trim().to_ascii_lowercase().as_str() {
            "on" | "开" | "开启" => return self.set_effort(current, true),
            "off" | "关" | "关闭" => return self.set_effort(current, false),
            "低" | "low" => "low",
            "中" | "medium" | "med" => "medium",
            "高" | "high" => "high",
            "极高" | "xhigh" => "xhigh",
            "最大" | "max" => "max",
            _ => {
                self.notice = "用法：/effort [low|medium|high|xhigh|max|on|off]".into();
                return vec![];
            }
        };
        let efforts = self.current_efforts();
        if !efforts.iter().any(|e| e == level) {
            let supported = efforts
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("/");
            self.notice = if supported.is_empty() {
                "当前模型不支持调整思考强度".into()
            } else {
                format!("当前模型支持：{supported}")
            };
            return vec![];
        }
        self.set_effort(json!(level), true)
    }
    pub fn show_info(&mut self, title: &str, lines: Vec<String>) {
        self.open(Drawer::Info);
        self.info_title = title.into();
        self.info_lines = lines;
    }
    pub fn terminal_query(&mut self, topic: &str) -> Vec<Command> {
        self.show_info("正在加载…", vec![]);
        self.extra_generation = self.extra_generation.wrapping_add(1);
        vec![self.command(
            "terminal.query",
            json!({"topic":topic,"ui_generation":self.extra_generation}),
        )]
    }
    fn terminal_action(&self, action: &str, mut params: Value) -> Command {
        params["action"] = json!(action);
        self.command("terminal.action", params)
    }
    pub fn extra_command(&mut self, command: &str, arg: &str) -> Vec<Command> {
        if command=="/btw" {if self.side_panel.is_none(){if let Some(key)=self.side_cache.iter().find(|(_,p)|p.data["kind"]=="side"&&p.data["session_id"]==self.snapshot["session"]["id"]).map(|(k,_)|k.clone()){self.side_panel=self.side_cache.remove(&key);}}let mut p=json!({"text":arg});if let Some(side)=self.side_panel.as_ref(){if side.data["kind"]=="side"{p["job_id"]=side.data["job_id"].clone();}}return self.workbench_query("wb.side.open",p);}
        if command=="/split" {if arg.is_empty(){return self.workbench_query("wb.sessions",json!({}));}return self.workbench_query("wb.session",json!({"target_session":arg}));}
        let topic=match command{"/jobs"=>Some("wb.jobs"),"/files"=>Some("wb.files"),"/git"=>Some("wb.git"),"/automation"=>Some("wb.automation"),"/backup"=>Some("wb.backup"),"/updates"=>Some("wb.update"),"/voice"=>Some("wb.voice"),"/media"=>Some("wb.media"),_=>None};
        if let Some(topic)=topic{return self.workbench_query(topic,if topic == "wb.files" && !arg.trim().is_empty() { json!({"path":arg.trim()}) } else { json!({}) });}

        match command {
            "/import" => self.scan_external_sessions(false),
            "/login" => self.open_login(),
            "/ssh" => self.open_management("ssh"),
            "/shell" => self.open_shell(),
            "/search" => self.open_archive_search(arg),
            "/effort" if arg.is_empty() => {
                self.open(Drawer::Effort);
                vec![]
            }
            "/effort" => self.effort_command(arg),
            "/fast" => self.fast_command(arg),
            "/connect" => {
                self.settings_page = 1;
                self.drawer = None;
                self.view = crate::app::View::Chat;
                self.edit_provider(json!({}));
                vec![self.command("settings.get", json!({}))]
            }
            "/mcp" => {
                self.settings_page = 2;
                self.drawer = None;
                self.view = crate::app::View::Chat;
                self.rebuild_settings();
                vec![self.command("settings.get", json!({}))]
            }
            "/status" | "/doctor" => self.terminal_query(command.trim_start_matches('/')),
            "/context" if arg == "contents" => self.open_context_contents(),
            "/context" if arg.is_empty() => self.terminal_query("context"),
            "/context" => {
                let value = arg.strip_prefix("set ").unwrap_or(arg);
                if value == "auto" {
                    vec![self.terminal_action("context.set", json!({"auto":true}))]
                } else if let Some(tokens) = token_count(value) {
                    vec![self.terminal_action("context.set", json!({"window":tokens}))]
                } else {
                    self.notice = "用法：/context 128k 或 /context auto".into();
                    vec![]
                }
            }
            "/cost" | "/usage" => self.terminal_query("usage"),
            "/price" => {
                let parts: Vec<_> = arg.split_whitespace().collect();
                let values: Option<Vec<f64>> = parts
                    .iter()
                    .take(3)
                    .map(|s| s.parse::<f64>().ok().filter(|v| v.is_finite() && *v >= 0.0))
                    .collect();
                if let Some(v) = values
                    && v.len() == 3
                    && parts.len() <= 4
                {
                    vec![self.terminal_action("price.set",json!({"input":v[0],"output":v[1],"cached":v[2],"currency":parts.get(3).unwrap_or(&"USD")}))]
                } else {
                    self.notice =
                        "用法：/price 输入 输出 缓存 [USD]，单价单位为每百万 Token".into();
                    vec![]
                }
            }
            "/rename" => {
                if arg.is_empty() {
                    self.notice = "用法：/rename 新名称".into();
                    vec![]
                } else {
                    vec![self.terminal_action("rename", json!({"text":arg}))]
                }
            }
            "/export" => vec![self.command("terminal.query", json!({"topic":"export","file":arg}))],
            "/pause" | "/continue" | "/retry" => {
                vec![self.terminal_action(command.trim_start_matches('/'), json!({}))]
            }
            "/memory" | "/skills" | "/hooks" => {
                self.terminal_query(command.trim_start_matches('/'))
            }
            "/init" => vec![self.terminal_action("init", json!({"text":arg}))],
            "/subagent" => {
                let Ok(mut args) = crate::editor::arguments(arg) else {
                    self.notice =
                        "用法：/subagent 模型 high 提示词；默认只读，可先加 --write=文件路径"
                            .into();
                    return vec![];
                };
                let paths = if args.first().is_some_and(|s| s.starts_with("--write=")) {
                    args.remove(0)[8..]
                        .split(',')
                        .map(str::to_owned)
                        .collect::<Vec<_>>()
                } else {
                    vec![]
                };
                if args.len() < 3 {
                    self.notice = "用法：/subagent 模型 high 提示词".into();
                    return vec![];
                }
                let model = args.remove(0);
                let effort = args.remove(0);
                if !["low", "medium", "high", "xhigh", "max"].contains(&effort.as_str()) {
                    self.notice = "智力可选 low/medium/high/xhigh/max".into();
                    return vec![];
                }
                vec![self.terminal_action("subagent.start",json!({"model":model,"effort":effort,"text":args.join(" "),"owned_paths":paths}))]
            }
            "/add-dir" => {
                self.extra_form(
                    FormKind::AddDir,
                    "追加授权目录",
                    vec![
                        Self::field("path", "绝对目录路径", arg, false, true),
                        Self::field("name", "目录别名（字母/数字）", "extra", false, true),
                        Self::field(
                            "access",
                            "权限 read-only/read-write",
                            "read-only",
                            false,
                            true,
                        ),
                        Self::field("__save", "确认追加目录", "", false, false),
                    ],
                    json!({}),
                );
                vec![]
            }
            "/diff" => {
                self.drawer = None;
                self.view = crate::app::View::Changes;
                self.selected = 0;
                self.scroll = 0;
                items(&self.snapshot, "changes")
                    .first()
                    .map(|c| vec![self.command("changes.diff", json!({"id":c["id"]}))])
                    .unwrap_or_default()
            }
            "/agents" => {
                self.drawer = None;
                self.view = crate::app::View::Agents;
                self.selected = 0;
                self.scroll = 0;
                vec![]
            }
            "/history" if arg == "messages" => {
                self.open_message_history("");
                vec![]
            }
            "/history" => {
                self.open(Drawer::History);
                vec![]
            }
            "/expand" | "/collapse" => {
                if arg.is_empty() {
                    self.expanded = command == "/expand";
                    if !self.expanded {
                        self.expanded_steps.clear();
                    }
                } else if let Some(step) = arg
                    .parse::<usize>()
                    .ok()
                    .and_then(|n| n.checked_sub(1))
                    .and_then(|n| items(&self.snapshot, "steps").get(n))
                    .cloned()
                {
                    let id = text(&step, "id").to_owned();
                    if command == "/expand" {
                        return self.open_tool_detail(step);
                    } else {
                        self.expanded_steps.remove(&id);
                    }
                } else {
                    self.notice = "步骤编号无效；/steps 查看编号".into();
                }
                vec![]
            }
            "/steps" => {
                self.open_tool_rounds(None);
                vec![]
            }
            "/failures" => {
                self.steps_message = None;
                self.steps_round = None;
                self.failures_only = arg != "off";
                self.open(Drawer::Steps);
                vec![]
            }
            "/attachments" => {
                self.open(Drawer::Attachments);
                vec![]
            }
            "/preview" if !arg.is_empty() && arg.parse::<usize>().is_err() => return self.workbench_query("wb.preview",json!({"path":arg})),
            "/preview" => {
                let index = arg.parse::<usize>().unwrap_or(1).saturating_sub(1);
                self.preview_attachment(index)
            }
            "/clear" => vec![self.command(
                "session.new",
                json!({"workspace_id":self.snapshot["session"]["workspace_id"]}),
            )],
            _ => vec![],
        }
    }
    pub(crate) fn extra_form(
        &mut self,
        kind: FormKind,
        title: &str,
        fields: Vec<FormField>,
        data: Value,
    ) {
        self.drawer = None;
        self.form_confirm = None;
        self.form_revision = self.form_revision.wrapping_add(1);
        let selected = fields.iter().position(|f| f.editable).unwrap_or(0);
        self.form = Some(TerminalForm {
            kind,
            title: title.into(),
            original_fields: fields.clone(),
            cursor: fields.get(selected).map_or(0, |f| f.value.len()),
            fields,
            selected,
            editing: false,
            notice: "Tab/↑↓ 切换 · Enter 编辑/执行 · Esc 返回".into(),
            items: vec![data],
            item_selected: 0,
        });
    }
    pub fn extra_response(&mut self, command: &Command, result: &Value) -> bool {
        if !matches!(
            command.method.as_str(),
            "terminal.query" | "terminal.action"
        ) {
            return false;
        }
        if command.method == "terminal.action" {
            let origin = self
                .pending_form
                .as_ref()
                .is_some_and(|(v, c)| *v == self.form_revision && c == command);
            if origin {
                self.pending_form = None;
                if command.params["action"] == "workspace.permission.set" {
                    if let Some(rows) = self.snapshot["workspaces"].as_array_mut() {
                        for row in rows.iter_mut().filter(|w| w["id"] == result["workspace"]["id"]) {
                            row["access"] = result["workspace"]["access"].clone();
                        }
                    }
                    self.show_workspace_permissions(&result["workspace"]);
                    self.notice = text(result, "notice").into();
                    if let Some(form) = self.form.as_mut() { form.notice = self.notice.clone(); }
                    return true;
                }
                if let Some(form) = self.form.as_mut() {
                    form.original_fields = self.pending_form_values.clone();
                    form.notice = text(result, "notice").into();
                    for key in ["id", "version", "revision"] {
                        if !result[key].is_null() {
                            form.items[0][key] = result[key].clone();
                        }
                    }
                }
            }
            if result["settings"].is_object() {
                self.snapshot["settings"] = result["settings"].clone();
                if origin
                    && let Some(form) = self.form.as_mut()
                    && form.kind == FormKind::Mcp
                {
                    if let Some(server) = items(&result["settings"], "mcp")
                        .iter()
                        .find(|v| v["id"] == command.params["id"])
                    {
                        form.items = vec![server.clone()];
                    }
                    if let Some(field) = form.fields.iter_mut().find(|f| f.key == "enabled") {
                        field.value = if command.params["action"] == "mcp.connect" {
                            "true"
                        } else {
                            "false"
                        }
                        .into();
                    }
                    form.original_fields = form.fields.clone();
                }
            }
            if command.params["session_id"] == self.snapshot["session"]["id"] {
                self.notice = text(result, "notice").into();
            }
            return true;
        }
        let topic = text(&command.params, "topic");
        if topic == "library" {
            if self.drawer == Some(Drawer::Library)
                && command.params["ui_generation"].as_u64() == Some(self.extra_generation)
            {
                self.library = result.clone();
                let n = items(result, if self.library_sets { "sets" } else { "assets" }).len();
                self.selected = self.selected.min(n.saturating_sub(1));
            }
            return true;
        }
        if topic == "export" {
            let requested = text(&command.params, "file");
            let path = if requested.is_empty() {
                format!(
                    "session-{}-{}.md",
                    command.params["session_id"]
                        .as_str()
                        .unwrap_or("export")
                        .chars()
                        .take(8)
                        .collect::<String>(),
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs()
                )
            } else {
                requested.to_owned()
            };
            use std::io::Write;
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
                .and_then(|mut f| f.write_all(text(result, "text").as_bytes()))
            {
                Ok(()) => self.notice = format!("已导出 {path}"),
                Err(error) => self.notice = format!("导出失败（不覆盖已有文件）：{error}"),
            };
            return true;
        }
        if command.params["session_id"] != self.snapshot["session"]["id"]
            || command.params["ui_generation"].as_u64() != Some(self.extra_generation)
            || self.drawer != Some(Drawer::Info)
        {
            return true;
        }
        match topic {
            "workspace.permissions" => self.show_workspace_permissions(&result["workspace"]),
            "usage" => {
                self.usage_detail = result.clone();
                if self.usage_detail["usage"].is_null() {
                    self.usage_detail["usage"] = self.snapshot["session"]["usage"].clone();
                }
                self.usage_expanded = false;
                self.open(Drawer::Usage);
            }
            "context" => {
                if command.params["view"] != "settings" {
                    self.show_info(
                        "上下文占用",
                        crate::context_manager::usage_lines(&result["contents"], self.ascii),
                    );
                    return true;
                }
                let prefs = &result["context"];
                let lines = items(result, "lines")
                    .iter()
                    .filter_map(Value::as_str)
                    .take(2)
                    .collect::<Vec<_>>()
                    .join(" · ");
                let automatic = result["output_auto"]
                    .as_bool()
                    .unwrap_or(prefs["maxOutputTokens"].as_u64().unwrap_or(0) == 0);
                self.extra_form(
                    FormKind::Context,
                    "模型上下文窗口",
                    vec![
                        Self::field("info", &lines, "", false, false),
                        Self::choice(
                            "preset",
                            "常用预设",
                            &context_preset(&prefs["contextWindowTokens"].to_string()),
                            CONTEXT_PRESETS,
                        ),
                        Self::field(
                            "window",
                            "窗口 tokens（支持 128k）",
                            &prefs["contextWindowTokens"].to_string(),
                            false,
                            true,
                        ),
                        Self::choice(
                            "output_mode",
                            "输出长度",
                            if automatic { "model" } else { "manual" },
                            &[
                                ("model", "模型上限（推荐）"),
                                ("manual", "手动设置（高级）"),
                            ],
                        ),
                        Self::field(
                            "reserve",
                            "输出预留 tokens",
                            &prefs["reservedOutputTokens"].to_string(),
                            false,
                            true,
                        ),
                        Self::field(
                            "history",
                            "历史条数（0=按 Token 自动）",
                            &prefs["maxHistoryMessages"].to_string(),
                            false,
                            true,
                        ),
                        Self::field("__contents", "选择上下文内容", "", false, false),
                        Self::field("__detail", "查看用量与设置说明", "", false, false),
                        Self::field("__save", "保存当前模型窗口", "", false, false),
                        Self::field("__auto", "恢复自动窗口", "", false, false),
                    ],
                    result.clone(),
                );
                self.sync_context_output();
                if let Some(form) = self.form.as_mut() {
                    form.original_fields = form.fields.clone();
                }
            }
            "memory" => {
                let m = &result["memory"];
                self.extra_form(
                    FormKind::Memory,
                    "任务记忆与固定要求",
                    vec![
                        Self::field(
                            "user_pins",
                            "固定要求（Alt+J 换行）",
                            text(m, "user_pins"),
                            false,
                            true,
                        ),
                        Self::field("__detail", "查看计划、摘要及约束", "", false, false),
                        Self::field("__save", "保存固定要求", "", false, false),
                    ],
                    m.clone(),
                );
            }
            "skills" | "hooks" => {
                let mut fields = vec![Self::field(
                    "new",
                    if topic == "skills" {
                        "＋ 新建技能"
                    } else {
                        "＋ 新建自动化规则"
                    },
                    "",
                    false,
                    false,
                )];
                for (index, item) in items(result, topic).iter().enumerate() {
                    fields.push(Self::field(
                        &index.to_string(),
                        &format!(
                            "{} · {}",
                            if item["enabled"] == true {
                                "启用"
                            } else {
                                "停用"
                            },
                            if topic == "skills" {
                                text(item, "name")
                            } else {
                                text(item, "command")
                            }
                        ),
                        "",
                        false,
                        false,
                    ));
                }
                self.extra_form(
                    if topic == "skills" {
                        FormKind::Skills
                    } else {
                        FormKind::Hooks
                    },
                    text(result, "title"),
                    fields,
                    result.clone(),
                );
            }
            _ => self.show_info(
                text(result, "title"),
                items(result, "lines")
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect(),
            ),
        }
        true
    }
    pub fn extra_form_action(&mut self) -> Option<Vec<Command>> {
        if let Some(commands) = self.workspace_permission_action() {
            return Some(commands);
        }
        if let Some(c)=self.workbench_action(){return Some(c);}
        if let Some(commands) = self.session_import_action() {
            return Some(commands);
        }
        if let Some(result) = self.quota_form_action() {
            return Some(result);
        }
        if let Some(result) = self.context_search_form_action() {
            return Some(result);
        }
        if let Some(result) = self.management_form_action() {
            return Some(result);
        }
        if let Some(result) = self.login_form_action() {
            return Some(result);
        }
        let form = self.form.clone()?;
        let field = form.fields.get(form.selected)?;
        if field.editable {
            return None;
        }
        let data = form.items.first().cloned().unwrap_or(json!({}));
        let get = |key: &str| {
            form.fields
                .iter()
                .find(|f| f.key == key)
                .map(|f| f.value.as_str())
                .unwrap_or("")
        };
        if form.kind == FormKind::Mcp
            && ["__connect", "__disconnect", "__tools"].contains(&field.key.as_str())
        {
            if text(&data, "id").is_empty() {
                self.notice = "请先保存 MCP 服务".into();
                return Some(vec![]);
            }
            if field.key == "__tools" {
                self.show_info(
                    "MCP 工具",
                    items(&data, "tools")
                        .iter()
                        .map(|t| format!("{}\n{}", text(t, "name"), text(t, "description")))
                        .collect(),
                );
                return Some(vec![]);
            }
            if !self.confirm_extra(&field.key, &format!("{}：再次 Enter 确认", field.label)) {
                return Some(vec![]);
            }
            let c = self.terminal_action(
                if field.key == "__connect" {
                    "mcp.connect"
                } else {
                    "mcp.disconnect"
                },
                json!({"id":data["id"],"confirmed":true}),
            );
            return Some(self.submit_extra(c));
        }
        if matches!(form.kind, FormKind::Skills | FormKind::Hooks) {
            let skills = form.kind == FormKind::Skills;
            let key = if skills { "skills" } else { "hooks" };
            let value = field
                .key
                .parse::<usize>()
                .ok()
                .and_then(|i| items(&data, key).get(i))
                .cloned()
                .unwrap_or(json!({}));
            let mut fields = if skills {
                vec![
                    Self::field("name", "名称", text(&value, "name"), false, true),
                    Self::field("when", "使用场景", text(&value, "when"), false, true),
                    Self::field("prefix", "触发前缀", text(&value, "prefix"), false, true),
                    Self::field(
                        "prompt",
                        "技能指令（Alt+J 换行）",
                        text(&value, "prompt"),
                        false,
                        true,
                    ),
                ]
            } else {
                vec![
                    Self::field(
                        "command",
                        "监控触发的命令",
                        text(&value, "command"),
                        false,
                        true,
                    ),
                    Self::field(
                        "watchPath",
                        "监控相对路径",
                        text(&value, "watchPath"),
                        false,
                        true,
                    ),
                ]
            };
            fields.push(Self::field(
                "enabled",
                "启用 true/false",
                if value["enabled"] == true {
                    "true"
                } else {
                    "false"
                },
                false,
                true,
            ));
            fields.push(Self::field("__save", "保存", "", false, false));
            if !skills && !value["id"].is_null() {
                fields.push(Self::field("__run", "立即运行（确认）", "", false, false));
                fields.push(Self::field(
                    "__remove",
                    "删除规则（确认）",
                    "",
                    false,
                    false,
                ));
            }
            self.extra_form(
                if skills {
                    FormKind::Skill
                } else {
                    FormKind::Hook
                },
                if skills {
                    "编辑技能"
                } else {
                    "编辑自动化规则"
                },
                fields,
                value,
            );
            return Some(vec![]);
        }
        let (action, mut args) = match form.kind {
            FormKind::Context => {
                if field.key == "__contents" {
                    return Some(self.open_context_contents());
                }
                if field.key == "__detail" {
                    self.show_info(
                        "上下文详情",
                        items(&data, "lines")
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect(),
                    );
                    return Some(vec![]);
                }
                if field.key == "__auto" {
                    (
                        "context.set",
                        json!({"auto":true,"model_key":data["model_key"]}),
                    )
                } else if field.key == "__save" {
                    let mut v = json!({"model_key":data["model_key"]});
                    for key in ["window", "reserve", "history"] {
                        let Some(number) = token_count(get(key)) else {
                            self.form.as_mut()?.notice = format!("{key} 请输入整数，可用 k/m 后缀");
                            return Some(vec![]);
                        };
                        v[key] = json!(number);
                    }
                    v["output"] = if get("output_mode") == "model" {
                        json!(0)
                    } else {
                        let Some(number) = token_count(get("output")).filter(|n| *n > 0) else {
                            self.form.as_mut()?.notice =
                                "手动输出上限请输入正整数，可用 k/m 后缀".into();
                            return Some(vec![]);
                        };
                        json!(number)
                    };
                    ("context.set", v)
                } else {
                    return Some(vec![]);
                }
            }
            FormKind::Memory => {
                if field.key == "__detail" {
                    self.show_info(
                        "任务记忆",
                        ["user_pins", "constraints", "plan", "summary"]
                            .iter()
                            .map(|key| format!("{key}\n{}", text(&data, key)))
                            .collect(),
                    );
                    return Some(vec![]);
                }
                (
                    "memory.save",
                    json!({"revision":data["revision"].as_u64().unwrap_or(0),"text":get("user_pins")}),
                )
            }
            FormKind::Skill => (
                "skill.save",
                json!({"id":data["id"],"version":data["version"],"name":get("name"),"when":get("when"),"prefix":get("prefix"),"prompt":get("prompt"),"enabled":get("enabled")=="true"}),
            ),
            FormKind::Hook => {
                if !self.confirm_extra(&field.key, "请核对命令和启用状态，再按 Enter 确认")
                {
                    return Some(vec![]);
                }
                (
                    match field.key.as_str() {
                        "__run" => "hook.run",
                        "__remove" => "hook.remove",
                        _ => "hook.save",
                    },
                    json!({"id":data["id"],"version":data["version"],"command":get("command"),"watchPath":get("watchPath"),"enabled":get("enabled")=="true","confirmed":true}),
                )
            }
            FormKind::AddDir => {
                if !self.confirm_extra(&field.key, "请核对目录和访问权限，再按 Enter 确认")
                {
                    return Some(vec![]);
                }
                (
                    "add-dir",
                    json!({"path":get("path"),"name":get("name"),"access":get("access"),"confirmed":true}),
                )
            }
            _ => return None,
        };
        args["action"] = json!(action);
        let c = self.command("terminal.action", args);
        Some(self.submit_extra(c))
    }
    pub(crate) fn confirm_extra(&mut self, key: &str, message: &str) -> bool {
        if self.form_confirm.as_deref() == Some(key) {
            self.form_confirm = None;
            true
        } else {
            self.form_confirm = Some(key.into());
            if let Some(form) = self.form.as_mut() {
                form.notice = message.into();
            }
            false
        }
    }
    pub(crate) fn submit_extra(&mut self, c: Command) -> Vec<Command> {
        if self.pending_form.is_some() {
            self.notice = "请等待当前操作回执".into();
            return vec![];
        }
        if let Some(form) = self.form.as_mut() {
            self.pending_form_values = form.fields.clone();
            form.notice = "正在处理…".into();
        }
        self.pending_form = Some((self.form_revision, c.clone()));
        vec![c]
    }
    pub fn latest_output(&mut self) {
        self.scroll = 0;
        self.reading_anchor = None;
        self.unseen_output = false;
        self.notice.clear();
    }
    pub(crate) fn sync_context_output(&mut self) {
        let Some(form) = self.form.as_mut().filter(|f| f.kind == FormKind::Context) else {
            return;
        };
        let mode = form
            .fields
            .iter()
            .position(|f| f.key == "output_mode")
            .unwrap_or(0);
        let existing = form.fields.iter().position(|f| f.key == "output");
        if form.fields[mode].value == "manual" && existing.is_none() {
            let saved = form.items[0]["manual_output"]
                .as_str()
                .map(str::to_owned)
                .or_else(|| {
                    form.items[0]["context"]["maxOutputTokens"]
                        .as_u64()
                        .filter(|n| *n > 0)
                        .map(|n| n.to_string())
                })
                .unwrap_or_else(|| "16384".into());
            form.fields.insert(
                mode + 1,
                Self::field("output", "手动输出上限 tokens", &saved, false, true),
            );
        } else if form.fields[mode].value != "manual"
            && let Some(index) = existing
        {
            let value = form.fields.remove(index).value;
            form.items[0]["manual_output"] = json!(value);
        }
    }
    pub fn preview_attachment(&mut self, index: usize) -> Vec<Command> {
        let Some(value) = self.attachments.get(index).cloned() else {
            self.notice = "附件编号不存在".into();
            return vec![];
        };
        if value["reference"] == true {
            self.show_info(
                "文件地址",
                vec![
                    format!("{} {}", text(&value, "_tag"), text(&value, "name")),
                    text(&value, "path").to_owned(),
                ],
            );
            return vec![];
        }
        if value["token"].is_null() {
            self.show_info(
                "附件导入状态",
                vec![
                    format!("{} {}", text(&value, "_tag"), text(&value, "name")),
                    if value["_state"] == "error" {
                        format!(
                            "导入失败：{}\n请在附件列表 Delete 移除，再重新粘贴。",
                            text(&value, "_error")
                        )
                    } else {
                        "正在读取、解析或转换附件，请稍候。".into()
                    },
                ],
            );
            return vec![];
        }
        if ["image", "audio", "video"].contains(&text(&value, "kind")) {
            vec![self.terminal_action("attachment.preview", json!({"token":value["token"]}))]
        } else {
            let mut commands = self.terminal_query("attachment");
            commands[0].params["token"] = value["token"].clone();
            commands
        }
    }
}
