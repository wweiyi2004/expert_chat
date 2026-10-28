use crate::app::{App, Command, FormKind, items, text};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    Frame,
    layout::Rect,
    style::Style,
    widgets::{Block, Borders, Clear, Paragraph},
};
use serde_json::{Value, json};

#[derive(Debug, Default, Clone)]
pub struct SidePanel {
    pub data: Value,
    pub input: String,
    pub cursor: usize,
    pub scroll: usize,
    pub focused: bool,
    pub promote_prepared: bool,
}
impl App {
    pub fn workbench_query(&mut self, topic: &str, mut params: Value) -> Vec<Command> {
        self.wb_epoch = self.wb_epoch.wrapping_add(1);
        params["_wb_epoch"] = json!(self.wb_epoch);
        params["_workbench"] = json!(true);
        if matches!(topic, "wb.side.open" | "wb.preview") {
            params["action"] = json!(topic);
            vec![self.command("terminal.action", params)]
        } else {
            params["topic"] = json!(topic);
            vec![self.command("terminal.query", params)]
        }
    }
    pub fn workbench_response(&mut self, c: &Command, r: &Value) -> bool {
        if c.params["_workbench"] != true {
            return false;
        }
        if self
            .wb_action_pending
            .is_some_and(|epoch| c.params["_wb_epoch"].as_u64() == Some(epoch))
        {
            self.wb_action_pending = None;
        }
        if r["file_saved"] == true {
            let Some(e) = self.native_editor.as_mut().filter(|e| {
                c.params["_editor_id"].as_u64() == Some(e.instance_id)
                    && c.params["session_id"].as_str() == e.session.as_deref()
            }) else {
                return true;
            };
            e.save_pending = false;
            e.file_hash = text(r, "sha256").into();
            e.saved_text = text(&c.params, "content").into();
            e.file_path = Some(text(r, "path").into());
            if e.run_after_save && e.text == e.saved_text {
                self.outbox.push(Command {
                    method: "terminal.action".into(),
                    params: json!({"path":e.file_path,"sha256":e.file_hash,"action":"wb.file.run","session_id":e.session,"_workbench":true}),
                });
            }
            e.run_after_save = false;
            if c.params["_wb_epoch"].as_u64() == Some(self.wb_epoch) {
                self.form = None;
                self.drawer = Some(crate::app::Drawer::Editor);
            }
            self.notice = "文件已保存".into();
            return true;
        }
        self.wb_poll_pending = false;
        if c.params["_wb_epoch"]
            .as_u64()
            .is_some_and(|n| n != self.wb_epoch)
        {
            return true;
        }
        if (c.params["topic"] == "wb.job" && self.form.is_none())
            || (c.params["_wb_poll"] == true
                && self.side_panel.is_none()
                && c.params["topic"] != "wb.job")
        {
            return true;
        }
        if c.params["session_id"] != self.snapshot["session"]["id"]
            && self
                .side_panel
                .as_ref()
                .is_none_or(|p| p.data["session_id"] != c.params["session_id"])
        {
            return true;
        }
        if r["side"] == true {
            let identity = format!(
                "{}:{}",
                text(r, "kind"),
                if text(r, "kind") == "agent" {
                    text(r, "agent_id")
                } else {
                    text(r, "job_id")
                }
            );
            if self.side_panel.as_ref().is_some_and(|p| {
                format!(
                    "{}:{}",
                    text(&p.data, "kind"),
                    if text(&p.data, "kind") == "agent" {
                        text(&p.data, "agent_id")
                    } else {
                        text(&p.data, "job_id")
                    }
                ) != identity
            }) {
                if let Some(old) = self.side_panel.take() {
                    let key = format!(
                        "{}:{}",
                        text(&old.data, "kind"),
                        if text(&old.data, "kind") == "agent" {
                            text(&old.data, "agent_id")
                        } else {
                            text(&old.data, "job_id")
                        }
                    );
                    self.side_cache.insert(key, old);
                }
            }
            let fresh = self.side_panel.is_none();
            let p = self
                .side_panel
                .get_or_insert_with(|| self.side_cache.remove(&identity).unwrap_or_default());
            if c.params["action"]
                .as_str()
                .is_some_and(|s| s.ends_with(".send") || s.ends_with(".promote"))
            {
                let sent = text(&c.params, "text");
                if !sent.is_empty() && p.input.starts_with(sent) {
                    p.input.drain(..sent.len());
                    p.cursor = p.cursor.saturating_sub(sent.len());
                }
            }
            p.data = r.clone();
            if fresh {
                p.focused = true;
            }
            return true;
        }
        if r["editor_file"] == true {
            self.open_native_editor();
            if let Some(e) = self.native_editor.as_mut() {
                e.text = text(r, "content").into();
                e.cursor = 0;
                e.file_path = Some(text(r, "path").into());
                e.file_hash = text(r, "sha256").into();
                e.saved_text = e.text.clone();
                e.language = language(text(r, "path")).into();
            }
            return true;
        }
        if r["workbench"] == true {
            let fields = items(r, "fields")
                .iter()
                .map(|v| {
                    Self::field(
                        text(v, "key"),
                        text(v, "label"),
                        text(v, "value"),
                        v["secret"] == true,
                        v["editable"] == true,
                    )
                })
                .collect();
            self.extra_form(FormKind::Workbench, text(r, "title"), fields, r.clone());
            self.wb_job = if r["done"] != true && !text(r, "job_id").is_empty() {
                Some(text(r, "job_id").into())
            } else {
                None
            };
        }
        true
    }
    pub fn workbench_error(&mut self, c: &Command, message: &str) -> bool {
        if c.params["_workbench"] != true {
            return false;
        }
        if self
            .wb_action_pending
            .is_some_and(|epoch| c.params["_wb_epoch"].as_u64() == Some(epoch))
        {
            self.wb_action_pending = None;
        }
        if c.params["action"] == "wb.file.save" {
            if let Some(e) = self.native_editor.as_mut().filter(|e| {
                c.params["_editor_id"].as_u64() == Some(e.instance_id)
                    && c.params["session_id"].as_str() == e.session.as_deref()
            }) {
                e.save_pending = false;
                e.run_after_save = false;
            } else {
                return true;
            }
        }
        self.wb_poll_pending = false;
        self.wb_job = None;
        self.notice = message.into();
        if let Some(f) = self.form.as_mut() {
            f.notice = message.into();
        }
        if let Some(p) = self.side_panel.as_mut() {
            p.data["notice"] = json!(message);
        }
        true
    }
    pub fn workbench_action(&mut self) -> Option<Vec<Command>> {
        let f = self.form.as_ref()?;
        if f.kind != FormKind::Workbench {
            return None;
        }
        let field = f.fields.get(f.selected)?;
        let source = f.items.first()?;
        let item = items(source, "fields")
            .iter()
            .find(|v| text(v, "key") == field.key)?;
        let mut action = text(item, "action").to_owned();
        if action.is_empty() {
            return None;
        }
        if self.wb_action_pending.is_some() {
            self.notice = "操作正在提交，请稍候".into();
            return Some(vec![]);
        }
        if action == "client.copy" {
            self.copy_requested = Some(text(&source["data"], "output").into());
            return Some(vec![]);
        }
        if action == "client.editor" {
            self.form = None;
            self.drawer = if self.native_editor.is_some() {
                Some(crate::app::Drawer::Editor)
            } else {
                None
            };
            return Some(vec![]);
        }

        let mut args = source["data"].as_object().cloned().unwrap_or_default();
        if field.key.starts_with("remote_") {
            let n = field.key.split(':').nth(1)?.parse::<usize>().ok()?;
            let remote = source["data"]["remote_items"][n].clone();
            args.insert("item".into(), remote.clone());
            args.insert("remote_id".into(), remote["id"].clone());
            if action == "client.remote.edit" {
                if let Some(form) = self.form.as_mut() {
                    for f in &mut form.fields {
                        let key = match f.key.as_str() {
                            "remote_id" => "id",
                            "seconds" => "intervalSeconds",
                            v => v,
                        };
                        if !remote[key].is_null() {
                            f.value = remote[key]
                                .as_str()
                                .map(str::to_owned)
                                .unwrap_or_else(|| remote[key].to_string());
                        }
                    }
                }
                return Some(vec![]);
            }
        }

        for v in &f.fields {
            if v.editable {
                args.insert(v.key.clone(), json!(v.value));
            }
        }
        if field.key.starts_with("entry:") {
            let n = field.key[6..].parse::<usize>().ok()?;
            let entry = &source["data"]["entries"][n];
            let base = text(&source["data"], "path");
            args.insert(
                "path".into(),
                json!(format!("{}/{}", base, text(entry, "name"))),
            );
            action = if entry["directory"] == true || entry["kind"] == "directory" {
                "wb.files"
            } else {
                "wb.file.open"
            }
            .into();
        } else if action == "wb.files.parent" {
            let path = text(&source["data"], "path");
            args.insert(
                "path".into(),
                json!(
                    std::path::Path::new(path)
                        .parent()
                        .unwrap_or(std::path::Path::new("."))
                        .to_string_lossy()
                ),
            );
            action = "wb.files".into();
        } else if field.key.starts_with("toggle:")
            || field.key.starts_with("remove:")
            || field.key.starts_with("run:")
            || field.key.starts_with("edit:")
            || field.key.starts_with("log:")
        {
            let n = field.key.split(':').nth(1)?.parse::<usize>().ok()?;
            args.insert(
                "schedule_id".into(),
                source["data"]["schedules"][n]["id"].clone(),
            );
            if action == "client.schedule.edit" {
                let value = source["data"]["schedules"][n].clone();
                if let Some(f) = self.form.as_mut() {
                    f.items[0]["data"]["schedule_id"] = value["id"].clone();
                    for field in &mut f.fields {
                        if ["seconds", "command"].contains(&field.key.as_str()) {
                            field.value = value[&field.key]
                                .as_str()
                                .map(str::to_owned)
                                .unwrap_or_else(|| value[&field.key].to_string());
                        }
                    }
                }
                return Some(vec![]);
            }
        } else if action == "wb.update.choose" {
            let n = field.key.split(':').nth(1)?.parse::<usize>().ok()?;
            let path = source["data"]["versions"][n].as_str()?.to_owned();
            if let Some(f) = self.form.as_mut() {
                if let Some(field) = f.fields.iter_mut().find(|v| v.key == "path") {
                    field.value = path;
                }
            }
            return Some(vec![]);
        }
        if field.key.starts_with("session:") {
            args.insert(
                "target_session".into(),
                json!(field.key.trim_start_matches("session:")),
            );
        }
        if field.key.starts_with("creation:") {
            args.insert(
                "item_id".into(),
                json!(field.key.trim_start_matches("creation:")),
            );
        }
        if field.key.starts_with("generation:") {
            args.insert(
                "generation_id".into(),
                json!(field.key.trim_start_matches("generation:")),
            );
        }
        if action == "wb.file.save" {
            if let Some(e) = self.native_editor.as_mut() {
                if e.session.as_deref() != self.snapshot["session"]["id"].as_str() {
                    self.notice = "编辑文件属于另一会话，请返回原会话保存".into();
                    return Some(vec![]);
                }
                if e.save_pending {
                    self.notice = "文件正在保存，请稍候".into();
                    return Some(vec![]);
                }
                e.save_pending = true;
                args.insert("_editor_id".into(), json!(e.instance_id));
                args.insert("content".into(), json!(e.text));
                args.insert(
                    "sha256".into(),
                    json!(if args.get("save_as") == Some(&json!(true)) {
                        "new"
                    } else {
                        &e.file_hash
                    }),
                );
            }
        }
        if field.key.starts_with("job:") {
            args.insert("job_id".into(), json!(field.key.trim_start_matches("job:")));
        }
        self.wb_epoch = self.wb_epoch.wrapping_add(1);
        args.insert("_wb_epoch".into(), json!(self.wb_epoch));
        self.wb_action_pending = Some(self.wb_epoch);
        args.insert("action".into(), json!(action));
        args.insert("_workbench".into(), json!(true));
        Some(vec![self.command("terminal.action", Value::Object(args))])
    }
    pub fn workbench_poll(&mut self) -> Vec<Command> {
        if self.wb_poll_pending {
            return vec![];
        }
        let (topic, mut args) = if let Some(p) = self.side_panel.as_ref() {
            (
                match text(&p.data, "kind") {
                    "agent" => "wb.agent.poll",
                    "session" => "wb.session",
                    _ => "wb.side.poll",
                },
                json!({"session_id":p.data["session_id"],"job_id":p.data["job_id"],"agent_id":p.data["agent_id"]}),
            )
        } else if let Some(job) = &self.wb_job {
            if self.form.is_none() {
                return vec![];
            }
            ("wb.job", json!({"job_id":job}))
        } else {
            return vec![];
        };
        args["_wb_poll"] = json!(true);
        args["_wb_epoch"] = json!(self.wb_epoch);
        args["topic"] = json!(topic);
        args["_workbench"] = json!(true);
        self.wb_poll_pending = true;
        let mut c = self.command("terminal.query", args.clone());
        if args["session_id"].is_string() {
            c.params["session_id"] = args["session_id"].clone();
        }
        vec![c]
    }
    pub fn side_key(&mut self, key: KeyEvent) -> Option<Vec<Command>> {
        let p = self.side_panel.as_mut()?;
        if key.code == KeyCode::F(6) {
            p.focused = !p.focused;
            return Some(vec![]);
        }
        if !p.focused {
            return None;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if ctrl && key.code == KeyCode::Char('v') {
            self.clipboard_requested = true;
            return Some(vec![]);
        }
        if key.code == KeyCode::Esc {
            if let Some(old) = self.side_panel.take() {
                let key = format!(
                    "{}:{}",
                    text(&old.data, "kind"),
                    if text(&old.data, "kind") == "agent" {
                        text(&old.data, "agent_id")
                    } else {
                        text(&old.data, "job_id")
                    }
                );
                self.side_cache.insert(key, old);
            }
            self.wb_poll_pending = false;
            return Some(vec![]);
        }
        let mut params = p.data.clone();
        params["_workbench"] = json!(true);
        if key.code == KeyCode::PageUp {
            p.scroll += 8;
            return Some(vec![]);
        }
        if key.code == KeyCode::PageDown {
            p.scroll = p.scroll.saturating_sub(8);
            return Some(vec![]);
        }
        let kind = text(&p.data, "kind");
        if ctrl && key.code == KeyCode::Char('r') {
            params["action"] = json!(if kind == "agent" {
                "wb.agent.poll"
            } else if kind == "session" {
                "wb.session"
            } else {
                "wb.side.refresh"
            });
        } else if ctrl && key.code == KeyCode::Char('c') {
            params["action"] = json!(if kind == "agent" {
                "wb.agent.cancel"
            } else {
                "wb.side.cancel"
            });
        } else if ctrl && key.code == KeyCode::Char('p') && kind == "side" {
            if !p.promote_prepared {
                p.input = items(&p.data, "messages")
                    .iter()
                    .rev()
                    .find(|m| m["role"] == "assistant")
                    .map(|m| text(m, "text"))
                    .unwrap_or("")
                    .to_owned();
                p.cursor = p.input.len();
                p.promote_prepared = true;
                p.data["notice"] = json!("编辑待加入的内容，再次点击加入主任务确认");
                return Some(vec![]);
            }
            params["action"] = json!("wb.side.promote");
            params["text"] = json!(p.input);
            p.promote_prepared = false;
        } else if key.code == KeyCode::Enter
            && !key
                .modifiers
                .intersects(KeyModifiers::ALT | KeyModifiers::SHIFT)
        {
            if p.input.trim().is_empty() {
                return Some(vec![]);
            }
            params["action"] = json!(if kind == "agent" {
                "wb.agent.send"
            } else if kind == "session" {
                "wb.session.send"
            } else {
                "wb.side.send"
            });
            params["text"] = json!(p.input);
        } else {
            match key.code {
                KeyCode::Char(c) if !ctrl => {
                    p.input.insert(p.cursor, c);
                    p.cursor += c.len_utf8();
                }
                KeyCode::Backspace => {
                    if p.cursor > 0 {
                        let start = p.input[..p.cursor]
                            .char_indices()
                            .last()
                            .map_or(0, |(i, _)| i);
                        p.input.drain(start..p.cursor);
                        p.cursor = start;
                    }
                }
                KeyCode::Delete => {
                    if let Some(c) = p.input[p.cursor..].chars().next() {
                        p.input.drain(p.cursor..p.cursor + c.len_utf8());
                    }
                }
                KeyCode::Left => {
                    p.cursor = p.input[..p.cursor]
                        .char_indices()
                        .last()
                        .map_or(0, |(i, _)| i);
                }
                KeyCode::Right => {
                    if let Some(c) = p.input[p.cursor..].chars().next() {
                        p.cursor += c.len_utf8();
                    }
                }
                KeyCode::Home => p.cursor = 0,
                KeyCode::End => p.cursor = p.input.len(),
                KeyCode::Enter => {
                    p.input.insert(p.cursor, '\n');
                    p.cursor += 1;
                }
                _ => {}
            }
            return Some(vec![]);
        }
        self.wb_epoch = self.wb_epoch.wrapping_add(1);
        params["_wb_epoch"] = json!(self.wb_epoch);
        Some(vec![Command {
            method: "terminal.action".into(),
            params,
        }])
    }
    pub fn open_agent_window(&mut self, id: &str) -> Vec<Command> {
        self.workbench_query("wb.agent.poll", json!({"agent_id":id}))
    }
}
pub fn language(path: &str) -> &'static str {
    match std::path::Path::new(path)
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
    {
        "py" => "python",
        "js" => "javascript",
        "rs" => "rust",
        "c" => "c",
        "cpp" | "cc" => "cpp",
        "json" => "json",
        "md" => "markdown",
        "dart" => "dart",
        _ => "text",
    }
}
pub fn side_rect(a: &App) -> Option<Rect> {
    let p = a.side_panel.as_ref()?;
    let (w, h) = a.viewport;
    let split = text(&p.data, "kind") == "session" && w >= 100;
    let width = if split {
        w / 2
    } else {
        w.saturating_sub(6).min(110)
    };
    Some(Rect::new(
        if split { w - width } else { (w - width) / 2 },
        if split { 1 } else { 2 },
        width,
        h.saturating_sub(if split { 7 } else { 4 }),
    ))
}
pub fn click(a: &mut App, x: u16, y: u16) -> Option<Vec<Command>> {
    let r = side_rect(a)?;
    if !r.contains((x, y).into()) {
        if let Some(p) = a.side_panel.as_mut() {
            p.focused = false;
        }
        return None;
    }
    if let Some(p) = a.side_panel.as_mut() {
        p.focused = true;
    }
    if y == r.bottom().saturating_sub(2) {
        let mut col = r.x + 1;
        for (label, key, modifiers) in [
            ("[发送]", KeyCode::Enter, KeyModifiers::NONE),
            ("[停止]", KeyCode::Char('c'), KeyModifiers::CONTROL),
            ("[加入主任务]", KeyCode::Char('p'), KeyModifiers::CONTROL),
            ("[刷新]", KeyCode::Char('r'), KeyModifiers::CONTROL),
            ("[收起]", KeyCode::Esc, KeyModifiers::NONE),
        ] {
            let end = col + crate::ui::width(label, a.ambiguous_width) as u16;
            if x >= col && x < end {
                return a.side_key(KeyEvent::new(key, modifiers));
            }
            col = end + 1;
        }
    }
    Some(vec![])
}

// Use terminal cells for both wrapping and cursor placement, including CJK.
fn input_rows(a: &App, p: &SidePanel, columns: usize) -> (Vec<String>, usize, usize) {
    let mut rows = vec![String::new()];
    let mut col = 0;
    let mut cursor = (0, 0);
    for (index, c) in p.input.char_indices() {
        let displayed = if c == '\t' { ' ' } else { c };
        let cells = crate::ui::width(&displayed.to_string(), a.ambiguous_width);
        if c != '\n' && col + cells > columns && col > 0 {
            rows.push(String::new());
            col = 0;
        }
        if index == p.cursor {
            cursor = (rows.len() - 1, col);
        }
        if c == '\n' {
            rows.push(String::new());
            col = 0;
        } else if !c.is_control() || c == '\t' {
            rows.last_mut().unwrap().push(displayed);
            col += cells;
        }
    }
    if p.cursor == p.input.len() {
        if col >= columns {
            rows.push(String::new());
            col = 0;
        }
        cursor = (rows.len() - 1, col);
    }
    (rows, cursor.0, cursor.1)
}

pub fn draw(f: &mut Frame, a: &App) {
    let Some(p) = a.side_panel.as_ref() else {
        return;
    };
    let area = f.area();
    let split = text(&p.data, "kind") == "session" && area.width >= 100;
    let w = if split {
        area.width / 2
    } else {
        area.width.saturating_sub(6).min(110)
    };
    let h = area.height.saturating_sub(if split { 7 } else { 4 });
    if w < 12 || h < 8 {
        return;
    }
    let r = Rect::new(
        if split {
            area.width - w
        } else {
            (area.width - w) / 2
        },
        if split { 1 } else { 2 },
        w,
        h,
    );
    f.render_widget(Clear, r);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(format!(" {} ", text(&p.data, "title")))
        .border_style(crate::ui::Theme::new(a).accent);
    f.render_widget(block, r);
    let prompt = if a.ascii { "> " } else { "› " };
    let prompt_width = crate::ui::width(prompt, a.ambiguous_width);
    let columns = (w as usize - 4).saturating_sub(prompt_width).max(1);
    let (rows, cursor_row, cursor_col) = input_rows(a, p, columns);
    let input_height = rows.len().min(3).min(h.saturating_sub(6) as usize).max(1);
    let input_start = cursor_row.saturating_sub(input_height - 1);
    let input_y = r.bottom() - 2 - input_height as u16;
    let inner = Rect::new(r.x + 2, r.y + 1, w - 4, h - 5 - input_height as u16);
    let view = App {
        snapshot: json!({"session":{"status":p.data["status"],"phase":p.data["notice"]},"messages":p.data["messages"],"steps":p.data["steps"],"changes":[],"agents":[]}),
        suppress_welcome: true,
        light: a.light,
        ascii: a.ascii,
        no_color: a.no_color,
        truecolor: a.truecolor,
        color256: a.color256,
        ambiguous_width: a.ambiguous_width,
        skin: a.skin.clone(),
        ..Default::default()
    };
    let lines = crate::ui::record(&view, inner.width as usize, inner.height);
    let start = lines.len().saturating_sub(inner.height as usize + p.scroll);
    f.render_widget(
        Paragraph::new(lines.into_iter().skip(start).collect::<Vec<_>>()),
        inner,
    );
    if split {
        let left = Rect::new(0, 1, area.width - w, area.height.saturating_sub(8));
        f.render_widget(Clear, left);
        let lines = crate::ui::record(a, left.width as usize, left.height);
        let start = lines
            .len()
            .saturating_sub(left.height as usize + a.scroll as usize);
        f.render_widget(
            Paragraph::new(lines.into_iter().skip(start).collect::<Vec<_>>()),
            left,
        );
    }
    f.render_widget(
        Paragraph::new(format!(
            "{} · {}",
            text(&p.data, "status"),
            text(&p.data, "notice")
        ))
        .style(crate::ui::Theme::new(a).muted),
        Rect::new(r.x + 2, input_y - 1, w - 4, 1),
    );
    let input = rows
        .iter()
        .enumerate()
        .skip(input_start)
        .take(input_height)
        .map(|(i, row)| {
            ratatui::text::Line::raw(format!(
                "{}{row}",
                if i == 0 {
                    prompt.to_owned()
                } else {
                    " ".repeat(prompt_width)
                }
            ))
        })
        .collect::<Vec<_>>();
    f.render_widget(
        Paragraph::new(input).style(crate::ui::input_surface(a)),
        Rect::new(r.x + 2, input_y, w - 4, input_height as u16),
    );
    if p.focused {
        f.set_cursor_position((
            r.x + 2 + prompt_width as u16 + cursor_col as u16,
            input_y + (cursor_row - input_start) as u16,
        ));
    }
    f.render_widget(
        Paragraph::new("[发送] [停止] [加入主任务] [刷新] [收起]  F6 切焦点  PgUp/PgDn 滚动")
            .style(Style::default()),
        Rect::new(r.x + 1, r.bottom() - 2, w - 2, 1),
    );
}
