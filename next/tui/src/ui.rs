use crate::app::{App, Drawer, View, items, text};
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
struct Theme {
    accent: Style,
    muted: Style,
    good: Style,
    warn: Style,
    bad: Style,
}
impl Theme {
    fn new(a: &App) -> Self {
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
    let danger =
        a.snapshot["session"]["permission"] == "full" || a.snapshot["session"]["mode"] == "plan";
    if height < 6 || a.view != View::Chat || a.completion().is_empty() || danger {
        Some(Rect::new(0, height - 1, width, 1))
    } else {
        None
    }
}

/// Shared layout rectangle for drawing and mouse hit testing, including the sidebar.
pub fn pet_rect(a: &App, terminal_width: u16, height: u16) -> Option<Rect> {
    let w = terminal_width.saturating_sub(if a.sidebar && terminal_width >= 140 {
        44
    } else {
        0
    });
    if pet_visible(a, w, height) {
        let visible_h = chat_layout(a, terminal_width as usize, height)
            .record_h
            .min(6);
        if visible_h == 0 {
            None
        } else {
            Some(Rect::new(w - 22, 0, 20, visible_h))
        }
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
}
fn record(a: &App, w: usize, h: u16) -> Vec<Line<'static>> {
    let dot = glyph(a, "·", ":");
    let t = Theme::new(a);
    let mut out = vec![];
    let s = &a.snapshot["session"];
    if welcome(a) {
        return welcome_record(a, w, h, true);
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
        let user = text(message, "role") == "user";
        if !text(message, "thinking").is_empty() {
            let elapsed = message
                .get("thinking_elapsed_ms")
                .filter(|v| v.is_number())
                .map(|v| format!("  {}", duration(v)))
                .unwrap_or_default();
            out.push(line(
                format!("  {} 思考{elapsed}", glyph(a, "∴", "~")),
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
        out.extend(step_lines(a, w, &linked, finished));
        if !linked.is_empty() {
            out.push(Line::default());
        }
        out.extend(message_lines(
            a,
            text(message, "text"),
            user,
            if user {
                w
            } else {
                w.saturating_sub(2).min(102)
            },
        ));
        for att in items(message, "attachments") {
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
        out.push(Line::default());
    }
    let orphans: Vec<&Value> = items(&a.snapshot, "steps")
        .iter()
        .filter(|s| linked_steps.contains_key(text(s, "message_id")))
        .collect();
    out.extend(step_lines(
        a,
        w,
        &orphans,
        orphans
            .iter()
            .all(|s| matches!(text(s, "status"), "done" | "failed" | "stopped")),
    ));
    let steps = items(&a.snapshot, "steps");
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
    if matches!(a.status(), "waiting_acceptance" | "accepted" | "stopped") && !changes.is_empty() {
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
        for c in changes {
            let kind_style = match text(c, "kind") {
                "A" => t.good,
                "D" => t.bad,
                "R" => t.accent,
                _ => t.warn,
            };
            let mut spans = vec![
                Span::raw("    "),
                Span::styled(text(c, "kind").to_owned(), kind_style),
                Span::raw(format!(
                    " {}  ",
                    middle(text(c, "path"), w.saturating_sub(24), a)
                )),
            ];
            for count in change_counts(c, a).split_whitespace() {
                spans.push(Span::styled(
                    format!("{count} "),
                    if count.starts_with('+') {
                        t.good
                    } else {
                        t.bad
                    },
                ));
            }
            out.push(Line::from(spans));
        }
        for check in steps
            .iter()
            .filter(|x| text(x, "verb") == "运行" && text(x, "status") == "done")
        {
            out.push(line(
                format!(
                    "  检查  {} {} {dot} 退出码 {}",
                    glyph(a, "✓", "v"),
                    text(check, "object"),
                    check["exit_code"]
                ),
                t.good,
            ));
        }
    }
    if a.status() == "failed" && !text(s, "error").is_empty() {
        out.push(line(
            format!("  {} {}", glyph(a, "✗", "x"), text(s, "error")),
            t.bad,
        ));
    }
    out
}
fn status_label(s: &str) -> &str {
    match s {
        "running" => "运行中",
        "approval" => "待批准",
        "waiting_acceptance" => "待验收",
        "accepted" => "已验收",
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
    } else {
        match a.status() {
            "running" => (
                format!(
                    "{} {} {dot} 第 {}/{} 轮 {dot} {}",
                    state_icon(a, "running"),
                    text(s, "phase"),
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
            "waiting_acceptance" => (
                format!("{} 检查完成 {dot} 待验收", glyph(a, "✓", "v")),
                glyph(
                    a,
                    "/accept 验收 · 直接输入修改意见",
                    "/accept 验收 : 直接输入修改意见",
                ),
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
            _ => return None,
        }
    };
    let mut result = pair(
        left,
        if w >= 60 { right } else { "" }.into(),
        w,
        a,
        style,
        t.muted,
    );
    if a.status() == "running"
        && a.esc_at.is_none_or(|x| x.elapsed().as_millis() >= 1500)
        && let Some(first) = result.spans.first_mut()
    {
        let original = first.content.to_string();
        if let Some((icon, rest)) = original.split_once(' ') {
            *first = Span::styled(icon.to_owned(), t.accent);
            result
                .spans
                .insert(1, Span::styled(format!(" {rest}"), t.muted));
        }
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
pub fn footer(a: &App, w: usize) -> Line<'static> {
    let dot = glyph(a, "·", ":");
    let t = Theme::new(a);
    let s = &a.snapshot["session"];
    let (permission, ps) = permission(a);
    let model = text(s, "model");
    let model = if model.is_empty() { "无模型" } else { model };
    let plan = if s["mode"] == "plan" {
        format!("{}   ", glyph(a, "▣ 计划", "[plan]"))
    } else {
        String::new()
    };
    let mut workspace = format!("{} {}", glyph(a, "⌂", "@"), text(s, "workspace_label"));
    if text(s, "workspace_label").is_empty() {
        workspace = format!(
            "{} {}",
            glyph(a, "⌂", "@"),
            text(&a.snapshot["startup"], "workspace")
        );
    }
    let mut branch = text(s, "branch").to_owned();
    let mut effort = if s["thinking"] == false {
        "关闭".into()
    } else {
        effort_label(text(s, "effort")).to_owned()
    };
    let mut model = model.to_owned();
    let mut context = s["context_percent"]
        .as_f64()
        .map(|p| p.round() as u64)
        .map(|p| format!("上下文 {p}%{}", if p >= 95 { " /compact" } else { "" }))
        .unwrap_or_default();
    let compose = |workspace: &str, branch: &str, model: &str, effort: &str, context: &str| {
        let mut parts = vec![
            format!(
                "{plan}{workspace}{}",
                if branch.is_empty() {
                    String::new()
                } else {
                    format!(" {} {branch}", glyph(a, "›", ">"))
                }
            ),
            format!(
                "{model}{}",
                if effort.is_empty() {
                    String::new()
                } else {
                    format!(" {dot} {effort}")
                }
            ),
            permission.into(),
        ];
        if !context.is_empty() {
            parts.push(context.into());
        }
        format!("  {}", parts.join("   "))
    };
    if w < 60 {
        workspace.clear();
        branch.clear();
        effort.clear();
        context.clear();
        model = short_model(&model);
    } else {
        for stage in 0..5 {
            if width(
                &compose(&workspace, &branch, &model, &effort, &context),
                a.ambiguous_width,
            ) <= w
            {
                break;
            }
            match stage {
                0 => context.clear(),
                1 => branch.clear(),
                2 => effort.clear(),
                3 => model = short_model(&model),
                _ => workspace = glyph(a, "⌂", "@").into(),
            }
        }
    }
    let before = if w < 60 {
        format!("  {plan}{model}   ")
    } else {
        format!(
            "  {plan}{workspace}{}   {model}{}   ",
            if branch.is_empty() {
                String::new()
            } else {
                format!(" {} {branch}", glyph(a, "›", ">"))
            },
            if effort.is_empty() {
                String::new()
            } else {
                format!(" {dot} {effort}")
            }
        )
    };
    let available = w.saturating_sub(width(permission, a.ambiguous_width));
    let before = truncate(&before, available, a.ambiguous_width);
    let mut spans = vec![
        Span::styled(before, t.muted),
        Span::styled(permission.to_owned(), ps),
    ];
    if !context.is_empty() {
        spans.push(Span::styled(
            format!("   {context}"),
            match s["context_percent"].as_f64().unwrap_or(0.0) as u64 {
                95.. => t.bad,
                80.. => t.warn,
                _ => t.muted,
            },
        ));
    }
    Line::from(spans)
}
fn short_model(s: &str) -> String {
    if s.contains("Sol") {
        "Sol".into()
    } else {
        s.split_whitespace()
            .next()
            .unwrap_or("无模型")
            .chars()
            .take(12)
            .collect()
    }
}
fn selection_line(value: &str, w: usize, a: &App, style: Style) -> Line<'static> {
    let value = truncate(value, w, a.ambiguous_width);
    let pad = w.saturating_sub(width(&value, a.ambiguous_width));
    line(format!("{value}{}", " ".repeat(pad)), style)
}

fn form_lines(a: &App, w: usize, height: usize) -> Vec<Line<'static>> {
    let Some(form) = &a.form else {
        return vec![];
    };
    let t = Theme::new(a);
    let mut out = vec![];
    let notice = usize::from(!form.notice.is_empty());
    let budget = height.saturating_sub(out.len() + 1 + notice).max(1);
    let selected = form.selected.min(form.fields.len().saturating_sub(1));
    let start = selected
        .saturating_sub(budget / 2)
        .min(form.fields.len().saturating_sub(budget));
    for (i, field) in form.fields.iter().enumerate().skip(start).take(budget) {
        let value = if field.secret {
            if field.value.is_empty() {
                "保留现有密钥".to_owned()
            } else {
                "*".repeat(field.value.chars().count().min(24))
            }
        } else {
            display_path(&field.value)
        };
        let label_width = if field.editable {
            w.saturating_sub(8).min(24).min(w / 3)
        } else {
            w.saturating_sub(3)
        };
        let label = truncate(&field.label, label_width, a.ambiguous_width);
        let value = if value.is_empty() {
            String::new()
        } else {
            format!(
                "  {}",
                middle(
                    &value,
                    w.saturating_sub(width(&label, a.ambiguous_width) + 5),
                    a
                )
            )
        };
        let marker = if i == selected {
            glyph(a, "›", ">")
        } else {
            " "
        };
        out.push(selection_line(
            &format!(" {marker} {label}{value}"),
            w,
            a,
            if i == selected {
                t.accent.add_modifier(Modifier::REVERSED)
            } else {
                Style::default()
            },
        ));
    }
    if !form.notice.is_empty() {
        out.push(line(truncate(&form.notice, w, a.ambiguous_width), t.warn));
    }
    out.push(line(
        if form.editing {
            " 输入编辑 · Tab 下一项 · Enter 确认 · Esc 返回"
        } else {
            " ↑/↓ 选择 · Enter 打开或确认 · Esc 返回"
        },
        t.muted,
    ));
    out
}

/// Dialog geometry is shared by painting and input hit testing.
pub fn popup_rect(a: &App, width: u16, height: u16) -> Option<Rect> {
    if (a.form.is_none() && a.drawer.is_none()) || width < 8 || height < 6 {
        return None;
    }
    let horizontal_margin = if width >= 70 { 4 } else { 1 };
    let w = width.saturating_sub(horizontal_margin * 2).min(112);
    let available = height.saturating_sub(3);
    let desired = a.form.as_ref().map_or(22, |form| {
        (form.fields.len() + 7).min(u16::MAX as usize) as u16
    });
    let h = desired.max(12).min(available);
    Some(Rect::new((width - w) / 2, (height - 1 - h) / 2, w, h))
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
    let form = a.form.as_ref()?;
    let inner = popup_inner(popup_rect(a, width, height)?);
    if !inner.contains(ratatui::layout::Position::new(x, y)) {
        return None;
    }
    let (start, budget) = form_window(a, inner.height as usize);
    let row = (y - inner.y) as usize;
    (row < budget && start + row < form.fields.len()).then_some(start + row)
}
fn draw_popup(f: &mut Frame, a: &App) {
    let area = f.area();
    let Some(rect) = popup_rect(a, area.width, area.height) else {
        return;
    };
    let t = Theme::new(a);
    // Keep permissions in the final row readable while muting the inactive page.
    for y in area.y..area.bottom().saturating_sub(1) {
        for x in area.x..area.right() {
            f.buffer_mut()[(x, y)].modifier.insert(Modifier::DIM);
        }
    }
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
    let title = a
        .form
        .as_ref()
        .map(|form| form.title.as_str())
        .unwrap_or(match a.drawer {
            Some(Drawer::Model) => "模型与思考",
            Some(Drawer::Permissions) => "工具权限",
            Some(Drawer::Sessions) => "会话",
            Some(Drawer::Workspace) => "工作区",
            Some(Drawer::History) => "历史搜索",
            Some(Drawer::Login) => "登录与来源",
            _ => "快捷键帮助",
        });
    let mut block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(t.accent)
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
    let close = popup_close_rect(a, area.width, area.height).unwrap();
    f.render_widget(paragraph(a, "[x]").style(t.accent), close);
    let inner = popup_inner(rect);
    if inner.is_empty() {
        return;
    }
    if let Some(form) = &a.form {
        f.render_widget(
            paragraph(
                a,
                form_lines(a, inner.width as usize, inner.height as usize),
            ),
            inner,
        );
        let (start, budget) = form_window(a, inner.height as usize);
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
        {
            let w = inner.width as usize;
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
            let col = (5 + width(&label, a.ambiguous_width) + width(&value, a.ambiguous_width))
                .min(w.saturating_sub(1));
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
    }
}

fn drawer_lines(a: &App, w: usize, height: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let mut out = vec![];
    let title = match a.drawer {
        Some(Drawer::Model) => "模型",
        Some(Drawer::Permissions) => "工具权限",
        Some(Drawer::Sessions) => "会话",
        Some(Drawer::Workspace) => "工作区",
        Some(Drawer::History) => "历史搜索",
        Some(Drawer::Login) => "登录或添加模型来源",
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
        if height >= 8 {
            out.push(line(
                format!(" {} {}", glyph(a, "⌕", "/"), a.search),
                t.accent,
            ));
        }
        let budget = height.saturating_sub(out.len() + 3).max(1);
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
                            Style::default().add_modifier(Modifier::REVERSED)
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
        if budget > 1
            && let Some(index) = rows.get(start).and_then(|(i, _)| *i)
        {
            out.push(line(format!(" {}", text(&list[index], "source")), t.muted));
            remaining -= 1;
        }
        out.extend(
            rows.into_iter()
                .skip(start)
                .take(remaining)
                .map(|(_, line)| line),
        );
        let efforts = items(&list[selected], "efforts");
        let labels = efforts
            .iter()
            .enumerate()
            .map(|(i, v)| {
                let e = effort_label(v.as_str().unwrap_or(""));
                if i == a.effort_index % efforts.len().max(1) {
                    format!("[{e}]")
                } else {
                    e.to_owned()
                }
            })
            .collect::<Vec<_>>()
            .join(" ");
        out.push(line(
            format!(
                " 思考 {}  强度 {labels}",
                if a.thinking { "开" } else { "已关闭" }
            ),
            if a.thinking { t.accent } else { t.muted },
        ));
        out.push(line(
            glyph(
                a,
                " tab 切换 · 左右 强度 · space 思考",
                " tab 切换 : 左右 强度 : space 思考",
            ),
            t.muted,
        ));
        out.push(line(glyph(a, "─", "-").repeat(w), t.muted));
        return out;
    }
    match a.drawer {
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
                " Ctrl+J / Shift+Enter 换行视终端支持",
                " 鼠标拖选后 ctrl+c 复制 · /copy [all] 复制正文",
                " esc 两次中断 · 未选文字时 ctrl+c 清空 / 中断",
                " ctrl+o 详情   ctrl+g 改动   ctrl+t 任务树",
                " ctrl+y 批准   ctrl+r 历史搜索   ctrl+b 宽屏侧栏",
                " pgup/pgdn 滚动   / 命令   @ 文件",
                " Shift 拖选可用终端复制任意界面文字 · ctrl+v 粘贴附件",
            ] {
                out.push(line(s, t.muted));
            }
        }
        Some(Drawer::Login) => {
            out.push(line(" 还没有可用的模型", t.warn));
            out.push(line(" enter 打开 GUI 登录 / 添加 API 来源", t.muted));
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
                        Style::default().add_modifier(Modifier::REVERSED)
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
            out.push(line(
                format!(" {} {}", glyph(a, "⌕", "/"), a.search),
                t.accent,
            ));
            if a.drawer == Some(Drawer::Workspace) && a.active() {
                out.push(line(" 当前任务结束后才能切换", t.warn));
            }
            let list = a.drawer_items();
            let mut source = "";
            let selected = a.selected % list.len().max(1);
            let limit = if a.drawer == Some(Drawer::Model) {
                3
            } else {
                6
            };
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
                    Some(Drawer::Model) => text(item, "id"),
                    Some(Drawer::Workspace) => text(item, "name"),
                    _ => text(item, "title"),
                };
                out.push(line(
                    format!(
                        " {} {label}{}",
                        if selected { glyph(a, "›", ">") } else { " " },
                        if item["choice"] == a.snapshot["session"]["model_choice"]
                            && !item["choice"].is_null()
                        {
                            "   当前"
                        } else {
                            ""
                        }
                    ),
                    if selected {
                        Style::default().add_modifier(Modifier::REVERSED)
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
    out.push(line(glyph(a, "─", "-").repeat(w), t.muted));
    out
}
fn render_pet(f: &mut Frame, a: &App, area: Rect) {
    if !pet_visible(a, area.width, area.height) {
        return;
    }
    let now = Instant::now();
    let frame = &a.pet.art.frames[a.pet.frame(now)];
    for y in 0..6 {
        let top: Vec<char> = frame[y * 2].chars().collect();
        let bottom: Vec<char> = frame[y * 2 + 1].chars().collect();
        for x in 0..20 {
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
            let up = color(top[x]);
            let down = color(bottom[x]);
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
            let xx = area.x + area.width - 22 + x as u16;
            let yy = area.y + y as u16;
            if yy < area.bottom() {
                f.buffer_mut()[(xx, yy)].set_symbol(symbol).set_style(style);
            }
        }
    }
    let quote = a.pet.quote(now);
    if !quote.is_empty() {
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
fn diff_lines(a: &App, c: &Value, w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    items(c, "diff")
        .iter()
        .flat_map(|v| {
            let s = v.as_str().unwrap_or("");
            let mut st = if s.starts_with('+') {
                t.good
            } else if s.starts_with('-') {
                t.bad
            } else {
                t.muted
            };
            if a.truecolor && !a.no_color {
                if s.starts_with('+') {
                    st = st.bg(if a.light {
                        Color::Rgb(230, 243, 234)
                    } else {
                        Color::Rgb(28, 51, 38)
                    });
                }
                if s.starts_with('-') {
                    st = st.bg(if a.light {
                        Color::Rgb(248, 230, 232)
                    } else {
                        Color::Rgb(58, 34, 38)
                    });
                }
            }
            wrap(s, w, a, "", st)
        })
        .collect()
}
fn persistent_notice(a: &App) -> Option<&str> {
    if a.snapshot_stale {
        Some("状态更新失败，当前为旧快照")
    } else if !a.notice.is_empty() {
        Some(&a.notice)
    } else {
        a.config_warning.as_deref()
    }
}

pub fn draw(f: &mut Frame, a: &App) {
    draw_inner(f, a);
    let area = f.area();
    if let Some(rect) = footer_at(a, area.width, area.height) {
        f.render_widget(paragraph(a, footer(a, area.width as usize)), rect);
    }
    draw_popup(f, a);
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

struct ChatLayout {
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
    let t = Theme::new(a);
    let completion = a.completion();
    let danger =
        a.snapshot["session"]["permission"] == "full" || a.snapshot["session"]["mode"] == "plan";
    let mut bottom_h = if completion.is_empty() {
        1
    } else {
        let usage = usize::from(w < 90 && height >= 12);
        (completion.len().min(8 - usage) + usage).min((height / 3) as usize) as u16
            + u16::from(danger)
    };
    let approval = a.status() == "approval" && !a.approval_collapsed && !a.rejection;
    let input_h = if approval {
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
    let notice_h = u16::from(!persistent_notice.is_empty());
    bottom_h = bottom_h.min(
        height
            .saturating_sub(input_h + status_h + queue_h + notice_h)
            .max(1),
    );
    let drawer = if a.form.is_some() || a.drawer.is_some() {
        vec![]
    } else if let Some(request) = items(&a.snapshot, "questions").first() {
        let mut lines = vec![line(" 需要你回答", t.warn.add_modifier(Modifier::BOLD))];
        if let Some(q) = items(request, "questions").get(a.question_index) {
            lines.extend(wrap(text(q, "question"), w, a, " ", Style::default()));
            for (i, option) in items(q, "options").iter().enumerate() {
                lines.push(line(
                    format!(" {}. {}", i + 1, option.as_str().unwrap_or("")),
                    t.accent,
                ));
            }
            lines.push(line(
                if q["multiple"] == true {
                    glyph(
                        a,
                        " 输入选项编号（逗号分隔）或文字 · enter 回答",
                        " 输入选项编号（逗号分隔）或文字 : enter 回答",
                    )
                } else {
                    glyph(
                        a,
                        " 输入选项编号或文字 · enter 回答",
                        " 输入选项编号或文字 : enter 回答",
                    )
                },
                t.muted,
            ));
        }
        lines
    } else {
        vec![]
    };
    let drawer_h = (drawer.len() as u16)
        .min(if height < 16 { 6 } else { 12 })
        .min(height / 2)
        .min(height.saturating_sub(bottom_h + input_h + status_h + queue_h + notice_h));
    let hint_h = u16::from(welcome(a) && height >= 12 && a.form.is_none() && a.drawer.is_none());
    let fixed = bottom_h + input_h + status_h + queue_h + notice_h + drawer_h + hint_h;
    let record_h = height.saturating_sub(fixed);
    ChatLayout {
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

/// Exact shared chat geometry keeps paging from overscrolling into empty history.
pub fn record_scroll_limit(a: &App, width: u16, height: u16) -> u16 {
    if height < 6 {
        return 0;
    }
    let layout = chat_layout(a, width as usize, height);
    let record_width = width.saturating_sub(if a.sidebar && width >= 140 { 44 } else { 0 });
    record(a, record_width as usize, height)
        .len()
        .saturating_sub(layout.record_h as usize)
        .min(u16::MAX as usize) as u16
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
    let rec = record(a, main_area.width as usize, area.height);
    let offset = if welcome(a) {
        a.scroll as usize
    } else {
        rec.len()
            .saturating_sub(record_h as usize)
            .saturating_sub(a.scroll as usize)
    };
    f.render_widget(
        paragraph(a, rec.into_iter().skip(offset).collect::<Vec<_>>()),
        main_area,
    );
    if offset == 0 {
        render_pet(
            f,
            a,
            Rect::new(main_area.x, main_area.y, main_area.width, area.height),
        );
    }
    let mut y = area.y + record_h;
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
                    &format!("  {} 下一轮发送：{q}", glyph(a, "↳", ">")),
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
        let mut counts = [0usize; 4];
        for attachment in &a.attachments {
            let mime = text(attachment, "mime");
            let kind = text(attachment, "kind");
            counts[if mime.starts_with("image/") || kind == "image" {
                1
            } else if mime.starts_with("video/") || kind == "video" {
                2
            } else if mime.starts_with("audio/") || kind == "audio" {
                3
            } else {
                0
            }] += 1;
        }
        let mut labels = ["File", "Image", "Video", "Audio"]
            .iter()
            .zip(counts)
            .filter(|(_, n)| *n > 0)
            .map(|(label, n)| format!("[{label} {n}]"))
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
        let block = block.title(format!(" {} ", clean(text(p, "tool"))));
        f.render_widget(block, input_area);
        let mut lines = approval_lines(a, inner.width as usize);
        let actions = wrap(
            "y 允许一次   a 本会话允许   n 拒绝   e 拒绝并说明",
            inner.width as usize,
            a,
            "",
            t.warn,
        );
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
                "先登录或添加模型来源".to_string()
            } else if a.active() {
                "输入补充要求，下一轮发送".to_string()
            } else {
                "描述任务；Alt+J 换行；/ 命令，@ 文件".to_string()
            }
        } else if a.paste_collapsed {
            format!("[char +{}]", a.input.chars().count())
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
        f.render_widget(paragraph(a, lines).scroll((offset as u16, 0)), inner);
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
            let completion_h = bottom_h - u16::from(danger);
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
                    let value = if description.is_empty() {
                        format!("  {c}")
                    } else if w >= 90 {
                        format!("  {c:<14} {description}  {usage}")
                    } else {
                        format!("  {c}  {description}")
                    };
                    selection_line(
                        &value,
                        w,
                        a,
                        if i == a.selected % completion.len() {
                            t.accent.add_modifier(Modifier::REVERSED)
                        } else {
                            t.accent
                        },
                    )
                })
                .collect::<Vec<_>>();
            if usage_h > 0 {
                while lines.len() < menu_h as usize {
                    lines.push(Line::default());
                }
                let (_, usage) = crate::app::command_metadata(&completion[selected]);
                lines.push(selection_line(&format!(" 用法 {usage}"), w, a, t.muted));
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
    let dot = glyph(a, "·", ":");
    let t = Theme::new(a);
    let s = &a.snapshot["session"];
    let mut out = vec![];
    let collapsed = !a.expanded && finished && !steps.iter().any(|s| text(s, "status") == "failed");
    if collapsed && !steps.is_empty() {
        out.push(pair(
            format!(
                "  {} {} 个步骤 {dot} {}",
                state_icon(
                    a,
                    if a.status() == "stopped" {
                        "stopped"
                    } else {
                        "done"
                    }
                ),
                steps.len(),
                duration(&s["elapsed_ms"])
            ),
            if w >= 60 { "ctrl+o 展开" } else { "" }.into(),
            w,
            a,
            t.muted,
            t.muted,
        ));
    } else {
        let skip = if a.expanded {
            0
        } else {
            steps.len().saturating_sub(6)
        };
        if skip > 0 {
            out.push(line(
                format!("  {} 另有 {skip} 个步骤", glyph(a, "…", "...")),
                t.muted,
            ));
        }
        for step in steps.iter().skip(skip) {
            let status = if a.status() == "approval" && text(step, "status") == "running" {
                "approval"
            } else {
                text(step, "status")
            };
            let meta = if w < 60 {
                String::new()
            } else if step["added"].as_u64().unwrap_or(0) > 0
                || step["removed"].as_u64().unwrap_or(0) > 0
            {
                change_counts(step, a)
            } else if status == "failed" {
                format!("退出码 {}", step["exit_code"])
            } else if text(step, "verb") == "运行" || status == "running" {
                duration(&step["elapsed_ms"])
            } else {
                String::new()
            };
            let fixed = format!("  {} {}  ", state_icon(a, status), text(step, "verb"));
            let available = w.saturating_sub(
                width(&fixed, a.ambiguous_width) + width(&meta, a.ambiguous_width) + 1,
            );
            let object = middle(text(step, "object"), available, a);
            let gap = w.saturating_sub(
                width(&fixed, a.ambiguous_width)
                    + width(&object, a.ambiguous_width)
                    + width(&meta, a.ambiguous_width),
            );
            let mut spans = vec![
                Span::raw("  "),
                Span::styled(state_icon(a, status), state_style(t, status)),
                Span::raw(format!(
                    " {}  {object}{}",
                    text(step, "verb"),
                    " ".repeat(gap)
                )),
            ];
            for part in meta.split_inclusive(' ') {
                spans.push(Span::styled(
                    part.to_owned(),
                    if part.starts_with('+') {
                        t.good
                    } else if part.starts_with('−') || part.starts_with('-') || status == "failed"
                    {
                        t.bad
                    } else {
                        t.muted
                    },
                ));
            }
            out.push(Line::from(spans));
            let count = if status == "failed" {
                3
            } else if status == "running" || status == "stopped" {
                2
            } else {
                0
            };
            let tail = items(step, "tail");
            for l in tail.iter().skip(tail.len().saturating_sub(count)) {
                let prefix = format!("    {} ", glyph(a, "│", "|"));
                out.push(line(
                    format!(
                        "{prefix}{}",
                        truncate(
                            l.as_str().unwrap_or(""),
                            w.saturating_sub(width(&prefix, a.ambiguous_width)),
                            a.ambiguous_width
                        )
                    ),
                    t.muted,
                ));
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
    for value in [
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
    ] {
        let value = middle(&value, inside, a);
        let pad = inside.saturating_sub(width(&value, a.ambiguous_width));
        out.push(Line::from(vec![
            Span::styled(glyph(a, "│", "|"), t.accent),
            Span::raw(format!("{value}{}", " ".repeat(pad))),
            Span::styled(glyph(a, "│", "|"), t.accent),
        ]));
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
            let panel = w.saturating_sub(4).min(72).max(1);
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
                let value = if w < 60 {
                    format!(" {marker} {}", text(item, "title"))
                } else {
                    format!(" {marker} {}  {state}", text(item, "title"))
                };
                hits.push((out.len(), text(item, "id").to_owned()));
                let mut row = vec![Span::raw(" ".repeat(left))];
                row.extend(
                    selection_line(
                        &value,
                        panel,
                        a,
                        if focused {
                            t.accent.add_modifier(Modifier::REVERSED)
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
    lines.extend(wrap(
        "y 允许一次   a 本会话允许   n 拒绝   e 拒绝并说明",
        w,
        a,
        "",
        t.warn,
    ));
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
fn code_tokens(a: &App, value: &str, language: &str) -> Vec<(char, Style)> {
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
    let t = Theme::new(a);
    let content = clean(content);
    let raws: Vec<&str> = content.split('\n').collect();
    let mut out = vec![];
    let mut fence: Option<(char, usize, String)> = None;
    let mut index = 0;
    while index < raws.len() {
        let raw = raws[index];
        index += 1;
        let trim = raw.trim_start();
        if !user {
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
                        .trim()
                        .split_whitespace()
                        .next()
                        .unwrap_or("")
                        .to_owned();
                    if !language.is_empty() {
                        out.push(line(format!("  {language}"), t.muted));
                    }
                    fence = Some((marker, count, language));
                    continue;
                }
            }
        }
        if let Some((_, _, language)) = &fence {
            let prefix = format!("  {} ", glyph(a, "│", "|"));
            out.extend(styled_lines(
                a,
                code_tokens(a, raw, language),
                w,
                prefix.clone(),
                prefix,
                t.muted,
            ));
            continue;
        }
        if !user
            && raw.trim().starts_with('|')
            && raw.trim().ends_with('|')
            && index < raws.len()
            && raws[index]
                .chars()
                .all(|c| matches!(c, '|' | '-' | ':' | ' ' | '\t'))
            && raws[index].contains('-')
        {
            let mut rows = vec![raw, raws[index]];
            index += 1;
            while index < raws.len()
                && raws[index].trim().starts_with('|')
                && raws[index].trim().ends_with('|')
            {
                rows.push(raws[index]);
                index += 1;
            }
            out.extend(table_lines(a, &rows, w));
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
            w,
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
fn table_lines(a: &App, rows: &[&str], w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let parsed: Vec<Vec<String>> = rows
        .iter()
        .filter(|r| !r.chars().all(|c| matches!(c, '|' | '-' | ':' | ' ' | '\t')))
        .map(|r| table_cells(r))
        .collect();
    let cols = parsed.iter().map(Vec::len).max().unwrap_or(1).max(1);
    let plain = |value: &str| {
        inline_markdown(a, value, Style::default())
            .iter()
            .map(|(c, _)| *c)
            .collect::<String>()
    };
    let widths: Vec<usize> = (0..cols)
        .map(|i| {
            parsed
                .iter()
                .map(|row| {
                    row.get(i)
                        .map_or(0, |c| width(&plain(c), a.ambiguous_width))
                })
                .max()
                .unwrap_or(0)
                .max(1)
        })
        .collect();
    if widths.iter().sum::<usize>() + cols * 3 + 3 > w {
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
        let mut spans = vec![Span::raw("  "), Span::styled(glyph(a, "│", "|"), t.muted)];
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
            let used = width(&plain(value), a.ambiguous_width);
            spans.push(Span::raw(" "));
            spans.extend(
                styled
                    .into_iter()
                    .map(|(c, s)| Span::styled(c.to_string(), s)),
            );
            spans.push(Span::raw(" ".repeat(cell_w.saturating_sub(used) + 1)));
            spans.push(Span::styled(glyph(a, "│", "|"), t.muted));
        }
        out.push(Line::from(spans));
        if row_index == 0 && parsed.len() > 1 {
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
    let f = footer(a, w);
    let before = f.spans.first().map(|s| s.content.as_ref()).unwrap_or("");
    let pw = width(before, a.ambiguous_width);
    if x >= pw {
        return Drawer::Permissions;
    }
    if w < 60 {
        return Drawer::Model;
    }
    let workspace = before.split("   ").next().unwrap_or("");
    if x < width(workspace, a.ambiguous_width) + 3 {
        Drawer::Workspace
    } else {
        Drawer::Model
    }
}

fn change_counts(v: &Value, a: &App) -> String {
    let mut out = vec![];
    if let Some(n) = v["added"].as_u64().filter(|n| *n > 0) {
        out.push(format!("+{n}"));
    }
    if let Some(n) = v["removed"].as_u64().filter(|n| *n > 0) {
        out.push(format!("{}{n}", glyph(a, "−", "-")));
    }
    out.join(" ")
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
