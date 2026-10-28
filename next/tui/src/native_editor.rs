use crate::app::{App, Command, Drawer};
use crate::ui::{self, PopupAction, Theme};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    Frame,
    layout::{Position, Rect},
    style::Style,
    text::{Line, Span},
    widgets::Paragraph,
};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_EDITOR_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Default)]
pub struct NativeEditor {
    pub instance_id: u64,
    pub save_pending: bool,
    pub file_path: Option<String>,
    pub file_hash: String,
    pub saved_text: String,
    pub run_after_save: bool,
    pub discard_confirm: bool,
    pub language: String,
    pub session: Option<String>,
    pub text: String,
    pub cursor: usize,
    undo: Vec<(String, usize)>,
    redo: Vec<(String, usize)>,
}
struct Row {
    start: usize,
    end: usize,
    number: usize,
    text: String,
}
impl NativeEditor {
    pub fn code_mode(&self) -> bool {
        !self.language.is_empty() && self.language != "text"
    }
    fn insert_character(&mut self, c: char) {
        if !self.code_mode() {
            self.insert(&c.to_string());
            return;
        }
        let next = self.text[self.cursor..].chars().next();
        if matches!(c, ')' | ']' | '}' | '"' | '\'') && next == Some(c) {
            self.cursor += c.len_utf8();
            return;
        }
        let pair = match c {
            '(' => Some(')'),
            '[' => Some(']'),
            '{' => Some('}'),
            '"' => Some('"'),
            '\'' => Some('\''),
            _ => None,
        };
        let previous = self.text[..self.cursor].chars().next_back();
        if let Some(close) = pair.filter(|_| {
            next.is_none_or(|n| n.is_whitespace() || matches!(n, ')' | ']' | '}' | ',' | ';'))
                && !previous
                    .is_some_and(|p| p == '\\' || (matches!(c, '"' | '\'') && p.is_alphanumeric()))
        }) {
            self.insert(&format!("{c}{close}"));
            self.cursor -= close.len_utf8();
        } else {
            self.insert(&c.to_string());
        }
    }
    fn newline(&mut self) {
        if !self.code_mode() {
            self.insert("\n");
            return;
        }
        let line = self.text[..self.cursor].rsplit('\n').next().unwrap_or("");
        let indent: String = line
            .chars()
            .take_while(|c| *c == ' ' || *c == '\t')
            .collect();
        let opens = line.trim_end().ends_with(['{', '[', '(', ':']);
        let closes = self.text[self.cursor..]
            .chars()
            .next()
            .is_some_and(|c| matches!(c, '}' | ']' | ')'));
        if opens && closes {
            self.insert(&format!("\n{indent}    \n{indent}"));
            self.cursor -= indent.len() + 1;
        } else {
            self.insert(&format!("\n{indent}{}", if opens { "    " } else { "" }));
        }
    }
    fn complete_or_indent(&mut self) {
        if self.code_mode() {
            let prefix: String = self.text[..self.cursor]
                .chars()
                .rev()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect::<String>()
                .chars()
                .rev()
                .collect();
            let candidates: &[&str] = match self.language.as_str() {
                "python" => &[
                    "def ", "class ", "import ", "return ", "print(", "async ", "await ",
                    "lambda ", "except ", "finally:",
                ],
                "javascript" | "typescript" => &[
                    "function ",
                    "const ",
                    "return ",
                    "console.log(",
                    "async ",
                    "await ",
                    "interface ",
                    "export ",
                ],
                "dart" => &[
                    "class ", "final ", "return ", "Future<", "async ", "await ", "import ",
                ],
                _ => &[
                    "function ",
                    "struct ",
                    "return ",
                    "println!(",
                    "pub ",
                    "impl ",
                    "const ",
                    "include ",
                    "typedef ",
                    "while ",
                    "match ",
                ],
            };
            if prefix.len() >= 2
                && let Some(candidate) = candidates
                    .iter()
                    .find(|c| c.starts_with(&prefix) && c.len() > prefix.len())
            {
                self.insert(&candidate[prefix.len()..]);
                return;
            }
        }
        self.insert("    ");
    }
    fn checkpoint(&mut self) {
        if self.undo.last().is_none_or(|(text, _)| text != &self.text) {
            if self.undo.len() >= 80 {
                self.undo.remove(0);
            }
            self.undo.push((self.text.clone(), self.cursor));
        }
        self.redo.clear();
    }
    pub fn insert(&mut self, text: &str) {
        self.checkpoint();
        self.text.insert_str(self.cursor, text);
        self.cursor += text.len();
    }
    fn previous(&self) -> usize {
        self.text[..self.cursor]
            .char_indices()
            .next_back()
            .map_or(0, |(i, _)| i)
    }
    fn next(&self) -> usize {
        self.cursor
            + self.text[self.cursor..]
                .chars()
                .next()
                .map_or(0, char::len_utf8)
    }
    fn rows(&self, width: usize, amb: u8) -> Vec<Row> {
        let width = width.max(1);
        let mut rows = vec![];
        let (mut start, mut col, mut number) = (0, 0, 1);
        let mut value = String::new();
        for (i, c) in self.text.char_indices() {
            if c == '\n' {
                rows.push(Row {
                    start,
                    end: i,
                    number,
                    text: std::mem::take(&mut value),
                });
                start = i + 1;
                col = 0;
                number += 1;
                continue;
            }
            let shown = if c == '\t' {
                "    ".into()
            } else {
                ui::clean(&c.to_string())
            };
            let cw = ui::width(&shown, amb);
            if col > 0 && col + cw > width {
                rows.push(Row {
                    start,
                    end: i,
                    number,
                    text: std::mem::take(&mut value),
                });
                start = i;
                col = 0;
            }
            value.push_str(&shown);
            col += cw;
        }
        rows.push(Row {
            start,
            end: self.text.len(),
            number,
            text: value,
        });
        rows
    }
    fn byte_at(&self, row: &Row, col: usize, amb: u8) -> usize {
        let mut used = 0;
        for (i, c) in self.text[row.start..row.end].char_indices() {
            let cw = if c == '\t' {
                4
            } else {
                ui::width(&ui::clean(&c.to_string()), amb)
            };
            if used + cw > col {
                return row.start + i;
            }
            used += cw;
        }
        row.end
    }
    fn position(&self, rows: &[Row], amb: u8) -> (usize, usize) {
        let index = rows
            .iter()
            .rposition(|r| r.start <= self.cursor)
            .unwrap_or(0);
        let col = ui::width(
            &ui::clean(&self.text[rows[index].start..self.cursor].replace('\t', "    ")),
            amb,
        );
        (index, col)
    }
}
pub fn rect(width: u16, height: u16) -> Rect {
    Rect::new(1, 1, width.saturating_sub(2), height.saturating_sub(2))
}
fn body(r: Rect) -> Rect {
    Rect::new(
        r.x + 1,
        r.y + 3,
        r.width.saturating_sub(2),
        r.height.saturating_sub(5),
    )
}
fn buttons(a: &App) -> Vec<&'static str> {
    if a.native_editor
        .as_ref()
        .is_some_and(|e| e.file_path.is_some())
    {
        vec!["[保存文件]", "[保存并运行]", "[撤销]", "[重做]", "[另存为]"]
    } else {
        vec!["[保存草稿]", "[发送]", "[撤销]", "[重做]"]
    }
}
pub fn hit(a: &App, width: u16, height: u16, x: u16, y: u16) -> Option<PopupAction> {
    let r = rect(width, height);
    let mut left = r.x + 2;
    if y == r.y + 1 {
        for (i, label) in buttons(a).iter().enumerate() {
            let w = ui::width(label, a.ambiguous_width) as u16;
            if x >= left && x < left + w {
                return Some(PopupAction::EditorButton(i));
            }
            left += w + 2;
        }
    }
    if body(r).contains(Position::new(x, y)) {
        Some(PopupAction::EditorCursor(x, y))
    } else {
        None
    }
}
pub fn draw(f: &mut Frame, a: &App) {
    let r = rect(f.area().width, f.area().height);
    let t = Theme::new(a);
    ui::draw_frame(
        f,
        a,
        r,
        if a.native_editor
            .as_ref()
            .is_some_and(|e| e.file_path.is_some())
        {
            "文件编辑 · Ctrl+S 保存 · Ctrl+Enter 运行 · Ctrl+Shift+S 另存为"
        } else {
            "编辑器 · Enter 换行 · Ctrl+S 保存草稿 · Ctrl+Enter 发送"
        },
        true,
    );
    let mut spans = vec![];
    for label in buttons(a) {
        spans.push(Span::styled(format!("{label}  "), t.accent));
    }
    f.render_widget(
        Paragraph::new(Line::from(spans)),
        Rect::new(r.x + 2, r.y + 1, r.width.saturating_sub(4), 1),
    );
    f.render_widget(
        Paragraph::new(format!(
            "语言 {} · Ctrl+L 切换 · Tab 补全/缩进 · Esc 返回 · Ctrl+Z 撤销",
            a.native_editor
                .as_ref()
                .map_or("text", |e| if e.language.is_empty() {
                    "text"
                } else {
                    &e.language
                })
        ))
        .style(t.muted),
        Rect::new(
            r.x + 2,
            r.bottom().saturating_sub(2),
            r.width.saturating_sub(4),
            1,
        ),
    );
    let Some(editor) = a.native_editor.as_ref() else {
        return;
    };
    if let Some(path) = &editor.file_path {
        f.render_widget(
            Paragraph::new(format!(
                "{}{}",
                path,
                if editor.text != editor.saved_text {
                    " · 未保存"
                } else {
                    ""
                }
            ))
            .style(t.muted),
            Rect::new(r.x + 2, r.y + 2, r.width.saturating_sub(4), 1),
        );
    }
    let b = body(r);
    if b.width < 8 || b.height == 0 {
        return;
    }
    let rows = editor.rows(b.width.saturating_sub(7) as usize, a.ambiguous_width);
    let (index, col) = editor.position(&rows, a.ambiguous_width);
    let start = index
        .saturating_sub(b.height as usize / 2)
        .min(rows.len().saturating_sub(b.height as usize));
    let lines = rows
        .iter()
        .skip(start)
        .take(b.height as usize)
        .map(|row| {
            let mut spans = vec![Span::styled(format!("{:>5} │", row.number), t.muted)];
            if editor.code_mode() {
                spans.extend(
                    ui::code_tokens(a, &row.text, &editor.language)
                        .into_iter()
                        .map(|(c, s)| Span::styled(c.to_string(), s)),
                );
            } else {
                spans.push(Span::styled(row.text.clone(), Style::default()));
            }
            Line::from(spans)
        })
        .collect::<Vec<_>>();
    f.render_widget(Paragraph::new(lines).style(ui::input_surface(a)), b);
    f.set_cursor_position((
        b.x + 7 + (col as u16).min(b.width.saturating_sub(8)),
        b.y + (index - start) as u16,
    ));
}
impl App {
    pub fn open_native_editor(&mut self) {
        let session = self.session_id().map(str::to_owned);
        self.open(Drawer::Editor);
        self.native_editor = Some(NativeEditor {
            instance_id: NEXT_EDITOR_ID.fetch_add(1, Ordering::Relaxed),
            session,
            text: self.input.clone(),
            language: "text".into(),
            cursor: self.cursor.min(self.input.len()),
            ..Default::default()
        });
    }
    pub fn finish_native_editor(&mut self, send: bool) -> Vec<Command> {
        if self
            .native_editor
            .as_ref()
            .is_some_and(|e| e.file_path.is_some())
        {
            let e = self.native_editor.as_mut().unwrap();
            if e.save_pending {
                self.notice = "文件正在保存，请稍候".into();
                return vec![];
            }
            e.save_pending = true;
            e.run_after_save = send;
            return vec![Command {
                method: "terminal.action".into(),
                params: serde_json::json!({"action":"wb.file.save","session_id":e.session,"path":e.file_path,"sha256":e.file_hash,"content":e.text,"_workbench":true,"_editor_id":e.instance_id}),
            }];
        }
        let Some(editor) = self.native_editor.take() else {
            return vec![];
        };
        self.drawer = None;
        if editor.session.as_deref() != self.session_id() {
            if let Some(id) = editor.session {
                let mut draft = self.session_drafts.remove(&id).unwrap_or_default();
                draft.text = editor.text;
                draft.cursor = editor.cursor;
                self.session_drafts.insert(id, draft);
            }
            self.notice = "内容已保存到原会话草稿".into();
            return vec![];
        }
        self.input = editor.text;
        self.cursor = editor.cursor;
        self.paste_collapsed = self.input.lines().count() > 5;
        self.completion_closed = true;
        self.notice = "已保存草稿".into();
        if send { self.submit() } else { vec![] }
    }
    pub fn native_editor_button(&mut self, index: usize) -> Vec<Command> {
        match index {
            4 => self.native_editor_key(KeyEvent::new(
                KeyCode::Char('s'),
                KeyModifiers::CONTROL | KeyModifiers::SHIFT,
            )),
            0 => self.finish_native_editor(false),
            1 => self.finish_native_editor(true),
            2 => self.native_editor_key(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::CONTROL)),
            3 => self.native_editor_key(KeyEvent::new(KeyCode::Char('y'), KeyModifiers::CONTROL)),
            _ => vec![],
        }
    }
    pub fn native_editor_click(&mut self, x: u16, y: u16) {
        let b = body(rect(self.viewport.0, self.viewport.1));
        let Some(editor) = self.native_editor.as_mut() else {
            return;
        };
        let rows = editor.rows(b.width.saturating_sub(7) as usize, self.ambiguous_width);
        let (index, _) = editor.position(&rows, self.ambiguous_width);
        let start = index
            .saturating_sub(b.height as usize / 2)
            .min(rows.len().saturating_sub(b.height as usize));
        if let Some(row) = rows.get(start + y.saturating_sub(b.y) as usize) {
            editor.cursor = editor.byte_at(
                row,
                x.saturating_sub(b.x + 7) as usize,
                self.ambiguous_width,
            );
        }
    }
    pub fn native_editor_key(&mut self, key: KeyEvent) -> Vec<Command> {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if self
            .native_editor
            .as_ref()
            .is_some_and(|e| e.file_path.is_some())
        {
            if key.code == KeyCode::Esc {
                let e = self.native_editor.as_mut().unwrap();
                if e.text != e.saved_text && !e.discard_confirm {
                    e.discard_confirm = true;
                    self.notice = "有未保存修改；Ctrl+S 保存，Esc 再次放弃".into();
                    return vec![];
                }
                self.native_editor = None;
                self.drawer = None;
                return vec![];
            }
            if ctrl && key.code == KeyCode::Char('s') && key.modifiers.contains(KeyModifiers::SHIFT)
            {
                let e = self.native_editor.as_ref().unwrap();
                let path = e.file_path.clone().unwrap_or_default();
                self.extra_form(crate::app::FormKind::Workbench,"另存为",vec![Self::field("path","目标文件路径",&path,false,true),Self::field("save_as","保存为新文件","",false,false)],serde_json::json!({"fields":[{"key":"save_as","action":"wb.file.save"}],"data":{"save_as":true}}));
                return vec![];
            }
        }
        if key.code == KeyCode::Esc || (ctrl && key.code == KeyCode::Char('s')) {
            return self.finish_native_editor(false);
        }
        if ctrl && key.code == KeyCode::Enter {
            return self.finish_native_editor(true);
        }
        if (ctrl && key.code == KeyCode::Char('v'))
            || (key.modifiers.contains(KeyModifiers::ALT) && key.code == KeyCode::Char('v'))
        {
            self.clipboard_requested = true;
            return vec![];
        }
        let Some(editor) = self.native_editor.as_mut() else {
            return vec![];
        };
        match key.code {
            KeyCode::Char('l') if ctrl => {
                let choices = [
                    "text",
                    "rust",
                    "python",
                    "javascript",
                    "typescript",
                    "dart",
                    "c",
                    "cpp",
                    "json",
                    "html",
                    "markdown",
                ];
                let next = choices
                    .iter()
                    .position(|l| *l == editor.language)
                    .map_or(1, |n| (n + 1) % choices.len());
                editor.language = choices[next].into();
            }
            KeyCode::Char('z') if ctrl => {
                if let Some((text, cursor)) = editor.undo.pop() {
                    editor
                        .redo
                        .push((std::mem::replace(&mut editor.text, text), editor.cursor));
                    editor.cursor = cursor;
                }
            }
            KeyCode::Char('y') if ctrl => {
                if let Some((text, cursor)) = editor.redo.pop() {
                    editor
                        .undo
                        .push((std::mem::replace(&mut editor.text, text), editor.cursor));
                    editor.cursor = cursor;
                }
            }
            KeyCode::Left => editor.cursor = editor.previous(),
            KeyCode::Right => editor.cursor = editor.next(),
            KeyCode::Home => {
                editor.cursor = if ctrl {
                    0
                } else {
                    editor.text[..editor.cursor]
                        .rfind('\n')
                        .map_or(0, |i| i + 1)
                }
            }
            KeyCode::End => {
                editor.cursor = if ctrl {
                    editor.text.len()
                } else {
                    editor.cursor
                        + editor.text[editor.cursor..]
                            .find('\n')
                            .unwrap_or(editor.text.len() - editor.cursor)
                }
            }
            KeyCode::Up | KeyCode::Down | KeyCode::PageUp | KeyCode::PageDown => {
                let b = body(rect(self.viewport.0, self.viewport.1));
                let rows = editor.rows(b.width.saturating_sub(7) as usize, self.ambiguous_width);
                let (index, col) = editor.position(&rows, self.ambiguous_width);
                let delta = if matches!(key.code, KeyCode::PageUp | KeyCode::PageDown) {
                    b.height.max(1) as usize
                } else {
                    1
                };
                let target = if matches!(key.code, KeyCode::Up | KeyCode::PageUp) {
                    index.saturating_sub(delta)
                } else {
                    (index + delta).min(rows.len() - 1)
                };
                editor.cursor = editor.byte_at(&rows[target], col, self.ambiguous_width);
            }
            KeyCode::Backspace if editor.cursor > 0 => {
                editor.checkpoint();
                let start = editor.previous();
                let before = editor.text[start..editor.cursor].chars().next();
                let after = editor.text[editor.cursor..].chars().next();
                let paired = editor.code_mode()
                    && matches!(
                        (before, after),
                        (Some('('), Some(')'))
                            | (Some('['), Some(']'))
                            | (Some('{'), Some('}'))
                            | (Some('"'), Some('"'))
                            | (Some('\''), Some('\''))
                    );
                let end = if paired { editor.next() } else { editor.cursor };
                editor.text.drain(start..end);
                editor.cursor = start;
            }
            KeyCode::Delete => {
                editor.checkpoint();
                editor.text.drain(editor.cursor..editor.next());
            }
            KeyCode::Enter => editor.newline(),
            KeyCode::Tab => editor.complete_or_indent(),
            KeyCode::Char(c) if !ctrl => editor.insert_character(c),
            _ => {}
        };
        vec![]
    }
}
