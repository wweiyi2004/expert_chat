use crate::{
    app::{App, items, text},
    ui::{self, Theme},
};
use ratatui::{
    Frame,
    layout::Rect,
    text::{Line, Span},
    widgets::Paragraph,
};

pub fn active(a: &App) -> bool {
    let plan = &a.snapshot["plan"];
    plan["is_current"] != false
        && text(plan, "status") != "cancelled"
        && items(plan, "steps")
            .iter()
            .any(|s| !matches!(text(s, "status"), "completed" | "cancelled"))
}
pub fn height(a: &App, available: u16) -> u16 {
    if !active(a) || available < 3 {
        return 0;
    }
    (items(&a.snapshot["plan"], "steps").len() as u16 + 1)
        .min(5)
        .min(available)
}
pub fn draw(f: &mut Frame, a: &App, rect: Rect) {
    if rect.height < 2 {
        return;
    }
    let t = Theme::new(a);
    let steps = items(&a.snapshot["plan"], "steps");
    let done = steps
        .iter()
        .filter(|s| text(s, "status") == "completed")
        .count();
    let first = steps
        .iter()
        .position(|s| text(s, "status") == "running")
        .or_else(|| steps.iter().position(|s| text(s, "status") == "pending"))
        .unwrap_or(0);
    let rows = rect.height.saturating_sub(1) as usize;
    let start = first
        .saturating_sub(1)
        .min(steps.len().saturating_sub(rows));
    let title = format!("  待办 {done}/{} · /todo 查看全部", steps.len());
    let mut lines = vec![Line::from(Span::styled(
        ui::truncate(&title, rect.width as usize, a.ambiguous_width),
        t.accent,
    ))];
    for step in steps.iter().skip(start).take(rows) {
        let status = text(step, "status");
        let icon = match status {
            "completed" => {
                if a.ascii {
                    "[x]"
                } else {
                    "[✓]"
                }
            }
            "running" => "[>]",
            "cancelled" => "[-]",
            _ => "[ ]",
        };
        let value = format!("  {icon} {}", text(step, "title"));
        lines.push(Line::from(Span::styled(
            ui::truncate(&value, rect.width as usize, a.ambiguous_width),
            if status == "running" {
                t.accent
            } else {
                t.muted
            },
        )));
    }
    f.render_widget(Paragraph::new(lines), rect);
}
