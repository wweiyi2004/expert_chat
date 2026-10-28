use crate::app::{App, Command, FormKind, items, text};
use serde_json::{Value, json};

impl App {
    pub fn open_quota(&mut self, profile_id: &str) -> Vec<Command> {
        self.extra_form(
            FormKind::Quota,
            "套餐与额度",
            vec![
                Self::field("__refresh", "刷新官方额度", "", false, false),
                Self::field("__accounts", "返回账号列表", "", false, false),
            ],
            json!({"profile_id":profile_id}),
        );
        self.form.as_mut().unwrap().notice = "正在读取本机记录…".into();
        vec![self.command(
            "provider.login.usage",
            json!({
                "profile_id":profile_id,"refresh":false,"ui_revision":self.form_revision
            }),
        )]
    }

    pub fn quota_form_action(&mut self) -> Option<Vec<Command>> {
        let form = self.form.as_ref()?;
        if form.kind != FormKind::Quota {
            return None;
        }
        let key = form.fields.get(form.selected)?.key.clone();
        let data = form.items.first()?.clone();
        let profile_id = text(&data, "profile_id");
        match key.as_str() {
            "__refresh" => {
                self.form.as_mut().unwrap().notice = "正在读取官方额度；不会发送模型请求…".into();
                Some(vec![self.command(
                    "provider.login.usage",
                    json!({
                        "profile_id":profile_id,"refresh":true,"ui_revision":self.form_revision
                    }),
                )])
            }
            "__console" => Some(vec![self.command(
                "provider.login.console",
                json!({
                    "profile_id":profile_id,"quota_origin":true,"ui_revision":self.form_revision
                }),
            )]),
            "__copy_console" => {
                self.copy_requested = Some(text(&data["usage"], "console_url").into());
                Some(vec![])
            }
            "__accounts" => Some(self.open_login()),
            _ => Some(vec![]),
        }
    }

    pub fn quota_response(&mut self, command: &Command, result: &Value) -> bool {
        let usage = command.method == "provider.login.usage";
        let console =
            command.method == "provider.login.console" && command.params["quota_origin"] == true;
        if !usage && !console {
            return false;
        }
        if !self
            .form
            .as_ref()
            .is_some_and(|f| f.kind == FormKind::Quota)
            || command.params["ui_revision"].as_u64() != Some(self.form_revision)
        {
            return true;
        }
        if console {
            self.form.as_mut().unwrap().notice = text(result, "notice").into();
            return true;
        }
        let data = &result["usage"];
        let mut lines = vec![format!("账号：{}", text(&result["account"], "name"))];
        let plan = text(data, "plan");
        lines.push(format!(
            "套餐：{}",
            if plan.is_empty() {
                "服务端未报告"
            } else {
                plan
            }
        ));
        let expiry = text(data, "subscription_expires_at");
        lines.push(format!(
            "套餐到期：{}",
            if expiry.is_empty() {
                "未报告，请在官方控制台查看"
            } else {
                expiry
            }
        ));
        if !text(data, "credential_expires_at").is_empty() {
            lines.push(format!(
                "授权令牌到期：{}（与套餐到期不同）",
                text(data, "credential_expires_at")
            ));
        }
        if !text(data, "checked_at").is_empty() {
            lines.push(format!(
                "查询时间：{}{}",
                text(data, "checked_at"),
                if data["cached"] == true {
                    " · 缓存，点击刷新更新"
                } else {
                    ""
                }
            ));
        }
        for window in items(data, "windows") {
            let remaining = window["remaining_percent"].as_f64();
            let amount = if let Some(value) = remaining {
                let value = value.clamp(0.0, 100.0);
                let fill = ((value / 100.0) * 16.0).round() as usize;
                format!(
                    "[{}{}] 剩余 {:.1}%",
                    "■".repeat(fill),
                    "·".repeat(16 - fill),
                    value
                )
            } else {
                "未报告百分比".into()
            };
            lines.push(format!("{}  {}", text(window, "label"), amount));
            if let (Some(used), Some(total)) = (window["used"].as_f64(), window["total"].as_f64()) {
                lines.push(format!("  已用 {:.0} / 总量 {:.0}", used, total));
            }
            let reset = text(window, "reset_at");
            lines.push(format!(
                "  重置：{}",
                if reset.is_empty() {
                    "服务端未报告"
                } else {
                    reset
                }
            ));
        }
        if items(data, "windows").is_empty() {
            lines.push(if data["capability"] == "unsupported" {
                "此来源尚无可用的官方额度查询接口".into()
            } else if data["state"] == "error" {
                "本次读取失败，未把未知额度显示为 0".into()
            } else {
                "尚未读取额度，请点击刷新".into()
            });
        }
        let mut fields = lines
            .iter()
            .enumerate()
            .map(|(i, line)| Self::field(&format!("line_{i}"), line, "", false, false))
            .collect::<Vec<_>>();
        if data["capability"] != "unsupported" {
            fields.push(Self::field("__refresh", "刷新官方额度", "", false, false));
        }
        if !text(data, "console_url").is_empty() {
            fields.push(Self::field("__console", "打开官方控制台", "", false, false));
            fields.push(Self::field(
                "__copy_console",
                "复制控制台网址",
                "",
                false,
                false,
            ));
        }
        fields.push(Self::field("__accounts", "返回账号列表", "", false, false));
        let selected = fields
            .iter()
            .position(|f| f.key.starts_with("__"))
            .unwrap_or(0);
        let mut stored = result.clone();
        stored["profile_id"] = command.params["profile_id"].clone();
        self.extra_form(FormKind::Quota, "套餐与额度", fields, stored);
        let form = self.form.as_mut().unwrap();
        form.selected = selected;
        form.notice = text(data, "notice").into();
        true
    }
}
