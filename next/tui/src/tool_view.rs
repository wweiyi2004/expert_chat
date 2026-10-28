use crate::app::{App, Command, Drawer, items, text};
use crossterm::event::{KeyCode, KeyEvent};
use serde_json::{Value, json};

pub fn skipped(step: &Value) -> bool {
    let detail = text(step, "detail");
    detail.contains("本轮最多执行") && detail.contains("跳过")
        || items(step, "tail")
            .iter()
            .filter_map(Value::as_str)
            .any(|s| s.contains("本轮最多执行") && s.contains("跳过"))
}
pub fn state(step: &Value) -> &str {
    if skipped(step) {
        "已跳过"
    } else {
        match text(step, "status") {
            "done" => "完成",
            "failed" => "失败",
            "running" => "进行中",
            "approval" => "待批准",
            "stopped" => "停止",
            _ => "结果待确认",
        }
    }
}
pub fn round_label(id: &str, index: usize) -> String {
    if id.is_empty() {
        return "未标注轮次".into();
    }
    if let Some(number) = id
        .strip_prefix("round-")
        .and_then(|s| s.parse::<usize>().ok())
    {
        return format!("第 {number} 轮");
    }
    format!("工具组 {}", index + 1)
}
impl App {
    pub fn open_tool_detail(&mut self, step: Value) -> Vec<Command> {
        self.open(Drawer::ToolDetail);
        self.tool_detail = step;
        self.tool_section = 0;
        self.refresh_tool_detail()
    }
    pub fn refresh_tool_detail(&self) -> Vec<Command> {
        vec![self.command("terminal.query",json!({"topic":"step.detail","step_id":self.tool_detail["id"],"ui_generation":self.extra_generation}))]
    }
    pub fn tool_detail_response(&mut self, command: &Command, result: &Value) -> bool {
        if command.method != "terminal.query" || command.params["topic"] != "step.detail" {
            return false;
        }
        if self.drawer == Some(Drawer::ToolDetail)
            && command.params["step_id"] == self.tool_detail["id"]
            && command.params["ui_generation"].as_u64() == Some(self.extra_generation)
        {
            self.tool_detail = result["step"].clone();
        }
        true
    }
    pub fn tool_detail_key(&mut self, key: KeyEvent) -> Vec<Command> {
        match key.code {
            KeyCode::Left => {
                self.tool_section = (self.tool_section + 3) % 4;
                self.selected = 0;
            }
            KeyCode::Right | KeyCode::Tab => {
                self.tool_section = (self.tool_section + 1) % 4;
                self.selected = 0;
            }
            KeyCode::Char('1'..='4') => {
                if let KeyCode::Char(c) = key.code {
                    self.tool_section = (c as usize) - ('1' as usize);
                    self.selected = 0;
                }
            }
            KeyCode::Char('c') => {
                self.copy_requested = Some(detail_text(&self.tool_detail, self.tool_section))
            }
            KeyCode::Char('r') => return self.refresh_tool_detail(),
            KeyCode::Down => self.selected = self.selected.saturating_add(1),
            KeyCode::Up => self.selected = self.selected.saturating_sub(1),
            KeyCode::PageDown => {
                self.selected = self
                    .selected
                    .saturating_add(self.viewport.1.saturating_sub(10) as usize)
            }
            KeyCode::PageUp => {
                self.selected = self
                    .selected
                    .saturating_sub(self.viewport.1.saturating_sub(10) as usize)
            }
            KeyCode::Home => self.selected = 0,
            KeyCode::End => self.selected = usize::MAX,
            KeyCode::Esc => self.open(Drawer::Steps),
            _ => {}
        };
        vec![]
    }
    pub fn open_tool_rounds(&mut self, message: Option<String>) {
        self.selection = None;
        self.steps_message = message;
        self.steps_round = None;
        self.failures_only = false;
        self.open(Drawer::Rounds);
    }
    pub fn round_items(&self) -> Vec<Value> {
        let mut groups: Vec<(String, Vec<&Value>)> = vec![];
        for step in items(&self.snapshot, "steps").iter().filter(|s| {
            self.steps_message
                .as_ref()
                .is_none_or(|id| text(s, "message_id") == id)
        }) {
            let id = text(step, "round_id");
            if let Some((_, list)) = groups.iter_mut().find(|(key, _)| key == id) {
                list.push(step);
            } else {
                groups.push((id.into(), vec![step]));
            }
        }
        groups.iter().enumerate().map(|(i,(id,steps))|{
            let failed=steps.iter().filter(|s|text(s,"status")=="failed"&&!skipped(s)).count();
            let skipped=steps.iter().filter(|s|skipped(s)).count();
            json!({"id":id,"title":format!("{} · {} 步{}{}",round_label(id,i),steps.len(),if failed>0{format!(" · {failed} 失败")}else{String::new()},if skipped>0{format!(" · {skipped} 跳过")}else{String::new()})})
        }).filter(|v|crate::app::search_rank(text(v,"title"),&self.search).is_some()).collect()
    }
    pub fn tool_step_items(&self) -> Vec<Value> {
        items(&self.snapshot,"steps").iter().enumerate()
            .filter(|(_,s)|(!self.failures_only||text(s,"status")=="failed"&&!skipped(s))
                && self.steps_message.as_ref().is_none_or(|id|text(s,"message_id")==id)
                && self.steps_round.as_ref().is_none_or(|id|text(s,"round_id")==id))
            .map(|(i,s)|json!({"index":i,"title":format!("{} · {} · {} {}",i+1,state(s),text(s,"verb"),text(s,"object"))}))
            .filter(|v|crate::app::search_rank(text(v,"title"),&self.search).is_some()).collect()
    }
}

fn readable(value: &Value, depth: usize) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(s) => {
            if depth < 3
                && let Ok(parsed) = serde_json::from_str::<Value>(s)
                && parsed.is_object()
            {
                return readable(&parsed, depth + 1);
            }
            s.clone()
        }
        Value::Object(map) => map
            .iter()
            .map(|(k, v)| {
                format!(
                    "{}：{}",
                    match k.as_str() {
                        "stdout" => "标准输出",
                        "stderr" => "错误输出",
                        "error" => "错误",
                        "message" => "说明",
                        "command" => "命令",
                        "path" => "路径",
                        "content" => "内容",
                        "exit_code" => "退出码",
                        "status" => "状态",
                        _ => k,
                    },
                    readable(v, depth + 1)
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n"),
        Value::Array(list) => list
            .iter()
            .map(|v| readable(v, depth + 1))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => value.to_string(),
    }
}
pub fn detail_text(step: &Value, section: usize) -> String {
    match section {
        1 => {
            let value = readable(&step["input"], 0);
            if value.is_empty() {
                "没有记录工具输入".into()
            } else {
                value
            }
        }
        2 => {
            let value = readable(&step["result"], 0);
            if value.is_empty() {
                let tail = items(step, "tail")
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join("\n");
                if tail.is_empty() {
                    "尚无输出".into()
                } else {
                    tail
                }
            } else {
                value
            }
        }
        3 => serde_json::to_string_pretty(step).unwrap_or_default(),
        _ => {
            let mut value = format!(
                "{} {}\n\n状态：{}",
                text(step, "verb"),
                text(step, "object"),
                state(step)
            );
            if let Some(ms) = step["elapsed_ms"].as_u64() {
                value.push_str(&format!("\n耗时：{:.2} 秒", ms as f64 / 1000.0));
            }
            if let Some(code) = step["exit_code"].as_i64() {
                value.push_str(&format!("\n退出码：{code}"));
            }
            if !text(step, "detail").is_empty() {
                value.push_str(&format!("\n\n错误或说明\n{}", text(step, "detail")));
            }
            value.push_str(&format!(
                "\n\n输入\n{}\n\n输出\n{}",
                detail_text(step, 1),
                detail_text(step, 2)
            ));
            value
        }
    }
}
