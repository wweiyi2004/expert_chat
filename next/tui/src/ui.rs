use crate::app::{App, Drawer, View, items, text};
use ratatui::{
    Frame,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Padding, Paragraph},
};
use serde_json::Value;
use std::time::Instant;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

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
    let ell = if app.ascii { "..." } else { "…" };
    let ew = ell.width();
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
    if app.ascii { ascii } else { normal }
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
        Self {
            accent: color(Color::Cyan, (124, 192, 222), (31, 98, 131)),
            muted: if a.no_color || !a.truecolor {
                Style::default().add_modifier(Modifier::DIM)
            } else {
                color(Color::Reset, (138, 154, 163), (102, 118, 126))
            },
            good: color(Color::Green, (143, 204, 168), (42, 115, 80)),
            warn: color(Color::Yellow, (227, 188, 114), (135, 89, 26)),
            bad: color(Color::Red, (234, 161, 168), (168, 62, 72)),
        }
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
            if a.ascii {
                "v"
            } else {
                "✓"
            }
        }
        "failed" => {
            if a.ascii {
                "x"
            } else {
                "✗"
            }
        }
        "stopped" | "cancelled" | "interrupted" => {
            if a.ascii {
                "#"
            } else {
                "■"
            }
        }
        "running" => {
            if a.reduce_motion {
                if a.ascii { "." } else { "◌" }
            } else if a.ascii {
                ["-", "\\", "|", "/"][(a.tick % 4) as usize]
            } else {
                ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"][(a.tick % 10) as usize]
            }
        }
        _ => {
            if a.ascii {
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
    welcome(a)
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
    for message in items(&a.snapshot, "messages") {
        let user = text(message, "role") == "user";
        out.extend(message_lines(a, text(message, "text"), user, w.min(104)));
        for att in items(message, "attachments") {
            out.push(line(
                format!(
                    "  {} {} · {} B",
                    glyph(a, "⎘", "@"),
                    text(att, "name"),
                    att["size"]
                ),
                t.muted,
            ));
        }
        if !text(message, "thinking").is_empty() {
            out.push(line(format!("  {} 思考", glyph(a, "∴", "~")), t.muted));
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
        out.push(Line::default());
        let linked: Vec<Value> = items(&a.snapshot, "steps")
            .iter()
            .filter(|step| step["message_id"] == message["id"])
            .cloned()
            .collect();
        let mut groups: Vec<Vec<Value>> = vec![];
        for step in linked {
            if let Some(last) = groups
                .last_mut()
                .filter(|g| g.first().is_some_and(|s| s["round_id"] == step["round_id"]))
            {
                last.push(step);
            } else {
                groups.push(vec![step]);
            }
        }
        for group in groups {
            let finished = group
                .iter()
                .all(|s| matches!(text(s, "status"), "done" | "failed" | "stopped"));
            out.extend(step_lines(a, w, &group, finished));
        }
    }
    let orphans: Vec<Value> = items(&a.snapshot, "steps")
        .iter()
        .filter(|step| {
            !items(&a.snapshot, "messages")
                .iter()
                .any(|m| m["id"] == step["message_id"])
        })
        .cloned()
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
                "  {} 助手  {} · {}",
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
            out.push(line(
                format!(
                    "    {} {}  {}",
                    text(c, "kind"),
                    middle(text(c, "path"), w.saturating_sub(24), a),
                    change_counts(c, a)
                ),
                match text(c, "kind") {
                    "A" => t.good,
                    "D" => t.bad,
                    "R" => t.accent,
                    _ => t.warn,
                },
            ));
        }
        for check in steps
            .iter()
            .filter(|x| text(x, "verb") == "运行" && text(x, "status") == "done")
        {
            out.push(line(
                format!(
                    "  检查  {} {} · 退出码 {}",
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
    let t = Theme::new(a);
    let s = &a.snapshot["session"];
    let (left, right, style) = if a.esc_at.is_some_and(|x| x.elapsed().as_millis() < 1500) {
        ("再按一次 esc 中断任务".into(), "", t.warn)
    } else {
        match a.status() {
            "running" => (
                format!(
                    "{} {} · 第 {}/{} 轮 · {}",
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
                        "! {} {} · {}s 后重试（{}/{}）",
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
                format!("{} 检查完成 · 待验收", glyph(a, "✓", "v")),
                "/accept 验收 · 直接输入修改意见",
                t.good,
            ),
            "stopped" => (
                format!(
                    "{} 已停止 · 第 {}/{} 轮",
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
    Some(pair(
        left,
        if w >= 60 { right } else { "" }.into(),
        w,
        a,
        style,
        t.muted,
    ))
}
fn permission(a: &App) -> (&str, Style) {
    let t = Theme::new(a);
    match text(&a.snapshot["session"], "permission") {
        "full" => (
            if a.ascii {
                "! 完全访问"
            } else {
                "▲ 完全访问"
            },
            t.bad.add_modifier(Modifier::BOLD),
        ),
        "assisted" => (
            if a.ascii {
                "+ 自动审查"
            } else {
                "◆ 自动审查"
            },
            t.accent,
        ),
        _ => (
            if a.ascii {
                "? 请求批准"
            } else {
                "◇ 请求批准"
            },
            t.muted,
        ),
    }
}
pub fn footer(a: &App, w: usize) -> Line<'static> {
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
                    format!(" · {effort}")
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
                format!(" · {effort}")
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
fn drawer_lines(a: &App, w: usize) -> Vec<Line<'static>> {
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
        "enter 确认 · esc 关闭".into(),
        w,
        a,
        Style::default().add_modifier(Modifier::BOLD),
        t.muted,
    ));
    match a.drawer {
        Some(Drawer::Help) => {
            for s in [
                " enter 发送   ctrl+j 换行   shift+tab 计划模式",
                " esc 两次中断   ctrl+c 清空 / 中断 / 两次退出",
                " ctrl+o 详情   ctrl+g 改动   ctrl+t 任务树",
                " ctrl+y 批准   ctrl+r 历史搜索   ctrl+b 宽屏侧栏",
                " pgup/pgdn 滚动   / 命令   @ 文件",
                " 按住 shift 拖动选择文字（多数终端支持）",
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
                "◇ 请求批准 · 写入和命令先确认",
                "◆ 自动审查 · 按规则自动批准安全操作",
                "▲ 完全访问 · 不再询问",
            ]
            .iter()
            .enumerate()
            {
                let s = if a.ascii {
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
                out.push(line(" tab 切换 · 左右 调整强度 · space 开关思考", t.muted));
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
                let hex = if c == 'K' && !a.light {
                    "#3d3448"
                } else {
                    a.pet.art.palette.get(&c)?.as_str()
                };
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
                Paragraph::new(quote).style(Theme::new(a).accent),
                Rect::new(end - qw, area.y + 1, qw, 1),
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
    let t = Theme::new(a);
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
            "j/k 选择 · q / esc 返回".into(),
            area.width as usize,
            a,
            Style::default(),
            t.muted,
        ),
        line(glyph(a, "─", "-").repeat(area.width as usize), t.muted),
    ];
    if a.view == View::Agents {
        let agents = items(&a.snapshot, "agents");
        for (i, agent) in agents.iter().enumerate() {
            lines.push(line(
                format!(
                    " {} {} {}  {}  {}  {}",
                    if i == a.selected % agents.len().max(1) {
                        glyph(a, "›", ">")
                    } else {
                        " "
                    },
                    state_icon(a, text(agent, "status")),
                    text(agent, "name"),
                    text(agent, "model"),
                    text(agent, "activity"),
                    duration(&agent["elapsed_ms"])
                ),
                state_style(t, text(agent, "status")),
            ));
        }
        lines.push(Line::default());
        lines.push(line(" enter 查看记录 · m 补充要求 · x 停止助手", t.muted));
        if !a.notice.is_empty() {
            lines.extend(wrap(&a.notice, area.width as usize, a, "  ", t.muted));
        }
        f.render_widget(Paragraph::new(lines), area);
        return;
    }
    let changes = items(&a.snapshot, "changes");
    let selected = a.selected % changes.len().max(1);
    if area.width >= 100 {
        f.render_widget(
            Paragraph::new(lines),
            Rect::new(area.x, area.y, area.width, 2),
        );
        let list_area = Rect::new(area.x, area.y + 2, 28, area.height.saturating_sub(2));
        let file_lines = changes
            .iter()
            .enumerate()
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
        f.render_widget(Paragraph::new(file_lines), list_area);
        for y in area.y + 2..area.bottom() {
            f.render_widget(
                Paragraph::new(glyph(a, "│", "|")).style(t.muted),
                Rect::new(area.x + 28, y, 1, 1),
            );
        }
        if let Some(c) = changes.get(selected) {
            let mut diff = vec![line(text(c, "path").to_owned(), t.accent)];
            diff.extend(diff_lines(a, c));
            f.render_widget(
                Paragraph::new(diff).scroll((a.scroll, 0)),
                Rect::new(
                    area.x + 30,
                    area.y + 2,
                    area.width.saturating_sub(30),
                    area.height.saturating_sub(2),
                ),
            );
        }
    } else {
        for (i, c) in changes.iter().enumerate().take(5) {
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
            lines.extend(diff_lines(a, c).into_iter().skip(a.scroll as usize));
        }
        f.render_widget(Paragraph::new(lines), area);
    }
}
fn diff_lines(a: &App, c: &Value) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    items(c, "diff")
        .iter()
        .map(|v| {
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
            line(clean(s), st)
        })
        .collect()
}
pub fn draw(f: &mut Frame, a: &App) {
    let area = f.area();
    if area.width == 0 || area.height == 0 {
        return;
    }
    if a.view != View::Chat {
        full_view(f, a, area);
        return;
    }
    let t = Theme::new(a);
    let w = area.width as usize;
    let completion = a.completion();
    let danger =
        a.snapshot["session"]["permission"] == "full" || a.snapshot["session"]["mode"] == "plan";
    let bottom_h = if completion.is_empty() {
        1
    } else {
        completion.len().min(8).min((area.height / 3) as usize) as u16 + u16::from(danger)
    };
    let approval = a.status() == "approval" && !a.approval_collapsed && !a.rejection;
    let input_h = if approval {
        (approval_lines(a, w.saturating_sub(4)).len() as u16 + 2)
            .min(area.height.saturating_sub(3))
            .max(3)
    } else {
        let n = a
            .input
            .split('\n')
            .map(|s| {
                width(s, a.ambiguous_width)
                    .div_ceil(w.saturating_sub(5).max(1))
                    .max(1)
            })
            .sum::<usize>();
        if a.input.lines().count() > 5 {
            3
        } else {
            (n as u16 + 2).min(if area.height < 16 { 3 } else { 8 })
        }
    };
    let status_line = status(a, w);
    let status_h = u16::from(status_line.is_some());
    let queued = items(&a.snapshot, "queued");
    let queue_h = u16::from(!queued.is_empty());
    let notice_h = u16::from(!a.notice.is_empty());
    let drawer = if a.drawer.is_some() {
        drawer_lines(a, w)
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
                    " 输入选项编号（逗号分隔）或文字 · enter 回答"
                } else {
                    " 输入选项编号或文字 · enter 回答"
                },
                t.muted,
            ));
        }
        lines
    } else {
        vec![]
    };
    let drawer_h = (drawer.len() as u16)
        .min(if area.height < 16 { 6 } else { 12 })
        .min(area.height / 2);
    let fixed = bottom_h + input_h + status_h + queue_h + notice_h + drawer_h;
    let record_h = area.height.saturating_sub(fixed);
    let mut main_area = Rect::new(area.x, area.y, area.width, record_h);
    if a.sidebar && area.width >= 140 {
        main_area.width = area.width - 44;
        let right = Rect::new(area.x + main_area.width, area.y, 44, record_h);
        let mut lines = vec![line("│ 任务树", t.muted)];
        for agent in items(&a.snapshot, "agents") {
            lines.push(line(
                format!(
                    "│ {} {}",
                    state_icon(a, text(agent, "status")),
                    text(agent, "name")
                ),
                t.muted,
            ));
        }
        lines.push(line("│ 改动", t.muted));
        for c in items(&a.snapshot, "changes") {
            lines.push(line(
                format!("│ {} {}", text(c, "kind"), text(c, "path")),
                t.muted,
            ));
        }
        f.render_widget(Paragraph::new(lines), right);
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
        Paragraph::new(rec.into_iter().skip(offset).collect::<Vec<_>>()),
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
    if drawer_h > 0 {
        f.render_widget(
            Paragraph::new(drawer),
            Rect::new(area.x, y, area.width, drawer_h),
        );
        y += drawer_h;
    }
    if notice_h > 0 {
        f.render_widget(
            Paragraph::new(truncate(&a.notice, w, a.ambiguous_width)).style(t.warn),
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
            Paragraph::new(truncate(
                &format!("  {} 下一轮发送：{q}", glyph(a, "↳", ">")),
                w,
                a.ambiguous_width,
            ))
            .style(t.muted),
            Rect::new(area.x, y, area.width, 1),
        );
        y += 1;
    }
    if let Some(s) = status_line {
        f.render_widget(Paragraph::new(s), Rect::new(area.x, y, area.width, 1));
        y += 1;
    }
    let input_area = Rect::new(
        area.x,
        y,
        area.width,
        input_h.min(area.bottom().saturating_sub(y)),
    );
    let border = if a.ascii {
        BorderType::Plain
    } else {
        BorderType::Rounded
    };
    let mut block = Block::default()
        .borders(Borders::ALL)
        .border_type(border)
        .border_style(if approval {
            t.warn
        } else if a.drawer.is_some() {
            t.muted
        } else {
            t.accent
        });
    if a.ascii {
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
        block = block.title(format!(
            " {} {} 个附件 ",
            glyph(a, "⎘", "@"),
            a.attachments.len()
        ));
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
        f.render_widget(Paragraph::new(lines), inner);
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
                "描述任务，/ 命令，@ 文件".to_string()
            }
        } else if a.input.lines().count() > 5 {
            format!("[已粘贴 {} 行]", a.input.lines().count())
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
        f.render_widget(Paragraph::new(lines), inner);
        if a.drawer.is_none() && inner.width > 2 && inner.height > 0 {
            let before = &a.input[..a.cursor.min(a.input.len())];
            let row = before.chars().filter(|c| *c == '\n').count() as u16;
            let col = width(before.rsplit('\n').next().unwrap_or(""), a.ambiguous_width) as u16;
            f.set_cursor_position((
                inner.x + (col + 2).min(inner.width - 1),
                inner.y + row.min(inner.height - 1),
            ));
        }
    }
    y += input_area.height;
    if y < area.bottom() {
        if completion.is_empty() {
            f.render_widget(
                Paragraph::new(footer(a, w)),
                Rect::new(area.x, y, area.width, 1),
            );
        } else {
            let completion_h = bottom_h - u16::from(danger);
            let selected = a.selected % completion.len();
            let start = (selected / completion.len().min(completion_h as usize).max(1))
                * completion.len().min(completion_h as usize).max(1);
            let lines = completion
                .iter()
                .enumerate()
                .skip(start)
                .take(completion_h as usize)
                .map(|(i, c)| {
                    line(
                        format!("  {c}"),
                        if i == a.selected % completion.len() {
                            t.accent.add_modifier(Modifier::REVERSED)
                        } else {
                            t.accent
                        },
                    )
                })
                .collect::<Vec<_>>();
            f.render_widget(
                Paragraph::new(lines),
                Rect::new(area.x, y, area.width, bottom_h),
            );
            if danger && y + completion_h < area.bottom() {
                f.render_widget(
                    Paragraph::new(footer(a, w)),
                    Rect::new(area.x, y + completion_h, area.width, 1),
                );
            }
        }
    }
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
            let symbol = buffer[(x, y)].symbol();
            row.push_str(symbol);
            skip = symbol.width().saturating_sub(1);
        }
        result.push_str(row.trim_end());
        result.push('\n');
    }
    result
}

fn step_lines(a: &App, w: usize, steps: &[Value], finished: bool) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let s = &a.snapshot["session"];
    let mut out = vec![];
    let collapsed = !a.expanded && finished && !steps.iter().any(|s| text(s, "status") == "failed");
    if collapsed && !steps.is_empty() {
        out.push(pair(
            format!(
                "  {} {} 个步骤 · {}",
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

fn welcome_record(a: &App, w: usize, h: u16, hint: bool) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let s = &a.snapshot["session"];
    let mut out = vec![];
    let start = &a.snapshot["startup"];
    out.push(Line::from(vec![
        Span::styled(
            format!("{} expert ", glyph(a, "◈", "*")),
            t.accent.add_modifier(Modifier::BOLD),
        ),
        Span::styled(format!(" v{}", text(start, "version")), t.muted),
    ]));
    out.push(Line::default());
    if h >= 16 {
        let project_w = if pet_visible(a, w as u16, h) {
            w.saturating_sub(24)
        } else {
            w
        };
        out.push(line(
            truncate(
                &format!(
                    "  {}  {}",
                    text(start, "workspace"),
                    text(start, "workspace_path")
                ),
                project_w,
                a.ambiguous_width,
            ),
            Style::default(),
        ));
        if !text(start, "branch").is_empty() {
            out.push(line(
                format!(
                    "  {} · {} 个未提交改动",
                    text(start, "branch"),
                    start["dirty_count"].as_u64().unwrap_or(0)
                ),
                t.muted,
            ));
        }
        let contexts = items(start, "contexts")
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(" · ");
        if !contexts.is_empty() {
            out.push(line(
                truncate(
                    &format!("  已加载 {contexts}"),
                    project_w,
                    a.ambiguous_width,
                ),
                t.muted,
            ));
        }
        if text(start, "workspace") == "默认工作区" {
            out.push(line("  用 expert <目录> 在项目中启动", t.muted));
        }
        let issues = items(start, "issues");
        if !issues.is_empty() {
            out.push(line(
                if issues.len() == 1 {
                    format!(
                        "  ! {} · /mcp 查看",
                        issues[0].as_str().unwrap_or("启动失败")
                    )
                } else {
                    format!("  ! {} 个问题 · /doctor 查看", issues.len())
                },
                t.warn,
            ));
        }
        out.push(Line::default());
        if items(&a.snapshot, "models").is_empty() {
            out.push(line("  还没有可用的模型", t.warn));
            out.push(line(
                "  /login 登录官方订阅   /model 添加 API 来源",
                t.muted,
            ));
        } else {
            let sessions = items(&a.snapshot, "sessions");
            if !sessions.is_empty() {
                while pet_visible(a, w as u16, h) && out.len() < 7 {
                    out.push(Line::default());
                }
                out.push(pair(
                    "  最近会话".into(),
                    "/resume".into(),
                    w,
                    a,
                    t.muted,
                    t.accent,
                ));
                for session in sessions
                    .iter()
                    .filter(|x| {
                        s["workspace_id"].is_null() || x["workspace_id"] == s["workspace_id"]
                    })
                    .take(3)
                {
                    let status = text(session, "status");
                    let icon = if status == "running" {
                        glyph(a, "●", "*")
                    } else {
                        glyph(a, "○", "o")
                    };
                    let name = format!("    {icon} {}", text(session, "title"));
                    out.push(if w < 60 {
                        line(name, t.muted)
                    } else {
                        pair(
                            name,
                            status_label(status).into(),
                            w,
                            a,
                            Style::default(),
                            t.muted,
                        )
                    });
                }
            }
        }
        out.push(Line::default());
    }
    if hint {
        out.push(line(
            "  / 命令   @ 文件   ? 快捷键   shift+tab 计划模式",
            t.muted,
        ));
    }

    out
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
    let t = Theme::new(a);
    let p = &a.snapshot["approvals"][0];
    let args = text(p, "arguments");
    let display = serde_json::from_str::<Value>(args)
        .ok()
        .and_then(|v| v["command"].as_str().map(str::to_owned))
        .unwrap_or_else(|| args.to_owned());
    let mut lines = wrap(&display, w, a, "", Style::default());
    lines.extend(wrap(
        &format!("目录 {} · 原因 {}", text(p, "target"), text(p, "reason")),
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
fn message_lines(a: &App, content: &str, user: bool, w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let content = clean(content);
    let raws: Vec<&str> = content.split('\n').collect();
    let mut out = vec![];
    let mut code = false;
    let mut index = 0;
    while index < raws.len() {
        let raw = raws[index];
        index += 1;
        if !user && raw.starts_with("```") {
            code = !code;
            continue;
        }
        if !user && !code && raw.trim().starts_with('|') && raw.trim().ends_with('|') {
            let mut rows = vec![raw];
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
        let first = out.is_empty();
        let mut prefix = vec![Span::styled(
            if code {
                format!("  {} ", glyph(a, "│", "|"))
            } else if first {
                format!(
                    "{} ",
                    if user {
                        glyph(a, "›", ">")
                    } else {
                        glyph(a, "◈", "*")
                    }
                )
            } else {
                "  ".into()
            },
            t.accent,
        )];
        let heading = !user && !code && raw.starts_with('#');
        let raw = if heading {
            raw.trim_start_matches('#').trim_start()
        } else {
            raw
        };
        let mut body = raw.to_owned();
        if !user && !code && (body.starts_with("- ") || body.starts_with("* ")) {
            body = format!("{} {}", glyph(a, "•", "*"), &body[2..]);
        }
        let base = if heading {
            t.accent.add_modifier(Modifier::BOLD)
        } else {
            Style::default()
        };
        let mut styled = vec![];
        if code {
            let mut quoted = false;
            for word in body.split_inclusive(char::is_whitespace) {
                let keyword = matches!(
                    word.trim_matches(|c: char| !c.is_alphanumeric()),
                    "fn" | "pub"
                        | "let"
                        | "mut"
                        | "use"
                        | "class"
                        | "final"
                        | "const"
                        | "return"
                        | "if"
                        | "else"
                        | "for"
                        | "import"
                        | "def"
                        | "true"
                        | "false"
                        | "null"
                );
                for c in word.chars() {
                    if c == '"' || c == '\'' {
                        quoted = !quoted;
                        styled.push((c, t.good));
                    } else {
                        styled.push((
                            c,
                            if quoted {
                                t.good
                            } else if c.is_ascii_digit() {
                                t.warn
                            } else if keyword {
                                t.accent
                            } else {
                                base
                            },
                        ));
                    }
                }
            }
        } else {
            let mut inline = false;
            for c in body.chars() {
                if !user && c == '`' {
                    inline = !inline;
                    continue;
                }
                styled.push((c, if inline { t.accent } else { base }));
            }
        }
        let mut col = prefix
            .iter()
            .map(|s| width(&s.content, a.ambiguous_width))
            .sum::<usize>();
        for (c, style) in styled {
            let cw = if a.ambiguous_width == 2 {
                c.width_cjk().unwrap_or(0)
            } else {
                c.width().unwrap_or(0)
            };
            if col + cw > w && col > 2 {
                out.push(Line::from(std::mem::take(&mut prefix)));
                let cont = if code {
                    format!("  {} ", glyph(a, "│", "|"))
                } else {
                    "  ".into()
                };
                col = width(&cont, a.ambiguous_width);
                prefix.push(Span::styled(cont, t.muted));
            }
            prefix.push(Span::styled(c.to_string(), style));
            col += cw;
        }
        out.push(Line::from(prefix));
    }
    out
}
fn table_lines(a: &App, rows: &[&str], w: usize) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let parsed: Vec<Vec<String>> = rows
        .iter()
        .filter(|r| !r.chars().all(|c| matches!(c, '|' | '-' | ':' | ' ')))
        .map(|r| {
            r.trim()
                .trim_matches('|')
                .split('|')
                .map(|s| s.trim().to_owned())
                .collect()
        })
        .collect();
    let cols = parsed.iter().map(Vec::len).max().unwrap_or(1).max(1);
    let available = w.saturating_sub(3 + cols * 3);
    let mut widths = vec![1; cols];
    for row in &parsed {
        for (i, c) in row.iter().enumerate() {
            widths[i] = widths[i]
                .max(width(c, a.ambiguous_width))
                .min((available / cols).max(1));
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
    for (i, row) in parsed.iter().enumerate() {
        let mut cells = vec![];
        for (col, w) in widths.iter().enumerate() {
            let value = truncate(
                row.get(col).map_or("", String::as_str),
                *w,
                a.ambiguous_width,
            );
            let pad = w.saturating_sub(width(&value, a.ambiguous_width));
            cells.push(format!(" {value}{} ", " ".repeat(pad)));
        }
        out.push(line(
            format!(
                "  {}{}{}",
                glyph(a, "│", "|"),
                cells.join(glyph(a, "│", "|")),
                glyph(a, "│", "|")
            ),
            Style::default(),
        ));
        if i == 0 && parsed.len() > 1 {
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
