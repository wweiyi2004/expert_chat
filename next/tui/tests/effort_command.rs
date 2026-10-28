use crossterm::event::{KeyCode as K, KeyEvent};
use expert_tui::{
    app::{App, Command, Drawer},
    ui,
};
use ratatui::{Terminal, backend::TestBackend};
use serde_json::json;
use std::time::Instant;

fn app() -> App {
    let mut app = App::default();
    app.apply_snapshot(json!({
        "session":{"id":"s1","status":"idle","mode":"work","permission":"request",
            "model":"model","model_choice":"c1","thinking":true,"effort":"high"},
        "messages":[],"models":[{"id":"model","choice":"c1","efforts":["low","medium","high"]}]
    }));
    app
}
fn key(a: &mut App, k: K) -> Vec<Command> {
    a.key(KeyEvent::from(k), Instant::now(), 80)
}
fn send(a: &mut App, text: &str) -> Vec<Command> {
    a.paste(text);
    key(a, K::Enter)
}
fn text(a: &App) -> String {
    let mut t = Terminal::new(TestBackend::new(80, 24)).unwrap();
    t.draw(|f| ui::draw(f, a)).unwrap();
    ui::buffer_text(t.backend().buffer())
}

#[test]
fn bare_effort_opens_its_own_picker_on_the_current_level() {
    let mut a = app();
    assert!(send(&mut a, "/effort").is_empty());
    assert_eq!(a.drawer, Some(Drawer::Effort));
    let out = text(&a);
    assert!(out.contains("思考强度"), "{out}");
    assert_eq!(a.effort_index, 2);
    assert!(
        out.contains("low") && out.contains("medium") && out.contains("high"),
        "{out}"
    );
    assert!(out.contains("更快") && out.contains("更深入"), "{out}");
    key(&mut a, K::Up);
    key(&mut a, K::Char(' '));
    let c = key(&mut a, K::Enter);
    assert_eq!(c.len(), 1);
    assert_eq!(c[0].method, "model.set");
    assert_eq!(c[0].params["choice"], "c1");
    assert_eq!(c[0].params["effort"], "medium");
    assert_eq!(c[0].params["thinking"], false);
    assert_eq!(a.drawer, None);
}

#[test]
fn effort_arguments_apply_directly_in_english_or_chinese() {
    for (arg, effort, thinking) in [
        ("low", json!("low"), true),
        ("中", json!("medium"), true),
        ("off", json!("high"), false),
        ("开", json!("high"), true),
    ] {
        let mut a = app();
        let c = send(&mut a, &format!("/effort {arg}"));
        assert_eq!(c.len(), 1, "{arg}");
        assert_eq!(c[0].method, "model.set");
        assert_eq!(c[0].params["effort"], effort, "{arg}");
        assert_eq!(c[0].params["thinking"], thinking, "{arg}");
    }
}

#[test]
fn unsupported_or_busy_effort_changes_explain_instead_of_sending() {
    let mut a = app();
    assert!(send(&mut a, "/effort max").is_empty());
    assert!(a.notice.contains("low/medium/high"), "{}", a.notice);
    let mut a = app();
    assert!(send(&mut a, "/effort turbo").is_empty());
    assert!(a.notice.contains("用法"), "{}", a.notice);
    let mut a = app();
    a.snapshot["session"]["status"] = json!("running");
    assert!(a.extra_command("/effort", "low").is_empty());
    assert!(a.notice.contains("任务结束后"), "{}", a.notice);
}

#[test]
fn model_drawer_points_to_effort_instead_of_editing_it() {
    let mut a = app();
    a.open(Drawer::Model);
    let out = text(&a);
    assert!(out.contains("/effort 调整"), "{out}");
    key(&mut a, K::Right);
    let c = key(&mut a, K::Enter);
    assert_eq!(c[0].params["effort"], "high");
}
