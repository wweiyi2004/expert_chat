use crate::{
    app::{App, items, text},
    ui::{self, PopupAction, Theme},
};
use ratatui::{
    Frame,
    layout::Rect,
    style::Modifier,
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph},
};

pub fn effort_rect(width: u16, height: u16) -> Rect {
    let h = height.saturating_sub(2).min(10);
    Rect::new(0, height.saturating_sub(h + 2), width, h)
}

fn choices(a: &App, rect: Rect) -> Vec<(Rect, usize)> {
    let count = a.current_efforts().len();
    if count == 0 || rect.width < 16 || rect.height < 6 {
        return vec![];
    }
    let available = rect.width.saturating_sub(8).min(70);
    let left = rect.x + (rect.width - available) / 2;
    let step = available / count as u16;
    (0..count)
        .map(|i| {
            (
                Rect::new(left + i as u16 * step, rect.y + 4, step.max(1), 2),
                i,
            )
        })
        .collect()
}

pub fn effort_hit(a: &App, width: u16, height: u16, x: u16, y: u16) -> Option<PopupAction> {
    let r = effort_rect(width, height);
    if !r.contains((x, y).into()) {
        return None;
    }
    for (r, index) in choices(a, r) {
        if r.contains((x, y).into()) {
            return Some(PopupAction::Item(index));
        }
    }
    if y == r.y + 7 {
        return Some(PopupAction::Thinking);
    }
    if y == r.bottom().saturating_sub(1) {
        return Some(PopupAction::Apply);
    }
    None
}

pub fn draw_effort(f: &mut Frame, a: &App) {
    let t = Theme::new(a);
    let rect = effort_rect(f.area().width, f.area().height);
    f.render_widget(Clear, rect);
    f.render_widget(
        Block::default()
            .borders(Borders::TOP)
            .border_style(t.accent),
        rect,
    );
    let put = |f: &mut Frame, y: u16, content: Line<'static>| {
        if y < rect.height {
            f.render_widget(
                Paragraph::new(content),
                Rect::new(2, rect.y + y, rect.width.saturating_sub(4), 1),
            );
        }
    };
    put(
        f,
        1,
        Line::from(Span::styled(
            "思考强度 · Effort",
            t.accent.add_modifier(Modifier::BOLD),
        )),
    );
    let levels = a.current_efforts();
    let ranges = choices(a, rect);
    if ranges.is_empty() {
        put(f, 3, Line::from("当前模型不支持调整思考强度"));
    } else {
        let first = ranges[0].0.x;
        let last = ranges.last().unwrap().0;
        f.render_widget(Paragraph::new("更快"), Rect::new(first, rect.y + 3, 6, 1));
        f.render_widget(
            Paragraph::new("更深入"),
            Rect::new(last.x, rect.y + 3, last.width, 1),
        );
        for (r, index) in ranges {
            let selected = index == a.effort_index % levels.len();
            let rail = if a.ascii || a.ambiguous_width == 2 {
                if selected { "^" } else { "-" }
            } else if selected {
                "▲"
            } else {
                "─"
            };
            let style = if selected {
                t.accent.add_modifier(Modifier::BOLD)
            } else {
                t.muted
            };
            f.render_widget(
                Paragraph::new({
                    let length = r.width.saturating_sub(1).max(1) as usize;
                    let mid = length / 2;
                    let line = if a.ascii || a.ambiguous_width == 2 {
                        "-"
                    } else {
                        "─"
                    };
                    format!(
                        "{}{}{}",
                        line.repeat(mid),
                        rail,
                        line.repeat(length.saturating_sub(mid + 1))
                    )
                })
                .style(style),
                Rect::new(r.x, r.y, r.width, 1),
            );
            f.render_widget(
                Paragraph::new(format!(
                    "{:^width$}",
                    levels[index].as_str().unwrap_or(""),
                    width = r.width as usize
                ))
                .style(style),
                Rect::new(r.x, r.y + 1, r.width, 1),
            );
        }
    }
    put(
        f,
        7,
        Line::from(vec![
            Span::styled("思考 ", t.muted),
            Span::styled(if a.thinking { "开启" } else { "关闭" }, t.accent),
            Span::styled("   Tab / 空格 切换", t.muted),
        ]),
    );
    put(
        f,
        rect.height.saturating_sub(1),
        Line::from(Span::styled("←/→ 调整 · [应用] Enter · Esc 取消", t.muted)),
    );
}

pub fn pinned_user(a: &App) -> Option<(&str, &str)> {
    if a.view != crate::app::View::Chat {
        return None;
    }
    let messages = items(&a.snapshot, "messages");
    let end = a
        .reading_anchor
        .as_ref()
        .and_then(|anchor| anchor.message_id.as_ref())
        .and_then(|id| messages.iter().position(|m| text(m, "id") == id))
        .map_or(messages.len(), |index| index + 1);
    messages[..end]
        .iter()
        .rev()
        .find(|m| text(m, "role") == "user")
        .map(|m| (text(m, "id"), ui::message_display_text(m)))
}
pub fn pinned_height(a: &App, height: u16) -> u16 {
    u16::from(height >= 12 && pinned_user(a).is_some())
}

pub fn draw_pinned_user(f: &mut Frame, a: &App, width: u16) {
    let Some((_, value)) = pinned_user(a) else {
        return;
    };
    if f.area().height < 12 || width == 0 {
        return;
    }
    let clean = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let marker = if a.ascii || a.ambiguous_width == 2 {
        ">"
    } else {
        "›"
    };
    let total = items(&a.snapshot, "messages")
        .iter()
        .filter(|m| text(m, "role") == "user")
        .count();
    let current = items(&a.snapshot, "messages")
        .iter()
        .filter(|m| text(m, "role") == "user")
        .position(|m| text(m, "id") == pinned_user(a).unwrap().0)
        .map_or(0, |i| i + 1);
    let hint = format!("  ↑↓ 提问 {current}/{total} ");
    let hint_width = ui::width(&hint, a.ambiguous_width);
    let title = ui::truncate(
        &format!(" {marker} {clean}"),
        (width as usize).saturating_sub(hint_width),
        a.ambiguous_width,
    );
    let style = ui::input_surface(a).patch(Theme::new(a).muted);
    f.render_widget(
        Paragraph::new(format!(
            "{title}{}{hint}",
            " ".repeat(
                (width as usize).saturating_sub(hint_width + ui::width(&title, a.ambiguous_width))
            )
        ))
        .style(style),
        Rect::new(0, 0, width, 1),
    );
}

pub fn hero(a: &App, width: usize, height: u16) -> bool {
    ui::welcome(a)
        && width >= 104
        && height >= 30
        && ui::welcome_graphics_height(a, width as u16, height) >= 21
        && !a.suppress_welcome
}

fn letters(c: char) -> [&'static str; 7] {
    match c {
        'E' => [
            "11111", "10000", "10000", "11110", "10000", "10000", "11111",
        ],
        'X' => [
            "10001", "10001", "01010", "00100", "01010", "10001", "10001",
        ],
        'P' => [
            "11110", "10001", "10001", "11110", "10000", "10000", "10000",
        ],
        'R' => [
            "11110", "10001", "10001", "11110", "10100", "10010", "10001",
        ],
        'T' => [
            "11111", "00100", "00100", "00100", "00100", "00100", "00100",
        ],
        'C' => [
            "01111", "10000", "10000", "10000", "10000", "10000", "01111",
        ],
        'H' => [
            "10001", "10001", "10001", "11111", "10001", "10001", "10001",
        ],
        'A' => [
            "01110", "10001", "10001", "11111", "10001", "10001", "10001",
        ],
        _ => ["00000"; 7],
    }
}

pub fn hero_lines(a: &App, width: usize, height: u16) -> Vec<Line<'static>> {
    let t = Theme::new(a);
    let mut result = vec![];
    let stretch = width.saturating_sub(48) as f64 / 36.0;
    let stretch = stretch.clamp(1.0, 4.0);
    for word in ["EXPERT", "CHAT"] {
        let rows = (0..7)
            .map(|y| {
                word.chars()
                    .map(|c| letters(c)[y])
                    .collect::<Vec<_>>()
                    .join("0")
                    .into_bytes()
            })
            .collect::<Vec<_>>();
        for y in 0..8 {
            let mut spans = vec![Span::raw(" ".repeat(46))];
            let columns = ((rows[0].len() + 1) as f64 * stretch).floor() as usize;
            for column in 0..columns {
                let x = (column as f64 / stretch).floor() as usize;
                let face = y < 7 && rows[y].get(x) == Some(&b'1');
                let shadow = y > 0 && x > 0 && rows[y - 1].get(x - 1) == Some(&b'1');
                spans.push(if face {
                    Span::styled(
                        if a.ascii { "#" } else { "█" },
                        t.accent.add_modifier(Modifier::BOLD),
                    )
                } else if shadow {
                    Span::styled(if a.ascii { "/" } else { "▓" }, t.muted)
                } else {
                    Span::raw(" ")
                });
            }
            result.push(Line::from(spans));
        }
        result.push(Line::default());
    }
    let s = &a.snapshot["session"];
    for value in [
        format!("{} · {}", text(s, "model"), text(s, "effort")),
        ui::display_path(text(s, "workspace_path")),
    ] {
        result.push(Line::from(vec![
            Span::raw(" ".repeat(46)),
            Span::styled(
                ui::truncate(&value, width.saturating_sub(46), a.ambiguous_width),
                t.muted,
            ),
        ]));
    }
    if let Some(pet) = ui::pet_rect(a, width as u16, height) {
        result.resize_with(result.len().max(pet.bottom() as usize + 2), Line::default);
    }
    result
}
