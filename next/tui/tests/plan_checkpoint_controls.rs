use crossterm::event::{KeyCode, KeyEvent};
use expert_tui::{
    app::{App, Command, Drawer},
    editor,
};
use serde_json::json;
use std::time::Instant;
fn enter(app: &mut App, text: &str) -> Vec<Command> {
    app.input = text.into();
    app.cursor = app.input.len();
    app.key(KeyEvent::from(KeyCode::Enter), Instant::now(), 80)
}
#[test]
fn approval_requires_review_of_the_current_plan_version() {
    let mut app = App::default();
    app.apply_snapshot(json!({"session":{"id":"c","status":"running"},
      "plan":{"id":"p","revision":1,"content_hash":"first","body":"review me","steps":[]}}));
    assert!(enter(&mut app, "/plan approve 1").is_empty());
    enter(&mut app, "/plan");
    app.key(KeyEvent::from(KeyCode::Esc), Instant::now(), 80);
    let request = enter(&mut app, "/plan approve 1");
    assert_eq!(request[0].params["content_hash"], "first");
    app.snapshot["plan"]["revision"] = json!(2);
    app.snapshot["plan"]["content_hash"] = json!("second");
    assert!(enter(&mut app, "/plan approve 2").is_empty());
}
#[test]
fn checkpoint_restore_is_bound_to_the_reviewed_session_and_fingerprint() {
    let mut app = App::default();
    app.apply_snapshot(json!({"session":{"id":"c","status":"idle"}}));
    assert!(enter(&mut app, "/rewind files").is_empty());
    let request = app.command("checkpoint.preview", json!({"message_id":"m"}));
    app.command_response(
        &request,
        &json!({"session_id":"c","message_id":"m","fingerprint":"exact","files":[]}),
    );
    assert_eq!(app.drawer, Some(Drawer::CheckpointReview));
    app.key(KeyEvent::from(KeyCode::Esc), Instant::now(), 80);
    let restore = enter(&mut app, "/rewind files");
    assert_eq!(restore[0].params["fingerprint"], "exact");
    app.snapshot["session"]["id"] = json!("other");
    assert!(enter(&mut app, "/rewind both").is_empty());
}
#[test]
fn editor_arguments_do_not_interpret_shell_metacharacters() {
    assert_eq!(
        editor::arguments(r#""C:\Program Files\Editor\editor.exe" --wait "$HOME;$(literal)""#)
            .unwrap(),
        vec![
            r"C:\Program Files\Editor\editor.exe",
            "--wait",
            "$HOME;$(literal)"
        ]
    );
    assert!(editor::arguments("\"unterminated").is_err());
}

#[test]
fn patch_cursor_gap_requests_a_full_snapshot_without_appending_twice() {
    let mut app = App::default();
    app.apply_event(&json!({"v":1,"event":"snapshot","cursor":1,"data":{
      "session":{"id":"c","status":"running"},"messages":[{"id":"m","role":"assistant","text":"hello"}]}})).unwrap();
    let patch = json!({"v":1,"event":"snapshot.patch","data":{"base":1,"cursor":2,"fields":{},"remove":[],
      "arrays":{"messages":{"updates":[{"id":"m","fields":{},"append":{"text":" world"},"remove":[]}],"remove":[],"order":["m"]}}}});
    app.apply_event(&patch).unwrap();
    assert_eq!(app.snapshot["messages"][0]["text"], "hello world");
    app.apply_event(&patch).unwrap();
    assert_eq!(app.snapshot["messages"][0]["text"], "hello world");
    assert!(app.snapshot_stale);
    assert_eq!(app.outbox.last().unwrap().method, "snapshot.get");
}

#[test]
fn pending_plan_exposes_its_action_even_in_a_small_terminal() {
    let mut app = App::default();
    app.apply_snapshot(
        json!({"session":{"id":"c","status":"running","mode":"plan"},
      "plan":{"id":"p","revision":1,"status":"awaitingApproval","is_current":true},
      "messages":[{"id":"m","role":"assistant","text":"计划已生成"}]}),
    );
    let mut terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(40, 16)).unwrap();
    terminal
        .draw(|frame| expert_tui::ui::draw(frame, &app))
        .unwrap();
    let text = expert_tui::ui::buffer_text(terminal.backend().buffer());
    assert!(text.contains("等待计划审核"));
    assert!(text.contains("/plan"));
}
