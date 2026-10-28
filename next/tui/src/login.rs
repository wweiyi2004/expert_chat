use crate::app::{App, Command, Drawer, FormKind, items, text};
use serde_json::{Value, json};
impl App {
    pub fn open_login(&mut self) -> Vec<Command> {
        if self.login_job.is_some() {
            self.extra_form(
                FormKind::LoginProgress,
                "账号登录",
                vec![Self::field("__cancel", "取消登录", "", false, false)],
                json!({}),
            );
            return vec![];
        }
        self.extra_form(FormKind::Login, "账号与订阅", vec![], json!({}));
        vec![self.command(
            "provider.login.list",
            json!({"ui_revision":self.form_revision}),
        )]
    }
    pub fn cancel_login(&mut self) -> Vec<Command> {
        self.login_job
            .as_ref()
            .map(|id| vec![self.command("provider.login.cancel", json!({"job_id":id}))])
            .unwrap_or_default()
    }
    pub fn login_form_action(&mut self) -> Option<Vec<Command>> {
        let form = self.form.as_ref()?;
        if form.kind == FormKind::LoginProgress {
            let field = form.fields.get(form.selected)?;
            if field.key == "__copy_url" || field.key == "__copy_code" {
                self.copy_requested = Some(
                    text(
                        &form.items[0],
                        if field.key == "__copy_url" {
                            "verification_url"
                        } else {
                            "user_code"
                        },
                    )
                    .into(),
                );
                return Some(vec![]);
            }
            return Some(if field.key == "__cancel" {
                self.cancel_login()
            } else {
                vec![]
            });
        }
        if form.kind != FormKind::Login {
            return None;
        }
        let item = form.items.get(form.selected)?.clone();
        match text(&item, "kind") {
            "accounts" => Some(self.open_login()),
            "account_quota" => Some(self.open_quota(text(&item, "profile_id"))),
            "account" => {
                self.form.as_mut().unwrap().notice = "正在读取账号信息…".into();
                Some(vec![self.command(
                    "provider.login.account",
                    json!({"profile_id":item["profile_id"],"ui_revision":self.form_revision}),
                )])
            }
            "account_edit" => {
                self.settings_page = 1;
                self.edit_provider(item["profile"].clone());
                self.login_provider_editor = true;
                Some(vec![])
            }
            "account_models" => {
                self.open(Drawer::Model);
                self.model_source_filter = Some(text(&item, "profile_id").into());
                self.selected = 0;
                let list = self.drawer_items();
                if let Some(index) = list
                    .iter()
                    .position(|m| crate::app::current_model(m, &self.snapshot["session"]))
                {
                    self.selected = index;
                }
                if let Some(model) = list.get(self.selected) {
                    self.effort_index = items(model, "efforts")
                        .iter()
                        .position(|e| e == &self.snapshot["session"]["effort"])
                        .unwrap_or(0);
                }
                self.notice = format!(
                    "{} 的模型 · /model 查看全部账号",
                    text(&item, "account_name")
                );
                Some(vec![self.command("models.list", json!({}))])
            }
            "subscription" => {
                let mut options = items(&item, "options").to_vec();
                options.push(Self::login_back());
                self.show_login_choices(text(&item, "name"), options);
                Some(vec![])
            }
            "oauth" => {
                let title = if item["provider"] == "kimiCode" {
                    "Kimi Code 订阅登录"
                } else {
                    "ChatGPT 订阅登录"
                };
                self.extra_form(
                    FormKind::LoginProgress,
                    title,
                    vec![Self::field("__cancel", "取消登录", "", false, false)],
                    json!({}),
                );
                self.form.as_mut().unwrap().notice =
                    "正在打开浏览器授权；完成后自动获取模型 · Esc 取消".into();
                let mut params = json!({"ui_revision":self.form_revision,"provider":item["provider"].as_str().unwrap_or("chatgpt")});
                if !item["profile_id"].is_null() {
                    params["profile_id"] = item["profile_id"].clone();
                }
                Some(vec![self.command("provider.login.start", params)])
            }
            "console" | "subscription_key" => {
                self.settings_page = 1;
                let models = item["models"].as_array().cloned().unwrap_or_default();
                let first = models
                    .first()
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                self.edit_provider(json!({"name":item["name"],"base_url":item["base_url"],"api_format":item["api_format"],"models":models,"chat_model":first,"reasoner_model":first}));
                self.login_provider_editor = true;
                let form = self.form.as_mut().unwrap();
                form.title = format!("连接 {}", text(&item, "name"));
                form.notice =
                    "从套餐控制台取得 Key，粘贴后保存；模型列表可自动获取或手动填写".into();
                form.selected = form
                    .fields
                    .iter()
                    .position(|f| f.key == "api_key")
                    .unwrap_or(0);
                form.editing = true;
                form.cursor = 0;
                let params = if item["kind"] == "subscription_key" {
                    json!({"provider":item["key"]})
                } else {
                    json!({})
                };
                Some(vec![self.command("provider.login.console", params)])
            }
            _ => {
                let commands = self.extra_command("/connect", "");
                self.login_provider_editor = true;
                Some(commands)
            }
        }
    }
    fn show_login_choices(&mut self, title: &str, rows: Vec<Value>) {
        let fields = rows
            .iter()
            .enumerate()
            .map(|(i, v)| {
                Self::field(
                    &i.to_string(),
                    &format!("{} · {}", text(v, "name"), text(v, "description")),
                    "",
                    false,
                    false,
                )
            })
            .collect();
        self.extra_form(FormKind::Login, title, fields, json!({}));
        self.form.as_mut().unwrap().items = rows;
    }
    fn login_back() -> Value {
        json!({"kind":"accounts","name":"返回账号列表","description":"查看已连接账号或添加账号"})
    }
    fn show_login_accounts(&mut self, result: &Value) {
        let (mut accounts, additions): (Vec<_>, Vec<_>) = items(result, "providers")
            .iter()
            .cloned()
            .partition(|row| row["kind"] == "account");
        let count = accounts.len();
        let labels: Vec<_> = accounts
            .iter()
            .map(|row| {
                (
                    text(row, "name").to_owned(),
                    text(row, "source_name").to_owned(),
                )
            })
            .collect();
        for (i, row) in accounts.iter_mut().enumerate() {
            let name = text(row, "name").to_owned();
            let source = text(row, "source_name");
            // A source alias distinguishes two saved connections with the same account name.
            let mut label = if !source.is_empty() && source != name {
                format!("{}. {}（{}）", i + 1, name, source)
            } else {
                format!("{}. {}", i + 1, name)
            };
            if labels
                .iter()
                .filter(|(n, s)| n == &name && s == source)
                .count()
                > 1
            {
                let id = text(row, "profile_id");
                let suffix = id
                    .chars()
                    .rev()
                    .take(6)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .collect::<String>();
                label.push_str(&format!(" · #{}", suffix));
            }
            row["name"] = json!(label);
            if row["profile_id"] == self.snapshot["session"]["model_source_id"] {
                row["description"] = json!(format!("当前会话 · {}", text(row, "description")));
            }
        }
        accounts.push(json!({"kind":"subscription","name":"＋ 添加账号","description":"同一服务可连接多个账号","options":additions}));
        self.show_login_choices(&format!("账号与订阅 · {} 个已保存来源", count), accounts);
    }
    fn show_login_account(&mut self, result: &Value) {
        let account = &result["account"];
        let profile = &result["profile"];
        let mut rows = vec![];
        rows.push(json!({"kind":"account_quota","name":"套餐与额度","description":"查看剩余额度、重置时间和官方控制台","profile_id":account["profile_id"]}));
        if account["enabled"] == true
            && account["credential_ready"] == true
            && !items(profile, "models").is_empty()
        {
            rows.push(json!({"kind":"account_models","name":"使用此账号","description":"选择此账号的模型","profile_id":account["profile_id"],"account_name":account["name"]}));
        }
        rows.push(json!({"kind":"account_edit","name":"管理此账号","description":"修改别名、模型、Key 或启用状态","profile":profile}));
        if account["can_reauthorize"] == true {
            rows.push(json!({"kind":"oauth","name":"重新登录此账号","description":"更新这个来源的授权","provider":account["provider"],"profile_id":account["profile_id"]}));
        }
        rows.push(Self::login_back());
        self.show_login_choices(
            &format!(
                "{} · {}",
                text(account, "provider_label"),
                text(account, "name")
            ),
            rows,
        );
        let source = if account["account_label_source"] == "source_name" {
            "名称来自保存的来源别名"
        } else {
            "名称来自账号授权信息"
        };
        self.form.as_mut().unwrap().notice =
            format!("{} · {}", text(account, "description"), source);
    }
    pub fn login_response(&mut self, command: &Command, result: &Value) -> bool {
        if !command.method.starts_with("provider.login.") {
            return false;
        }
        match command.method.as_str() {
            "provider.login.list" => {
                if self
                    .form
                    .as_ref()
                    .is_some_and(|f| f.kind == FormKind::Login)
                    && command.params["ui_revision"].as_u64() == Some(self.form_revision)
                {
                    self.show_login_accounts(result);
                }
            }
            "provider.login.account" => {
                if self
                    .form
                    .as_ref()
                    .is_some_and(|f| f.kind == FormKind::Login)
                    && command.params["ui_revision"].as_u64() == Some(self.form_revision)
                {
                    self.show_login_account(result);
                }
            }
            "provider.login.start" => {
                if let Some(id) = result["job_id"].as_str() {
                    self.login_job = Some(id.into());
                    if !self
                        .form
                        .as_ref()
                        .is_some_and(|f| f.kind == FormKind::LoginProgress)
                        || command.params["ui_revision"].as_u64() != Some(self.form_revision)
                    {
                        let commands = self.cancel_login();
                        self.outbox.extend(commands);
                    }
                }
            }
            "provider.login.status" | "provider.login.cancel" => {
                self.login_poll_pending = false;
                if result["job_id"].as_str() != self.login_job.as_deref() {
                    return true;
                }
                let status = text(result, "stage").to_owned();
                if let Some(form) = self
                    .form
                    .as_mut()
                    .filter(|f| f.kind == FormKind::LoginProgress)
                {
                    form.notice = status.clone();
                    if !text(result, "verification_url").is_empty()
                        && form.items[0]["verification_url"] != result["verification_url"]
                    {
                        form.items = vec![result.clone()];
                        form.fields = vec![
                            Self::field("code", "授权码", text(result, "user_code"), false, false),
                            Self::field(
                                "url",
                                "授权网址",
                                text(result, "verification_url"),
                                false,
                                false,
                            ),
                            Self::field("__copy_code", "复制授权码", "", false, false),
                            Self::field("__copy_url", "复制授权网址", "", false, false),
                            Self::field("__cancel", "取消登录", "", false, false),
                        ];
                        form.original_fields = form.fields.clone();
                        form.selected = 4;
                    }
                }
                if result["done"] == true {
                    self.login_job = None;
                    self.notice = status.clone();
                    if self
                        .form
                        .as_ref()
                        .is_some_and(|f| f.kind == FormKind::LoginProgress)
                    {
                        let commands = self.open_login();
                        self.outbox.extend(commands);
                    }
                    self.outbox.push(self.command("settings.get", json!({})));
                    self.outbox.push(self.command("models.list", json!({})));
                }
            }
            _ => {
                self.notice = text(result, "notice").into();
            }
        }
        true
    }
}
