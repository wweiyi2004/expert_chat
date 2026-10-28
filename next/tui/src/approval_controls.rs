use crate::{
    app::{App, items, text},
    ui::{self, Theme},
};
use ratatui::{
    layout::Rect,
    text::{Line, Span},
};
pub const LABELS: [&str; 4] = ["y 允许一次", "a 本会话允许", "n 拒绝", "e 拒绝并说明"];
/// Drawing and mouse handling use the same wrapped button geometry.
pub fn rows(a: &App, width: usize) -> (Vec<Line<'static>>, Vec<(Rect, usize)>) {
    let t = Theme::new(a);
    let approval = items(&a.snapshot, "approvals")
        .first()
        .map(|v| text(v, "id"))
        .unwrap_or("");
    let mut lines = vec![];
    let mut row = vec![];
    let mut x = 0;
    let mut hits = vec![];
    for (index, label) in LABELS.iter().enumerate() {
        let label = if width < 18 {
            ["y 一次", "a 本会话", "n 拒绝", "e 说明"][index]
        } else {
            label
        };
        let value = ui::truncate(&format!("[ {label} ]"), width, a.ambiguous_width);
        let columns = ui::width(&value, a.ambiguous_width);
        if x > 0 && x + 2 + columns > width {
            lines.push(Line::from(row));
            row = vec![];
            x = 0;
        }
        if x > 0 {
            row.push(Span::raw("  "));
            x += 2;
        }
        let selected = a
            .approval_focus
            .as_ref()
            .is_some_and(|(id, i)| id == approval && *i == index);
        hits.push((
            Rect::new(x as u16, lines.len() as u16, columns as u16, 1),
            index,
        ));
        row.push(Span::styled(
            value,
            if selected { t.selected } else { t.warn },
        ));
        x += columns;
    }
    if !row.is_empty() {
        lines.push(Line::from(row));
    }
    (lines, hits)
}
