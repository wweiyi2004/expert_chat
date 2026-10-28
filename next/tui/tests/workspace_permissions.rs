use crossterm::event::{KeyCode, KeyEvent};
use expert_tui::{
    app::{App, Drawer, FormKind},
    ui,
};
use ratatui::{Terminal, backend::TestBackend};
use serde_json::{Value, json};
use std::time::Instant;

fn workspace(access: &str) -> Value {
    json!({"id":"fish","name":"deepfish","path":"E:\\projects\\deepfish",
    "remote":false,"access":access,"scopes":[
        {"name":"root","path":"E:\\projects\\deepfish","access":access},
        {"name":"private","path":"E:\\projects\\deepfish\\private","access":"deny"}
    ]})
}

fn app() -> App {
    let mut app = App::default();
    app.binding_ready = true;
    app.viewport = (100, 32);
    app.apply_snapshot(
        json!({"session":{"id":"s","status":"idle","mode":"work","workspace_id":"fish"},
        "workspaces":[workspace("read-only")],"messages":[],"models":[],"steps":[]}),
    );
    app.open(Drawer::Workspace);
    app
}

#[test]
fn workspace_picker_edits_root_permission_with_explicit_receipt() {
    let mut app = app();
    let mut terminal = Terminal::new(TestBackend::new(100, 32)).unwrap();
    terminal.draw(|f| ui::draw(f, &app)).unwrap();
    let rendered = ui::buffer_text(terminal.backend().buffer());
    assert!(rendered.contains("目录权限"));
    assert!(rendered.contains("只读"));
    let command = app
        .key(KeyEvent::from(KeyCode::F(2)), Instant::now(), 100)
        .remove(0);
    assert_eq!(command.params["workspace_id"], "fish");
    assert_eq!(command.params["topic"], "workspace.permissions");
    app.command_response(&command, &json!({"workspace":workspace("read-only")}));
    assert_eq!(
        app.form.as_ref().unwrap().kind,
        FormKind::WorkspacePermissions
    );
    assert!(app.click_form_field(0).is_empty());
    assert_eq!(app.form.as_ref().unwrap().kind, FormKind::WorkspaceScope);
    assert!(app.click_form_field(2).is_empty());
    assert_eq!(app.form.as_ref().unwrap().fields[2].value, "read-write");
    assert!(app.click_form_field(3).is_empty());
    let save = app.click_form_field(3).remove(0);
    assert_eq!(save.params["action"], "workspace.permission.set");
    assert_eq!(save.params["name"], "root");
    assert_eq!(save.params["expected_access"], "read-only");
    assert_eq!(save.params["access"], "read-write");
    assert_eq!(save.params["confirmed"], true);
    assert_eq!(app.snapshot["workspaces"][0]["access"], "read-only");
    app.command_response(
        &save,
        &json!({"workspace":workspace("read-write"),"notice":"已将根目录改为读写"}),
    );
    assert_eq!(app.snapshot["workspaces"][0]["access"], "read-write");
    assert_eq!(
        app.form.as_ref().unwrap().kind,
        FormKind::WorkspacePermissions
    );
    assert_eq!(app.form.as_ref().unwrap().fields[0].label, "根目录 · 读写");
    assert!(app.pending_inputs.is_empty());
}

#[test]
fn closed_workspace_query_does_not_reopen_and_child_rules_remain_editable() {
    let mut app = app();
    let query = app.open_workspace_permissions().remove(0);
    app.drawer = None;
    app.command_response(&query, &json!({"workspace":workspace("read-only")}));
    assert!(app.form.is_none());
    app.open(Drawer::Workspace);
    let query = app.open_workspace_permissions().remove(0);
    app.command_response(&query, &json!({"workspace":workspace("read-only")}));
    app.click_form_field(1);
    assert_eq!(app.form.as_ref().unwrap().fields[2].value, "deny");
    app.click_form_field(2);
    app.click_form_field(3);
    let save = app.click_form_field(3).remove(0);
    assert_eq!(save.params["name"], "private");
    assert_eq!(save.params["expected_access"], "deny");
    assert_eq!(save.params["access"], "read-only");
}
