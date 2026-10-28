use crate::app::{App, Drawer, FormKind, StartupPhase, TerminalForm, View, items, text};
use ratatui::{
    Frame,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Clear, Padding, Paragraph, Widget},
};
use serde_json::Value;
use std::time::Instant;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// Ratatui uses narrow East Asian Ambiguous widths. Reflow each paragraph's
/// own content rectangle into physical CJK columns without moving neighboring
/// borders, separators, or other widgets and without changing original symbols.
struct CellParagraph<'a> {
    inner: Paragraph<'a>,
    ambiguous_width: u8,
}
fn paragraph<'a>(a: &App, text: impl Into<ratatui::text::Text<'a>>) -> CellParagraph<'a> {
    CellParagraph {
        inner: Paragraph::new(text),
        ambiguous_width: a.ambiguous_width,
    }
}
impl CellParagraph<'_> {
    fn style(mut self, style: Style) -> Self {
        self.inner = self.inner.style(style);
        self
    }
    fn scroll(mut self, offset: (u16, u16)) -> Self {
        self.inner = self.inner.scroll(offset);
        self
    }
}
impl Widget for CellParagraph<'_> {
    fn render(self, area: Rect, buffer: &mut ratatui::buffer::Buffer) {
        if self.ambiguous_width != 2 {
            self.inner.render(area, buffer);
            return;
        }
        use ratatui::buffer::{Buffer, CellDiffOption};
        let area = area.intersection(buffer.area);
        if area.is_empty() {
            return;
        }
        let mut narrow = Buffer::empty(area);
        self.inner.render(area, &mut narrow);
        for y in area.y..area.bottom() {
            for x in area.x..area.right() {
                buffer[(x, y)].reset();
            }
            let mut source = area.x;
            let mut target = area.x;
            while source < area.right() && target < area.right() {
                let cell = &narrow[(source, y)];
                let narrow_width = cell.symbol().width().max(1) as u16;
                let physical_width = cell.symbol().width_cjk().max(1) as u16;
                if target.saturating_add(physical_width) > area.right() {
                    break;
                }
                buffer[(target, y)] = cell.clone();
                buffer[(target, y)].set_diff_option(CellDiffOption::ForcedWidth(
                    std::num::NonZeroU16::new(physical_width).unwrap(),
                ));
                for continuation in target + 1..target + physical_width {
                    buffer[(continuation, y)].set_diff_option(CellDiffOption::Skip);
                }
                source = source.saturating_add(narrow_width);
                target = target.saturating_add(physical_width);
            }
        }
    }
}

pub fn clean(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            match chars.next() {
                Some('[') => {
                    for n in chars.by_ref() {
                        if ('@'..='~').contains(&n) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    while let Some(n) = chars.next() {
                        if n == '\x07' {
                            break;
                        }
                        if n == '\x1b' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {}
            }
        } else if !c.is_control() || c == '\n' || c == '\t' {
            out.push(if c == '\t' { ' ' } else { c });
        }
    }
    out
}
pub fn width(s: &str, amb: u8) -> usize {
    if amb == 2 { s.width_cjk() } else { s.width() }
}
pub fn truncate(s: &str, max: usize, amb: u8) -> String {
    let s = clean(s);
    let mut n = 0;
    s.chars()
        .take_while(|c| {
            let w = if amb == 2 {
                c.width_cjk().unwrap_or(0)
            } else {
                c.width().unwrap_or(0)
            };
            if n + w > max {
                false
            } else {
                n += w;
                true
            }
        })
        .collect()
}
pub fn middle(s: &str, max: usize, app: &App) -> String {
    let s = clean(s);
    if width(&s, app.ambiguous_width) <= max {
        return s;
    }
    let ell = if app.ascii || app.ambiguous_width == 2 {
        "..."
    } else {
        "…"
    };
    let ew = width(ell, app.ambiguous_width);
    if max <= ew {
        return truncate(ell, max, app.ambiguous_width);
    }
    let left = (max - ew) / 2;
    let a = truncate(&s, left, app.ambiguous_width);
    let reversed: String = s.chars().rev().collect();
    let b: String = truncate(&reversed, max - ew - left, app.ambiguous_width)
        .chars()
        .rev()
        .collect();
    format!("{a}{ell}{b}")
}
fn glyph<'a>(app: &App, normal: &'a str, ascii: &'a str) -> &'a str {
    if app.ascii || app.ambiguous_width == 2 {
        ascii
    } else {
        normal
    }
}
#[derive(Clone, Copy)]
pub(crate) struct Theme {
    pub(crate) accent: Style,
    pub(crate) muted: Style,
    pub(crate) good: Style,
    pub(crate) warn: Style,
    pub(crate) bad: Style,
    /// Selected rows: accent text on a faint accent tint (reverse video without truecolor).
    pub(crate) selected: Style,
}
fn tinted(a: &App, accent: Style) -> Style {
    let Some(Color::Rgb(r, g, b)) = accent.fg.filter(|_| !a.no_color && a.truecolor) else {
        return accent.add_modifier(Modifier::REVERSED);
    };
    let skin = crate::theme::effective_skin_colors(&a.skin, a.background.as_deref(), a.light);
    let base = match a
        .background
        .as_deref()
        .and_then(crate::theme::parse_color)
        .or(skin.background)
    {
        Some(Color::Rgb(r, g, b)) => (r, g, b),
        _ if a.light => (250, 250, 250),
        _ => (24, 28, 34),
    };
    let k = if a.light { 0.14 } else { 0.24 };
    let mix = |c: u8, b: u8| (f64::from(b) + (f64::from(c) - f64::from(b)) * k).round() as u8;
    Style::default()
        .fg(Color::Rgb(r, g, b))
        .bg(Color::Rgb(mix(r, base.0), mix(g, base.1), mix(b, base.2)))
        .add_modifier(Modifier::BOLD)
}
fn user_message_style(a: &App) -> Style {
    if a.no_color {
        return Style::default();
    }
    if !a.truecolor {
        return Style::default().bg(if a.light {
            Color::Gray
        } else {
            Color::DarkGray
        });
    }
    let skin = crate::theme::effective_skin_colors(&a.skin, a.background.as_deref(), a.light);
    if let Some(color) = skin.user_background.filter(|_| a.background.is_none()) {
        return Style::default().bg(color);
    }
    let base = match skin.background {
        Some(Color::Rgb(r, g, b)) => (r, g, b),
        _ if a.light => (250, 250, 250),
        _ => (24, 28, 34),
    };
    let mix = |c: u8| {
        if a.light {
            (u16::from(c) * 93 / 100) as u8
        } else {
            (u16::from(c) + (255 - u16::from(c)) * 8 / 100) as u8
        }
    };
    Style::default().bg(Color::Rgb(mix(base.0), mix(base.1), mix(base.2)))
}
pub(crate) fn input_surface(a: &App) -> Style {
    user_message_style(a)
}
impl Theme {
    pub(crate) fn new(a: &App) -> Self {
        let color = |ansi: Color, dark: (u8, u8, u8), light: (u8, u8, u8)| {
            if a.no_color {
                Style::default()
            } else if a.truecolor {
                let c = if a.light { light } else { dark };
                Style::default().fg(Color::Rgb(c.0, c.1, c.2))
            } else {
                Style::default().fg(ansi)
            }
        };
        let mut theme = Self {
            accent: color(Color::Cyan, (124, 192, 222), (31, 98, 131)),
            muted: if a.no_color || !a.truecolor {
                Style::default().add_modifier(Modifier::DIM)
            } else {
                color(Color::Reset, (138, 154, 163), (102, 118, 126))
            },
            good: color(Color::Green, (143, 204, 168), (42, 115, 80)),
            warn: color(Color::Yellow, (227, 188, 114), (135, 89, 26)),
            bad: color(Color::Red, (234, 161, 168), (168, 62, 72)),
            selected: Style::default(),
        };
        if !a.no_color {
            let skin =
                crate::theme::effective_skin_colors(&a.skin, a.background.as_deref(), a.light);
            let custom = a.accent.as_deref().and_then(crate::theme::parse_color);
            if let Some(color) = custom.or(skin.accent) {
                theme.accent = Style::default().fg(color);
            }
            if let Some(color) = skin.muted {
                theme.muted = Style::default().fg(color);
            }
            if let Some(color) = skin.good {
                theme.good = Style::default().fg(color);
            }
            if let Some(color) = skin.warn {
                theme.warn = Style::default().fg(color);
            }
            if let Some(color) = skin.bad {
                theme.bad = Style::default().fg(color);
            }
        }
        theme.selected = tinted(a, theme.accent);
        theme
    }
}
fn line(s: impl Into<String>, style: Style) -> Line<'static> {
    Line::from(Span::styled(clean(&s.into()), style))
}
fn pair(left: String, right: String, w: usize, a: &App, ls: Style, rs: Style) -> Line<'static> {
    let right = clean(&right);
    let rw = width(&right, a.ambiguous_width);
    let l = truncate(&left, w.saturating_sub(rw + 1), a.ambiguous_width);
    let gap = w.saturating_sub(width(&l, a.ambiguous_width) + rw);
    Line::from(vec![
        Span::styled(l, ls),
        Span::raw(" ".repeat(gap)),
        Span::styled(right, rs),
    ])
}
fn wrap(s: &str, w: usize, a: &App, prefix: &str, style: Style) -> Vec<Line<'static>> {
    let mut lines = vec![];
    for raw in clean(s).split('\n') {
        let mut buf = String::new();
        let mut col = 0;
        let available = w.saturating_sub(width(prefix, a.ambiguous_width)).max(1);
        for c in raw.chars() {
            let cw = if a.ambiguous_width == 2 {
                c.width_cjk().unwrap_or(0)
            } else {
                c.width().unwrap_or(0)
            };
            if col + cw > available && !buf.is_empty() {
                let p = if !lines.is_empty() && matches!(prefix.trim(), "›" | "◈" | ">" | "*") {
                    " ".repeat(width(prefix, a.ambiguous_width))
                } else {
                    prefix.to_owned()
                };
                lines.push(line(format!("{p}{buf}"), style));
                buf.clear();
                col = 0;
            }
            buf.push(c);
            col += cw;
        }
        let p = if !lines.is_empty() && matches!(prefix.trim(), "›" | "◈" | ">" | "*") {
            " ".repeat(width(prefix, a.ambiguous_width))
        } else {
            prefix.to_owned()
        };
        lines.push(line(format!("{p}{buf}"), style));
    }
    lines
}
/// Cursor position in the wrapped input body, excluding the three-column prompt.
pub fn input_visual_position(a: &App, terminal_width: usize) -> (usize, usize) {
    if a.paste_collapsed {
        return (0, 0);
    }
    let available = terminal_width.saturating_sub(5).max(1);
    let mut row = 0;
    let mut col = 0;
    for c in a.input[..a.cursor.min(a.input.len())].chars() {
        if c == '\n' {
            row += 1;
            col = 0;
            continue;
        }
        let cw = width(&clean(&c.to_string()), a.ambiguous_width);
        if col + cw > available && col > 0 {
            row += 1;
            col = 0;
        }
        col += cw;
    }
    if col >= available {
        row += 1;
        col = 0;
    }
    (row, col)
}

/// The final row is a footer only when it is not replaced by completion rows.
pub fn footer_at(a: &App, width: u16, height: u16) -> Option<Rect> {
    if height == 0 || width == 0 {
        return None;
    }
    Some(Rect::new(
        0,
        height
            - if a.view == View::Chat && height >= 8 {
                2
            } else {
                1
            },
        width,
        1,
    ))
}

pub fn approval_button_at(
    a: &App,
    width: u16,
    height: u16,
    x: u16,
    y: u16,
) -> Option<(String, usize)> {
    if a.status() != "approval"
        || a.view != View::Chat
        || a.approval_collapsed
        || a.rejection
        || a.form.is_some()
        || a.drawer.is_some()
        || height < 6
    {
        return None;
    }
    let width = width.saturating_sub(if a.sidebar && width >= 140 { 44 } else { 0 });
    let layout = chat_layout(a, width as usize, height);
    let inner = Rect::new(
        2,
        height.saturating_sub(layout.bottom_h + layout.input_h) + 1,
        width.saturating_sub(4),
        layout.input_h.saturating_sub(2),
    );
    if !inner.contains((x, y).into()) {
        return None;
    }
    let (rows, hits) = crate::approval_controls::rows(a, inner.width as usize);
    let total = approval_lines(a, inner.width as usize).len();
    let start = total
        .saturating_sub(rows.len())
        .min((inner.height as usize).saturating_sub(rows.len()));
    hits.into_iter()
        .find(|(r, _)| {
            Rect::new(inner.x + r.x, inner.y + start as u16 + r.y, r.width, 1)
                .contains((x, y).into())
        })
        .map(|(_, index)| (text(&a.snapshot["approvals"][0], "id").to_owned(), index))
}

/// Shared layout rectangle for drawing and mouse hit testing, including the sidebar.
pub fn pet_rect(a: &App, terminal_width: u16, height: u16) -> Option<Rect> {
    let w = terminal_width.saturating_sub(if a.sidebar && terminal_width >= 140 {
        44
    } else {
        0
    });
    if pet_visible(a, w, height) {
        let large = crate::presentation::hero(a, w as usize, height);
        let available = chat_layout(a, terminal_width as usize, height).record_h;
        let max_width = if large { 40 } else { 20 };
        let max_height = if large {
            available.saturating_sub(3).min(24)
        } else {
            available.min(6)
        };
        let (pixels_w, pixels_h) = a.pet.art.dimensions();
        let scale =
            (max_width as f64 / pixels_w as f64).min(max_height as f64 * 2.0 / pixels_h as f64);
        let drawn_w = ((pixels_w as f64 * scale).floor() as u16).max(1);
        let drawn_h = ((pixels_h as f64 * scale / 2.0).ceil() as u16).max(1);
        Some(Rect::new(
            if large {
                2 + (40 - drawn_w) / 2
            } else {
                w - 22 + (20 - drawn_w) / 2
            },
            u16::from(large),
            drawn_w,
            drawn_h,
        ))
    } else {
        None
    }
}

fn duration(v: &Value) -> String {
    let Some(ms) = v.as_u64() else {
        return String::new();
    };
    let s = ms / 1000;
    if s >= 60 {
        format!("{}m{}s", s / 60, s % 60)
    } else {
        format!("{s}s")
    }
}
fn state_icon<'a>(a: &App, status: &str) -> &'a str {
    match status {
        "done" | "completed" | "accepted" => {
            if a.ascii || a.ambiguous_width == 2 {
                "v"
            } else {
                "✓"
            }
        }
        "failed" => {
            if a.ascii || a.ambiguous_width == 2 {
                "x"
            } else {
                "✗"
            }
        }
        "stopped" | "cancelled" | "interrupted" => {
            if a.ascii || a.ambiguous_width == 2 {
                "#"
            } else {
                "■"
            }
        }
        "running" => {
            if a.reduce_motion {
                if a.ascii || a.ambiguous_width == 2 {
                    "."
                } else {
                    "◌"
                }
            } else if a.ascii || a.ambiguous_width == 2 {
                ["-", "\\", "|", "/"][(a.tick % 4) as usize]
            } else {
                ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"][(a.tick % 10) as usize]
            }
        }
        _ => {
            if a.ascii || a.ambiguous_width == 2 {
                "."
            } else {
                "◌"
            }
        }
    }
}
fn state_style(t: Theme, status: &str) -> Style {
    match status {
        "done" | "completed" | "accepted" => t.good,
        "failed" => t.bad,
        "running" => t.accent,
        _ => t.muted,
    }
}
pub fn welcome(a: &App) -> bool {
    items(&a.snapshot, "messages").is_empty()
}
pub fn pet_visible(a: &App, w: u16, h: u16) -> bool {
    a.view == View::Chat
        && welcome(a)
        && a.scroll == 0
        && w >= 80
        && h >= 20
        && (a.truecolor || a.color256)
        && !a.ascii
        && !a.no_color
        && a.ambiguous_width == 1
        && a.pet.enabled
        && welcome_graphics_height(a, w, h) >= 6
}
pub(crate) fn record(a: &App, w: usize, h: u16) -> Vec<Line<'static>> {
    record_layout(a, w, h).0
}

/// A receipt records queue/context preparation, never a model's agreement.
pub fn steering_label(value: &Value) -> String {
    match text(value, "status") {
        "queued" => "已排队 · 等待工具边界".into(),
        "context_prepared" => value["round"]
            .as_u64()
            .map(|round| format!("已纳入第 {round} 轮上下文"))
            .unwrap_or_else(|| "已纳入请求上下文".into()),
        "withdrawn" => "已撤回 · 未纳入请求".into(),
        "cancelled" => "已取消 · 未纳入请求".into(),
        _ => "补充状态待确认".into(),
    }
}

pub fn message_display_text(message: &Value) -> &str {
    let body = text(message, "text");
    if message["steering"].is_object() {
        if let Some(original) = message["steering"]["text"]
            .as_str()
            .filter(|s| !s.is_empty())
        {
            return original;
        }
        body.split_once('\n')
            .filter(|(header, _)| header.starts_with("【运行中补充 #") && header.ends_with('】'))
            .map_or(body, |(_, content)| content)
    } else {
        body
    }
}
type RecordLayout = (
    Vec<Line<'static>>,
    Vec<(String, usize)>,
    Vec<(String, std::ops::Range<usize>)>,
    Vec<(String, std::ops::Range<usize>)>,
    Vec<(String, std::ops::Range<usize>)>,
);
fn record_layout(a: &App, w: usize, h: u16) -> RecordLayout {
    let dot = glyph(a, "·", ":");
    let t = Theme::new(a);
    let mut out = vec![];
    let mut anchors = vec![];
    let mut user_rows = vec![];
    let mut tool_rows = vec![];
    let mut change_rows = vec![];
    let s = &a.snapshot["session"];
    if welcome(a) {
        return (
            welcome_record(a, w, h, true),
            anchors,
            user_rows,
            tool_rows,
            change_rows,
        );
    }
    if a.welcome_seen && !a.suppress_welcome {
        out.extend(welcome_record(a, w, h, false));
        out.push(Line::default());
    }
    // Index once instead of scanning M messages against S tools twice.
    let mut linked_steps: std::collections::HashMap<&str, Vec<&Value>> =
        std::collections::HashMap::new();
    for step in items(&a.snapshot, "steps") {
        linked_steps
            .entry(text(step, "message_id"))
            .or_default()
            .push(step);
    }
    for message in items(&a.snapshot, "messages") {
        anchors.push((text(message, "id").to_owned(), out.len()));
        let user = text(message, "role") == "user";
        if !text(message, "thinking").is_empty() {
            let count = text(message, "thinking").chars().count();
            let live = a.status() == "running"
                && items(&a.snapshot, "messages")
                    .last()
                    .is_some_and(|m| m["id"] == message["id"])
                && text(message, "text").is_empty();
            let elapsed = message
                .get("thinking_elapsed_ms")
                .filter(|v| v.is_number())
                .map(|v| format!("  {}", duration(v)))
                .unwrap_or_default();
            let detail = if live {
                let age = a
                    .thinking_updated_at
                    .as_ref()
                    .filter(|(id, _)| id == text(message, "id"))
                    .map(|(_, at)| at.elapsed().as_secs());
                format!(
                    " · 本轮 {} · {} · 正文尚未输出",
                    duration(&s["elapsed_ms"]),
                    age.map(|seconds| format!("本端更新于 {seconds}s 前"))
                        .unwrap_or_else(|| "等待更新".into())
                )
            } else {
                String::new()
            };
            out.extend(wrap(
                &format!(
                    "{} 思考{elapsed} · 已接收 {count} 字{detail}{}",
                    glyph(a, "∴", "~"),
                    if a.expanded { "" } else { " · Ctrl+O 展开" }
                ),
                w,
                a,
                "  ",
                t.muted,
            ));
            if a.expanded {
                out.extend(wrap(
                    text(message, "thinking"),
                    w.min(104),
                    a,
                    &format!("    {} ", glyph(a, "│", "|")),
                    t.muted,
                ));
            }
        }
        let linked = linked_steps.remove(text(message, "id")).unwrap_or_default();
        let finished = linked
            .iter()
            .all(|step| matches!(text(step, "status"), "done" | "failed" | "stopped"));
        let timed =
            !user && !linked.is_empty() && linked.iter().all(|s| s["content_offset"].is_number());
        let tool_start = out.len();
        if !timed {
            out.extend(step_lines(a, w, &linked, finished));
        }
        if out.len() > tool_start {
            tool_rows.push((text(message, "id").to_owned(), tool_start..out.len()));
        }
        if !linked.is_empty() {
            out.push(Line::default());
        }
        if !user {
            let related: Vec<_> = items(&a.snapshot, "changes")
                .iter()
                .filter(|c| c["message_id"] == message["id"])
                .collect();
            if related.len() > 3 {
                out.push(line(
                    format!("    另有 {} 条改动 · Ctrl+G 查看全部", related.len() - 3),
                    t.muted,
                ));
            }
            for change in related.iter().skip(related.len().saturating_sub(3)) {
                let start = out.len();
                out.extend(diff_card(a, change, w));
                change_rows.push((text(change, "id").to_owned(), start..out.len()));
                out.push(Line::default());
            }
        }
        let message_start = out.len();
        let steering = message.get("steering").filter(|value| value.is_object());
        let body = message_display_text(message);
        if timed {
            let boundaries: Vec<usize> = body
                .char_indices()
                .map(|(i, _)| i)
                .chain(std::iter::once(body.len()))
                .collect();
            let mut ordered = linked.clone();
            ordered.sort_by_key(|s| s["content_offset"].as_u64().unwrap_or(0));
            let mut cursor = 0;
            let mut index = 0;
            while index < ordered.len() {
                let offset = (ordered[index]["content_offset"].as_u64().unwrap_or(0) as usize)
                    .min(boundaries.len() - 1);
                let end = boundaries[offset].max(cursor);
                if end > cursor {
                    out.extend(message_lines(a, &body[cursor..end], false, w));
                }
                let mut next = index + 1;
                while next < ordered.len()
                    && ordered[next]["content_offset"] == ordered[index]["content_offset"]
                {
                    next += 1;
                }
                let start = out.len();
                out.extend(step_lines(
                    a,
                    w,
                    &ordered[index..next],
                    ordered[index..next]
                        .iter()
                        .all(|s| matches!(text(s, "status"), "done" | "failed" | "stopped")),
                ));
                tool_rows.push((text(message, "id").to_owned(), start..out.len()));
                cursor = end;
                index = next;
            }
            if cursor < body.len() {
                out.extend(message_lines(a, &body[cursor..], false, w));
            }
        } else {
            out.extend(message_lines(a, body, user, w));
        }
        if let Some(receipt) = steering {
            out.extend(wrap(
                &format!("补充要求 · {}", steering_label(receipt)),
                w,
                a,
                "  ",
                t.muted,
            ));
        }
        for att in items(message, "attachments") {
            if att["reference"] == true && text(message, "text").contains(text(att, "_tag")) {
                continue;
            }
            out.push(line(
                format!(
                    "  {} {} {dot} {} B",
                    glyph(a, "⎘", "@"),
                    text(att, "name"),
                    att["size"]
                ),
                t.muted,
            ));
        }
        if user {
            user_rows.push((text(message, "id").to_owned(), message_start..out.len()));
            let style = user_message_style(a);
            for row in &mut out[message_start..] {
                row.style = row.style.patch(style);
                let used = row
                    .spans
                    .iter()
                    .map(|s| width(&s.content, a.ambiguous_width))
                    .sum::<usize>();
                for span in &mut row.spans {
                    span.style = span.style.patch(style);
                }
                row.spans
                    .push(Span::styled(" ".repeat(w.saturating_sub(used)), style));
            }
        }
        out.push(Line::default());
    }
    let orphans: Vec<&Value> = items(&a.snapshot, "steps")
        .iter()
        .filter(|s| linked_steps.contains_key(text(s, "message_id")))
        .collect();
    let tool_start = out.len();
    out.extend(step_lines(
        a,
        w,
        &orphans,
        orphans
            .iter()
            .all(|s| matches!(text(s, "status"), "done" | "failed" | "stopped")),
    ));
    if out.len() > tool_start {
        tool_rows.push((String::new(), tool_start..out.len()));
    }
    for change in items(&a.snapshot, "changes")
        .iter()
        .filter(|c| {
            !items(&a.snapshot, "messages")
                .iter()
                .any(|m| m["id"] == c["message_id"])
        })
        .rev()
        .take(3)
    {
        let start = out.len();
        out.extend(diff_card(a, change, w));
        change_rows.push((text(change, "id").to_owned(), start..out.len()));
        out.push(Line::default());
    }
    for agent in items(&a.snapshot, "agents")
        .iter()
        .filter(|x| text(x, "status") == "running" && !x["parent_id"].is_null())
    {
        out.push(pair(
            format!(
                "  {} 助手  {} {dot} {}",
                state_icon(a, "running"),
                text(agent, "name"),
                text(agent, "activity")
            ),
            if w >= 60 { "ctrl+t" } else { "" }.into(),
            w,
            a,
            t.muted,
            t.muted,
        ));
    }
    let changes = items(&a.snapshot, "changes");
    if matches!(
        a.status(),
        "waiting_acceptance" | "completed" | "accepted" | "stopped"
    ) && !changes.is_empty()
    {
        out.push(Line::default());
        out.push(pair(
            format!(
                "  {}  {} 个文件  +{} {}{}",
                if a.status() == "stopped" {
                    "未完成"
                } else if a.status() == "accepted" {
                    "已验收"
                } else {
                    "改动"
                },
                changes.len(),
                changes
                    .iter()
                    .map(|c| c["added"].as_u64().unwrap_or(0))
                    .sum::<u64>(),
                glyph(a, "−", "-"),
                changes
                    .iter()
                    .map(|c| c["removed"].as_u64().unwrap_or(0))
                    .sum::<u64>()
            ),
            if w >= 60 { "ctrl+g 查看差异" } else { "" }.into(),
            w,
            a,
            Style::default(),
            t.muted,
        ));
    }
    if a.status() == "failed" && !text(s, "error").is_empty() {
        out.push(line(
            format!("  {} {}", glyph(a, "✗", "x"), text(s, "error")),
            t.bad,
        ));
    }
    (out, anchors, user_rows, tool_rows, change_rows)
}
fn status_label(s: &str) -> &str {
    match s {
        "running" => "运行中",
        "approval" => "待批准",
        "waiting_acceptance" | "completed" => "已完成",
        "accepted" => "已完成",
        "stopped" => "已停止",
        "failed" => "失败",
        _ => "已结束",
    }
}
fn status(a: &App, w: usize) -> Option<Line<'static>> {
    let dot = glyph(a, "·", ":");
    let t = Theme::new(a);
    let s = &a.snapshot["session"];
    let (left, right, style) = if a.esc_at.is_some_and(|x| x.elapsed().as_millis() < 1500) {
        ("再按一次 esc 中断任务".into(), "", t.warn)
    } else if a.snapshot["plan"]["status"] == "awaitingApproval"
        && a.snapshot["plan"]["is_current"] != false
    {
        (
            format!(
                "{} 等待计划审核 v{}{}",
                glyph(a, "◇", "?"),
                a.snapshot["plan"]["revision"],
                if w < 60 { " /plan" } else { "" }
            ),
            "/plan 查看并处理",
            t.warn,
        )
    } else {
        match a.status() {
            "running" => (
                format!(
                    "{} {} {dot} 第 {}/{} 轮 {dot} {}",
                    state_icon(a, "running"),
                    if text(s, "phase").contains("运行身份") {
                        "正在处理任务"
                    } else {
                        text(s, "phase")
                    },
                    s["round"],
                    s["round_limit"],
                    duration(&s["elapsed_ms"])
                ),
                "esc 中断",
                t.muted,
            ),
            "approval" => (
                format!(
                    "{} {} 个操作等待批准",
                    glyph(a, "◇", "?"),
                    items(&a.snapshot, "approvals").len()
                ),
                "ctrl+y 处理",
                t.warn,
            ),
            "retrying" => {
                let r = a.retry.as_ref().unwrap_or(&s["retry"]);
                (
                    format!(
                        "! {} {} {dot} {}s 后重试（{}/{}）",
                        text(r, "code"),
                        text(r, "message"),
                        r["retry_after_ms"].as_u64().unwrap_or(0) / 1000,
                        r["attempt"],
                        r["max_attempts"]
                    ),
                    "esc 中断",
                    t.warn,
                )
            }
            "waiting_acceptance" | "completed" => (
                format!("{} 任务完成", glyph(a, "✓", "v")),
                glyph(a, "直接输入新任务或修改意见", "直接输入新任务或修改意见"),
                t.good,
            ),
            "stopped" => (
                format!(
                    "{} 已停止 {dot} 第 {}/{} 轮",
                    glyph(a, "■", "#"),
                    s["round"],
                    s["round_limit"]
                ),
                "enter 继续",
                t.muted,
            ),
            _ => (String::new(), "", t.muted),
        }
    };
    let notice = persistent_notice(a).unwrap_or("");
    let action = if w >= 60 { right } else { "" };
    let right_budget = w.saturating_sub(if left.is_empty() { 6 } else { 24 });
    let notice = truncate(
        notice,
        right_budget
            .saturating_sub(width(action, a.ambiguous_width) + usize::from(!action.is_empty()) * 3),
        a.ambiguous_width,
    );
    let feedback = if notice.is_empty() {
        action.into()
    } else if action.is_empty() {
        notice.clone()
    } else {
        format!("{notice} {dot} {action}")
    };
    let mut result = pair(
        format!("    {left}"),
        feedback,
        w.saturating_sub(2),
        a,
        style,
        if notice.is_empty() {
            t.muted
        } else if notice.starts_with("已") && !notice.contains("失败") {
            t.good
        } else {
            t.warn
        },
    );
    let prefix = format!("    {}", state_icon(a, "running"));
    if a.status() == "running"
        && let Some(rest) = result.spans[0].content.strip_prefix(&prefix)
    {
        let rest = rest.to_owned();
        let mut spans = vec![
            Span::styled("    ", style),
            Span::styled(state_icon(a, "running"), t.accent),
            Span::styled(rest, style),
        ];
        spans.extend(result.spans.drain(1..));
        result.spans = spans;
    }
    Some(result)
}
fn permission(a: &App) -> (&str, Style) {
    let t = Theme::new(a);
    match text(&a.snapshot["session"], "permission") {
        "full" => (
            if a.ascii || a.ambiguous_width == 2 {
                "! 完全访问"
            } else {
                "▲ 完全访问"
            },
            t.bad.add_modifier(Modifier::BOLD),
        ),
        "assisted" => (
            if a.ascii || a.ambiguous_width == 2 {
                "+ 自动审查"
            } else {
                "◆ 自动审查"
            },
            t.accent,
        ),
        _ => (
            if a.ascii || a.ambiguous_width == 2 {
                "? 请求批准"
            } else {
                "◇ 请求批准"
            },
            t.muted,
        ),
    }
}
fn compact_tokens(v: &Value) -> String {
    let Some(n) = v.as_u64() else {
        return "--".into();
    };
    if n >= 1_000_000 {
        format!("{:.1}m", n as f64 / 1_000_000.0)
    } else if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        n.to_string()
    }
}
pub fn footer(a: &App, w: usize) -> Line<'static> {
    let t = Theme::new(a);
    let session = &a.snapshot["session"];
    let (permission, ps) = permission(a);
    let dot = glyph(a, "·", ":");
    let model = if text(session, "model").is_empty() {
        "未选择模型"
    } else {
        text(session, "model")
    };
    let mode = if session["mode"] == "plan" {
        format!("计划模式 {dot} ")
    } else {
        String::new()
    };
    let fast = if session["fast"] == true {
        format!(" {dot} 快速")
    } else {
        String::new()
    };
    let left = format!(
        "    {}  {model} {dot} {}{fast}",
        text(session, "workspace_label"),
        effort_label(text(session, "effort"))
    );
    let right = format!("{mode}{permission}  ");
    pair(left, right, w, a, t.muted, ps)
}
fn context_statistics(a: &App, w: usize) -> Vec<Span<'static>> {
    let t = Theme::new(a);
    let Some(percent) = a.snapshot["session"]["context_percent"].as_f64() else {
        return vec![];
    };
    let percent = percent.clamp(0.0, 100.0);
    let emphasis = if percent >= 95.0 {
        t.bad
    } else if percent >= 80.0 {
        t.warn
    } else {
        t.accent
    };
    let mut spans = vec![
        Span::styled(
            if w >= 24 {
                "    上下文 "
            } else {
                "上下文 "
            },
            t.muted,
        ),
        Span::styled(
            format!("{percent:.0}%"),
            emphasis.add_modifier(Modifier::BOLD),
        ),
    ];
    let segments = if w >= 100 {
        10
    } else if w >= 60 {
        8
    } else {
        0
    };
    if segments > 0 {
        // Each segment represents a usage band; even a small nonzero amount
        // has a visible mark, while the percentage retains the precise value.
        let filled = (percent * segments as f64 / 100.0).ceil() as usize;
        spans.push(Span::raw("  "));
        spans.push(Span::styled(glyph(a, "▰", "#").repeat(filled), emphasis));
        spans.push(Span::styled(
            glyph(a, "▱", ".").repeat(segments - filled),
            t.muted.add_modifier(Modifier::DIM),
        ));
    }
    if percent >= 95.0 {
        spans.push(Span::styled(" /compact", emphasis));
    }
    spans
}

pub fn footer_statistics(a: &App, w: usize) -> Line<'static> {
    let t = Theme::new(a);
    let session = &a.snapshot["session"];
    let u = &session["usage"];
    let dot = glyph(a, "·", ":");
    let mut usage = vec![];
    if !u["input"].is_null() {
        usage.push(format!("输入 {}", compact_tokens(&u["input"])));
    }
    if !u["output"].is_null() {
        usage.push(format!("输出 {}", compact_tokens(&u["output"])));
    }
    if w >= 70 && !u["cached"].is_null() {
        usage.push(format!("缓存 {}", compact_tokens(&u["cached"])));
    }
    if u["cache_complete"] == false || u["unknown"].as_u64().unwrap_or(0) > 0 {
        usage.push("统计未完整".into());
    }
    if let Some(cost) = u["cost"].as_f64() {
        usage.push(format!(
            "{}{cost:.4} {}{}",
            if u["estimated"] == true { "约 " } else { "" },
            text(u, "currency"),
            if u["complete"] == false {
                "（部分）"
            } else {
                ""
            }
        ));
    }
    let speed = &u["speed"];
    if a.active()
        && w >= 110
        && let Some(v) = speed["download_tps"].as_f64()
    {
        usage.push(format!("↓约{v:.1} tok/s"));
    }
    let usage = usage.join(&format!(" {dot} "));
    let mut spans = context_statistics(a, w);
    let left_width: usize = spans
        .iter()
        .map(|s| width(&s.content, a.ambiguous_width))
        .sum();
    let budget = w.saturating_sub(left_width + 4);
    let right = truncate(&usage, budget, a.ambiguous_width);
    let right = if right.is_empty() {
        right
    } else {
        format!("{right}  ")
    };
    let right_width = width(&right, a.ambiguous_width);
    let mut remaining = w.saturating_sub(right_width);
    spans.retain_mut(|span| {
        span.content = truncate(&span.content, remaining, a.ambiguous_width).into();
        remaining = remaining.saturating_sub(width(&span.content, a.ambiguous_width));
        !span.content.is_empty()
    });
    spans.push(Span::raw(" ".repeat(remaining)));
    spans.push(Span::styled(right, t.muted));
    Line::from(spans)
}
pub fn statistics_at(a: &App, w: u16, h: u16) -> Option<Rect> {
    (a.view == View::Chat && h >= 8 && w > 0).then(|| Rect::new(0, h - 1, w, 1))
}
pub fn footer_action(_a: &App, _w: usize, _x: usize) -> Option<&'static str> {
    None
}
pub fn statistics_action(a: &App, w: usize, x: usize) -> &'static str {
    let len = context_statistics(a, w)
        .iter()
        .map(|s| width(&s.content, a.ambiguous_width))
        .sum::<usize>()
        .min(w);
    if x < len { "context" } else { "usage" }
}
pub fn latest_button_rect(a: &App, w: u16, h: u16) -> Option<Rect> {
    if a.view != View::Chat
        || welcome(a)
        || a.drawer.is_some()
        || a.form.is_some()
        || (a.reading_anchor.is_none() && a.scroll == 0)
        || h < 8
    {
        return None;
    }
    let record_w = w.saturating_sub(if a.sidebar && w >= 140 { 44 } else { 0 });
    let layout = chat_layout(a, w as usize, h);
    if layout.record_h == 0 {
        return None;
    }
    let bw = record_w.min(if a.unseen_output { 44 } else { 34 });
    Some(Rect::new(
        record_w.saturating_sub(bw) / 2,
        layout.record_h - 1,
        bw,
        1,
    ))
}
pub fn attachment_hit(a: &App, frame: &ratatui::buffer::Buffer, x: u16, y: u16) -> Option<usize> {
    if a.drawer.is_some()
        || a.form.is_some()
        || !frame.area.contains(ratatui::layout::Position::new(x, y))
    {
        return None;
    }
    let layout = chat_layout(a, frame.area.width as usize, frame.area.height);
    if y < layout.record_h {
        return None;
    }
    for (index, v) in a.attachments.iter().enumerate() {
        let tag = text(v, "_tag");
        if tag.is_empty() {
            continue;
        }
        for start in frame.area.x..frame.area.right() {
            let end = start.saturating_add(tag.len() as u16);
            if end <= frame.area.right()
                && x >= start
                && x < end
                && tag
                    .chars()
                    .enumerate()
                    .all(|(i, c)| frame[(start + i as u16, y)].symbol() == c.to_string())
            {
                return Some(index);
            }
        }
    }
    None
}

/// Resolve the hovered label in its own draft or message, so reused labels
/// such as [File 1] never show another turn's address.
pub fn attachment_path_at(
    a: &App,
    frame: &ratatui::buffer::Buffer,
    x: u16,
    y: u16,
) -> Option<String> {
    if a.trust_prompt.is_some()
        || a.workspace_pending
        || a.startup_phase.is_some()
        || a.drawer.is_some()
        || a.form.is_some()
        || a.question_popup_visible()
        || !frame.area.contains(ratatui::layout::Position::new(x, y))
    {
        return None;
    }
    if let Some(index) = attachment_hit(a, frame, x, y) {
        let attachment = &a.attachments[index];
        if text(attachment, "kind") == "image" {
            return None;
        }
        let path = ["path", "_path"]
            .into_iter()
            .map(|key| text(attachment, key))
            .find(|path| !path.is_empty())?;
        return Some(path.to_owned());
    }
    let id = if y == 0 && show_pinned_user(a, frame.area.width, frame.area.height) {
        crate::presentation::pinned_user(a)?.0.to_owned()
    } else {
        user_message_at(a, frame.area.width, frame.area.height, x, y)?
    };
    let message = items(&a.snapshot, "messages")
        .iter()
        .find(|m| text(m, "id") == id)?;
    for attachment in items(message, "attachments") {
        let tag = text(attachment, "_tag");
        if attachment["reference"] != true || tag.is_empty() {
            continue;
        }
        for start in frame.area.x..frame.area.right() {
            let end = start.saturating_add(tag.len() as u16);
            if end <= frame.area.right()
                && x >= start
                && x < end
                && tag
                    .chars()
                    .enumerate()
                    .all(|(i, c)| frame[(start + i as u16, y)].symbol() == c.to_string())
            {
                return Some(text(attachment, "path").to_owned());
            }
        }
    }
    None
}

pub fn image_message_hit(
    a: &App,
    frame: &ratatui::buffer::Buffer,
    x: u16,
    y: u16,
) -> Option<(String, String)> {
    if !frame.area.contains((x, y).into()) {
        return None;
    }
    let id = user_message_at(a, frame.area.width, frame.area.height, x, y)?;
    let m = items(&a.snapshot, "messages")
        .iter()
        .find(|m| text(m, "id") == id)?;
    let mut n = 0;
    for att in items(m, "attachments") {
        if !text(att, "mime").starts_with("image/") {
            continue;
        }
        n += 1;
        let fallback = format!("[Image {n}]");
        let tag = if text(att, "_tag").is_empty() {
            fallback.as_str()
        } else {
            text(att, "_tag")
        };
        for start in frame.area.x..frame.area.right() {
            if start + tag.len() as u16 <= frame.area.right()
                && x >= start
                && x < start + tag.len() as u16
                && tag
                    .chars()
                    .enumerate()
                    .all(|(i, c)| frame[(start + i as u16, y)].symbol() == c.to_string())
            {
                return Some((id, text(att, "id").to_owned()));
            }
        }
    }
    None
}

pub fn draw_attachment_tooltip(f: &mut Frame, a: &App, x: u16, y: u16) {
    let Some(path) = attachment_path_at(a, f.buffer_mut(), x, y) else {
        return;
    };
    let area = f.area();
    if area.width < 8 || area.height < 4 {
        return;
    }
    let w = (width(&clean(&path), a.ambiguous_width) + 2)
        .min(90)
        .min(area.width as usize) as u16;
    let lines = wrap(&path, w.saturating_sub(2) as usize, a, "", Style::default());
    let h = (lines.len() as u16 + 2).min(area.height.saturating_sub(1));
    let left = x.min(area.right().saturating_sub(w));
    let top = if y.saturating_add(h + 1) <= area.bottom() {
        y + 1
    } else {
        y.saturating_sub(h)
    };
    let rect = Rect::new(left, top, w, h);
    f.render_widget(Clear, rect);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Theme::new(a).accent);
    let inner = block.inner(rect);
    f.render_widget(block, rect);
    f.render_widget(paragraph(a, lines), inner);
}

fn selection_line(value: &str, w: usize, a: &App, style: Style) -> Line<'static> {
    let value = truncate(value, w, a.ambiguous_width);
    let pad = w.saturating_sub(width(&value, a.ambiguous_width));
    line(format!("{value}{}", " ".repeat(pad)), style)
}

fn field_window(
    a: &App,
    field: &crate::app::FormField,
    columns: usize,
    editing: bool,
    cursor: usize,
) -> (String, usize) {
    if !editing {
        let value = if field.secret {
            if field.value.is_empty() {
                "保留现有密钥".to_owned()
            } else {
                "*".repeat(field.value.chars().count().min(24))
            }
        } else {
            display_path(&field.value)
        };
        let visible = middle(&value, columns, a);
        let col = width(&visible, a.ambiguous_width);
        return (visible, col);
    }
    let cursor = cursor.min(field.value.len());
    let display = |value: &str| -> String {
        value
            .chars()
            .map(|c| {
                if field.secret {
                    '*'
                } else if c == '\n' || c == '\r' {
                    '|'
                } else if c == '\t' {
                    ' '
                } else {
                    c
                }
            })
            .collect()
    };
    let prefix = display(&field.value[..cursor]);
    let value = display(&field.value);
    let available = columns.saturating_sub(1);
    let want_skip = width(&prefix, a.ambiguous_width).saturating_sub(available);
    let mut skipped = 0;
    let mut start = 0;
    for (i, c) in value.char_indices() {
        if skipped >= want_skip {
            start = i;
            break;
        }
        skipped += width(&c.to_string(), a.ambiguous_width);
        start = i + c.len_utf8();
    }
    let visible = truncate(&value[start..], columns, a.ambiguous_width);
    (
        visible,
        width(&prefix, a.ambiguous_width)
            .saturating_sub(skipped)
            .min(available),
    )
}

/// Add/edit editors opened from settings are layered dialogs, not page swaps.
fn is_dialog(form: &TerminalForm) -> bool {
    matches!(
        form.kind,
        FormKind::Provider | FormKind::Mcp | FormKind::Asr
    )
}
/// Actions that act on a stored object stay visible but inert until saved.
fn needs_saved_item(form: &TerminalForm, field: &crate::app::FormField) -> bool {
    matches!(form.kind, FormKind::Provider | FormKind::Mcp)
        && matches!(
            field.key.as_str(),
            "__scan" | "__remove" | "__connect" | "__disconnect" | "__tools" | "__bind"
        )
        && form
            .items
            .first()
            .is_none_or(|item| text(item, "id").is_empty())
}
/// MCP fields for the other transport stay editable but recede visually.
fn applies_to_transport(form: &TerminalForm, field: &crate::app::FormField) -> bool {
    if form.kind != FormKind::Mcp {
        return true;
    }
    let http = form
        .fields
        .iter()
        .any(|f| f.key == "transport" && f.value == "http");
    match field.key.as_str() {
        "command" | "args" | "working_directory" | "env" => !http,
        "base_url" | "headers" | "token" => http,
        _ => true,
    }
}
/// Editable labels share one column so values line up like a real form.
fn label_column(a: &App, form: &TerminalForm, w: usize) -> usize {
    form.fields
        .iter()
        .filter(|field| field.editable)
        .map(|field| width(&field.label, a.ambiguous_width))
        .max()
        .unwrap_or(0)
        .min(w.saturating_sub(8).min(24).min(w / 3))
}
fn choice_value(a: &App, field: &crate::app::FormField, columns: usize) -> String {
    let current = field
        .choices
        .iter()
        .position(|(value, _)| *value == field.value)
        .unwrap_or(0);
    let full = field
        .choices
        .iter()
        .enumerate()
        .map(|(i, (_, label))| {
            let mark = if i == current {
                glyph(a, "◉", "(*)")
            } else {
                glyph(a, "○", "( )")
            };
            format!("{mark} {label}")
        })
        .collect::<Vec<_>>()
        .join("  ");
    if width(&full, a.ambiguous_width) <= columns {
        return full;
    }
    let compact = format!(
        "{} {} {}  {}/{}",
        glyph(a, "‹", "<"),
        field.choices[current].1,
        glyph(a, "›", ">"),
        current + 1,
        field.choices.len()
    );
    truncate(&compact, columns, a.ambiguous_width)
}

fn form_lines(
    a: &App,
    form: &TerminalForm,
    w: usize,
    height: usize,
    active: bool,
) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let mut out = vec![];
    let notice = usize::from(!form.notice.is_empty());
    let budget = height.saturating_sub(out.len() + 1 + notice).max(1);
    let selected = form.selected.min(form.fields.len().saturating_sub(1));
    let start = selected
        .saturating_sub(budget / 2)
        .min(form.fields.len().saturating_sub(budget));
    let dialog = is_dialog(form);
    let column = label_column(a, form, w);
    for (i, field) in form.fields.iter().enumerate().skip(start).take(budget) {
        let disabled = needs_saved_item(form, field);
        let mut label = if field.editable {
            let label = truncate(&field.label, column, a.ambiguous_width);
            let pad = column.saturating_sub(width(&label, a.ambiguous_width));
            format!("{label}{}", " ".repeat(pad))
        } else if dialog {
            format!("[ {} ]", field.label)
        } else {
            field.label.clone()
        };
        if !field.editable {
            label = truncate(&label, w.saturating_sub(3), a.ambiguous_width);
            if !dialog && !field.value.is_empty() {
                let state = truncate(
                    &field.value,
                    w.saturating_sub(width(&label, a.ambiguous_width) + 8),
                    a.ambiguous_width,
                );
                let gap = w.saturating_sub(
                    width(&label, a.ambiguous_width) + width(&state, a.ambiguous_width) + 4,
                );
                label = format!("{label}{}{state}", " ".repeat(gap.max(2)));
            }
        }
        let columns = w.saturating_sub(width(&label, a.ambiguous_width) + 5);
        let unsaved = dialog
            && form
                .items
                .first()
                .is_none_or(|item| text(item, "id").is_empty());
        let value = if !field.editable && !dialog {
            String::new()
        } else if !field.choices.is_empty() {
            choice_value(a, field, columns)
        } else if field.key == "id" && field.value.is_empty() && dialog {
            "保存后自动生成".to_owned()
        } else if field.secret
            && field.value.is_empty()
            && dialog
            && !(active && i == selected && form.editing)
        {
            if unsaved {
                "未设置"
            } else {
                "已保存 · 留空保留"
            }
            .to_owned()
        } else {
            field_window(
                a,
                field,
                columns,
                active && i == selected && form.editing,
                form.cursor,
            )
            .0
        };
        let value = if value.is_empty() {
            String::new()
        } else {
            format!("  {value}")
        };
        let marker = if i == selected {
            glyph(a, "›", ">")
        } else {
            " "
        };
        let style = if i == selected && active {
            t.selected
        } else if i == selected || disabled || !applies_to_transport(form, field) {
            t.muted
        } else {
            Style::default()
        };
        out.push(selection_line(
            &format!(" {marker} {label}{value}"),
            w,
            a,
            style,
        ));
    }
    if !form.notice.is_empty() {
        out.push(line(truncate(&form.notice, w, a.ambiguous_width), t.warn));
    }
    let current = form.fields.get(selected);
    out.push(line(
        if current.is_some_and(|field| !field.choices.is_empty()) {
            " ←/→ 或空格切换 · Tab 下一项 · Esc 返回"
        } else if current.is_some_and(|field| needs_saved_item(form, field)) {
            " 保存后可用 · ↑/↓ 选择 · Esc 返回"
        } else if form.editing {
            " 输入编辑 · Ctrl+U 清空 · Tab 下一项 · Enter 确认 · Esc 返回"
        } else {
            " ↑/↓ 选择 · Enter 打开或确认 · Esc 返回"
        },
        t.muted,
    ));
    out
}

fn panel_rect(width: u16, safe_height: u16, rows: usize, dialog: bool) -> Rect {
    let available = safe_height.saturating_sub(3);
    // Rows are the visible content lines; four more cover border and padding.
    let w = if dialog {
        width.saturating_sub(4).min(78).max(width.min(36))
    } else {
        let horizontal_margin = if width >= 70 { 4 } else { 1 };
        width.saturating_sub(horizontal_margin * 2).min(112)
    };
    let h = ((rows + 4).min(u16::MAX as usize) as u16)
        .max(8)
        .min(available);
    Rect::new((width - w) / 2, (safe_height - 1 - h) / 2, w, h)
}
/// Dialog geometry is shared by painting and input hit testing.
pub fn popup_rect(a: &App, width: u16, height: u16) -> Option<Rect> {
    if a.drawer == Some(Drawer::Effort) && a.form.is_none() {
        return Some(crate::presentation::effort_rect(width, height));
    }
    if a.drawer == Some(Drawer::Editor) {
        return Some(crate::native_editor::rect(width, height));
    }
    if crate::palette::is_picker(a) {
        return Some(crate::palette::layout(a, width, height).rect);
    }
    if a.question_popup_visible() {
        if width < 8 || height < 6 {
            return None;
        }
        let safe_height = height.saturating_sub(u16::from(persistent_notice(a).is_some()));
        let inner_w = panel_rect(width, safe_height, 0, true)
            .width
            .saturating_sub(4) as usize;
        let q = a.current_question();
        let question_rows = wrap(
            &format!("必答 · 单选 · {}", text(q, "question")),
            inner_w,
            a,
            "",
            Style::default(),
        )
        .len()
            + wrap(text(q, "description"), inner_w, a, "", Style::default()).len();
        let options = items(q, "options")
            .iter()
            .map(|v| {
                wrap(
                    &format!(" > [ ] 99. {}", v.as_str().unwrap_or("")),
                    inner_w,
                    a,
                    "",
                    Style::default(),
                )
                .len()
            })
            .sum::<usize>();
        return Some(panel_rect(
            width,
            safe_height,
            question_rows.clamp(1, 8) + options.min(8) + 2,
            true,
        ));
    }
    if (a.form.is_none() && a.drawer.is_none()) || width < 8 || height < 6 {
        return None;
    }
    let notice_rows = u16::from(persistent_notice(a).is_some());
    let safe_height = height.saturating_sub(notice_rows);
    if a.form.is_none() && a.drawer == Some(Drawer::Diff) {
        let w = panel_rect(width, safe_height, 0, false)
            .width
            .saturating_sub(6) as usize;
        return Some(panel_rect(
            width,
            safe_height,
            diff_body(a, w).len().max(4),
            false,
        ));
    }
    Some(match &a.form {
        Some(form) => panel_rect(
            width,
            safe_height,
            form.fields.len() + usize::from(!form.notice.is_empty()) + 1,
            is_dialog(form),
        ),
        None => {
            // Size list popups to what they show instead of a fixed tall frame.
            let w = panel_rect(width, safe_height, 0, false)
                .width
                .saturating_sub(6) as usize;
            let rows = drawer_lines(a, w, safe_height.saturating_sub(3) as usize)
                .len()
                .saturating_sub(2);
            panel_rect(width, safe_height, rows.max(4), false)
        }
    })
}
fn backdrop_rect(a: &App, width: u16, height: u16) -> Option<(Rect, &TerminalForm)> {
    let backdrop = a.form_backdrop.as_ref()?;
    if !a.form.as_ref().is_some_and(is_dialog) || width < 8 || height < 6 {
        return None;
    }
    let safe_height = height.saturating_sub(u16::from(persistent_notice(a).is_some()));
    Some((
        panel_rect(width, safe_height, backdrop.fields.len(), false),
        backdrop,
    ))
}
pub fn popup_close_rect(a: &App, width: u16, height: u16) -> Option<Rect> {
    let r = popup_rect(a, width, height)?;
    Some(Rect::new(r.right().saturating_sub(5), r.y, 3, 1))
}
fn popup_inner(r: Rect) -> Rect {
    Rect::new(
        r.x + 3,
        r.y + 2,
        r.width.saturating_sub(6),
        r.height.saturating_sub(4),
    )
}

pub fn shell_max_scroll(a: &App) -> usize {
    let Some(rect) = popup_rect(a, a.viewport.0, a.viewport.1) else {
        return 0;
    };
    let inner = popup_inner(rect);
    let rows = a
        .shell_output
        .lines()
        .map(|line| wrap(line, inner.width as usize, a, " ", Style::default()).len())
        .sum::<usize>();
    rows.saturating_sub(inner.height.saturating_sub(4) as usize)
}

pub struct DiffScrollbar {
    pub track: Rect,
    pub thumb: Rect,
    pub position: usize,
    pub maximum: usize,
    pub page: usize,
}
pub fn diff_scrollbar(a: &App, width: u16, height: u16) -> Option<DiffScrollbar> {
    if a.drawer != Some(Drawer::Diff) || a.form.is_some() {
        return None;
    }
    let rect = popup_rect(a, width, height)?;
    let inner = popup_inner(rect);
    if inner.height == 0 || inner.width == 0 {
        return None;
    }
    let total = diff_body(a, inner.width as usize).len();
    let visible = inner.height as usize;
    let maximum = total.saturating_sub(visible);
    let position = a.selected.min(maximum);
    let track = Rect::new(rect.right().saturating_sub(2), inner.y, 1, inner.height);
    let thumb_height = (visible * visible / total.max(1)).clamp(1, visible) as u16;
    let travel = track.height - thumb_height;
    let offset = (position * travel as usize)
        .checked_div(maximum)
        .unwrap_or(0);
    let thumb = Rect::new(track.x, track.y + offset as u16, 1, thumb_height);
    Some(DiffScrollbar {
        track,
        thumb,
        position,
        maximum,
        page: visible.saturating_sub(1).max(1),
    })
}
pub fn drag_diff_scrollbar(a: &mut App, width: u16, height: u16, y: u16, grab: u16) {
    let Some(bar) = diff_scrollbar(a, width, height) else {
        return;
    };
    let travel = bar.track.height - bar.thumb.height;
    let top = y
        .saturating_sub(bar.track.y.saturating_add(grab))
        .min(travel) as usize;
    a.selected = if travel == 0 {
        0
    } else {
        (top * bar.maximum + travel as usize / 2) / travel as usize
    };
}
fn draw_diff_scrollbar(f: &mut Frame, a: &App) {
    let Some(bar) = diff_scrollbar(a, f.area().width, f.area().height) else {
        return;
    };
    let t = Theme::new(a);
    let track = (0..bar.track.height)
        .map(|_| line(glyph(a, "│", ":"), t.muted))
        .collect::<Vec<_>>();
    let thumb = (0..bar.thumb.height)
        .map(|_| line(glyph(a, "█", "#"), t.accent))
        .collect::<Vec<_>>();
    f.render_widget(paragraph(a, track), bar.track);
    f.render_widget(paragraph(a, thumb), bar.thumb);
    if let Some(rect) = popup_rect(a, f.area().width, f.area().height) {
        let percent = (bar.position * 100).checked_div(bar.maximum).unwrap_or(100);
        let hint = format!(" ←→ / PgUp PgDn 翻页 · Home/End · {percent}% ");
        f.render_widget(
            paragraph(
                a,
                truncate(
                    &hint,
                    rect.width.saturating_sub(6) as usize,
                    a.ambiguous_width,
                ),
            )
            .style(t.muted),
            Rect::new(
                rect.x + 3,
                rect.bottom() - 1,
                rect.width.saturating_sub(6),
                1,
            ),
        );
    }
}
fn form_window(a: &App, height: usize) -> (usize, usize) {
    let Some(form) = &a.form else { return (0, 0) };
    let budget = height
        .saturating_sub(1 + usize::from(!form.notice.is_empty()))
        .max(1);
    let selected = form.selected.min(form.fields.len().saturating_sub(1));
    (
        selected
            .saturating_sub(budget / 2)
            .min(form.fields.len().saturating_sub(budget)),
        budget,
    )
}
pub fn popup_field_at(a: &App, width: u16, height: u16, x: u16, y: u16) -> Option<usize> {
    if crate::palette::is_picker(a) {
        return None;
    }
    let form = a.form.as_ref()?;
    let inner = popup_inner(popup_rect(a, width, height)?);
    if !inner.contains(ratatui::layout::Position::new(x, y)) {
        return None;
    }
    let (start, budget) = form_window(a, inner.height as usize);
    let row = (y - inner.y) as usize;
    (row < budget && start + row < form.fields.len()).then_some(start + row)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PopupAction {
    ShellCopy,
    ShellCancel,
    ShellRefresh,
    ToolSection(usize),
    ToolCopy,
    ToolRefresh,
    LibraryManage,
    WorkspacePermissions,
    EditorButton(usize),
    EditorCursor(u16, u16),
    UsageDetails,
    SkinSelect(usize),
    SkinApply,
    SkinCustom,
    Item(usize),
    Thinking,
    Apply,
    LibraryTab(bool),
    Question(usize),
    AnswerOption(usize),
    AnswerText,
    AnswerNext,
    AnswerSubmit,
}

struct QuestionPanel {
    rect: Rect,
    rows: Vec<(Rect, Line<'static>)>,
    hits: Vec<(Rect, PopupAction)>,
    cursor: Option<(u16, u16)>,
}

fn question_panel(a: &App, width: u16, height: u16) -> Option<QuestionPanel> {
    let rect = popup_rect(a, width, height)?;
    let inner = Rect::new(
        rect.x + 2,
        rect.y + 1,
        rect.width.saturating_sub(4),
        rect.height.saturating_sub(2),
    );
    let mut panel = QuestionPanel {
        rect,
        rows: vec![],
        hits: vec![],
        cursor: None,
    };
    if inner.width < 4 || inner.height < 5 {
        return Some(panel);
    }
    let t = Theme::new(a);
    let w = inner.width as usize;
    let questions = items(&a.snapshot["questions"][0], "questions");
    let slots = (w / 7).max(1);
    let start = a
        .question_index
        .saturating_sub(slots / 2)
        .min(questions.len().saturating_sub(slots));
    let mut tabs = vec![];
    let mut x = inner.x;
    for (i, q) in questions.iter().enumerate().skip(start).take(slots) {
        let raw = if i == a.question_index {
            a.input.as_str()
        } else {
            a.question_ui
                .drafts
                .get(text(q, "id"))
                .map_or("", String::as_str)
        };
        let label = format!(
            "[{}{}] ",
            i + 1,
            if raw.trim().is_empty() { "" } else { "*" }
        );
        let len = label.len() as u16;
        if x + len > inner.right() {
            break;
        }
        tabs.push(Span::styled(
            label,
            if i == a.question_index {
                t.selected
            } else {
                t.muted
            },
        ));
        panel
            .hits
            .push((Rect::new(x, inner.y, len, 1), PopupAction::Question(i)));
        x += len;
    }
    panel.rows.push((
        Rect::new(inner.x, inner.y, inner.width, 1),
        Line::from(tabs),
    ));
    let q = a.current_question();
    let options = items(q, "options");
    let body_h = inner.height.saturating_sub(4) as usize;
    let label = format!(
        "{}{}{}",
        if q["required"] == true {
            "必答 · "
        } else {
            "可选 · "
        },
        if options.is_empty() {
            ""
        } else if q["multiple"] == true {
            "多选 · "
        } else {
            "单选 · "
        },
        text(q, "question")
    );
    let mut question = wrap(&label, w, a, "", t.accent);
    if !text(q, "description").is_empty() {
        question.extend(wrap(text(q, "description"), w, a, "", t.muted));
    }
    let qh = if options.is_empty() {
        body_h
    } else {
        (body_h / 2).max(1).min(question.len().max(1))
    };
    let offset = a.question_ui.scroll.min(question.len().saturating_sub(qh));
    let mut y = inner.y + 1;
    for row in question.into_iter().skip(offset).take(qh) {
        panel
            .rows
            .push((Rect::new(inner.x, y, inner.width, 1), row));
        y += 1;
    }
    let option_h = body_h.saturating_sub(qh);
    let selected: Vec<_> = a
        .input
        .split(',')
        .filter_map(|s| s.trim().parse::<usize>().ok())
        .collect();
    let mut option_rows = vec![];
    for (index, option) in options.iter().enumerate() {
        let label = format!(
            "{} [{}] {}. {}",
            if index == a.question_ui.option && !a.question_ui.editing {
                ">"
            } else {
                " "
            },
            if selected.contains(&(index + 1)) {
                "x"
            } else {
                " "
            },
            index + 1,
            option.as_str().unwrap_or("")
        );
        for row in wrap(
            &label,
            w,
            a,
            "",
            if index == a.question_ui.option && !a.question_ui.editing {
                t.selected
            } else {
                Style::default()
            },
        ) {
            option_rows.push((index, row));
        }
    }
    let focus = option_rows
        .iter()
        .position(|(i, _)| *i == a.question_ui.option)
        .unwrap_or(0);
    let option_start = focus
        .saturating_sub(option_h / 2)
        .min(option_rows.len().saturating_sub(option_h));
    for (index, row) in option_rows.into_iter().skip(option_start).take(option_h) {
        let r = Rect::new(inner.x, y, inner.width, 1);
        panel.rows.push((r, row));
        panel.hits.push((r, PopupAction::AnswerOption(index)));
        y += 1;
    }
    let input_y = inner.bottom() - 3;
    let input_rect = Rect::new(inner.x, input_y, inner.width, 1);
    let input_w = w.saturating_sub(7).max(1);
    let cursor = a.cursor.min(a.input.len());
    let before = a.input.get(..cursor).unwrap_or("").replace('\n', "↵");
    let input = a.input.replace('\n', "↵");
    let mut skip = 0;
    let mut remaining = width_of_question_input(&before, a);
    for c in before.chars() {
        if remaining < input_w {
            break;
        }
        remaining = remaining.saturating_sub(crate::ui::width(&c.to_string(), a.ambiguous_width));
        skip += c.len_utf8();
    }
    let value = if a.question_pending() {
        "答案已提交，等待确认".into()
    } else if input.is_empty() {
        "输入文字或选项编号".into()
    } else {
        truncate(&input[skip..], input_w, a.ambiguous_width)
    };
    panel.rows.push((
        input_rect,
        line(
            format!("填写：{value}"),
            if a.question_ui.editing {
                t.selected
            } else {
                t.muted
            },
        ),
    ));
    panel.hits.push((input_rect, PopupAction::AnswerText));
    if a.question_ui.editing && !a.question_pending() {
        panel.cursor = Some((inner.x + 6 + remaining.min(input_w - 1) as u16, input_y));
    }
    let mut x = inner.x;
    for (label, action) in [
        (
            "[上一题]",
            PopupAction::Question(a.question_index.saturating_sub(1)),
        ),
        ("[下一题]", PopupAction::AnswerNext),
        ("[提交]", PopupAction::AnswerSubmit),
    ] {
        let len = crate::ui::width(label, a.ambiguous_width) as u16;
        if x + len > inner.right() {
            break;
        }
        let r = Rect::new(x, inner.bottom() - 2, len, 1);
        panel.rows.push((r, line(label, t.accent)));
        panel.hits.push((r, action));
        x += len + 1;
    }
    panel.rows.push((
        Rect::new(inner.x, inner.bottom() - 1, inner.width, 1),
        line(
            truncate(
                if a.question_ui.editing {
                    "Tab 选项 · Ctrl+Enter 提交 · Esc 收起"
                } else {
                    "←→ 换题 ↑↓ 选项 空格勾选 Tab 填写"
                },
                w,
                a.ambiguous_width,
            ),
            t.muted,
        ),
    ));
    Some(panel)
}

fn width_of_question_input(value: &str, a: &App) -> usize {
    width(&clean(value), a.ambiguous_width)
}

fn draw_question_popup(f: &mut Frame, a: &App) {
    let Some(panel) = question_panel(a, f.area().width, f.area().height) else {
        return;
    };
    dim_page(f);
    let count = items(&a.snapshot["questions"][0], "questions").len();
    draw_frame(
        f,
        a,
        panel.rect,
        &format!("需要你回答 · {}/{}", a.question_index + 1, count),
        true,
    );
    for (rect, row) in panel.rows {
        f.render_widget(paragraph(a, row), rect);
    }
    if let Some(cursor) = panel.cursor {
        f.set_cursor_position(cursor);
    }
}

pub fn popup_action_at(a: &App, width: u16, height: u16, x: u16, y: u16) -> Option<PopupAction> {
    if a.drawer == Some(Drawer::Effort) && a.form.is_none() {
        return crate::presentation::effort_hit(a, width, height, x, y);
    }
    if a.drawer == Some(Drawer::Editor) {
        return crate::native_editor::hit(a, width, height, x, y);
    }
    if crate::palette::is_picker(a) {
        return crate::palette::hit(a, width, height, x, y);
    }
    let point = ratatui::layout::Position::new(x, y);
    if a.question_popup_visible() {
        return question_panel(a, width, height)?
            .hits
            .into_iter()
            .find(|(r, _)| r.contains(point))
            .map(|(_, action)| action);
    }
    if a.form.is_some() || a.drawer.is_none() {
        return None;
    }
    let inner = popup_inner(popup_rect(a, width, height)?);
    if !inner.contains(point) {
        return None;
    }
    if a.drawer == Some(Drawer::Shell) {
        if y == inner.y + 3 {
            let mut left = inner.x;
            for (label, action) in [
                (" [复制输出] ", PopupAction::ShellCopy),
                (" [中断命令] ", PopupAction::ShellCancel),
                (" [刷新] ", PopupAction::ShellRefresh),
            ] {
                let columns = crate::ui::width(label, a.ambiguous_width) as u16;
                if x >= left && x < left + columns {
                    return Some(action);
                }
                left += columns;
            }
        }
        return None;
    }
    if a.drawer == Some(Drawer::ToolDetail) {
        let mut left = inner.x;
        if y == inner.y {
            for (i, label) in ["概览", "输入", "输出", "原始数据"].iter().enumerate() {
                let columns = crate::ui::width(&format!(" [{label}] "), a.ambiguous_width) as u16;
                if x >= left && x < left + columns {
                    return Some(PopupAction::ToolSection(i));
                }
                left += columns;
            }
        }
        if y == inner.y + 1 {
            let columns = crate::ui::width(" [复制当前内容] ", a.ambiguous_width) as u16;
            return if x < inner.x + columns {
                Some(PopupAction::ToolCopy)
            } else if x < inner.x + columns + crate::ui::width(" [刷新] ", a.ambiguous_width) as u16
            {
                Some(PopupAction::ToolRefresh)
            } else {
                None
            };
        }
        return None;
    }
    if a.drawer == Some(Drawer::Library) && y == inner.y + 1 {
        let first = crate::ui::width(
            &format!(" 素材 {} ", items(&a.library, "assets").len()),
            a.ambiguous_width,
        ) as u16;
        let second = crate::ui::width(
            &format!(" 资料集 {} ", items(&a.library, "sets").len()),
            a.ambiguous_width,
        ) as u16;
        if x > inner.x && x < inner.x + 1 + first {
            return Some(PopupAction::LibraryTab(false));
        }
        if x >= inner.x + 2 + first && x < inner.x + 2 + first + second {
            return Some(PopupAction::LibraryTab(true));
        }
        return None;
    }
    let mut hits = vec![];
    drawer_lines_with_hits(
        a,
        inner.width as usize,
        inner.height as usize + 2,
        &mut hits,
    );
    let row = (y - inner.y) as usize + 2;
    hits.into_iter()
        .find(|(r, action)| *r == row && (*action != PopupAction::Apply || x < inner.x + 6))
        .map(|(_, action)| action)
}
fn dim_page(f: &mut Frame) {
    let area = f.area();
    // Keep both permission/model and usage footer rows readable.
    for y in area.y..area.bottom().saturating_sub(2) {
        for x in area.x..area.right() {
            f.buffer_mut()[(x, y)].modifier.insert(Modifier::DIM);
        }
    }
}
pub(crate) fn draw_frame(f: &mut Frame, a: &App, rect: Rect, title: &str, active: bool) {
    let t = Theme::new(a);
    f.render_widget(Clear, rect);
    let skin = crate::theme::effective_skin_colors(&a.skin, a.background.as_deref(), a.light);
    let mut panel = Style::default();
    if !a.no_color {
        panel = panel.bg(skin.background.unwrap_or(if a.light {
            Color::Rgb(250, 250, 250)
        } else {
            Color::Rgb(24, 28, 34)
        }));
        if let Some(fg) = skin.foreground {
            panel = panel.fg(fg);
        }
    }
    let mut block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(if active { t.accent } else { t.muted })
        .style(panel)
        .title(format!(
            " {} ",
            truncate(
                title,
                rect.width.saturating_sub(10) as usize,
                a.ambiguous_width
            )
        ));
    if a.ascii || a.ambiguous_width == 2 {
        block = block.border_set(ratatui::symbols::border::Set {
            top_left: "+",
            top_right: "+",
            bottom_left: "+",
            bottom_right: "+",
            vertical_left: "|",
            vertical_right: "|",
            horizontal_top: "-",
            horizontal_bottom: "-",
        });
    }
    f.render_widget(block, rect);
    if active {
        let close = Rect::new(rect.right().saturating_sub(5), rect.y, 3, 1);
        f.render_widget(paragraph(a, "[x]").style(t.accent), close);
    }
}
fn draw_popup(f: &mut Frame, a: &App) {
    if a.drawer == Some(Drawer::Effort) && a.form.is_none() {
        dim_page(f);
        crate::presentation::draw_effort(f, a);
        return;
    }
    if a.drawer == Some(Drawer::Editor) {
        dim_page(f);
        crate::native_editor::draw(f, a);
        return;
    }
    if crate::palette::is_picker(a) {
        dim_page(f);
        crate::palette::draw(f, a);
        return;
    }
    if a.question_popup_visible() {
        draw_question_popup(f, a);
        return;
    }
    let area = f.area();
    let Some(rect) = popup_rect(a, area.width, area.height) else {
        return;
    };
    let t = Theme::new(a);
    dim_page(f);
    let mut title = a
        .form
        .as_ref()
        .map(|form| form.title.clone())
        .unwrap_or_else(|| {
            match a.drawer {
                Some(Drawer::Info) => &a.info_title,
                Some(Drawer::Usage) => "用量与费用",
                Some(Drawer::Diff) => "文件改动 · 完整差异",
                Some(Drawer::ToolDetail) => "工具步骤 · 方向键切换与翻页",
                Some(Drawer::Shell) => "命令执行 · Ctrl+C 中断 · Esc 返回对话",
                Some(Drawer::Attachments) => "附件 · Enter 预览 · Delete 移除",
                Some(Drawer::Steps) => "工具步骤 · Enter 查看详情",
                Some(Drawer::Rounds) => "工作记录 · 按轮次查看",
                Some(Drawer::Plan) => "计划审核",
                Some(Drawer::Tasks) => "任务总览",
                Some(Drawer::Checkpoints) => "选择检查点",
                Some(Drawer::CheckpointReview) => "检查点回退预览",
                Some(Drawer::Model) => {
                    if a.model_source_filter.is_some() {
                        "此账号的模型与思考"
                    } else {
                        "模型与思考"
                    }
                }
                Some(Drawer::Permissions) => "工具权限",
                Some(Drawer::Sessions) => "会话",
                Some(Drawer::Workspace) => "工作区",
                Some(Drawer::History) => "历史搜索",
                Some(Drawer::Messages) => "我的提问 · 点击定位",
                Some(Drawer::Login) => "登录与来源",
                Some(Drawer::Effort) => "思考强度",
                Some(Drawer::Library) => "资料库",
                _ => "快捷键帮助",
            }
            .to_owned()
        });
    if let Some((back, backdrop)) = backdrop_rect(a, area.width, area.height)
        // Only frame the dialog when the parent can show a clean margin around it.
        && back.width >= rect.width + 8
    {
        let back = Rect::new(
            back.x,
            rect.y.saturating_sub(1),
            back.width,
            (rect.height + 2).max(back.height),
        );
        draw_frame(f, a, back, &backdrop.title, false);
        let inner = popup_inner(back);
        // A few clipped columns of the parent list read as noise, not context.
        if !inner.is_empty() && rect.x >= inner.x + 12 {
            f.render_widget(
                paragraph(
                    a,
                    form_lines(
                        a,
                        backdrop,
                        inner.width as usize,
                        inner.height as usize,
                        false,
                    ),
                ),
                inner,
            );
        }
        dim_page(f);
    }
    if a.form.as_ref().is_some_and(is_dialog)
        && let Some(backdrop) = &a.form_backdrop
    {
        title = format!("{} {} {title}", backdrop.title, glyph(a, "›", ">"));
    }
    draw_frame(f, a, rect, &title, true);
    let inner = popup_inner(rect);
    if inner.is_empty() {
        return;
    }
    if let Some(form) = &a.form {
        f.render_widget(
            paragraph(
                a,
                form_lines(a, form, inner.width as usize, inner.height as usize, true),
            ),
            inner,
        );
        let (start, budget) = form_window(a, inner.height as usize);
        if let Some(bg) = input_surface(a).bg {
            for (row, field) in form.fields.iter().skip(start).take(budget).enumerate() {
                if field.editable && row < inner.height as usize {
                    for x in inner.x..inner.right() {
                        f.buffer_mut()[(x, inner.y + row as u16)].set_bg(bg);
                    }
                }
            }
        }
        if form.fields.len() > budget {
            f.render_widget(
                paragraph(a, format!(" {}/{} ", form.selected + 1, form.fields.len()))
                    .style(t.muted),
                Rect::new(
                    rect.x + 3,
                    rect.bottom() - 1,
                    rect.width.saturating_sub(9),
                    1,
                ),
            );
        }
        if form.editing
            && let Some(field) = form.fields.get(form.selected)
            && field.editable
            && field.choices.is_empty()
        {
            let w = inner.width as usize;
            let column = label_column(a, form, w);
            let (_, cursor_col) =
                field_window(a, field, w.saturating_sub(column + 5), true, form.cursor);
            let col = (5 + column + cursor_col).min(w.saturating_sub(1));
            f.set_cursor_position((
                inner.x + col as u16,
                inner.y
                    + form
                        .selected
                        .saturating_sub(start)
                        .min(inner.height.saturating_sub(1) as usize) as u16,
            ));
        }
    } else {
        let rows = drawer_lines(a, inner.width as usize, inner.height as usize + 2);
        let prefix = format!(" {} ", glyph(a, "⌕", "/"));
        // Typing goes to the search row, so the cursor shows it is focused there.
        let search_row = a.drawer_has_search()
            && rows
                .get(2)
                .and_then(|row| row.spans.first())
                .is_some_and(|span| span.content == prefix);
        f.render_widget(
            paragraph(
                a,
                rows.into_iter()
                    .skip(2)
                    .take(inner.height as usize)
                    .collect::<Vec<_>>(),
            ),
            inner,
        );
        if search_row && inner.height > 0 {
            f.render_widget(
                paragraph(a, search_line(a, "输入以筛选")).style(input_surface(a)),
                Rect::new(inner.x, inner.y, inner.width, 1),
            );
            let before = &a.search[..a.search_cursor.min(a.search.len())];
            let before = if a.search.is_char_boundary(before.len()) {
                before
            } else {
                ""
            };
            let col = width(&prefix, a.ambiguous_width) + width(&clean(before), a.ambiguous_width);
            f.set_cursor_position((
                inner.x + (col as u16).min(inner.width.saturating_sub(1)),
                inner.y,
            ));
        }
    }
    draw_diff_scrollbar(f, a);
}

fn drawer_lines(a: &App, w: usize, height: usize) -> Vec<Line<'static>> {
    drawer_lines_with_hits(a, w, height, &mut vec![])
}
fn drawer_lines_with_hits(
    a: &App,
    w: usize,
    height: usize,
    hits: &mut Vec<(usize, PopupAction)>,
) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let mut out = vec![];
    let title = match a.drawer {
        Some(Drawer::Info) => &a.info_title,
        Some(Drawer::Usage) => "用量与费用",
        Some(Drawer::Diff) => "文件改动 · 完整差异",
        Some(Drawer::ToolDetail) => "工具步骤",
        Some(Drawer::Shell) => "命令执行",
        Some(Drawer::Attachments) => "附件 · Enter 预览 · Delete 移除",
        Some(Drawer::Steps) => "工具步骤 · Enter 查看详情",
        Some(Drawer::Rounds) => "工作记录 · 按轮次查看",
        Some(Drawer::Plan) => "计划审核",
        Some(Drawer::Tasks) => "任务总览",
        Some(Drawer::Checkpoints) => "选择检查点",
        Some(Drawer::CheckpointReview) => "检查点回退预览",
        Some(Drawer::Model) => {
            if a.model_source_filter.is_some() {
                "此账号的模型"
            } else {
                "模型"
            }
        }
        Some(Drawer::Permissions) => "工具权限",
        Some(Drawer::Sessions) => "会话",
        Some(Drawer::Workspace) => "工作区",
        Some(Drawer::History) => "历史搜索",
        Some(Drawer::Messages) => "我的提问 · 点击定位",
        Some(Drawer::Login) => "登录或添加模型来源",
        Some(Drawer::Effort) => "思考强度",
        Some(Drawer::Library) => "资料库",
        _ => "快捷键",
    };
    out.push(line(glyph(a, "─", "-").repeat(w), t.muted));
    out.push(pair(
        format!(" {title}"),
        glyph(a, "enter 确认 · esc 关闭", "enter 确认 : esc 关闭").into(),
        w,
        a,
        Style::default().add_modifier(Modifier::BOLD),
        t.muted,
    ));
    if a.drawer == Some(Drawer::Model) {
        let list = a.drawer_items();
        if list.is_empty() {
            out.push(line(" 没有可用模型", t.warn));
            return out;
        }
        let selected = a.selected % list.len();
        // Always present: it is where typing goes, even in a short popup.
        out.push(search_line(a, "输入以筛选模型"));
        // Two trailing rows: thinking summary and key hint.
        let budget = height.saturating_sub(out.len() + 2).max(1);
        let mut sources = vec![];
        for model in &list {
            let source = crate::app::model_source_key(model);
            if !sources.contains(&source) {
                sources.push(source);
            }
        }
        let mut rows = vec![];
        for source in sources {
            let model = list
                .iter()
                .find(|m| crate::app::model_source_key(m) == source)
                .unwrap();
            let label = if text(model, "source_host").is_empty() {
                text(model, "source").to_owned()
            } else {
                format!("{} · {}", text(model, "source"), text(model, "source_host"))
            };
            rows.push((None, line(format!(" {label}"), t.muted)));
            for (i, item) in list
                .iter()
                .enumerate()
                .filter(|(_, item)| crate::app::model_source_key(item) == source)
            {
                rows.push((
                    Some(i),
                    selection_line(
                        &format!(
                            " {} {}",
                            if i == selected {
                                glyph(a, "›", ">")
                            } else {
                                " "
                            },
                            text(item, "id")
                        ),
                        w,
                        a,
                        if i == selected {
                            t.selected
                        } else {
                            Style::default()
                        },
                    ),
                ));
            }
        }
        let selected_row = rows
            .iter()
            .position(|(i, _)| *i == Some(selected))
            .unwrap_or(0);
        let start = selected_row
            .saturating_sub(budget / 2)
            .min(rows.len().saturating_sub(budget));
        let mut remaining = budget;
        // A repeated source header is optional; the selected model is not.
        if budget > 1
            && selected_row < start + budget - 1
            && let Some(index) = rows.get(start).and_then(|(i, _)| *i)
        {
            out.push(line(format!(" {}", text(&list[index], "source")), t.muted));
            remaining -= 1;
        }
        for (index, row) in rows.into_iter().skip(start).take(remaining) {
            if let Some(index) = index {
                hits.push((out.len(), PopupAction::Item(index)));
            }
            out.push(row);
        }
        let session = &a.snapshot["session"];
        let effort = text(session, "effort");
        let fast = match (session["fast_supported"] == true, session["fast"] == true) {
            (_, true) => " · 快速 开 (/fast)",
            (true, false) => " · 快速 关 (/fast)",
            _ => "",
        };
        out.push(line(
            format!(
                " 思考 {}{}{fast}  {} /effort 调整",
                if a.thinking { "开" } else { "已关闭" },
                if effort.is_empty() {
                    String::new()
                } else {
                    format!(" · 强度 {}", effort_label(effort))
                },
                glyph(a, "·", ":")
            ),
            t.muted,
        ));
        out.push(line(
            glyph(
                a,
                " ↑/↓ 选择模型 · 输入筛选 · Enter 切换",
                " up/down 选择模型 : 输入筛选 : Enter 切换",
            ),
            t.muted,
        ));
        return out;
    }
    if a.drawer == Some(Drawer::Effort) {
        if a.current_model_value().is_some() {
            let count = a.current_efforts().len();
            for index in 0..count {
                hits.push((out.len() + 2 + index, PopupAction::Item(index)));
            }
            hits.push((out.len() + 3 + count.max(1), PopupAction::Thinking));
            hits.push((out.len() + 4 + count.max(1), PopupAction::Apply));
        }
        out.extend(effort_lines(a, w));
        return out;
    }
    if a.drawer == Some(Drawer::Library) {
        out.extend(library_lines(a, w, height.saturating_sub(out.len()), hits));
        return out;
    }
    match a.drawer {
        Some(Drawer::Shell) => {
            out.push(line(
                truncate(
                    &format!(" 目录：{}", text(&a.shell_state, "target")),
                    w,
                    a.ambiguous_width,
                ),
                t.muted,
            ));
            out.push(line(
                truncate(
                    &format!(
                        " ! {}",
                        clean(text(&a.shell_state, "command")).replace('\n', " ↵ ")
                    ),
                    w,
                    a.ambiguous_width,
                ),
                t.accent,
            ));
            out.push(line(
                format!(" {}", crate::shell::status(&a.shell_state)),
                if a.shell_state["error"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty())
                    || a.shell_state["exit_code"].as_i64().is_some_and(|c| c != 0)
                {
                    t.bad
                } else {
                    t.muted
                },
            ));
            out.push(line(
                " [复制输出]  [中断命令]  [刷新] · C 复制 · End 跟随输出",
                t.accent,
            ));
            let output = if a.shell_output.is_empty() {
                "等待命令输出…"
            } else {
                &a.shell_output
            };
            let body: Vec<_> = output
                .lines()
                .flat_map(|line| wrap(line, w, a, " ", Style::default()))
                .collect();
            let budget = height.saturating_sub(out.len()).max(1);
            let maximum = body.len().saturating_sub(budget);
            let start = if a.shell_follow {
                maximum
            } else {
                a.selected.min(maximum)
            };
            out.extend(body.into_iter().skip(start).take(budget));
        }
        Some(Drawer::ToolDetail) => {
            out.push(Line::from(
                ["概览", "输入", "输出", "原始数据"]
                    .iter()
                    .enumerate()
                    .map(|(i, label)| {
                        Span::styled(
                            format!(" [{label}] "),
                            if i == a.tool_section {
                                t.selected
                            } else {
                                t.accent
                            },
                        )
                    })
                    .collect::<Vec<_>>(),
            ));
            out.push(line(
                " [复制当前内容]  [刷新] · C 复制 · R 刷新 · Esc 返回",
                t.muted,
            ));
            let body = wrap(
                &crate::tool_view::detail_text(&a.tool_detail, a.tool_section),
                w,
                a,
                " ",
                Style::default(),
            );
            let budget = height.saturating_sub(out.len()).max(1);
            let start = a.selected.min(body.len().saturating_sub(budget));
            out.extend(body.into_iter().skip(start).take(budget));
        }
        Some(Drawer::Usage) => {
            let body = usage_lines(a, w);
            let start = a
                .selected
                .min(body.len().saturating_sub(height.saturating_sub(2)));
            for (index, row) in body.into_iter().enumerate().skip(start) {
                if row.spans.iter().any(|s| s.content.contains("统计说明")) {
                    hits.push((out.len(), PopupAction::UsageDetails));
                }
                let _ = index;
                out.push(row);
            }
        }
        Some(Drawer::Diff) => {
            let body = diff_body(a, w);
            let start = a
                .selected
                .min(body.len().saturating_sub(height.saturating_sub(2)));
            out.extend(body.into_iter().skip(start));
        }
        Some(Drawer::Info) => {
            let body: Vec<_> = a
                .info_lines
                .iter()
                .flat_map(|v| wrap(v, w, a, " ", t.muted))
                .collect();
            out.extend(body.into_iter().skip(a.selected));
        }
        Some(Drawer::CheckpointReview) => {
            let review = &a.checkpoint_review;
            let mut body = wrap(
                "回到所选用户消息之前。会话回退保留旧分支；新分支不修改原会话。",
                w,
                a,
                " ",
                t.accent,
            );
            body.extend(wrap(text(review, "warning"), w, a, " ", t.warn));
            for file in items(review, "files") {
                body.extend(wrap(
                    &format!(
                        "{} · {}",
                        text(file, "path"),
                        if file["restorable"] != true {
                            "无法回退"
                        } else if file["new_file"] == true {
                            "将删除新增文件"
                        } else {
                            "核验 SHA 后回退"
                        }
                    ),
                    w,
                    a,
                    " ",
                    t.accent,
                ));
                body.extend(wrap(
                    &format!(
                        "当前快照：\n{}\n回退目标：\n{}",
                        text(file, "after"),
                        file["before"].as_str().unwrap_or("文件不存在")
                    ),
                    w,
                    a,
                    " ",
                    t.muted,
                ));
                if file["preview_truncated"] == true {
                    body.push(line(" 长文件预览已截断", t.warn));
                }
            }
            body.extend(wrap("Esc 关闭后 /rewind conversation 仅会话；/rewind files 仅文件；/rewind both 两者；/rewind branch 新分支。",w,a," ",t.warn));
            let budget = height.saturating_sub(3).max(1);
            let start = a.selected.min(body.len().saturating_sub(budget));
            out.extend(body.into_iter().skip(start).take(budget));
            out.push(line(" ↑↓ / PgUp PgDn 滚动 · Esc 关闭", t.muted));
        }
        Some(Drawer::Plan) => {
            let plan = &a.reviewed_plan;
            let mut body = vec![];
            if plan.is_null() {
                body.push(line(" 当前任务尚无结构化计划", t.muted));
            } else {
                let status = match text(plan, "status") {
                    "awaitingApproval" => "等待审核",
                    "approved" => "已批准",
                    "cancelled" => "已取消",
                    _ => "进度记录",
                };
                body.extend(wrap(
                    &format!("v{} · {status} · {}", plan["revision"], text(plan, "goal")),
                    w,
                    a,
                    " ",
                    t.accent,
                ));
                if plan["revision"] != a.snapshot["plan"]["revision"]
                    || plan["content_hash"] != a.snapshot["plan"]["content_hash"]
                {
                    body.extend(wrap(
                        "计划已改变；关闭后重新 /plan 查看，旧批准不会执行。",
                        w,
                        a,
                        " ",
                        t.warn,
                    ));
                }
                body.extend(wrap(text(plan, "body"), w, a, " ", t.muted));
                if let Some(criteria) = plan.get("criteria") {
                    body.extend(wrap(
                        &format!(
                            "验收：{}\n检查：{}\n交付：{}",
                            text(criteria, "description"),
                            criteria["checkIds"],
                            criteria["artifactPaths"]
                        ),
                        w,
                        a,
                        " ",
                        t.muted,
                    ));
                }
                for step in items(plan, "steps") {
                    let status = match text(step, "status") {
                        "running" => "进行中",
                        "cancelled" => "已取消",
                        "completed" if step["verified"] == true => "报告完成·有工具记录",
                        "completed" => "报告完成·无工具证据",
                        _ => "待开始",
                    };
                    body.extend(wrap(
                        &format!("[{status}] {}", text(step, "title")),
                        w,
                        a,
                        " ",
                        t.muted,
                    ));
                }
                for comment in items(plan, "comments") {
                    body.extend(wrap(
                        &format!(
                            "用户意见 v{}：{}",
                            comment["version"],
                            text(comment, "text")
                        ),
                        w,
                        a,
                        " ",
                        t.accent,
                    ));
                }
                for old in items(plan, "history").iter().rev() {
                    body.extend(wrap(
                        &format!("历史 v{}：{}", old["revision"], text(old, "body")),
                        w,
                        a,
                        " ",
                        t.muted,
                    ));
                }
                body.extend(wrap(&format!("步骤完成不等于验收。Esc 关闭后 /plan approve {} 批准；/plan comment {} 意见",plan["revision"],plan["revision"]),w,a," ",t.warn));
            }
            let budget = height.saturating_sub(3).max(1);
            let start = a.selected.min(body.len().saturating_sub(budget));
            out.extend(body.into_iter().skip(start).take(budget));
            out.push(line(" ↑↓ / PgUp PgDn 滚动 · Esc 关闭", t.muted));
        }
        Some(Drawer::Help) => {
            if let Some(warning) = &a.config_warning {
                out.extend(wrap(warning, w, a, " ", t.warn));
            }
            out.push(line(
                glyph(
                    a,
                    " /recover 恢复失败草稿 · 再次执行切换保留草稿",
                    " /recover 恢复失败草稿 : 再次执行切换保留草稿",
                ),
                t.muted,
            ));
            for s in [
                " enter 发送   Alt+J 换行   shift+tab 计划模式",
                " !命令 在当前工作目录执行 · /shell 查看输出",
                " Ctrl+J / Shift+Enter 换行视终端支持",
                " 鼠标拖选后 ctrl+c 复制 · /copy [all] 复制正文",
                " esc 两次中断 · 未选文字时 ctrl+c 清空 / 中断",
                " ctrl+o 详情   ctrl+g 改动   ctrl+t 任务树",
                " ctrl+y 批准   ctrl+r 历史搜索   ctrl+b 宽屏侧栏",
                " pgup/pgdn 滚动   / 命令   @ 文件",
                " /help commands 查看主入口与快捷命令",
                " Shift 拖选可用终端复制任意界面文字 · ctrl+v 粘贴附件",
            ] {
                out.push(line(s, t.muted));
            }
        }
        Some(Drawer::Login) => {
            out.push(line(" 还没有可用的模型", t.warn));
            out.push(line(" enter 选择登录提供商", t.muted));
        }
        Some(Drawer::Permissions) => {
            for (i, s) in [
                glyph(
                    a,
                    "◇ 请求批准 · 写入和命令先确认",
                    "◇ 请求批准 : 写入和命令先确认",
                ),
                glyph(
                    a,
                    "◆ 自动审查 · 按规则自动批准安全操作",
                    "◆ 自动审查 : 按规则自动批准安全操作",
                ),
                glyph(a, "▲ 完全访问 · 不再询问", "▲ 完全访问 : 不再询问"),
            ]
            .iter()
            .enumerate()
            {
                hits.push((out.len(), PopupAction::Item(i)));
                let s = if a.ascii || a.ambiguous_width == 2 {
                    s.replace('◇', "?").replace('◆', "+").replace('▲', "!")
                } else {
                    s.to_string()
                };
                out.push(line(
                    format!(
                        " {} {s}",
                        if i == a.selected % 3 {
                            glyph(a, "›", ">")
                        } else {
                            " "
                        }
                    ),
                    if i == a.selected % 3 {
                        t.selected
                    } else {
                        t.muted
                    },
                ));
            }
            if a.full_confirm {
                out.push(line(
                    " 完全访问：再次按 enter 确认",
                    t.bad.add_modifier(Modifier::BOLD),
                ));
            }
        }
        _ => {
            out.push(search_line(
                a,
                match a.drawer {
                    Some(Drawer::Sessions) => "输入以搜索会话标题或编号",
                    Some(Drawer::Workspace) => "输入以筛选工作区",
                    Some(Drawer::History) => "输入以搜索历史输入",
                    Some(Drawer::Messages) => "搜索提问，Enter 或点击定位正文",
                    _ => "输入以筛选",
                },
            ));
            if a.drawer == Some(Drawer::Workspace) && a.active() {
                out.push(line(" 当前任务结束后才能切换", t.warn));
            }
            if a.drawer == Some(Drawer::Workspace) {
                hits.push((out.len(), PopupAction::WorkspacePermissions));
                out.push(line(" [目录权限 · F2]  查看或修改选中工作区的目录规则", t.accent));
            }
            let list = a.drawer_items();
            let mut source = "";
            let selected = a.selected % list.len().max(1);
            // Use the popup's real height instead of a fixed handful of rows.
            let limit = height.saturating_sub(out.len()).max(3);
            if list.is_empty() {
                out.push(line(
                    if a.search.is_empty() {
                        " 暂无内容"
                    } else {
                        " 没有匹配项"
                    },
                    t.muted,
                ));
            }
            let start = selected
                .saturating_sub(1)
                .min(list.len().saturating_sub(limit));
            for (i, item) in list.iter().enumerate().skip(start).take(limit) {
                if a.drawer == Some(Drawer::Model) && source != text(item, "source") {
                    source = text(item, "source");
                    out.push(line(format!(" {source}"), t.muted));
                }
                let selected = i == a.selected % list.len().max(1);
                let label = match a.drawer {
                    Some(Drawer::Tasks) => format!(
                        "{} · {} · {}",
                        text(item, "execution"),
                        text(item, "acceptance"),
                        text(item, "title")
                    ),
                    Some(Drawer::Model) => text(item, "id").to_owned(),
                    Some(Drawer::Workspace) => {
                        let path = crate::workspaces::display_path(text(item, "path"));
                        if path.is_empty() {
                            text(item, "name").to_owned()
                        } else {
                            format!("{} · {} · {}", text(item, "name"), crate::workspaces::access_label(text(item, "access")), path)
                        }
                    }
                    Some(Drawer::Sessions) => {
                        let title = text(item, "title");
                        let title = if title.is_empty() {
                            "未命名会话"
                        } else {
                            title
                        };
                        let when = relative_time(text(item, "updated_at"), now_secs());
                        let state = match text(item, "status") {
                            "running" => "  运行中",
                            "approval" => "  待批准",
                            "failed" => "  失败",
                            _ => "",
                        };
                        let current = if item["id"] == a.snapshot["session"]["id"] {
                            "  当前"
                        } else {
                            ""
                        };
                        let right = format!("{when}{state}{current}");
                        let room = w.saturating_sub(width(&right, a.ambiguous_width) + 6);
                        let title = truncate(title, room, a.ambiguous_width);
                        let gap = w.saturating_sub(
                            width(&title, a.ambiguous_width) + width(&right, a.ambiguous_width) + 4,
                        );
                        format!("{title}{}{right}", " ".repeat(gap.max(2)))
                    }
                    _ => text(item, "title").to_owned(),
                };
                hits.push((out.len(), PopupAction::Item(i)));
                let label = format!(
                    " {} {label}{}",
                    if selected { glyph(a, "›", ">") } else { " " },
                    if item["choice"] == a.snapshot["session"]["model_choice"]
                        && !item["choice"].is_null()
                    {
                        "   当前"
                    } else {
                        ""
                    }
                );
                let label = if a.drawer == Some(Drawer::Workspace) {
                    let label = truncate(&label, w, a.ambiguous_width);
                    format!(
                        "{label}{}",
                        " ".repeat(w.saturating_sub(width(&label, a.ambiguous_width)))
                    )
                } else {
                    label
                };
                out.push(line(
                    label,
                    if selected {
                        t.selected
                    } else {
                        Style::default()
                    },
                ));
            }
            if a.drawer == Some(Drawer::Model) && !list.is_empty() {
                let model = &list[a.selected % list.len()];
                let efforts = items(model, "efforts");
                let labels = efforts
                    .iter()
                    .enumerate()
                    .map(|(i, e)| {
                        let s = effort_label(e.as_str().unwrap_or(""));
                        if i == a.effort_index % efforts.len().max(1) {
                            format!("[{s}]")
                        } else {
                            s.to_owned()
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("  ");
                out.push(line(
                    format!(
                        " 思考 {}   强度 {}",
                        if a.thinking { "开" } else { "已关闭" },
                        labels
                    ),
                    if a.thinking { t.accent } else { t.muted },
                ));
                out.push(line(
                    glyph(
                        a,
                        " tab 切换 · 左右 调整强度 · space 开关思考",
                        " tab 切换 : 左右 调整强度 : space 开关思考",
                    ),
                    t.muted,
                ));
            }
        }
    }
    out
}
/// The search row shared by list drawers; the terminal cursor is placed on it.
fn search_line(a: &App, placeholder: &str) -> Line<'static> {
    let t = Theme::new(a);
    let icon = glyph(a, "⌕", "/");
    if a.search.is_empty() {
        Line::from(vec![
            Span::styled(format!(" {icon} "), t.accent),
            Span::styled(placeholder.to_owned(), t.muted),
        ])
    } else {
        Line::from(vec![
            Span::styled(format!(" {icon} "), t.accent),
            Span::raw(clean(&a.search)),
        ])
    }
}
fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}
/// Seconds since the Unix epoch for `YYYY-MM-DDTHH:MM:SS[.fff](Z|±HH:MM)`.
fn iso_seconds(value: &str) -> Option<i64> {
    let b = value.as_bytes();
    let num = |r: std::ops::Range<usize>| value.get(r)?.parse::<i64>().ok();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || b[13] != b':' {
        return None;
    }
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (hh, mm, ss) = (num(11..13)?, num(14..16)?, num(17..19)?);
    // Days from civil (Howard Hinnant), valid for the proleptic Gregorian calendar.
    let y2 = if m <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let mut secs = days * 86_400 + hh * 3_600 + mm * 60 + ss;
    let tail = &value[19..];
    let tail = tail.trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
    if let Some(sign) = tail.chars().next().filter(|c| *c == '+' || *c == '-') {
        let oh = tail.get(1..3)?.parse::<i64>().ok()?;
        let om = tail
            .get(4..6)
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(0);
        let offset = oh * 3_600 + om * 60;
        secs -= if sign == '+' { offset } else { -offset };
    }
    Some(secs)
}
/// "刚刚" / "12 分钟前" / "5 小时前" / "3 天 4 小时前"; empty when unknown.
pub fn relative_time(value: &str, now: i64) -> String {
    let Some(then) = iso_seconds(value) else {
        return String::new();
    };
    let ago = (now - then).max(0);
    let (days, hours, minutes) = (ago / 86_400, ago % 86_400 / 3_600, ago % 3_600 / 60);
    match (days, hours, minutes) {
        (0, 0, 0) => "刚刚".into(),
        (0, 0, m) => format!("{m} 分钟前"),
        (0, h, _) => format!("{h} 小时前"),
        (d, 0, _) => format!("{d} 天前"),
        (d, h, _) => format!("{d} 天 {h} 小时前"),
    }
}
fn human_size(bytes: u64) -> String {
    match bytes {
        b if b >= 1 << 30 => format!("{:.1} GB", b as f64 / (1u64 << 30) as f64),
        b if b >= 1 << 20 => format!("{:.1} MB", b as f64 / (1u64 << 20) as f64),
        b if b >= 1 << 10 => format!("{} KB", b >> 10),
        b => format!("{b} B"),
    }
}
fn library_lines(
    a: &App,
    w: usize,
    height: usize,
    hits: &mut Vec<(usize, PopupAction)>,
) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let mut out = vec![search_line(a, "输入以搜索素材或资料集")];
    let (assets, sets) = (
        items(&a.library, "assets").len(),
        items(&a.library, "sets").len(),
    );
    let tab = |label: String, on: bool| {
        Span::styled(format!(" {label} "), if on { t.selected } else { t.muted })
    };
    out.push(Line::from(vec![
        Span::raw(" "),
        tab(format!("素材 {assets}"), !a.library_sets),
        Span::raw(" "),
        tab(format!("资料集 {sets}"), a.library_sets),
        Span::styled("   Tab 切换", t.muted),
    ]));
    hits.push((out.len() + 2, PopupAction::LibraryManage));
    out.push(line(
        " [管理资料库] · F2 新建资料集、导入和管理文件",
        t.accent,
    ));
    if a.library.is_null() {
        out.push(line(" 正在读取资料库…", t.muted));
        return out;
    }
    let list = a.drawer_items();
    if list.is_empty() {
        out.push(line(
            match (a.search.is_empty(), a.library_sets) {
                (false, _) => " 没有匹配项",
                (true, false) => " 资料库里还没有素材；点击管理资料库导入",
                (true, true) => " 还没有资料集；点击管理资料库创建",
            },
            t.muted,
        ));
    }
    // Two trailing rows: a spacer and the key hint.
    let budget = height.saturating_sub(out.len() + 2).max(1);
    let selected = a.selected % list.len().max(1);
    let start = selected
        .saturating_sub(budget / 2)
        .min(list.len().saturating_sub(budget));
    let now = now_secs();
    for (i, item) in list.iter().enumerate().skip(start).take(budget) {
        let right = if a.library_sets {
            format!(
                "{} 份 · {}",
                item["count"].as_u64().unwrap_or(0),
                relative_time(text(item, "updated_at"), now)
            )
        } else {
            let kind = if text(item, "kind") == "image" {
                "图片"
            } else {
                "文件"
            };
            format!(
                "{kind} · {} · {}",
                human_size(item["size"].as_u64().unwrap_or(0)),
                relative_time(text(item, "last_used_at"), now)
            )
        };
        let chosen = i == selected;
        let marker = if chosen { glyph(a, "›", ">") } else { " " };
        let room = w.saturating_sub(width(&right, a.ambiguous_width) + 7);
        let name = truncate(text(item, "name"), room, a.ambiguous_width);
        let gap = w
            .saturating_sub(width(&name, a.ambiguous_width) + width(&right, a.ambiguous_width) + 5);
        hits.push((out.len() + 2, PopupAction::Item(i)));
        out.push(selection_line(
            &format!(" {marker} {name}{}{right}", " ".repeat(gap.max(2))),
            w,
            a,
            if chosen { t.selected } else { Style::default() },
        ));
    }
    out.push(Line::default());
    out.push(line(
        if a.library_sets {
            glyph(
                a,
                " Enter 查看文件 · 学习与创作请用 /gui · Esc 关闭",
                " Enter 查看文件 : 学习与创作请用 /gui : Esc 关闭",
            )
        } else {
            glyph(
                a,
                " Enter 加入草稿附件 · Delete 删除 · 学习与创作请用 /gui",
                " Enter 加入草稿附件 : Delete 删除 : 学习与创作请用 /gui",
            )
        },
        t.muted,
    ));
    out
}
fn effort_lines(a: &App, w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let mut out = vec![];
    let Some(model) = a.current_model_value() else {
        out.push(line(" 尚未选择模型；先用 /model 选择", t.warn));
        return out;
    };
    let efforts = items(&model, "efforts");
    out.push(line(format!(" 模型 {}", text(&model, "id")), t.muted));
    out.push(Line::default());
    if efforts.is_empty() {
        out.push(line(" 当前模型不支持调整思考强度", t.warn));
    }
    let current = text(&a.snapshot["session"], "effort");
    let selected = a.effort_index % efforts.len().max(1);
    for (i, effort) in efforts.iter().enumerate() {
        let value = effort.as_str().unwrap_or("");
        let marker = if i == selected {
            glyph(a, "›", ">")
        } else {
            " "
        };
        let now = if value == current { "  当前" } else { "" };
        out.push(selection_line(
            &format!(
                " {marker} {}{}{now}",
                effort_label(value),
                " ".repeat(6usize.saturating_sub(width(effort_label(value), a.ambiguous_width)))
            ),
            w,
            a,
            if i == selected {
                t.selected
            } else if a.thinking {
                Style::default()
            } else {
                t.muted
            },
        ));
    }
    out.push(Line::default());
    out.push(Line::from(vec![
        Span::styled(" 思考 ", t.muted),
        Span::styled(
            if a.thinking {
                format!("{} 开启", glyph(a, "◉", "(*)"))
            } else {
                format!("{} 关闭", glyph(a, "○", "( )"))
            },
            if a.thinking { t.accent } else { t.muted },
        ),
    ]));
    out.push(line(
        glyph(
            a,
            "[应用] ↑/↓ 选择 · space 开关思考 · Enter 应用",
            "[应用] up/down 选择 : space 开关思考 : Enter 应用",
        ),
        t.muted,
    ));
    out
}
fn render_pet(f: &mut Frame, a: &App, area: Rect) {
    let terminal_height = f.area().height;
    if !pet_visible(a, area.width, terminal_height) || area.height < 6 {
        return;
    }
    let now = Instant::now();
    let frame = &a.pet.art.frames[a.pet.frame(now)];
    let Some(rect) = pet_rect(a, f.area().width, terminal_height) else {
        return;
    };
    let (source_w, source_h) = a.pet.art.dimensions();
    for y in 0..rect.height {
        let top = (y as usize * 2 * source_h / (rect.height as usize * 2)).min(source_h - 1);
        let bottom =
            ((y as usize * 2 + 1) * source_h / (rect.height as usize * 2)).min(source_h - 1);
        for x in 0..rect.width {
            let color = |c: char| -> Option<Color> {
                let hex = a.pet.art.palette.get(&c)?.as_str();
                let value = u32::from_str_radix(&hex[1..], 16).ok()?;
                let (r, g, b) = ((value >> 16) as u8, (value >> 8) as u8, value as u8);
                if a.truecolor {
                    Some(Color::Rgb(r, g, b))
                } else {
                    Some(Color::Indexed(nearest_xterm(r, g, b)))
                }
            };
            let source_x = x as usize * source_w / rect.width as usize;
            let up = color(frame[top].as_bytes()[source_x] as char);
            let down = color(frame[bottom].as_bytes()[source_x] as char);
            let mut style = Style::default();
            let symbol = match (up, down) {
                (Some(u), Some(d)) => {
                    style = style.fg(u).bg(d);
                    "▀"
                }
                (Some(u), None) => {
                    style = style.fg(u);
                    "▀"
                }
                (None, Some(d)) => {
                    style = style.fg(d);
                    "▄"
                }
                _ => " ",
            };
            let xx = rect.x + x;
            let yy = rect.y + y;
            if area.contains((xx, yy).into()) {
                f.buffer_mut()[(xx, yy)].set_symbol(symbol).set_style(style);
            }
        }
    }
    let quote = a.pet.quote(now);
    if !quote.is_empty() {
        if crate::presentation::hero(a, area.width as usize, terminal_height) {
            f.render_widget(
                paragraph(a, truncate(quote, 40, a.ambiguous_width)).style(Theme::new(a).accent),
                Rect::new(
                    area.x + 2,
                    rect.bottom() + 1,
                    40.min(area.width.saturating_sub(2)),
                    1,
                ),
            );
            return;
        }
        let end = area.x + area.width - 24;
        let qw = width(quote, 1) as u16;
        if end >= qw {
            f.render_widget(
                paragraph(a, quote).style(Theme::new(a).accent),
                Rect::new(end - qw, area.y + 5, qw, 1),
            );
        }
    }
}
fn nearest_xterm(r: u8, g: u8, b: u8) -> u8 {
    let mut best = (u32::MAX, 16);
    for n in 16..=255u16 {
        let (rr, gg, bb) = if n < 232 {
            let i = n - 16;
            let steps = [0, 95, 135, 175, 215, 255];
            (
                steps[(i / 36) as usize],
                steps[((i / 6) % 6) as usize],
                steps[(i % 6) as usize],
            )
        } else {
            let gray = 8 + (n - 232) * 10;
            (gray, gray, gray)
        };
        let dist = (i32::from(r) - i32::from(rr)).pow(2)
            + (i32::from(g) - i32::from(gg)).pow(2)
            + (i32::from(b) - i32::from(bb)).pow(2);
        if (dist as u32) < best.0 {
            best = (dist as u32, n as u8);
        }
    }
    best.1
}
fn full_view(f: &mut Frame, a: &App, area: Rect) {
    if a.view == View::Agents
        && a.agent_detail_id.is_none()
        && crate::swarm::enabled(area.width, area.height)
    {
        crate::swarm::draw(f, a, area);
        return;
    }
    let dot = glyph(a, "·", ":");
    let t = Theme::new(a);
    if a.reviewing_proposed_write() {
        let approval = &a.snapshot["approvals"][0];
        let mut lines = vec![
            pair(
                glyph(a, " 拟写入差异 · 尚未执行", " 拟写入差异 : 尚未执行").into(),
                glyph(a, "q 返回 · ctrl+y 批准", "q 返回 : ctrl+y 批准").into(),
                area.width as usize,
                a,
                t.warn,
                t.muted,
            ),
            line(glyph(a, "─", "-").repeat(area.width as usize), t.muted),
        ];
        lines.extend(
            diff_lines(a, approval, area.width as usize)
                .into_iter()
                .skip(a.scroll as usize),
        );
        f.render_widget(paragraph(a, lines), area);
        return;
    }
    let mut lines = vec![
        pair(
            format!(
                " {}",
                if a.view == View::Changes {
                    "改动"
                } else {
                    "任务树"
                }
            ),
            glyph(a, "j/k 选择 · q / esc 返回", "j/k 选择 : q / esc 返回").into(),
            area.width as usize,
            a,
            Style::default(),
            t.muted,
        ),
        line(glyph(a, "─", "-").repeat(area.width as usize), t.muted),
    ];
    if a.view == View::Agents {
        let agents = items(&a.snapshot, "agents");
        if let Some(id) = &a.agent_detail_id {
            if let Some(agent) = agents.iter().find(|v| text(v, "id") == id) {
                lines[0] = pair(
                    format!(" {} {dot} 记录", text(agent, "name")),
                    glyph(a, "pgup/pgdn 滚动 · q 返回", "pgup/pgdn 滚动 : q 返回").into(),
                    area.width as usize,
                    a,
                    t.accent,
                    t.muted,
                );
                let mut body = wrap(
                    text(agent, "task"),
                    area.width as usize,
                    a,
                    "",
                    Style::default(),
                );
                body.extend(wrap(
                    text(agent, "output"),
                    area.width as usize,
                    a,
                    "",
                    Style::default(),
                ));
                lines.extend(body.into_iter().skip(a.scroll as usize));
            }
        } else {
            let available = area.height.saturating_sub(3) as usize;
            let selected = a.selected % agents.len().max(1);
            let start = selected.saturating_sub(available.saturating_sub(1));
            for (i, agent) in agents.iter().enumerate().skip(start).take(available) {
                lines.push(line(
                    format!(
                        " {} {}{} {}  {}  {}  {}",
                        if i == selected {
                            glyph(a, "›", ">")
                        } else {
                            " "
                        },
                        agent_tree_prefix(agents, i, a.ascii || a.ambiguous_width == 2),
                        state_icon(a, text(agent, "status")),
                        text(agent, "name"),
                        text(agent, "model"),
                        text(agent, "activity"),
                        duration(&agent["elapsed_ms"])
                    ),
                    state_style(t, text(agent, "status")),
                ));
            }
            while lines.len() < area.height.saturating_sub(1) as usize {
                lines.push(Line::default());
            }
            lines.push(line(
                glyph(
                    a,
                    " enter 查看记录 · m 补充要求 · x 停止助手",
                    " enter 查看记录 : m 补充要求 : x 停止助手",
                ),
                t.muted,
            ));
        }
        f.render_widget(paragraph(a, lines), area);
        return;
    }
    let changes = items(&a.snapshot, "changes");
    let selected = a.selected % changes.len().max(1);
    if area.width >= 100 {
        f.render_widget(
            paragraph(a, lines),
            Rect::new(area.x, area.y, area.width, 2),
        );
        let list_area = Rect::new(area.x, area.y + 2, 28, area.height.saturating_sub(2));
        let file_lines = changes
            .iter()
            .enumerate()
            .skip(selected.saturating_sub(list_area.height.saturating_sub(1) as usize))
            .take(list_area.height as usize)
            .map(|(i, c)| {
                line(
                    format!(
                        " {} {} {}",
                        if i == selected {
                            glyph(a, "›", ">")
                        } else {
                            " "
                        },
                        text(c, "kind"),
                        middle(text(c, "path"), 20, a)
                    ),
                    if i == selected { t.accent } else { t.muted },
                )
            })
            .collect::<Vec<_>>();
        f.render_widget(paragraph(a, file_lines), list_area);
        for y in area.y + 2..area.bottom() {
            f.render_widget(
                paragraph(a, glyph(a, "│", "|")).style(t.muted),
                Rect::new(area.x + 28, y, 1, 1),
            );
        }
        if let Some(c) = changes.get(selected) {
            let mut diff = vec![line(text(c, "path").to_owned(), t.accent)];
            diff.extend(diff_lines(a, c, area.width.saturating_sub(30) as usize));
            f.render_widget(
                paragraph(a, diff).scroll((a.scroll, 0)),
                Rect::new(
                    area.x + 30,
                    area.y + 2,
                    area.width.saturating_sub(30),
                    area.height.saturating_sub(2),
                ),
            );
        }
    } else {
        for (i, c) in changes
            .iter()
            .enumerate()
            .skip(selected.saturating_sub(4))
            .take(5)
        {
            lines.push(line(
                format!(
                    " {} {} {} +{} -{}",
                    if i == selected {
                        glyph(a, "›", ">")
                    } else {
                        " "
                    },
                    text(c, "kind"),
                    middle(text(c, "path"), area.width.saturating_sub(19) as usize, a),
                    c["added"],
                    c["removed"]
                ),
                if i == selected { t.accent } else { t.muted },
            ));
        }
        lines.push(line(
            glyph(a, "─", "-").repeat(area.width as usize),
            t.muted,
        ));
        if let Some(c) = changes.get(selected) {
            lines.extend(
                diff_lines(a, c, area.width as usize)
                    .into_iter()
                    .skip(a.scroll as usize),
            );
        }
        f.render_widget(paragraph(a, lines), area);
    }
}
fn code_background(a: &App) -> Style {
    if a.no_color {
        return Style::default();
    }
    user_message_style(a)
}
fn shade_code_rows(a: &App, rows: &mut [Line<'static>], w: usize, style: Style) {
    for row in rows {
        row.style = row.style.patch(style);
        let used = row
            .spans
            .iter()
            .map(|s| width(&s.content, a.ambiguous_width))
            .sum::<usize>();
        for span in &mut row.spans {
            span.style = style.patch(span.style);
            if let Some(bg) = style.bg {
                span.style = span.style.bg(bg);
            }
        }
        row.spans
            .push(Span::styled(" ".repeat(w.saturating_sub(used)), style));
    }
}
fn diff_row_lines(
    a: &App,
    row: &crate::diff_view::DiffRow,
    w: usize,
    language: &str,
) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    if !matches!(row.kind, '+' | '-' | ' ') {
        return wrap(&row.text, w, a, "    ", t.muted);
    }
    let old = row.old.map(|n| n.to_string()).unwrap_or_default();
    let new = row.new.map(|n| n.to_string()).unwrap_or_default();
    let prefix = if w >= 60 {
        format!(" {old:>5} {new:>5} {} ", row.kind)
    } else {
        format!(
            " {:>5} {} ",
            if row.kind == '-' { &old } else { &new },
            row.kind
        )
    };
    let mut style = match row.kind {
        '+' => t.good,
        '-' => t.bad,
        _ => Style::default(),
    };
    if !a.no_color {
        style = style.bg(if a.truecolor {
            match (row.kind, a.light) {
                ('+', true) => Color::Rgb(224, 248, 229),
                ('+', false) => Color::Rgb(24, 53, 36),
                ('-', true) => Color::Rgb(253, 231, 232),
                ('-', false) => Color::Rgb(59, 30, 34),
                _ => code_background(a).bg.unwrap_or(Color::Reset),
            }
        } else {
            match row.kind {
                '+' => Color::Green,
                '-' => Color::Red,
                _ => Color::Reset,
            }
        });
        if !a.truecolor && matches!(row.kind, '+' | '-') {
            style = style.fg(Color::White);
        }
    }
    let body = clean(&row.text);
    let styled = if row.kind == ' ' {
        code_tokens(a, &body, language)
    } else {
        body.chars().map(|c| (c, style)).collect()
    };
    let mut rows = styled_lines(
        a,
        styled,
        w,
        prefix.clone(),
        " ".repeat(width(&prefix, a.ambiguous_width)),
        t.muted,
    );
    shade_code_rows(a, &mut rows, w, style);
    rows
}
fn diff_lines(a: &App, c: &Value, w: usize) -> Vec<Line<'static>> {
    let language = crate::diff_view::language(text(c, "path"));
    crate::diff_view::rows(c)
        .iter()
        .flat_map(|row| diff_row_lines(a, row, w, language))
        .collect()
}
fn diff_body(a: &App, w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let mut body = wrap(text(&a.diff_detail, "path"), w, a, "", t.accent);
    body.push(line(
        truncate(
            "旧行 / 新行 · ↑↓逐行 · ←→翻页 · 右侧滑条可拖动",
            w,
            a.ambiguous_width,
        ),
        t.muted,
    ));
    body.extend(diff_lines(a, &a.diff_detail, w));
    body
}
fn diff_card(a: &App, c: &Value, w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let verb = match text(c, "kind") {
        "A" => "已新建",
        "D" => "已删除",
        _ => "已修改",
    };
    let added = c["added"]
        .as_u64()
        .map(|n| format!(" +{n}"))
        .unwrap_or_default();
    let removed = c["removed"]
        .as_u64()
        .map(|n| format!(" -{n}"))
        .unwrap_or_default();
    let path = middle(
        text(c, "path"),
        w.saturating_sub(18 + added.len() + removed.len()),
        a,
    );
    let mut result = vec![Line::from(vec![
        Span::styled(format!("    {verb} {path}"), t.accent),
        Span::styled(added, t.good),
        Span::styled(removed, t.bad),
    ])];
    let rows = crate::diff_view::rows(c);
    let first = rows
        .iter()
        .position(|r| matches!(r.kind, '+' | '-'))
        .unwrap_or(0);
    let language = crate::diff_view::language(text(c, "path"));
    let preview: Vec<_> = rows
        .iter()
        .skip(first)
        .take(3)
        .flat_map(|row| diff_row_lines(a, row, w, language))
        .take(3)
        .collect();
    if preview.is_empty() {
        result.push(line("    暂无文本差异", t.muted));
    } else {
        result.extend(preview);
    }
    result.push(line("    + 查看完整差异", t.muted));
    result
}
fn usage_lines(a: &App, w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let data = &a.usage_detail;
    let u = &data["usage"];
    let mut out = vec![];
    let cost = if let Some(v) = u["cost"].as_f64() {
        format!("{v:.4} {}", text(u, "currency"))
    } else {
        "暂无法计算".into()
    };
    let badge = if u["cost"].is_null() {
        "缺少用量或定价"
    } else if u["estimated"] == true {
        "估算费用"
    } else {
        "提供商报告"
    };
    out.push(line(
        format!("  {cost}"),
        t.accent.add_modifier(Modifier::BOLD),
    ));
    out.push(line(
        format!(
            "  {badge}{}",
            if u["complete"] == false && !u["cost"].is_null() {
                " · 仅包含已知部分"
            } else {
                ""
            }
        ),
        t.muted,
    ));
    out.push(Line::default());
    for (label, key) in [
        ("输入 Token", "input"),
        ("输出 Token", "output"),
        ("缓存命中 Token", "cached"),
    ] {
        out.push(pair(
            format!("  {label}"),
            u[key]
                .as_u64()
                .map(|n| format!("{n}  ({})", compact_tokens(&u[key])))
                .unwrap_or_else(|| "尚无数据".into()),
            w,
            a,
            t.muted,
            Style::default(),
        ));
    }
    out.push(Line::default());
    out.push(pair(
        "  请求次数".into(),
        u["requests"]
            .as_u64()
            .map(|n| n.to_string())
            .unwrap_or_else(|| "—".into()),
        w,
        a,
        t.muted,
        Style::default(),
    ));
    out
}

fn persistent_notice(a: &App) -> Option<&str> {
    if a.snapshot_stale {
        Some("状态更新失败，当前为旧快照")
    } else if !a.notice.is_empty() {
        Some(&a.notice)
    } else if a.unseen_output {
        Some("有新输出 · /latest 返回最新；阅读位置已保留")
    } else {
        a.config_warning.as_deref()
    }
}

pub fn draw(f: &mut Frame, a: &App) {
    // A folder is not shown in any form until it is trusted.
    if a.trust_prompt.is_some() || a.workspace_pending || a.startup_phase.is_some() {
        draw_gate(f, a);
        paint_skin(f, a);
        sync_wide_trailers(f);
        return;
    }
    draw_inner(f, a);
    let pinned_width = f
        .area()
        .width
        .saturating_sub(if a.sidebar && f.area().width >= 140 {
            44
        } else {
            0
        });
    if a.drawer.is_none() && a.form.is_none() {
        if show_pinned_user(a, pinned_width, f.area().height) {
            crate::presentation::draw_pinned_user(f, a, pinned_width);
        }
    }
    let area = f.area();
    if let Some(rect) = footer_at(a, area.width, area.height) {
        f.render_widget(paragraph(a, footer(a, area.width as usize)), rect);
    }
    if let Some(rect) = statistics_at(a, area.width, area.height) {
        f.render_widget(
            paragraph(a, footer_statistics(a, area.width as usize)),
            rect,
        );
    }
    if let Some(rect) = latest_button_rect(a, area.width, area.height) {
        f.render_widget(Clear, rect);
        f.render_widget(
            paragraph(
                a,
                if a.unseen_output {
                    " 有新内容 · 回到底部 (Ctrl+End) ↓ "
                } else {
                    " 回到底部 (Ctrl+End) ↓ "
                },
            )
            .style(Theme::new(a).accent.add_modifier(Modifier::REVERSED)),
            rect,
        );
    }
    draw_popup(f, a);
    if (a.form.is_some() || a.drawer.is_some() || a.question_popup_visible())
        && area.height >= 2
        && let Some(notice) = persistent_notice(a)
    {
        let layout = chat_layout(a, area.width as usize, area.height);
        let rect = Rect::new(
            area.x,
            area.height
                .saturating_sub(layout.bottom_h + layout.input_h + 1),
            area.width,
            1,
        );
        f.render_widget(Clear, rect);
        f.render_widget(
            paragraph(
                a,
                pair(
                    String::new(),
                    notice.into(),
                    area.width.saturating_sub(2) as usize,
                    a,
                    Theme::new(a).muted,
                    Theme::new(a).warn,
                ),
            )
            .style(Theme::new(a).warn),
            rect,
        );
    }
    paint_skin(f, a);
    sync_wide_trailers(f);
}
/// Terminals paint both columns of a wide glyph with the glyph's style. Mirror
/// that on the trailing cell, or ratatui later believes a recolored cell is
/// unchanged and leaves a stale colored block on screen.
fn sync_wide_trailers(f: &mut Frame) {
    let buffer = f.buffer_mut();
    let area = buffer.area;
    for y in area.y..area.bottom() {
        let mut x = area.x;
        while x < area.right() {
            let cell = &buffer[(x, y)];
            let width = match cell.diff_option {
                ratatui::buffer::CellDiffOption::ForcedWidth(w) => w.get(),
                ratatui::buffer::CellDiffOption::Skip => 1,
                _ => cell.symbol().width().max(1) as u16,
            };
            if width > 1 {
                let style = cell.style();
                for trailer in x + 1..(x + width).min(area.right()) {
                    buffer[(trailer, y)].set_style(style);
                }
            }
            x = x.saturating_add(width.max(1));
        }
    }
}
fn paint_skin(f: &mut Frame, a: &App) {
    if !a.no_color {
        let skin = crate::theme::effective_skin_colors(&a.skin, a.background.as_deref(), a.light);
        let background = a
            .background
            .as_deref()
            .and_then(crate::theme::parse_color)
            .or(skin.background);
        for cell in &mut f.buffer_mut().content {
            if cell.fg == Color::Reset
                && let Some(color) = skin.foreground
            {
                cell.set_fg(color);
            }
            if cell.bg == Color::Reset
                && let Some(color) = background
            {
                cell.set_bg(color);
            }
        }
    }
}

fn draw_startup(f: &mut Frame, a: &App) {
    let area = f.area();
    if area.width == 0 || area.height == 0 {
        return;
    }
    let t = Theme::new(a);
    let phase = a.startup_phase.unwrap_or(StartupPhase::Workspace);
    let (status, destination) = match phase {
        StartupPhase::Connecting => ("正在连接本地服务", "准备工作区"),
        StartupPhase::Workspace => ("正在准备工作区", "准备工作区"),
        StartupPhase::Session => ("正在恢复会话", "恢复会话"),
    };
    let active = format!("{} {status}", state_icon(a, "running"));
    if area.width < 30 || area.height < 15 {
        let mut rows = vec![line("EXPERT", t.accent.add_modifier(Modifier::BOLD))];
        rows.extend(wrap(&active, area.width as usize, a, "", t.accent));
        if area.height >= 5 {
            rows.push(Line::default());
            rows.push(line("Ctrl+C 退出", t.muted));
        }
        let h = (rows.len() as u16).min(area.height);
        f.render_widget(
            paragraph(a, rows),
            Rect::new(area.x, area.y + (area.height - h) / 2, area.width, h),
        );
        return;
    }
    let w = area.width.saturating_sub(4).min(64);
    let rect = Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - 13) / 2,
        w,
        13,
    );
    let inner = popup_inner(rect);
    let centered = |mut spans: Vec<Span<'static>>| {
        let used: usize = spans
            .iter()
            .map(|s| width(&s.content, a.ambiguous_width))
            .sum();
        spans.insert(
            0,
            Span::raw(" ".repeat((inner.width as usize).saturating_sub(used) / 2)),
        );
        Line::from(spans)
    };
    let second_stage = phase != StartupPhase::Connecting;
    let stages = if inner.width >= 32 {
        centered(vec![
            Span::styled(
                format!(
                    "{} 连接服务",
                    if second_stage {
                        glyph(a, "✓", "v")
                    } else {
                        glyph(a, "●", "*")
                    }
                ),
                if second_stage { t.muted } else { t.accent },
            ),
            Span::styled(format!("   {}   ", glyph(a, "·", ":")), t.muted),
            Span::styled(
                format!(
                    "{} {destination}",
                    if second_stage {
                        glyph(a, "●", "*")
                    } else {
                        glyph(a, "○", "o")
                    }
                ),
                if second_stage { t.accent } else { t.muted },
            ),
        ])
    } else {
        Line::default()
    };
    let rows = vec![
        centered(vec![Span::styled(
            "E X P E R T",
            t.accent.add_modifier(Modifier::BOLD),
        )]),
        centered(vec![Span::styled("你的 AI 工作空间", t.muted)]),
        Line::default(),
        centered(vec![Span::styled(active, t.accent)]),
        centered(vec![Span::styled("就绪后自动进入", t.muted)]),
        Line::default(),
        stages,
        Line::default(),
        centered(vec![Span::styled("Ctrl+C 退出", t.muted)]),
    ];
    let mut block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(t.accent.add_modifier(Modifier::DIM));
    if a.ascii || a.ambiguous_width == 2 {
        block = block.border_set(ratatui::symbols::border::Set {
            top_left: "+",
            top_right: "+",
            bottom_left: "+",
            bottom_right: "+",
            vertical_left: "|",
            vertical_right: "|",
            horizontal_top: "-",
            horizontal_bottom: "-",
        });
    }
    f.render_widget(block, rect);
    f.render_widget(paragraph(a, rows), inner);
}

/// Trust screen for a first-visit folder, or the startup card while it is checked.
fn draw_gate(f: &mut Frame, a: &App) {
    let t = Theme::new(a);
    let area = f.area();
    let Some(path) = &a.trust_prompt else {
        draw_startup(f, a);
        return;
    };
    let w = area.width.saturating_sub(4).min(76);
    let inner = w.saturating_sub(6) as usize;
    let mut rows = vec![
        line("是否信任此文件夹？", t.accent.add_modifier(Modifier::BOLD)),
        Line::default(),
    ];
    // The full path is the thing being trusted, so it wraps instead of truncating.
    let mut chunk = String::new();
    for c in display_path(path).chars() {
        if width(&chunk, a.ambiguous_width) + width(&c.to_string(), a.ambiguous_width)
            > inner.max(1)
        {
            rows.push(line(
                std::mem::take(&mut chunk),
                Style::default().add_modifier(Modifier::BOLD),
            ));
        }
        chunk.push(c);
    }
    rows.push(line(chunk, Style::default().add_modifier(Modifier::BOLD)));
    rows.push(Line::default());
    rows.extend(wrap(
        "Expert 会读取这个文件夹中的文件；选择读写后，在你批准的前提下还可能修改文件、运行命令。请只信任你了解来源的项目。",
        inner,
        a,
        "",
        t.muted,
    ));
    rows.push(Line::default());
    for (i, choice) in crate::trust::TRUST_CHOICES.iter().enumerate() {
        let chosen = i == a.trust_choice;
        let marker = if chosen { glyph(a, "›", ">") } else { " " };
        rows.push(selection_line(
            &format!("{marker} {}. {choice}", i + 1),
            inner,
            a,
            if chosen { t.selected } else { Style::default() },
        ));
    }
    rows.push(Line::default());
    rows.extend(wrap(
        glyph(
            a,
            "↑/↓ 选择 · 1-3 快速选择 · Enter 确认 · Esc 退出",
            "up/down 选择 : 1-3 快速选择 : Enter 确认 : Esc 退出",
        ),
        inner,
        a,
        "",
        t.muted,
    ));
    if !a.notice.is_empty() {
        rows.push(Line::default());
        rows.extend(wrap(&a.notice, inner, a, "", t.warn));
    }
    let h = (rows.len() as u16 + 4).min(area.height);
    let rect = Rect::new(
        area.x + area.width.saturating_sub(w) / 2,
        area.y + area.height.saturating_sub(h) / 2,
        w,
        h,
    );
    let mut block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(t.accent);
    if a.ascii || a.ambiguous_width == 2 {
        block = block.border_set(ratatui::symbols::border::Set {
            top_left: "+",
            top_right: "+",
            bottom_left: "+",
            bottom_right: "+",
            vertical_left: "|",
            vertical_right: "|",
            horizontal_top: "-",
            horizontal_bottom: "-",
        });
    }
    f.render_widget(block, rect);
    f.render_widget(paragraph(a, rows), popup_inner(rect));
}

struct ChatLayout {
    todo_h: u16,
    completion: Vec<String>,
    bottom_h: u16,
    input_h: u16,
    status_line: Option<Line<'static>>,
    queue_h: u16,
    notice_h: u16,
    persistent_notice: String,
    drawer: Vec<Line<'static>>,
    drawer_h: u16,
    record_h: u16,
    hint_h: u16,
}
fn chat_layout(a: &App, w: usize, height: u16) -> ChatLayout {
    let completion = a.completion();
    let footer_rows = if height >= 8 { 2 } else { 1 };
    let mut bottom_h = if completion.is_empty() {
        footer_rows
    } else {
        let usage = usize::from(w < 90 && height >= 12);
        (completion.len().min(8 - usage) + usage).min((height / 3) as usize) as u16 + footer_rows
    };
    let approval = a.status() == "approval" && !a.approval_collapsed && !a.rejection;
    let mut input_h = if approval {
        (approval_lines(a, w.saturating_sub(4)).len() as u16 + 2)
            .min(height.saturating_sub(3))
            .max(3)
    } else if a.paste_collapsed {
        3
    } else {
        let n = a
            .input
            .split('\n')
            .map(|s| {
                width(&clean(s), a.ambiguous_width)
                    .div_ceil(w.saturating_sub(5).max(1))
                    .max(1)
            })
            .sum::<usize>()
            .max(input_visual_position(a, w).0 + 1);
        (n as u16 + 2).min(if height < 16 { 3 } else { 8 })
    };
    let status_line = status(a, w);
    let status_h = u16::from(status_line.is_some());
    let queued = items(&a.snapshot, "queued");
    let queue_h = u16::from(!queued.is_empty());
    let persistent_notice = persistent_notice(a).unwrap_or("").to_owned();
    let notice_h = 0;
    let hint_h = u16::from(welcome(a) && height >= 12 && a.form.is_none() && a.drawer.is_none());
    // Long approval commands must leave room for every fixed row; otherwise
    // the composer moves down a row while mouse geometry still points above it.
    input_h = input_h
        .min(height.saturating_sub(status_h + queue_h + notice_h + hint_h + 1))
        .max(3);
    bottom_h = bottom_h.min(
        height
            .saturating_sub(input_h + status_h + queue_h + notice_h + hint_h)
            .max(1),
    );
    let drawer = vec![];
    let drawer_h = (drawer.len() as u16)
        .min(if height < 16 { 6 } else { 12 })
        .min(height / 2)
        .min(height.saturating_sub(bottom_h + input_h + status_h + queue_h + notice_h + hint_h));
    let fixed = bottom_h + input_h + status_h + queue_h + notice_h + drawer_h + hint_h;
    let todo_h = crate::todo::height(a, height.saturating_sub(fixed + 3));
    let fixed = fixed + todo_h;
    let record_h = height.saturating_sub(fixed);
    ChatLayout {
        todo_h,
        completion,
        bottom_h,
        input_h,
        status_line,
        queue_h,
        notice_h,
        persistent_notice,
        drawer,
        drawer_h,
        record_h,
        hint_h,
    }
}

/// Space reserved for the transcript/welcome graphics after composer, status,
/// completion menu and footers have claimed their rows.
pub(crate) fn welcome_graphics_height(a: &App, width: u16, height: u16) -> u16 {
    chat_layout(a, width as usize, height).record_h
}

/// Exact shared chat geometry keeps paging from overscrolling into empty history.
pub fn show_pinned_user(a: &App, width: u16, height: u16) -> bool {
    if height < 12 || a.view != View::Chat {
        return false;
    }
    let Some((id, _)) = crate::presentation::pinned_user(a) else {
        return false;
    };
    let w = width.saturating_sub(if a.sidebar && width >= 140 { 44 } else { 0 });
    let (rows, anchors, users, _, _) = record_layout(a, w as usize, height);
    let visible = chat_layout(a, width as usize, height).record_h as usize;
    let offset = anchored_offset(a, &anchors, rows.len().saturating_sub(visible));
    if offset == 0 {
        return false;
    }
    !users
        .iter()
        .any(|(user, range)| user == id && range.start < offset + visible && range.end > offset)
}

pub fn record_scroll_limit(a: &App, width: u16, height: u16) -> u16 {
    if height < 6 {
        return 0;
    }
    let layout = chat_layout(a, width as usize, height);
    let record_width = width.saturating_sub(if a.sidebar && width >= 140 { 44 } else { 0 });
    record(a, record_width as usize, height)
        .len()
        .saturating_sub(
            layout
                .record_h
                .saturating_sub(u16::from(show_pinned_user(a, width, height))) as usize,
        )
        .min(u16::MAX as usize) as u16
}

pub fn user_message_at(a: &App, width: u16, height: u16, x: u16, y: u16) -> Option<String> {
    if a.view != View::Chat
        || a.drawer.is_some()
        || a.form.is_some()
        || a.question_popup_visible()
        || a.trust_prompt.is_some()
        || a.workspace_pending
        || height < 6
    {
        return None;
    }
    let pin = u16::from(show_pinned_user(a, width, height));
    let y = y.checked_sub(pin)?;
    let record_h = chat_layout(a, width as usize, height)
        .record_h
        .saturating_sub(pin);
    let record_w = width.saturating_sub(if a.sidebar && width >= 140 { 44 } else { 0 });
    if x >= record_w || y >= record_h {
        return None;
    }
    let (rows, anchors, users, _, _) = record_layout(a, record_w as usize, height);
    let offset = anchored_offset(a, &anchors, rows.len().saturating_sub(record_h as usize));
    let row = offset + y as usize;
    users
        .into_iter()
        .find(|(_, range)| range.contains(&row))
        .map(|(id, _)| id)
        .filter(|id| !id.is_empty())
}

pub fn focus_message(a: &mut App, id: &str) {
    if !items(&a.snapshot, "messages")
        .iter()
        .any(|m| text(m, "id") == id)
    {
        return;
    }
    a.selection = None;
    a.view = View::Chat;
    a.drawer = None;
    a.reading_anchor = Some(crate::app::ReadingAnchor {
        message_id: Some(id.into()),
        line: 0,
    });
    a.scroll = 0;
    a.notice = "已定位到历史提问 · /latest 返回最新".into();
}
/// Repeated double-clicks walk back through the conversation's user turns.
pub fn jump_pinned_user(a: &mut App) {
    let Some((id, _)) = crate::presentation::pinned_user(a) else {
        return;
    };
    let id = id.to_owned();
    if a.reading_anchor
        .as_ref()
        .is_some_and(|anchor| anchor.message_id.as_deref() == Some(id.as_str()) && anchor.line == 0)
    {
        jump_user_turn(a, -1);
    } else {
        focus_message(a, &id);
    }
}
pub fn jump_user_turn(a: &mut App, direction: i32) {
    let Some((id, _)) = crate::presentation::pinned_user(a) else {
        return;
    };
    let turns: Vec<_> = items(&a.snapshot, "messages")
        .iter()
        .filter(|m| text(m, "role") == "user")
        .collect();
    let index = turns.iter().position(|m| text(m, "id") == id).unwrap_or(0);
    let next = index
        .saturating_add_signed(direction as isize)
        .min(turns.len().saturating_sub(1));
    let id = text(turns[next], "id").to_owned();
    focus_message(a, &id);
}
pub fn tool_record_at(a: &App, w: u16, h: u16, x: u16, y: u16) -> Option<String> {
    if a.view != View::Chat
        || a.form.is_some()
        || a.drawer.is_some()
        || a.question_popup_visible()
        || h < 8
    {
        return None;
    }
    let pin = u16::from(show_pinned_user(a, w, h));
    let y = y.checked_sub(pin)?;
    let height = chat_layout(a, w as usize, h).record_h.saturating_sub(pin);
    let width = w.saturating_sub(if a.sidebar && w >= 140 { 44 } else { 0 });
    if y >= height || x >= width {
        return None;
    }
    let (rows, anchors, _, tools, _) = record_layout(a, width as usize, h);
    let offset = anchored_offset(a, &anchors, rows.len().saturating_sub(height as usize));
    tools
        .into_iter()
        .find(|(_, r)| r.contains(&(offset + y as usize)))
        .map(|(id, _)| id)
}
pub fn diff_card_at(a: &App, w: u16, h: u16, x: u16, y: u16) -> Option<String> {
    if a.view != View::Chat
        || a.form.is_some()
        || a.drawer.is_some()
        || a.question_popup_visible()
        || h < 8
    {
        return None;
    }
    let pin = u16::from(show_pinned_user(a, w, h));
    let y = y.checked_sub(pin)?;
    let height = chat_layout(a, w as usize, h).record_h.saturating_sub(pin);
    let width = w.saturating_sub(if a.sidebar && w >= 140 { 44 } else { 0 });
    if y >= height || x >= width {
        return None;
    }
    let (rows, anchors, _, _, changes) = record_layout(a, width as usize, h);
    let offset = anchored_offset(a, &anchors, rows.len().saturating_sub(height as usize));
    changes
        .into_iter()
        .find(|(_, range)| range.contains(&(offset + y as usize)))
        .map(|(id, _)| id)
}

fn anchored_offset(a: &App, anchors: &[(String, usize)], limit: usize) -> usize {
    if let Some(anchor) = &a.reading_anchor {
        let start = anchor
            .message_id
            .as_ref()
            .and_then(|id| anchors.iter().find(|(m, _)| m == id).map(|(_, row)| *row));
        return start.unwrap_or(0).saturating_add(anchor.line).min(limit);
    }
    limit.saturating_sub(a.scroll as usize)
}

pub fn scroll_transcript(a: &mut App, lines: i32) {
    let (w, h) = a.viewport;
    let actual_w = w.saturating_sub(if a.sidebar && w >= 140 { 44 } else { 0 });
    let (rows, anchors, _, _, _) = record_layout(a, actual_w as usize, h);
    let limit = rows.len().saturating_sub(
        chat_layout(a, w as usize, h)
            .record_h
            .saturating_sub(u16::from(show_pinned_user(a, w, h))) as usize,
    );
    let current = anchored_offset(a, &anchors, limit);
    let target = current.saturating_add_signed(lines as isize).min(limit);
    a.scroll = limit.saturating_sub(target).min(u16::MAX as usize) as u16;
    if target == limit {
        a.reading_anchor = None;
        a.unseen_output = false;
    } else {
        let base = anchors.iter().rev().find(|(_, row)| *row <= target);
        a.reading_anchor = Some(crate::app::ReadingAnchor {
            message_id: base.map(|(id, _)| id.clone()),
            line: target.saturating_sub(base.map_or(0, |(_, row)| *row)),
        });
    }
}

pub fn find_transcript(a: &mut App, previous: bool) {
    if a.transcript_query.is_empty() {
        a.notice = "先输入 /find 关键词搜索会话正文".into();
        return;
    }
    let query = a.transcript_query.to_lowercase();
    let matches: Vec<String> = items(&a.snapshot, "messages")
        .iter()
        .filter(|m| text(m, "text").to_lowercase().contains(&query))
        .map(|m| text(m, "id").to_owned())
        .collect();
    if matches.is_empty() {
        a.notice = format!("未找到：{}", a.transcript_query);
        return;
    }
    let current = a
        .transcript_match
        .as_ref()
        .and_then(|id| matches.iter().position(|v| v == id));
    let i = match (current, previous) {
        (Some(i), true) => (i + matches.len() - 1) % matches.len(),
        (Some(i), false) => (i + 1) % matches.len(),
        (None, true) => matches.len() - 1,
        (None, false) => 0,
    };
    a.transcript_match = Some(matches[i].clone());
    a.reading_anchor = Some(crate::app::ReadingAnchor {
        message_id: Some(matches[i].clone()),
        line: 0,
    });
    a.view = View::Chat;
    a.drawer = None;
    a.notice = format!(
        "正文匹配 {}/{}：{} · /next /prev · /latest 返回最新",
        i + 1,
        matches.len(),
        a.transcript_query
    );
}

pub fn jump_transcript(a: &mut App, kind: &str) {
    if !matches!(kind, "user" | "failure") {
        a.notice = "用法：/jump user 或 /jump failure".into();
        return;
    }
    let messages = items(&a.snapshot, "messages");
    let before = a
        .reading_anchor
        .as_ref()
        .and_then(|anchor| anchor.message_id.as_ref())
        .and_then(|id| messages.iter().position(|m| text(m, "id") == id))
        .unwrap_or(messages.len());
    let target = messages
        .iter()
        .take(before)
        .rev()
        .find(|m| {
            if kind == "user" {
                text(m, "role") == "user"
            } else {
                items(&a.snapshot, "steps")
                    .iter()
                    .any(|s| s["message_id"] == m["id"] && text(s, "status") == "failed")
            }
        })
        .map(|m| text(m, "id").to_owned());
    if let Some(id) = target {
        a.reading_anchor = Some(crate::app::ReadingAnchor {
            message_id: Some(id),
            line: 0,
        });
        if kind == "failure" {
            a.expanded = true;
        }
        a.view = View::Chat;
        a.notice = "已定位 · /latest 返回最新".into();
    } else {
        a.notice = "前面没有对应记录".into();
    }
}

fn draw_inner(f: &mut Frame, a: &App) {
    let area = f.area();
    if area.width == 0 || area.height == 0 {
        return;
    }
    // On extremely short terminals preserve dangerous permissions before decorative chrome.
    if area.height < 6 {
        f.render_widget(
            paragraph(a, footer(a, area.width as usize)),
            Rect::new(area.x, area.bottom() - 1, area.width, 1),
        );
        if area.height > 1
            && let Some(status) = status(a, area.width as usize)
        {
            f.render_widget(
                paragraph(a, status),
                Rect::new(area.x, area.y, area.width, 1),
            );
        }
        return;
    }
    if a.view != View::Chat {
        let warning = persistent_notice(a);
        let warning_h = u16::from(warning.is_some());
        if area.height >= 3 + warning_h {
            full_view(
                f,
                a,
                Rect::new(area.x, area.y, area.width, area.height - 1 - warning_h),
            );
        }
        if let Some(warning) = warning {
            f.render_widget(
                paragraph(a, warning).style(Theme::new(a).warn),
                Rect::new(area.x, area.bottom() - 2, area.width, 1),
            );
        }
        f.render_widget(
            paragraph(a, footer(a, area.width as usize)),
            Rect::new(area.x, area.bottom() - 1, area.width, 1),
        );
        return;
    }
    let t = Theme::new(a);
    let w = area.width as usize;
    let ChatLayout {
        todo_h,
        completion,
        bottom_h,
        input_h,
        status_line,
        queue_h,
        notice_h,
        persistent_notice,
        drawer,
        drawer_h,
        record_h,
        hint_h,
    } = chat_layout(a, w, area.height);
    let queued = items(&a.snapshot, "queued");
    let danger =
        a.snapshot["session"]["permission"] == "full" || a.snapshot["session"]["mode"] == "plan";
    let approval = a.status() == "approval" && !a.approval_collapsed && !a.rejection;
    let mut main_area = Rect::new(area.x, area.y, area.width, record_h);
    if a.sidebar && area.width >= 140 {
        main_area.width = area.width - 44;
        let right = Rect::new(area.x + main_area.width, area.y, 44, record_h);
        let edge = glyph(a, "│", "|");
        let mut lines = vec![line(format!("{edge} 任务树"), t.muted)];
        let agents = items(&a.snapshot, "agents");
        for (index, agent) in agents.iter().enumerate() {
            lines.push(line(
                format!(
                    "{edge} {}{} {}",
                    agent_tree_prefix(agents, index, a.ascii || a.ambiguous_width == 2),
                    state_icon(a, text(agent, "status")),
                    text(agent, "name")
                ),
                t.muted,
            ));
        }
        lines.push(line(format!("{edge} 改动"), t.muted));
        for c in items(&a.snapshot, "changes") {
            lines.push(line(
                format!("{edge} {} {}", text(c, "kind"), text(c, "path")),
                t.muted,
            ));
        }
        f.render_widget(paragraph(a, lines), right);
    }
    let pin = u16::from(show_pinned_user(a, area.width, area.height));
    main_area.y += pin;
    main_area.height = main_area.height.saturating_sub(pin);
    let (rec, anchors, _, _, _) = record_layout(a, main_area.width as usize, area.height);
    let offset = if welcome(a) {
        a.scroll as usize
    } else {
        anchored_offset(
            a,
            &anchors,
            rec.len().saturating_sub(main_area.height as usize),
        )
    };
    f.render_widget(
        paragraph(a, rec.into_iter().skip(offset).collect::<Vec<_>>()),
        main_area,
    );
    if offset == 0 {
        render_pet(f, a, main_area);
    }
    let mut y = area.y + record_h;
    if todo_h > 0 {
        crate::todo::draw(f, a, Rect::new(area.x, y, area.width, todo_h));
        y += todo_h;
    }
    if hint_h > 0 {
        let hint = if w >= 64 {
            "/ 命令   @ 文件   ? 快捷键   shift+tab 计划模式"
        } else {
            "/ 命令  @ 文件  ? 帮助"
        };
        let hint = truncate(hint, w, a.ambiguous_width);
        let left = w.saturating_sub(width(&hint, a.ambiguous_width));
        f.render_widget(
            paragraph(a, format!("{}{hint}", " ".repeat(left))).style(t.muted),
            Rect::new(area.x, y, area.width, 1),
        );
        y += 1;
    }
    if drawer_h > 0 {
        f.render_widget(
            paragraph(a, drawer),
            Rect::new(area.x, y, area.width, drawer_h),
        );
        if let Some(form) = &a.form
            && form.editing
            && let Some(field) = form.fields.get(form.selected)
            && field.editable
        {
            let budget = (drawer_h as usize)
                .saturating_sub(3 + usize::from(!form.notice.is_empty()))
                .max(1);
            let start = form
                .selected
                .saturating_sub(budget / 2)
                .min(form.fields.len().saturating_sub(budget));
            let row = 2 + form.selected.saturating_sub(start);
            if row < drawer_h as usize {
                let label = truncate(
                    &field.label,
                    w.saturating_sub(8).min(24).min(w / 3),
                    a.ambiguous_width,
                );
                let value = if field.secret {
                    "*".repeat(field.value.chars().count().min(24))
                } else {
                    display_path(&field.value)
                };
                let value = middle(
                    &value,
                    w.saturating_sub(width(&label, a.ambiguous_width) + 5),
                    a,
                );
                let col =
                    3 + width(&label, a.ambiguous_width) + 2 + width(&value, a.ambiguous_width);
                f.set_cursor_position((
                    area.x + col.min(w.saturating_sub(1)) as u16,
                    y + row as u16,
                ));
            }
        }
        y += drawer_h;
    }
    if notice_h > 0 {
        f.render_widget(
            paragraph(a, truncate(&persistent_notice, w, a.ambiguous_width)).style(t.warn),
            Rect::new(area.x, y, area.width, 1),
        );
        y += 1;
    }
    if queue_h > 0 {
        let q = queued
            .iter()
            .map(|q| text(q, "text"))
            .collect::<Vec<_>>()
            .join("；");
        f.render_widget(
            paragraph(
                a,
                truncate(
                    &format!(
                        "  {} 已排队 · 工具边界后纳入上下文：{q}",
                        glyph(a, "↳", ">")
                    ),
                    w,
                    a.ambiguous_width,
                ),
            )
            .style(t.muted),
            Rect::new(area.x, y, area.width, 1),
        );
        y += 1;
    }
    if let Some(s) = status_line {
        f.render_widget(paragraph(a, s), Rect::new(area.x, y, area.width, 1));
        y += 1;
    }
    let input_area = Rect::new(
        area.x,
        y,
        area.width,
        input_h.min(area.bottom().saturating_sub(y)),
    );
    let border = if a.ascii || a.ambiguous_width == 2 {
        BorderType::Plain
    } else {
        BorderType::Rounded
    };
    let mut block = Block::default()
        .borders(Borders::ALL)
        .border_type(border)
        .border_style(if approval {
            t.warn
        } else if a.drawer.is_some() || a.form.is_some() {
            t.muted
        } else {
            t.accent
        });
    if a.ascii || a.ambiguous_width == 2 {
        block = block.border_set(ratatui::symbols::border::Set {
            top_left: "+",
            top_right: "+",
            bottom_left: "+",
            bottom_right: "+",
            vertical_left: "|",
            vertical_right: "|",
            horizontal_top: "-",
            horizontal_bottom: "-",
        });
    }
    if !a.attachments.is_empty() {
        let mut labels = a
            .attachments
            .iter()
            .map(|attachment| {
                let state = match text(attachment, "_state") {
                    "loading" => " 导入中…",
                    "error" => " 导入失败",
                    _ => "",
                };
                format!("{}{state}", text(attachment, "_tag"))
            })
            .collect::<Vec<_>>()
            .join(" ");
        if width(&labels, a.ambiguous_width) > w.saturating_sub(4) {
            labels = labels.replace("] [", "][");
        }
        block = block.title(format!(" {labels} "));
    }
    if approval {
        block = block.padding(Padding::horizontal(1));
    }
    let inner = block.inner(input_area);
    if approval {
        let p = &a.snapshot["approvals"][0];
        let block = block.title(format!(
            " {} · ←→ 选择 · Enter 确认 ",
            clean(text(p, "tool"))
        ));
        f.render_widget(block, input_area);
        let mut lines = approval_lines(a, inner.width as usize);
        let actions = crate::approval_controls::rows(a, inner.width as usize).0;
        if lines.len() > inner.height as usize {
            lines.truncate((inner.height as usize).saturating_sub(actions.len()));
            lines.extend(actions);
        }
        f.render_widget(paragraph(a, lines), inner);
    } else {
        f.render_widget(block, input_area);
        let content = if a.input.is_empty() {
            if a.rejection {
                "填写拒绝理由".to_string()
            } else if items(&a.snapshot, "models").is_empty() {
                "先登录模型，或用 !命令直接执行".to_string()
            } else if a.active() {
                "输入补充要求，下一轮发送".to_string()
            } else {
                "描述任务；Alt+J 换行；/ 命令，@ 文件，! 执行".to_string()
            }
        } else if a.paste_collapsed {
            format!(
                "[文本 · {} 行 · {} 字]",
                a.input.lines().count().max(1),
                a.input.chars().count()
            )
        } else {
            a.input.clone()
        };
        let lines = wrap(
            &content,
            inner.width as usize,
            a,
            &format!(" {} ", glyph(a, "›", ">")),
            if a.input.is_empty() {
                t.muted
            } else {
                Style::default()
            },
        );
        let (row, col) = input_visual_position(a, w);
        let offset = row.saturating_sub(inner.height.saturating_sub(1) as usize);
        f.render_widget(
            paragraph(a, lines)
                .style(input_surface(a))
                .scroll((offset as u16, 0)),
            inner,
        );
        if a.drawer.is_none() && a.form.is_none() && inner.width > 3 && inner.height > 0 {
            f.set_cursor_position((
                inner.x + (col as u16 + 3).min(inner.width - 1),
                inner.y + row.saturating_sub(offset) as u16,
            ));
        }
    }
    y += input_area.height;
    if y < area.bottom() {
        if completion.is_empty() {
            f.render_widget(
                paragraph(a, footer(a, w)),
                Rect::new(area.x, y, area.width, 1),
            );
        } else {
            let completion_h = bottom_h.saturating_sub(if area.height >= 8 { 2 } else { 1 });
            let usage_h = u16::from(w < 90 && completion_h >= 2);
            let menu_h = completion_h.saturating_sub(usage_h);
            let selected = a.selected % completion.len();
            let start = (selected / completion.len().min(menu_h as usize).max(1))
                * completion.len().min(menu_h as usize).max(1);
            let mut lines = completion
                .iter()
                .enumerate()
                .skip(start)
                .take(menu_h as usize)
                .map(|(i, c)| {
                    let (description, usage) = crate::app::command_metadata(c);
                    let chosen = i == a.selected % completion.len();
                    let base = if chosen { t.selected } else { Style::default() };
                    // Aligned columns only where the description still fits beside them.
                    let name = if w >= 60 {
                        format!("    {c:<14}")
                    } else {
                        format!("    {c} ")
                    };
                    // Usage that only repeats the command name adds noise.
                    let args = usage.strip_prefix(c.as_str()).unwrap_or(usage).trim();
                    let mut spans = vec![Span::styled(name.clone(), base.patch(t.accent))];
                    let mut used = width(&name, a.ambiguous_width);
                    if !description.is_empty() {
                        let room = w.saturating_sub(used + 1);
                        let d = truncate(&format!(" {description}"), room, a.ambiguous_width);
                        used += width(&d, a.ambiguous_width);
                        spans.push(Span::styled(
                            d,
                            if chosen { base } else { Style::default() },
                        ));
                    }
                    if w >= 90 && !args.is_empty() {
                        let room = w.saturating_sub(used + 2);
                        let u = truncate(&format!("  {args}"), room, a.ambiguous_width);
                        used += width(&u, a.ambiguous_width);
                        spans.push(Span::styled(
                            u,
                            base.patch(t.muted).remove_modifier(Modifier::BOLD),
                        ));
                    }
                    spans.push(Span::styled(" ".repeat(w.saturating_sub(used)), base));
                    Line::from(spans)
                })
                .collect::<Vec<_>>();
            if usage_h > 0 {
                while lines.len() < menu_h as usize {
                    lines.push(Line::default());
                }
                let (_, usage) = crate::app::command_metadata(&completion[selected]);
                lines.push(selection_line(&format!("    用法 {usage}"), w, a, t.muted));
            }
            f.render_widget(
                paragraph(a, lines),
                Rect::new(area.x, y, area.width, bottom_h),
            );
            if danger && y + completion_h < area.bottom() {
                f.render_widget(
                    paragraph(a, footer(a, w)),
                    Rect::new(area.x, y + completion_h, area.width, 1),
                );
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileLink {
    pub area: Rect,
    pub path: String,
}

/// Associate only complete visible paths with file objects. URI construction and
/// canonical authorization remain the backend's responsibility; truncated paths
/// and arbitrary Markdown/query text never become guessed destinations.
pub fn file_links_from_buffer(a: &App, buffer: &ratatui::buffer::Buffer) -> Vec<FileLink> {
    let session = &a.snapshot["session"];
    if session["remote"] == true
        || session["workspace_remote"] == true
        || text(session, "workspace_path").starts_with("ssh:")
    {
        return vec![];
    }
    let mut paths = std::collections::BTreeSet::new();
    for c in items(&a.snapshot, "changes") {
        paths.insert(text(c, "path"));
    }
    for step in items(&a.snapshot, "steps") {
        if matches!(text(step, "verb"), "读取" | "编辑" | "新建" | "删除") {
            paths.insert(text(step, "object"));
        }
    }
    let boundary = |c: char| c.is_whitespace() || c == '│' || c == '|';
    let mut candidates: std::collections::HashMap<&str, Vec<&str>> =
        std::collections::HashMap::new();
    for path in paths {
        if path.is_empty() || path.contains(['\n', '\r', '\x1b']) {
            continue;
        }
        if let Some(first) = path.split(boundary).next() {
            candidates.entry(first).or_default().push(path);
        }
    }
    let mut out = vec![];
    // Walk visible cells once instead of rescanning the screen per historical path.
    for y in buffer.area.y..buffer.area.bottom() {
        let mut row = String::new();
        let mut offsets = vec![];
        let mut skip = 0;
        for x in buffer.area.x..buffer.area.right() {
            if skip > 0 {
                skip -= 1;
                continue;
            }
            if buffer[(x, y)].diff_option == ratatui::buffer::CellDiffOption::Skip {
                continue;
            }
            let symbol = buffer[(x, y)].symbol();
            offsets.push((row.len(), x));
            row.push_str(symbol);
            skip = width(symbol, a.ambiguous_width).saturating_sub(1);
        }
        for (byte, x) in offsets {
            if byte > 0
                && row[..byte]
                    .chars()
                    .next_back()
                    .is_some_and(|c| !boundary(c))
            {
                continue;
            }
            let rest = &row[byte..];
            let first = rest.split(boundary).next().unwrap_or("");
            if let Some(paths) = candidates.get(first) {
                for path in paths {
                    if !rest.starts_with(path)
                        || rest[path.len()..]
                            .chars()
                            .next()
                            .is_some_and(|c| !boundary(c))
                    {
                        continue;
                    }
                    let w = width(path, a.ambiguous_width) as u16;
                    if x + w <= buffer.area.right() {
                        out.push(FileLink {
                            area: Rect::new(x, y, w, 1),
                            path: (*path).to_owned(),
                        });
                    }
                }
            }
        }
    }
    out
}

pub fn buffer_text(buffer: &ratatui::buffer::Buffer) -> String {
    let mut result = String::new();
    for y in buffer.area.y..buffer.area.bottom() {
        let mut row = String::new();
        let mut skip = 0;
        for x in buffer.area.x..buffer.area.right() {
            if skip > 0 {
                skip -= 1;
                continue;
            }
            if buffer[(x, y)].diff_option == ratatui::buffer::CellDiffOption::Skip {
                continue;
            }
            let symbol = buffer[(x, y)].symbol();
            row.push_str(symbol);
            skip = match buffer[(x, y)].diff_option {
                ratatui::buffer::CellDiffOption::ForcedWidth(w) => {
                    usize::from(w.get()).saturating_sub(1)
                }
                _ => symbol.width().saturating_sub(1),
            };
        }
        result.push_str(row.trim_end());
        result.push('\n');
    }
    result
}

fn step_lines(a: &App, w: usize, steps: &[&Value], finished: bool) -> Vec<Line<'static>> {
    if steps.is_empty() {
        return vec![];
    }
    let t = Theme::new(a);
    let dot = glyph(a, "·", ":");
    let done = steps.iter().filter(|s| text(s, "status") == "done").count();
    let failed = steps
        .iter()
        .filter(|s| text(s, "status") == "failed" && !crate::tool_view::skipped(s))
        .count();
    let skipped = steps
        .iter()
        .filter(|s| crate::tool_view::skipped(s))
        .count();
    let active = steps
        .iter()
        .filter(|s| matches!(text(s, "status"), "running" | "approval"))
        .count();
    let commands = steps.iter().filter(|s| text(s, "verb") == "运行").count();
    let mut summary = if finished && failed == 0 && skipped == 0 {
        if commands == steps.len() {
            format!("    已运行 {commands} 条命令")
        } else {
            format!("    已完成 {done} 次工具调用")
        }
    } else {
        format!("    工具进展 {dot} {done}/{} 步完成", steps.len())
    };
    if active > 0 {
        summary.push_str(&format!(
            " {dot} {active} {}",
            if a.status() == "approval" {
                "等待批准"
            } else {
                "进行中"
            }
        ));
    }
    if failed > 0 {
        summary.push_str(&format!(" {dot} {failed} 失败"));
    }
    if skipped > 0 {
        summary.push_str(&format!(" {dot} {skipped} 跳过"));
    }
    let mut out = vec![pair(
        summary,
        "[查看记录]".into(),
        w,
        a,
        if failed > 0 { t.warn } else { t.muted },
        t.accent,
    )];
    if !finished || a.expanded || failed > 0 {
        let mut indices: Vec<usize> = steps
            .iter()
            .enumerate()
            .filter(|(_, s)| {
                text(s, "status") == "failed" && !crate::tool_view::skipped(s)
                    || matches!(text(s, "status"), "running" | "approval")
            })
            .map(|(i, _)| i)
            .rev()
            .take(3)
            .collect();
        for i in (0..steps.len()).rev() {
            if indices.len() >= 3 {
                break;
            }
            if !indices.contains(&i) {
                indices.push(i);
            }
        }
        indices.sort_unstable();
        for i in indices {
            let step = steps[i];
            let skipped = crate::tool_view::skipped(step);
            let status = if skipped {
                "skipped"
            } else if a.status() == "approval" && text(step, "status") == "running" {
                "approval"
            } else {
                text(step, "status")
            };
            let verb = if skipped {
                "跳过"
            } else {
                text(step, "verb")
            };
            let marker = if skipped { "-" } else { state_icon(a, status) };
            let object = text(step, "object")
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            let label = format!(
                "      {marker} {verb}  {}",
                truncate(&object, w.saturating_sub(26).min(64), a.ambiguous_width)
            );
            let meta = if skipped {
                "未执行".into()
            } else if let Some(code) = step["exit_code"].as_i64() {
                format!("退出码 {code}")
            } else if status == "running" {
                duration(&step["elapsed_ms"])
            } else {
                String::new()
            };
            out.push(pair(
                label,
                meta,
                w,
                a,
                if skipped {
                    t.muted
                } else {
                    state_style(t, status)
                },
                t.muted,
            ));
            if matches!(status, "failed" | "running") {
                let keep = if status == "failed" { 3 } else { 2 };
                let tail = items(step, "tail")
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>();
                for row in tail.iter().skip(tail.len().saturating_sub(keep)) {
                    out.extend(wrap(
                        row,
                        w,
                        a,
                        &format!("    {} ", glyph(a, "│", "|")),
                        t.muted,
                    ));
                }
            }
        }
    }
    out
}

/// Display-only normalization; actual workspace and tool targets stay untouched.
pub fn display_path(path: &str) -> String {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else {
        path.strip_prefix(r"\\?\").unwrap_or(path).to_owned()
    }
}
fn startup_date(a: &App) -> String {
    let provided = text(&a.snapshot["startup"], "date");
    if !provided.is_empty() {
        return provided.to_owned();
    }
    crate::theme::local_date()
}
fn welcome_sessions(a: &App) -> Vec<Value> {
    a.recent_sessions()
}

fn welcome_content(
    a: &App,
    w: usize,
    h: u16,
    recent: bool,
) -> (Vec<Line<'static>>, Vec<(usize, String)>) {
    let t = Theme::new(a);
    let session = &a.snapshot["session"];
    let startup = &a.snapshot["startup"];
    let mut out = vec![];
    let mut hits = vec![];
    let card_w = if pet_visible(a, w as u16, h) {
        w.saturating_sub(24)
    } else {
        w
    };
    let inside = card_w.saturating_sub(2);
    let version = text(startup, "version");
    let title = truncate(
        &format!(
            " expert{} {} ",
            if version.is_empty() {
                String::new()
            } else {
                format!(" v{version}")
            },
            startup_date(a)
        ),
        inside.saturating_sub(1),
        a.ambiguous_width,
    );
    out.push(line(
        format!(
            "{}{}{}{}",
            glyph(a, "╭", "+"),
            title,
            glyph(a, "─", "-").repeat(inside.saturating_sub(width(&title, a.ambiguous_width))),
            glyph(a, "╮", "+")
        ),
        t.accent,
    ));
    let model = items(&a.snapshot, "models")
        .iter()
        .find(|m| crate::app::current_model(m, session));
    let category = model
        .map(|m| text(m, "source"))
        .filter(|v| !v.is_empty())
        .unwrap_or("未选择来源");
    let path = text(session, "workspace_path");
    let path = if path.is_empty() {
        text(startup, "workspace_path")
    } else {
        path
    };
    for (index, mut value) in [
        format!(" 类别 {category}"),
        format!(
            " 模型 {}",
            if text(session, "model").is_empty() {
                "尚未选择"
            } else {
                text(session, "model")
            }
        ),
        format!(" 目录 {}", display_path(path)),
    ]
    .into_iter()
    .enumerate()
    {
        if index == 0 {
            let id = text(session, "id");
            let short = if id.is_empty() {
                "待建立".to_owned()
            } else {
                id.chars().take(8).collect::<String>()
            };
            let label = format!("Session {short}");
            let start = 32.min(inside.saturating_sub(width(&label, a.ambiguous_width)));
            let prefix = truncate(&value, start.saturating_sub(2), a.ambiguous_width);
            value = format!(
                "{prefix}{}{label}",
                " ".repeat(start.saturating_sub(width(&prefix, a.ambiguous_width)))
            );
        }
        let value = middle(&value, inside, a);
        let pad = inside.saturating_sub(width(&value, a.ambiguous_width));
        let body = format!("{value}{}", " ".repeat(pad));
        // " 类别 " style labels are three columns plus a space.
        let split = body.char_indices().nth(3).map_or(body.len(), |(i, _)| i);
        let (label, rest) = body.split_at(split);
        let mut row = vec![
            Span::styled(glyph(a, "│", "|"), t.accent),
            Span::styled(label.to_owned(), t.muted),
        ];
        match rest.rfind("Session ") {
            Some(at) => {
                row.push(Span::raw(rest[..at].to_owned()));
                row.push(Span::styled(rest[at..].to_owned(), t.muted));
            }
            None => row.push(Span::raw(rest.to_owned())),
        }
        row.push(Span::styled(glyph(a, "│", "|"), t.accent));
        out.push(Line::from(row));
    }
    out.push(line(
        format!(
            "{}{}{}",
            glyph(a, "╰", "+"),
            glyph(a, "─", "-").repeat(inside),
            glyph(a, "╯", "+")
        ),
        t.accent,
    ));
    if recent && crate::presentation::hero(a, w, h) {
        out = crate::presentation::hero_lines(a, w, h);
    }
    if let Some(warning) = &a.config_warning {
        out.extend(wrap(warning, w, a, " ! ", t.warn));
    }
    for issue in items(startup, "issues") {
        out.extend(wrap(
            issue.as_str().unwrap_or("启动问题"),
            w,
            a,
            " ! ",
            t.warn,
        ));
    }
    if recent && items(&a.snapshot, "models").is_empty() {
        out.extend(wrap(
            "还没有可用模型：/login 登录，/model 添加来源",
            w,
            a,
            " ",
            t.warn,
        ));
    }
    if recent {
        let sessions = welcome_sessions(a);
        if !sessions.is_empty() {
            out.push(Line::default());
            let panel = w.saturating_sub(4).clamp(1, 72);
            let left = w.saturating_sub(panel) / 2;
            let title = if a.recent_confirm.is_some() {
                "确认进入此会话？Enter 继续 · Esc 取消"
            } else {
                "最近会话 · ↑/↓ 选择 · Enter 确认"
            };
            out.push(line(
                format!(
                    "{}{}",
                    " ".repeat(left),
                    truncate(title, panel, a.ambiguous_width)
                ),
                t.muted,
            ));
            for (index, item) in sessions.iter().enumerate() {
                let focused = a.recent_selected == Some(index);
                let marker = if focused {
                    glyph(a, "›", ">")
                } else if text(item, "status") == "running" {
                    glyph(a, "●", "*")
                } else {
                    glyph(a, "○", "o")
                };
                let state = status_label(text(item, "status"));
                let title = match text(item, "title") {
                    "" => "未命名会话",
                    title => title,
                };
                let value = if w < 60 {
                    format!(" {marker} {title}")
                } else {
                    format!(" {marker} {title}  {state}")
                };
                hits.push((out.len(), text(item, "id").to_owned()));
                let mut row = vec![Span::raw(" ".repeat(left))];
                row.extend(
                    selection_line(
                        &value,
                        panel,
                        a,
                        if focused {
                            t.selected
                        } else {
                            Style::default()
                        },
                    )
                    .spans,
                );
                out.push(Line::from(row));
            }
        }
    }
    (out, hits)
}
fn welcome_record(a: &App, w: usize, h: u16, recent: bool) -> Vec<Line<'static>> {
    welcome_content(a, w, h, recent).0
}

pub fn recent_session_rects(a: &App, width: u16, height: u16) -> Vec<(Rect, String)> {
    if a.view != View::Chat || !welcome(a) || a.drawer.is_some() || a.form.is_some() {
        return vec![];
    }
    let w = width.saturating_sub(if a.sidebar && width >= 140 { 44 } else { 0 });
    let (_, hits) = welcome_content(a, w as usize, height, true);
    let record_h = chat_layout(a, width as usize, height).record_h;
    let panel = w.saturating_sub(4).min(72);
    let left = w.saturating_sub(panel) / 2;
    hits.into_iter()
        .filter_map(|(row, id)| {
            let y = row.checked_sub(a.scroll as usize)?;
            if y < record_h as usize {
                Some((Rect::new(left, y as u16, panel, 1), id))
            } else {
                None
            }
        })
        .collect()
}

fn effort_label(s: &str) -> &str {
    match s {
        "low" => "低",
        "medium" => "中",
        "high" => "高",
        "xhigh" => "极高",
        "max" => "最大",
        _ => s,
    }
}
fn approval_lines(a: &App, w: usize) -> Vec<Line<'static>> {
    let dot = glyph(a, "·", ":");
    let t = Theme::new(a);
    let p = &a.snapshot["approvals"][0];
    let args = text(p, "arguments");
    let display = serde_json::from_str::<Value>(args)
        .ok()
        .and_then(|v| v["command"].as_str().map(str::to_owned))
        .unwrap_or_else(|| args.to_owned());
    let mut lines = wrap(&display, w, a, "", Style::default());
    lines.extend(wrap(
        &format!(
            "目录 {} {dot} 原因 {}",
            text(p, "target"),
            text(p, "reason")
        ),
        w,
        a,
        "",
        t.muted,
    ));
    for d in items(p, "diff").iter().take(8) {
        lines.extend(wrap(d.as_str().unwrap_or(""), w, a, "", t.muted));
    }
    lines.push(Line::default());
    lines.extend(crate::approval_controls::rows(a, w).0);
    lines
}
fn inline_markdown(a: &App, value: &str, base: Style) -> Vec<(char, Style)> {
    let t = Theme::new(a);
    let mut out = vec![];
    let mut i = 0;
    while i < value.len() {
        let rest = &value[i..];
        if let Some(escaped) = rest.strip_prefix('\\')
            && let Some(c) = escaped.chars().next()
            && r"\`*_{}[]()#+-.!>|".contains(c)
        {
            out.push((c, base));
            i += 1 + c.len_utf8();
            continue;
        }
        let mut consumed = false;
        for marker in ["**", "__", "~~", "`"] {
            if let Some(after) = rest.strip_prefix(marker)
                && let Some(close) = after.find(marker)
                && close > 0
            {
                let inside = &after[..close];
                let style = if marker == "`" {
                    base.patch(t.accent)
                } else if marker == "~~" {
                    base.add_modifier(Modifier::CROSSED_OUT)
                } else {
                    base.add_modifier(Modifier::BOLD)
                };
                if marker == "`" {
                    out.extend(inside.chars().map(|c| (c, style)));
                } else {
                    out.extend(inline_markdown(a, inside, style));
                }
                i += marker.len() * 2 + close;
                consumed = true;
                break;
            }
        }
        if consumed {
            continue;
        }
        if rest.starts_with('[')
            && let Some(label_end) = rest.find("](")
        {
            let target_start = label_end + 2;
            // Balance parentheses in destinations; leave malformed links verbatim.
            let mut depth = 1usize;
            let mut end = None;
            for (j, c) in rest[target_start..].char_indices() {
                if c == '(' {
                    depth += 1;
                } else if c == ')' {
                    depth -= 1;
                    if depth == 0 {
                        end = Some(target_start + j);
                        break;
                    }
                }
            }
            if let Some(end) = end {
                out.extend(inline_markdown(
                    a,
                    &rest[1..label_end],
                    base.patch(t.accent),
                ));
                out.extend(
                    format!(" ({})", &rest[target_start..end])
                        .chars()
                        .map(|c| (c, base.patch(t.accent))),
                );
                i += end + 1;
                continue;
            }
        }
        let c = rest.chars().next().unwrap();
        out.push((c, base));
        i += c.len_utf8();
    }
    out
}
pub(crate) fn code_tokens(a: &App, value: &str, language: &str) -> Vec<(char, Style)> {
    let colors = crate::theme::code_colors(&a.code_style, a.light);
    let styled = |color| {
        if a.no_color {
            Style::default()
        } else {
            Style::default().fg(color)
        }
    };
    let language = language.to_ascii_lowercase();
    let keywords: &[&str] = match language.as_str() {
        "rs" | "rust" => &[
            "fn", "pub", "let", "mut", "use", "impl", "struct", "enum", "trait", "match", "self",
            "Self", "where", "async", "await", "move", "mod", "crate", "super", "const", "return",
            "if", "else", "for", "while", "loop", "in", "true", "false",
        ],
        "py" | "python" => &[
            "def", "class", "import", "from", "as", "if", "elif", "else", "for", "while", "in",
            "is", "not", "and", "or", "return", "yield", "with", "lambda", "try", "except",
            "finally", "pass", "None", "True", "False", "async", "await",
        ],
        "js" | "javascript" | "ts" | "typescript" | "jsx" | "tsx" => &[
            "function",
            "const",
            "let",
            "var",
            "class",
            "interface",
            "type",
            "export",
            "import",
            "from",
            "return",
            "if",
            "else",
            "for",
            "of",
            "in",
            "new",
            "this",
            "async",
            "await",
            "throw",
            "try",
            "catch",
            "true",
            "false",
            "null",
            "undefined",
        ],
        "dart" => &[
            "class",
            "final",
            "const",
            "var",
            "void",
            "int",
            "double",
            "String",
            "bool",
            "return",
            "if",
            "else",
            "for",
            "in",
            "new",
            "this",
            "extends",
            "implements",
            "import",
            "async",
            "await",
            "true",
            "false",
            "null",
            "required",
            "late",
        ],
        "c" | "cpp" | "c++" | "h" | "java" | "cs" | "csharp" => &[
            "int", "char", "float", "double", "void", "bool", "class", "struct", "enum", "public",
            "private", "static", "const", "return", "if", "else", "for", "while", "switch", "case",
            "break", "continue", "new", "this", "true", "false", "null", "nullptr", "include",
            "define",
        ],
        "sql" => &[
            "SELECT", "FROM", "WHERE", "JOIN", "ON", "AS", "INSERT", "INTO", "VALUES", "UPDATE",
            "SET", "DELETE", "CREATE", "TABLE", "GROUP", "BY", "ORDER", "LIMIT", "NULL", "AND",
            "OR", "select", "from", "where", "join", "on", "as", "insert", "into", "values",
        ],
        "sh" | "bash" | "shell" | "zsh" => &[
            "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "case", "esac",
            "function", "export", "local", "echo", "return", "exit",
        ],
        "json" | "yaml" | "yml" => &["true", "false", "null"],
        _ => &[],
    };
    let comment = if matches!(
        language.as_str(),
        "py" | "python" | "sh" | "bash" | "shell" | "yaml" | "yml" | "ruby"
    ) {
        Some("#")
    } else if language == "sql" {
        Some("--")
    } else if matches!(
        language.as_str(),
        "rs" | "rust"
            | "js"
            | "javascript"
            | "ts"
            | "typescript"
            | "jsx"
            | "tsx"
            | "c"
            | "cpp"
            | "c++"
            | "java"
            | "cs"
            | "dart"
    ) {
        Some("//")
    } else {
        None
    };
    let mut out = vec![];
    let mut i = 0;
    while i < value.len() {
        let rest = &value[i..];
        let c = rest.chars().next().unwrap();
        if comment.is_some_and(|marker| rest.starts_with(marker)) {
            out.extend(rest.chars().map(|c| (c, styled(colors.comment))));
            break;
        }
        if c == '\"'
            || c == '\''
            || (c == '`' && matches!(language.as_str(), "js" | "javascript" | "ts" | "typescript"))
        {
            let quote = c;
            let mut escaped = false;
            let mut end = c.len_utf8();
            for ch in rest[c.len_utf8()..].chars() {
                end += ch.len_utf8();
                if ch == quote && !escaped {
                    break;
                }
                if ch == '\\' {
                    escaped = !escaped;
                } else {
                    escaped = false;
                }
            }
            out.extend(rest[..end].chars().map(|c| (c, styled(colors.string))));
            i += end;
            continue;
        }
        if c.is_ascii_digit() {
            let end = rest
                .char_indices()
                .find(|(_, c)| !c.is_ascii_alphanumeric() && !matches!(c, '.' | '_'))
                .map_or(rest.len(), |(i, _)| i);
            out.extend(rest[..end].chars().map(|c| (c, styled(colors.number))));
            i += end;
            continue;
        }
        if c.is_alphabetic() || c == '_' {
            let end = rest
                .char_indices()
                .find(|(_, c)| !c.is_alphanumeric() && *c != '_')
                .map_or(rest.len(), |(i, _)| i);
            let word = &rest[..end];
            let style = if keywords.contains(&word) {
                styled(colors.keyword)
            } else {
                Style::default()
            };
            out.extend(word.chars().map(|c| (c, style)));
            i += end;
            continue;
        }
        out.push((
            c,
            if c.is_ascii_punctuation() {
                styled(colors.punctuation)
            } else {
                Style::default()
            },
        ));
        i += c.len_utf8();
    }
    out
}
fn styled_lines(
    a: &App,
    styled: Vec<(char, Style)>,
    w: usize,
    prefix: String,
    continuation: String,
    prefix_style: Style,
) -> Vec<Line<'static>> {
    let mut out = vec![];
    let mut spans = vec![Span::styled(prefix.clone(), prefix_style)];
    let mut col = width(&prefix, a.ambiguous_width);
    for (c, style) in styled {
        let cw = width(&c.to_string(), a.ambiguous_width);
        if col + cw > w && col > width(&continuation, a.ambiguous_width) {
            out.push(Line::from(std::mem::take(&mut spans)));
            col = width(&continuation, a.ambiguous_width);
            spans.push(Span::styled(continuation.clone(), prefix_style));
        }
        spans.push(Span::styled(c.to_string(), style));
        col += cw;
    }
    out.push(Line::from(spans));
    out
}
fn message_lines(a: &App, content: &str, user: bool, w: usize) -> Vec<Line<'static>> {
    use std::hash::{Hash, Hasher};
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    content.hash(&mut hash);
    user.hash(&mut hash);
    w.hash(&mut hash);
    (
        a.ascii,
        a.no_color,
        a.truecolor,
        a.color256,
        a.light,
        a.ambiguous_width,
    )
        .hash(&mut hash);
    (&a.skin, &a.background, &a.accent, &a.code_style).hash(&mut hash);
    let key = hash.finish();
    if let Some(lines) = MESSAGE_LAYOUT_CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        let position = cache
            .iter()
            .position(|entry| entry.0 == key && entry.1 == content)?;
        let entry = cache.remove(position)?;
        let lines = entry.2.clone();
        cache.push_back(entry);
        Some(lines)
    }) {
        return lines;
    }
    let lines = render_message_lines(a, content, user, w);
    let size = content.len()
        + lines
            .iter()
            .map(|line| {
                line.spans
                    .iter()
                    .map(|s| s.content.len() + 64)
                    .sum::<usize>()
                    + 64
            })
            .sum::<usize>();
    if size <= 2 * 1024 * 1024 {
        MESSAGE_LAYOUT_CACHE.with(|cache| {
            let mut cache = cache.borrow_mut();
            while cache.len() >= 2048
                || cache.iter().map(|entry| entry.3).sum::<usize>() + size > 32 * 1024 * 1024
            {
                cache.pop_front();
            }
            cache.push_back((key, content.to_owned(), lines.clone(), size));
        });
    }
    lines
}
type CachedMessageLayout = (u64, String, Vec<Line<'static>>, usize);
thread_local! {
    static MESSAGE_LAYOUT_CACHE: std::cell::RefCell<std::collections::VecDeque<CachedMessageLayout>>=
        const {std::cell::RefCell::new(std::collections::VecDeque::new())};
}
fn render_message_lines(a: &App, content: &str, user: bool, w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let text_width = if user {
        w
    } else {
        w.saturating_sub(2).min(102)
    };
    let content = clean(content);
    let raws: Vec<&str> = content.split('\n').collect();
    let mut out = vec![];
    let mut fence: Option<(char, usize, String)> = None;
    let mut index = 0;
    let mut code_line = 0usize;
    while index < raws.len() {
        let raw = raws[index];
        index += 1;
        let trim = raw.trim_start();
        {
            if let Some((mark, length, _)) = &fence {
                if trim.chars().take_while(|c| c == mark).count() >= *length
                    && trim.trim_matches(*mark).trim().is_empty()
                {
                    fence = None;
                    continue;
                }
            } else {
                let marker = trim.chars().next().unwrap_or(' ');
                let count = trim.chars().take_while(|c| *c == marker).count();
                if matches!(marker, '`' | '~') && count >= 3 && raw.len() - trim.len() <= 3 {
                    let language = trim[count..]
                        .split_whitespace()
                        .next()
                        .unwrap_or("")
                        .to_owned();
                    let label = if language.is_empty() {
                        "代码"
                    } else {
                        &language
                    };
                    let mut heading = vec![line(format!("    {label}"), t.accent)];
                    shade_code_rows(a, &mut heading, w, code_background(a));
                    out.extend(heading);
                    code_line = 0;
                    fence = Some((marker, count, language));
                    continue;
                }
            }
        }
        if let Some((_, _, language)) = &fence {
            code_line += 1;
            let prefix = format!(" {code_line:>4} {} ", glyph(a, "│", "|"));
            let continuation = " ".repeat(width(&prefix, a.ambiguous_width));
            let mut rows = styled_lines(
                a,
                code_tokens(a, raw, language),
                w,
                prefix,
                continuation,
                t.muted,
            );
            shade_code_rows(a, &mut rows, w, code_background(a));
            out.extend(rows);
            continue;
        }
        if !user
            && raw.contains('|')
            && index < raws.len()
            && table_separator(raws[index], table_cells(raw).len())
        {
            let mut rows = vec![raw, raws[index]];
            index += 1;
            while index < raws.len() && raws[index].contains('|') && !raws[index].trim().is_empty()
            {
                rows.push(raws[index]);
                index += 1;
            }
            out.extend(table_lines(a, &rows, w.saturating_sub(2)));
            continue;
        }
        let mut body = raw.to_owned();
        let mut base = Style::default();
        let mut quote = false;
        let indent = body.len() - body.trim_start_matches([' ', '\t']).len();
        if !user {
            let heading = trim.chars().take_while(|c| *c == '#').count();
            if heading > 0 && heading <= 6 && trim[heading..].starts_with(' ') {
                body = trim[heading..].trim_start().to_owned();
                base = t.accent.add_modifier(Modifier::BOLD);
            } else if let Some(value) = trim.strip_prefix('>') {
                body = format!(
                    "{}{} {}",
                    " ".repeat(indent),
                    glyph(a, "│", "|"),
                    value.trim_start()
                );
                base = t.muted;
                quote = true;
            } else if let Some(value) = trim
                .strip_prefix("- ")
                .or_else(|| trim.strip_prefix("* "))
                .or_else(|| trim.strip_prefix("+ "))
            {
                body = format!("{}{} {value}", " ".repeat(indent), glyph(a, "•", "*"));
            }
        }
        let prefix = if out.is_empty() {
            format!(
                "{} ",
                if user {
                    glyph(a, "›", ">")
                } else {
                    glyph(a, "◈", "*")
                }
            )
        } else {
            "  ".to_owned()
        };
        let continuation = format!(
            "  {}",
            if quote {
                format!("{} ", glyph(a, "│", "|"))
            } else {
                " ".repeat(indent)
            }
        );
        let styled = if user {
            body.chars().map(|c| (c, base)).collect()
        } else {
            inline_markdown(a, &body, base)
        };
        out.extend(styled_lines(
            a,
            styled,
            text_width,
            prefix,
            continuation,
            if quote { t.muted } else { t.accent },
        ));
    }
    out
}
fn table_cells(row: &str) -> Vec<String> {
    let trimmed = row.trim();
    let inner = trimmed.strip_prefix('|').unwrap_or(trimmed);
    let inner = inner.strip_suffix('|').unwrap_or(inner);
    let mut cells = vec![];
    let mut value = String::new();
    let mut escaped = false;
    let mut code = false;
    for c in inner.chars() {
        if escaped {
            value.push('\\');
            value.push(c);
            escaped = false;
            continue;
        }
        if c == '\\' {
            escaped = true;
            continue;
        }
        if c == '`' {
            code = !code;
            value.push(c);
            continue;
        }
        if c == '|' && !code {
            cells.push(value.trim().to_owned());
            value.clear();
        } else {
            value.push(c);
        }
    }
    if escaped {
        value.push('\\');
    }
    cells.push(value.trim().to_owned());
    cells
}
fn table_separator(row: &str, columns: usize) -> bool {
    let cells = table_cells(row);
    cells.len() == columns
        && cells.iter().all(|cell| {
            let rule = cell.trim().trim_matches(':');
            !rule.is_empty() && rule.chars().all(|c| c == '-')
        })
}
fn table_lines(a: &App, rows: &[&str], w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let parsed: Vec<Vec<String>> = rows
        .iter()
        .enumerate()
        .filter(|(index, _)| *index != 1)
        .map(|(_, r)| table_cells(r))
        .collect();
    let cols = parsed.iter().map(Vec::len).max().unwrap_or(1).max(1);
    let plain = |value: &str| {
        inline_markdown(a, value, Style::default())
            .iter()
            .map(|(c, _)| *c)
            .collect::<String>()
    };
    let ideal: Vec<usize> = (0..cols)
        .map(|i| {
            parsed
                .iter()
                .map(|row| {
                    row.get(i)
                        .map_or(0, |c| width(&plain(c), a.ambiguous_width))
                })
                .max()
                .unwrap_or(0)
                .max(2)
        })
        .collect();
    let available = w.saturating_sub(cols * 3 + 3);
    // Only fall back when even two display cells per column cannot fit.
    if available < cols * 2 {
        let mut out = vec![];
        let headers = parsed.first();
        for (row_index, row) in parsed.iter().enumerate().skip(1) {
            out.push(line(format!("  [{}]", row_index), t.muted));
            for (i, cell) in row.iter().enumerate() {
                let label = headers
                    .and_then(|r| r.get(i))
                    .map(|s| plain(s))
                    .unwrap_or_else(|| format!("{}", i + 1));
                let styled = inline_markdown(a, &format!("{label}: {cell}"), Style::default());
                out.extend(styled_lines(
                    a,
                    styled,
                    w,
                    "  ".into(),
                    "  ".into(),
                    t.muted,
                ));
            }
        }
        if parsed.len() == 1 {
            for cell in &parsed[0] {
                out.extend(styled_lines(
                    a,
                    inline_markdown(a, cell, Style::default()),
                    w,
                    "  ".into(),
                    "  ".into(),
                    t.muted,
                ));
            }
        }
        return out;
    }
    let mut widths: Vec<usize> = ideal.iter().map(|n| (*n).min(available / cols)).collect();
    let mut remaining = available.saturating_sub(widths.iter().sum());
    while remaining > 0 {
        let mut changed = false;
        for (size, desired) in widths.iter_mut().zip(&ideal) {
            if *size < *desired && remaining > 0 {
                *size += 1;
                remaining -= 1;
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    let rule = |left: &str, join: &str, right: &str| {
        format!(
            "  {left}{}{right}",
            widths
                .iter()
                .map(|w| glyph(a, "─", "-").repeat(w + 2))
                .collect::<Vec<_>>()
                .join(join)
        )
    };
    let mut out = vec![line(
        rule(glyph(a, "┌", "+"), glyph(a, "┬", "+"), glyph(a, "┐", "+")),
        t.muted,
    )];
    for (row_index, row) in parsed.iter().enumerate() {
        let mut cells = Vec::new();
        for (i, cell_w) in widths.iter().enumerate() {
            let value = row.get(i).map_or("", String::as_str);
            let styled = inline_markdown(
                a,
                value,
                if row_index == 0 {
                    Style::default().add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                },
            );
            cells.push(styled_lines(
                a,
                styled,
                *cell_w,
                String::new(),
                String::new(),
                t.muted,
            ));
        }
        for line_index in 0..cells.iter().map(Vec::len).max().unwrap_or(1) {
            let mut spans = vec![Span::raw("  "), Span::styled(glyph(a, "│", "|"), t.muted)];
            for (cell, cell_w) in cells.iter().zip(&widths) {
                let row = cell.get(line_index).cloned().unwrap_or_default();
                let content: String = row.spans.iter().map(|s| s.content.as_ref()).collect();
                let used = width(&content, a.ambiguous_width);
                spans.push(Span::raw(" "));
                spans.extend(row.spans);
                spans.push(Span::raw(" ".repeat(cell_w.saturating_sub(used) + 1)));
                spans.push(Span::styled(glyph(a, "│", "|"), t.muted));
            }
            out.push(Line::from(spans));
        }
        if row_index + 1 < parsed.len() {
            out.push(line(
                rule(glyph(a, "├", "+"), glyph(a, "┼", "+"), glyph(a, "┤", "+")),
                t.muted,
            ));
        }
    }
    out.push(line(
        rule(glyph(a, "└", "+"), glyph(a, "┴", "+"), glyph(a, "┘", "+")),
        t.muted,
    ));
    out
}
pub fn footer_hit(a: &App, w: usize, x: usize) -> Drawer {
    let (permission, _) = permission(a);
    if x >= w.saturating_sub(width(permission, a.ambiguous_width) + 2) {
        return Drawer::Permissions;
    }
    if w < 60 {
        return Drawer::Model;
    }
    let workspace = text(&a.snapshot["session"], "workspace_label");
    if x < width(workspace, a.ambiguous_width) + 5 {
        Drawer::Workspace
    } else {
        Drawer::Model
    }
}

/// Preserve backend preorder so visible rows and enter/m/x select the same IDs.
/// Missing parents are roots; malformed cycles are bounded by visited indices.
fn agent_tree_prefix(agents: &[Value], index: usize, ascii: bool) -> String {
    let Some(_) = agents.get(index) else {
        return String::new();
    };
    let mut ancestry = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut current = index;
    while seen.insert(current) {
        let Some(parent_id) = agents[current]["parent_id"].as_str() else {
            break;
        };
        let Some(parent) = agents
            .iter()
            .position(|agent| text(agent, "id") == parent_id)
        else {
            break;
        };
        if seen.contains(&parent) {
            break;
        }
        ancestry.push(current);
        current = parent;
    }
    ancestry.reverse();
    let mut prefix = String::new();
    for (depth, &child) in ancestry.iter().enumerate() {
        let has_next = agents
            .iter()
            .skip(child + 1)
            .any(|candidate| candidate["parent_id"] == agents[child]["parent_id"]);
        if depth + 1 == ancestry.len() {
            prefix.push_str(match (ascii, has_next) {
                (true, true) => "+- ",
                (true, false) => "`- ",
                (false, true) => "├ ",
                (false, false) => "└ ",
            });
        } else {
            prefix.push_str(if has_next {
                if ascii { "|  " } else { "│ " }
            } else if ascii {
                "   "
            } else {
                "  "
            });
        }
    }
    prefix
}
