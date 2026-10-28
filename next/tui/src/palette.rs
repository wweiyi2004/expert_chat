use crate::{
    app::{App, FormKind},
    theme::{self, SKINS},
    ui::PopupAction,
};
use ratatui::{
    Frame,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph},
};

pub struct PaletteLayout {
    pub rect: Rect,
    pub columns: usize,
    pub tiles: Vec<(usize, Rect)>,
    pub preview: Rect,
    pub custom: Rect,
    pub apply: Rect,
}

pub fn is_picker(a: &App) -> bool {
    a.form
        .as_ref()
        .is_some_and(|f| f.kind == FormKind::Skin && f.fields.iter().any(|v| v.key == "__custom"))
}
pub fn layout(a: &App, w: u16, h: u16) -> PaletteLayout {
    let width = w.saturating_sub(4).min(106).max(w.min(24));
    let side = width >= 74 && h >= 18;
    let cols = if side {
        if width >= 98 { 4 } else { 3 }
    } else {
        ((width.saturating_sub(4)) / 14).clamp(1, 4) as usize
    };
    let rows = SKINS.len().div_ceil(cols);
    let height =
        (if side { rows * 2 + 5 } else { rows * 2 + 11 }).min(h.saturating_sub(3) as usize) as u16;
    let rect = Rect::new(
        (w - width) / 2,
        h.saturating_sub(height + 1) / 2,
        width,
        height,
    );
    let inner = Rect::new(
        rect.x + 2,
        rect.y + 1,
        rect.width.saturating_sub(4),
        rect.height.saturating_sub(3),
    );
    let (grid, preview) = if side {
        let pw = 28;
        (
            Rect::new(
                inner.x,
                inner.y,
                inner.width.saturating_sub(pw + 2),
                inner.height,
            ),
            Rect::new(
                inner.right().saturating_sub(pw),
                inner.y,
                pw,
                inner.height.min(12),
            ),
        )
    } else {
        let ph = 6.min(inner.height.saturating_sub(3));
        (
            Rect::new(
                inner.x,
                inner.y,
                inner.width,
                inner.height.saturating_sub(ph + 1),
            ),
            Rect::new(inner.x, inner.bottom().saturating_sub(ph), inner.width, ph),
        )
    };
    let tile_h = if grid.height >= 4 { 2 } else { 1 };
    let visible = (grid.height / tile_h).max(1) as usize;
    let selected = a
        .form
        .as_ref()
        .map_or(0, |f| f.selected.min(SKINS.len() - 1));
    let first = (selected / cols)
        .saturating_sub(visible / 2)
        .min(rows.saturating_sub(visible));
    let tw = grid.width / (cols as u16).max(1);
    let tiles = (first * cols..((first + visible) * cols).min(SKINS.len()))
        .map(|i| {
            (
                i,
                Rect::new(
                    grid.x + (i % cols) as u16 * tw,
                    grid.y + (i / cols - first) as u16 * tile_h,
                    tw,
                    tile_h,
                ),
            )
        })
        .collect();
    let bottom = rect.bottom().saturating_sub(2);
    PaletteLayout {
        rect,
        columns: cols,
        tiles,
        preview,
        custom: Rect::new(inner.x, bottom, inner.width.min(12), 1),
        apply: Rect::new(
            inner.right().saturating_sub(10),
            bottom,
            inner.width.min(10),
            1,
        ),
    }
}

pub fn hit(a: &App, w: u16, h: u16, x: u16, y: u16) -> Option<PopupAction> {
    let l = layout(a, w, h);
    let p = (x, y).into();
    if l.custom.contains(p) {
        return Some(PopupAction::SkinCustom);
    }
    if l.apply.contains(p) {
        return Some(PopupAction::SkinApply);
    }
    l.tiles
        .into_iter()
        .find(|(_, r)| r.contains(p))
        .map(|(i, _)| PopupAction::SkinSelect(i))
}

fn colors(a: &App, id: &str) -> (Color, Color, Color, Color, Color) {
    let light = theme::skin_is_light(id).unwrap_or(a.terminal_light.unwrap_or(a.light));
    let c = theme::skin_colors(id, light);
    let bg = c.background.unwrap_or(if light {
        Color::Rgb(250, 250, 250)
    } else {
        Color::Rgb(24, 28, 34)
    });
    (
        bg,
        c.foreground
            .unwrap_or(if light { Color::Black } else { Color::White }),
        c.accent.unwrap_or(Color::Cyan),
        c.muted.unwrap_or(Color::Gray),
        c.user_background.unwrap_or(if light {
            Color::Rgb(225, 229, 232)
        } else {
            Color::Rgb(48, 50, 58)
        }),
    )
}
fn frame(title: &str, style: Style) -> Block<'_> {
    Block::default()
        .borders(Borders::ALL)
        .border_set(ratatui::symbols::border::Set {
            top_left: "+",
            top_right: "+",
            bottom_left: "+",
            bottom_right: "+",
            vertical_left: "|",
            vertical_right: "|",
            horizontal_top: "-",
            horizontal_bottom: "-",
        })
        .title(title)
        .style(style)
}
pub fn draw(f: &mut Frame, a: &App) {
    let area = f.area();
    if area.width < 12 || area.height < 8 {
        return;
    }
    let l = layout(a, area.width, area.height);
    let selected = a.form.as_ref().map_or(0, |v| v.selected);
    let (bg, fg, _, _, _) = colors(a, &a.skin);
    let base = if a.no_color {
        Style::default()
    } else {
        Style::default().fg(fg).bg(bg)
    };
    f.render_widget(Clear, l.rect);
    f.render_widget(frame(" 配色 · 方向键预览，Enter 保存 ", base), l.rect);
    let close = Rect::new(l.rect.right().saturating_sub(5), l.rect.y, 3, 1);
    f.render_widget(Paragraph::new("[x]").style(base), close);
    for (index, r) in &l.tiles {
        let (id, label) = SKINS[*index];
        let (tile_bg, tile_fg, tile_accent, _, _) = colors(a, id);
        let active = selected == *index;
        let st = if a.no_color {
            Style::default()
        } else {
            Style::default().fg(tile_fg).bg(tile_bg)
        };
        let title = format!("{} {}", if active { ">" } else { " " }, label);
        let mut lines = vec![Line::styled(
            title,
            st.add_modifier(if active {
                Modifier::BOLD
            } else {
                Modifier::empty()
            }),
        )];
        if r.height > 1 {
            lines.push(Line::from(vec![
                Span::raw("  "),
                Span::styled("    ", if a.no_color { st } else { st.bg(tile_accent) }),
                Span::styled(if a.skin == id { " 当前" } else { "" }, st),
            ]));
        }
        f.render_widget(
            Paragraph::new(lines).style(st),
            Rect::new(r.x, r.y, r.width.saturating_sub(1), r.height),
        );
    }
    let id = SKINS.get(selected).map_or(a.skin.as_str(), |(id, _)| *id);
    let label = SKINS
        .iter()
        .find(|(key, _)| *key == id)
        .map_or(id, |(_, label)| *label);
    let (bg, fg, accent, muted, user_bg) = colors(a, id);
    let st = if a.no_color {
        Style::default()
    } else {
        Style::default().bg(bg).fg(fg)
    };
    let border = frame(label, st);
    let inner = border.inner(l.preview);
    f.render_widget(border, l.preview);
    if inner.height > 0 {
        let mut rows = vec![
            Line::styled(
                " 你：帮我整理项目 ",
                if a.no_color { st } else { st.bg(user_bg) },
            ),
            Line::styled(
                " Agent 正在读取文件",
                if a.no_color { st } else { st.fg(accent) },
            ),
            Line::styled(
                " 已完成 3 步 · 点击查看",
                if a.no_color { st } else { st.fg(muted) },
            ),
            Line::styled(" > 输入你的问题", st),
        ];
        if inner.height >= 6 {
            rows.push(Line::styled(
                " 上下文 12% · 输出 1.2k",
                if a.no_color { st } else { st.fg(muted) },
            ));
        }
        if inner.height >= 8 {
            rows.push(Line::styled(
                " 错误提示示例",
                if a.no_color {
                    st
                } else {
                    st.fg(theme::skin_colors(id, false).bad.unwrap_or(Color::Red))
                },
            ));
        }
        f.render_widget(Paragraph::new(rows).style(st), inner);
    }
    f.render_widget(
        Paragraph::new(if selected == SKINS.len() {
            "> 自定义"
        } else {
            "[自定义]"
        })
        .style(base),
        l.custom,
    );
    f.render_widget(
        Paragraph::new("[应用配色]").style(if a.no_color { base } else { base.fg(accent) }),
        l.apply,
    );
}
