use crate::{
    app::{App, items, text},
    ui::{self, Theme},
};
use ratatui::{
    Frame,
    layout::Rect,
    style::Modifier,
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Paragraph},
};

fn cards(a: &App, area: Rect) -> Vec<(Rect, usize)> {
    let count = items(&a.snapshot, "agents").len();
    let columns = if area.width >= 100 { 2 } else { 1 };
    let rows = area.height.saturating_sub(4) / 7;
    let capacity = (rows as usize * columns).max(1);
    let selected = a.selected % count.max(1);
    let start = selected / capacity * capacity;
    let width = area.width.saturating_sub(4) / columns as u16;
    (start..(start + capacity).min(count))
        .map(|i| {
            let j = i - start;
            (
                Rect::new(
                    area.x + 2 + j as u16 % columns as u16 * width,
                    area.y + 3 + (j / columns) as u16 * 7,
                    width.saturating_sub(1),
                    6,
                ),
                i,
            )
        })
        .filter(|(r, _)| r.bottom() <= area.bottom())
        .collect()
}
pub fn enabled(width: u16, height: u16) -> bool {
    width >= 90 && height >= 28
}
pub fn hit(a: &App, width: u16, height: u16, x: u16, y: u16) -> Option<usize> {
    cards(a, Rect::new(0, 0, width, height.saturating_sub(1)))
        .into_iter()
        .find(|(r, _)| r.contains((x, y).into()))
        .map(|(_, i)| i)
}
pub fn draw(f: &mut Frame, a: &App, area: Rect) {
    let t = Theme::new(a);
    let agents = items(&a.snapshot, "agents");
    let active = agents
        .iter()
        .filter(|v| matches!(text(v, "status"), "running" | "queued" | "waiting"))
        .count();
    f.render_widget(
        Paragraph::new(format!(
            "  子代理蜂群   {active} 活动 / {} 总计",
            agents.len()
        ))
        .style(t.accent.add_modifier(Modifier::BOLD)),
        Rect::new(area.x, area.y, area.width, 1),
    );
    f.render_widget(
        Paragraph::new("  ↑↓ 选择 · Enter 详情 · m 补充任务 · x 停止 · /subagent 手动创建")
            .style(t.muted),
        Rect::new(area.x, area.y + 1, area.width, 1),
    );
    if agents.is_empty() {
        f.render_widget(
            Paragraph::new("还没有子代理。在会话输入 /subagent 模型 high 提示词 创建。")
                .style(t.muted),
            Rect::new(area.x + 2, area.y + 4, area.width.saturating_sub(4), 2),
        );
        return;
    }
    for (r, i) in cards(a, area) {
        let v = &agents[i];
        let selected = i == a.selected % agents.len();
        let status = text(v, "status");
        let status_label = match status {
            "running" => "运行中",
            "queued" => "排队中",
            "waiting" => "等待中",
            "completed" => "已完成",
            "failed" => "失败",
            "cancelled" => "已停止",
            "interrupted" => "已中断",
            other => other,
        };
        let color = match status {
            "failed" | "cancelled" | "interrupted" => t.bad,
            "completed" => t.good,
            _ => t.accent,
        };
        let mut block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(if selected { t.accent } else { t.muted });
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
        block = block.title(format!(
            " {} {} ",
            if selected { ">" } else { " " },
            ui::truncate(
                text(v, "name"),
                r.width.saturating_sub(9) as usize,
                a.ambiguous_width
            )
        ));
        f.render_widget(block, r);
        let lines = vec![
            Line::from(vec![
                Span::styled(
                    format!(
                        "{} {status_label}  ",
                        if a.ascii || a.ambiguous_width == 2 {
                            "*"
                        } else {
                            "●"
                        }
                    ),
                    color,
                ),
                Span::styled(text(v, "model").to_owned(), t.muted),
            ]),
            Line::from(ui::truncate(
                text(v, "activity"),
                r.width.saturating_sub(4) as usize,
                a.ambiguous_width,
            )),
            Line::from(Span::styled(
                ui::truncate(
                    text(v, "task"),
                    r.width.saturating_sub(4) as usize,
                    a.ambiguous_width,
                ),
                t.muted,
            )),
            Line::from(Span::styled(
                format!(
                    "{} 轮 · 输入 {} · 输出 {}",
                    v["rounds"].as_u64().unwrap_or(0),
                    v["input_tokens"].as_u64().unwrap_or(0),
                    v["output_tokens"].as_u64().unwrap_or(0)
                ),
                t.muted,
            )),
        ];
        f.render_widget(
            Paragraph::new(lines),
            Rect::new(r.x + 1, r.y + 1, r.width.saturating_sub(2), 4),
        );
    }
}
