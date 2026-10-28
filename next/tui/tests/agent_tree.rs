use crossterm::event::{KeyCode, KeyEvent};
use expert_tui::{
    app::{App, View},
    ui,
};
use serde_json::json;
use std::time::Instant;
fn tree() -> App {
    let mut app = App {
        view: View::Agents,
        reduce_motion: true,
        ..Default::default()
    };
    app.snapshot = json!({"session":{"id":"s"},"agents":[
        {"id":"root","parent_id":null,"name":"ROOT","status":"running"},
        {"id":"a","parent_id":"root","name":"PARENT_A","status":"completed"},
        {"id":"g","parent_id":"a","name":"GRANDCHILD_G","status":"running"},
        {"id":"h","parent_id":"a","name":"GRANDCHILD_H","status":"failed","output":"H_LOG"},
        {"id":"b","parent_id":"root","name":"SIBLING_B","status":"completed"},
        {"id":"orphan","parent_id":"missing","name":"ORPHAN","status":"waiting"},
        {"id":"cycle_a","parent_id":"cycle_b","name":"CYCLE_A","status":"waiting"},
        {"id":"cycle_b","parent_id":"cycle_a","name":"CYCLE_B","status":"waiting"}
    ]});
    app
}
#[test]
fn descendants_keep_connectors_statuses_and_width_bounds() {
    for width in [40, 80, 140] {
        let app = tree();
        let mut term =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, 24)).unwrap();
        term.draw(|f| ui::draw(f, &app)).unwrap();
        let rendered = ui::buffer_text(term.backend().buffer());
        for expected in [
            "├ ✓ PARENT_A",
            "│ ├ ◌ GRANDCHILD_G",
            "│ └ ✗ GRANDCHILD_H",
            "└ ✓ SIBLING_B",
            "ORPHAN",
            "CYCLE_A",
            "CYCLE_B",
        ] {
            assert!(
                rendered.contains(expected),
                "{width}: {expected}\n{rendered}"
            );
        }
        for row in rendered.lines() {
            assert!(ui::width(row, 1) <= usize::from(width));
        }
        assert!(
            term.backend()
                .buffer()
                .content
                .iter()
                .any(|c| c.fg == ratatui::style::Color::Green)
        );
        assert!(
            term.backend()
                .buffer()
                .content
                .iter()
                .any(|c| c.fg == ratatui::style::Color::Red)
        );
    }
}
#[test]
fn ascii_tree_uses_ascii_connectors() {
    let mut app = tree();
    app.ascii = true;
    let mut term = ratatui::Terminal::new(ratatui::backend::TestBackend::new(80, 24)).unwrap();
    term.draw(|f| ui::draw(f, &app)).unwrap();
    let rendered = ui::buffer_text(term.backend().buffer());
    assert!(rendered.contains("|  +- . GRANDCHILD_G"));
    assert!(rendered.contains("|  `- x GRANDCHILD_H"));
    for glyph in ['├', '└', '│'] {
        assert!(!rendered.contains(glyph));
    }
}
#[test]
fn action_selection_uses_the_same_preorder_as_rendering() {
    let mut app = tree();
    app.selected = 3;
    let stop = app.key(KeyEvent::from(KeyCode::Char('x')), Instant::now(), 80);
    assert_eq!(stop[0].params["id"], "h");
    let open = app.key(KeyEvent::from(KeyCode::Enter), Instant::now(), 80);
    assert_eq!(open[0].params["topic"], "wb.agent.poll");
    assert_eq!(open[0].params["agent_id"], "h");
    app.key(KeyEvent::from(KeyCode::Char('m')), Instant::now(), 80);
    assert_eq!(app.agent_message_id.as_deref(), Some("h"));
}
#[test]
fn inserting_a_grandchild_preserves_the_selected_agent_id() {
    let mut app = tree();
    app.selected = 4;
    let mut snapshot = app.snapshot.clone();
    snapshot["agents"].as_array_mut().unwrap().insert(
        4,
        json!({"id":"new","parent_id":"h","name":"HOT_INSERT","status":"running"}),
    );
    app.apply_snapshot(snapshot);
    assert_eq!(app.selected, 5);
    let stop = app.key(KeyEvent::from(KeyCode::Char('x')), Instant::now(), 80);
    assert_eq!(stop[0].params["id"], "b");
}
