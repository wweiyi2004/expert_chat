use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use expert_tui::app::{App, FormKind};
use serde_json::json;
use std::time::Instant;
fn app() -> App {
    let mut a = App::default();
    a.apply_snapshot(json!({"session":{"id":"s","model":"m","model_choice":"p:m","status":"idle","mode":"work","effort":"high"},"models":[{"id":"m","choice":"p:m","efforts":["low","high"]}],"messages":[]}));
    a
}
fn send(a: &mut App, s: &str) -> Vec<expert_tui::app::Command> {
    a.paste(s);
    a.key(KeyEvent::from(KeyCode::Enter), Instant::now(), 100)
}
#[test]
fn code_editor_pairs_indents_and_undoes() {
    let mut a = app();
    send(&mut a, "/editor rust");
    a.native_editor_key(KeyEvent::from(KeyCode::Char('{')));
    assert_eq!(a.native_editor.as_ref().unwrap().text, "{}");
    a.native_editor_key(KeyEvent::from(KeyCode::Enter));
    assert_eq!(a.native_editor.as_ref().unwrap().text, "{\n    \n}");
    a.native_editor_key(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::CONTROL));
    assert_eq!(a.native_editor.as_ref().unwrap().text, "{}");
}
#[test]
fn manual_subagent_keeps_model_effort_prompt_and_write_scope() {
    let mut a = app();
    let c = send(
        &mut a,
        "/subagent --write=src/a.rs p:m high \"edit this file\"",
    );
    assert_eq!(c[0].params["action"], "subagent.start");
    assert_eq!(c[0].params["model"], "p:m");
    assert_eq!(c[0].params["text"], "edit this file");
    assert_eq!(c[0].params["owned_paths"], json!(["src/a.rs"]));
}
#[test]
fn external_import_requires_preview_then_explicit_confirmation() {
    let mut a = app();
    let c = a.scan_external_sessions(true).remove(0);
    a.session_import_response(
        &c,
        &json!({"sessions":[{"id":"e","source":"Codex","title":"old","updated":"recent"}]}),
    );
    assert_eq!(a.form.as_ref().unwrap().kind, FormKind::ImportSessions);
    a.form.as_mut().unwrap().selected = 1;
    assert!(a.session_import_action().unwrap().is_empty());
    a.form.as_mut().unwrap().selected = 1;
    let preview = a.session_import_action().unwrap().remove(0);
    assert_eq!(preview.params["topic"], "session.import.preview");
    a.session_import_response(&preview,&json!({"id":"e","fingerprint":"hash","source":"Codex","title":"old","preview":"user: hello"}));
    a.form.as_mut().unwrap().selected = a
        .form
        .as_ref()
        .unwrap()
        .fields
        .iter()
        .position(|f| f.key == "import")
        .unwrap();
    let import = a.session_import_action().unwrap().remove(0);
    assert_eq!(import.params["confirmed"], true);
    assert_eq!(import.params["fingerprint"], "hash");
}
#[test]
fn settings_owns_window_configuration() {
    let mut a = app();
    let c = send(&mut a, "/settings context");
    assert_eq!(c[0].params["view"], "settings");
    a.close_popup();
    let c = send(&mut a, "/context");
    a.command_response(
        &c[0],
        &json!({"contents":{"input_budget":1000,"history_estimate":200,"tool_estimate":0}}),
    );
    assert!(a.info_lines.iter().any(|s| s.contains('▰')));
    assert!(!a.info_lines.iter().any(|s| s.contains("null")));
}

#[test]
fn swarm_cards_keep_ascii_frames_and_selected_agent_accessible() {
    let mut a = app();
    a.view = expert_tui::app::View::Agents;
    a.ascii = true;
    a.snapshot["agents"] = json!([{"id":"a","name":"FIRST","status":"running"},{"id":"b","name":"SECOND","status":"completed"}]);
    a.selected = 1;
    let mut t = ratatui::Terminal::new(ratatui::backend::TestBackend::new(140, 40)).unwrap();
    t.draw(|f| expert_tui::ui::draw(f, &a)).unwrap();
    let text = expert_tui::ui::buffer_text(t.backend().buffer());
    assert!(text.contains("FIRST") && text.contains("SECOND"));
    for c in ['╭', '╮', '╰', '╯', '│'] {
        assert!(!text.contains(c));
    }
    let open = a.key(KeyEvent::from(KeyCode::Enter), Instant::now(), 140);
    assert_eq!(open[0].params["topic"], "wb.agent.poll");
    assert_eq!(open[0].params["agent_id"], "b");
}

#[test]
fn wide_welcome_stretches_portrait_vertically_and_title_horizontally() {
    let mut a = app();
    a.truecolor = true;
    a.sidebar = false;
    a.viewport = (120, 36);
    let pet = expert_tui::ui::pet_rect(&a, 120, 36).unwrap();
    assert!(pet.width <= 40 && pet.height <= 24);
    assert!((pet.width as f64 / (pet.height * 2) as f64 - 64.0 / 80.0).abs() < 0.05);
    for width in [104, 120, 160] {
        let lines = expert_tui::presentation::hero_lines(&a, width, 36);
        let first: String = lines[0].spans.iter().map(|s| s.content.as_ref()).collect();
        let used = expert_tui::ui::width(&first, 1);
        assert!(used <= width);
        assert!(
            used >= width - 3,
            "title should use the right-hand area: {width} {used}"
        );
    }
}
