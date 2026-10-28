use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use expert_tui::{
    app::{App, FormKind},
    ui,
};
use ratatui::{Terminal, backend::TestBackend};
use serde_json::json;
use std::time::Instant;

fn settings() -> App {
    let mut app = App {
        reduce_motion: true,
        ..Default::default()
    };
    app.apply_snapshot(json!({
        "session": {"id":"dialog-session","status":"idle"},
        "settings": {"providers":[{"id":"p1","name":"Existing provider","enabled":true}],
            "mcp":[{"id":"m1","name":"Existing MCP","transport":"stdio"}]},
        "messages":[]
    }));
    app.open_settings();
    app
}
fn open(app: &mut App, key: &str) {
    let index = app
        .form
        .as_ref()
        .unwrap()
        .fields
        .iter()
        .position(|f| f.key == key)
        .unwrap();
    app.click_form_field(index);
}
fn select(app: &mut App, key: &str) {
    let form = app.form.as_mut().unwrap();
    form.selected = form.fields.iter().position(|f| f.key == key).unwrap();
}
fn press(app: &mut App, code: KeyCode) -> Vec<expert_tui::app::Command> {
    app.key(KeyEvent::new(code, KeyModifiers::NONE), Instant::now(), 80)
}
fn value<'a>(app: &'a App, key: &str) -> &'a str {
    let form = app.form.as_ref().unwrap();
    &form.fields.iter().find(|f| f.key == key).unwrap().value
}
fn text(app: &App, w: u16, h: u16) -> String {
    let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
    t.draw(|f| ui::draw(f, app)).unwrap();
    ui::buffer_text(t.backend().buffer())
}

#[test]
fn adding_from_settings_opens_a_stacked_dialog_over_the_list() {
    for (entry, kind, title) in [
        ("provider.new", FormKind::Provider, "添加模型来源"),
        ("mcp.new", FormKind::Mcp, "添加 MCP 服务"),
    ] {
        let mut app = settings();
        open(&mut app, entry);
        assert_eq!(app.form.as_ref().unwrap().kind, kind);
        assert!(app.form_backdrop.is_some());
        for (w, h) in [(120, 40), (80, 24)] {
            let out = text(&app, w, h);
            assert!(out.contains(&format!("终端设置 › {title}")), "{out}");
            // The parent settings frame stays behind the dialog when there is room.
            assert_eq!(out.contains("╭ 终端设置 ─"), w >= 120, "{out}");
            let dialog = ui::popup_rect(&app, w, h).unwrap();
            assert!(dialog.width <= 78 && dialog.x > 0, "{dialog:?}");
        }
        press(&mut app, KeyCode::Esc);
        press(&mut app, KeyCode::Esc);
        assert_eq!(app.form.as_ref().unwrap().kind, FormKind::Settings);
        assert!(app.form_backdrop.is_none());
    }
}

#[test]
fn closed_option_fields_cycle_instead_of_accepting_free_text() {
    let mut app = settings();
    open(&mut app, "mcp.new");
    select(&mut app, "transport");
    assert_eq!(value(&app, "transport"), "stdio");
    press(&mut app, KeyCode::Char('x'));
    press(&mut app, KeyCode::Backspace);
    assert_eq!(value(&app, "transport"), "stdio");
    press(&mut app, KeyCode::Right);
    assert_eq!(value(&app, "transport"), "http");
    press(&mut app, KeyCode::Char(' '));
    assert_eq!(value(&app, "transport"), "stdio");
    press(&mut app, KeyCode::Left);
    assert_eq!(value(&app, "transport"), "http");
    assert!(text(&app, 100, 30).contains("◉ 远程 HTTP"));
}

#[test]
fn unsaved_dialog_marks_object_actions_as_available_after_save() {
    let mut app = settings();
    open(&mut app, "mcp.new");
    select(&mut app, "__remove");
    let out = text(&app, 100, 40);
    assert!(out.contains("保存后可用"), "{out}");
    assert!(out.contains("保存后自动生成"), "{out}");
    assert!(press(&mut app, KeyCode::Enter).is_empty());
}

#[test]
fn direct_connect_dialog_has_no_stale_backdrop() {
    let mut app = settings();
    open(&mut app, "provider.new");
    app.close_popup();
    app.close_popup();
    assert!(app.form.is_none() && app.form_backdrop.is_none());
    app.input = "/connect".into();
    press(&mut app, KeyCode::Enter);
    assert_eq!(app.form.as_ref().unwrap().kind, FormKind::Provider);
    assert!(app.form_backdrop.is_none());
    assert!(!text(&app, 80, 24).contains("Existing MCP"));
}
