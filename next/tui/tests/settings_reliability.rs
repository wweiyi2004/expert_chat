use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use expert_tui::app::App;
use serde_json::json;
use std::time::Instant;

fn select(app: &mut App, field: &str) -> Vec<expert_tui::app::Command> {
    let index = app
        .form
        .as_ref()
        .unwrap()
        .fields
        .iter()
        .position(|f| f.key == field)
        .unwrap();
    app.click_form_field(index)
}
fn set(app: &mut App, field: &str, value: &str) {
    app.form
        .as_mut()
        .unwrap()
        .fields
        .iter_mut()
        .find(|f| f.key == field)
        .unwrap()
        .value = value.into();
}
fn value<'a>(app: &'a App, field: &str) -> &'a str {
    &app.form
        .as_ref()
        .unwrap()
        .fields
        .iter()
        .find(|f| f.key == field)
        .unwrap()
        .value
}

fn mcp_form() -> App {
    let mut app = provider_form();
    app.snapshot["settings"]["mcp"] = json!([{
        "id":"existing-mcp","name":"Synthetic MCP","transport":"stdio",
        "command":"synthetic-not-executed","args":[],"enabled":false
    }]);
    app.open_settings();
    select(&mut app, "mcp.0");
    app
}

fn provider_form() -> App {
    let mut app = App::default();
    app.apply_snapshot(json!({
        "session": {"id":"audit-session","status":"idle"},
        "settings": {"providers":[{
            "id":"existing-provider","name":"Synthetic provider",
            "api_format":"openAiCompatible","auth_mode":"apiKey",
            "base_url":"http://127.0.0.1:1/v1","models":["synthetic"],
            "chat_model":"synthetic","enabled":true
        }],"mcp":[]},"messages":[]
    }));
    app.open_settings();
    select(&mut app, "provider.0");
    app
}

#[test]
fn readonly_provider_id_survives_clear_field_shortcut() {
    let mut app = provider_form();
    app.click_form_field(0);
    app.key(
        KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL),
        Instant::now(),
        80,
    );
    let save = app
        .form
        .as_ref()
        .unwrap()
        .fields
        .iter()
        .position(|f| f.key == "__save")
        .unwrap();
    let commands = app.click_form_field(save);
    assert_eq!(
        commands[0].params["id"], "existing-provider",
        "Clearing a read-only field must not turn editing into creating a new provider"
    );
}

#[test]
fn failed_save_retains_newly_entered_credential_for_retry() {
    let mut app = provider_form();
    app.form
        .as_mut()
        .unwrap()
        .fields
        .iter_mut()
        .find(|f| f.key == "api_key")
        .unwrap()
        .value = "synthetic-audit-only".into();
    let save = app
        .form
        .as_ref()
        .unwrap()
        .fields
        .iter()
        .position(|f| f.key == "__save")
        .unwrap();
    let command = app.click_form_field(save).remove(0);
    app.command_error(&command, "synthetic save rejected");
    let retry = app.click_form_field(save).remove(0);
    assert_eq!(
        retry.params["api_key"], "synthetic-audit-only",
        "A failed save must not discard the new credential before a retry"
    );
}

#[test]
fn readonly_fields_reject_keyboard_paste_and_backspace_for_both_forms() {
    for mut app in [provider_form(), mcp_form()] {
        select(&mut app, "id");
        let original = value(&app, "id").to_owned();
        app.paste("should-not-appear");
        for key in [
            KeyEvent::from(KeyCode::Backspace),
            KeyEvent::from(KeyCode::Char('x')),
            KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL),
        ] {
            app.key(key, Instant::now(), 80);
        }
        assert_eq!(value(&app, "id"), original);
        // Even a damaged display value cannot change the object being edited.
        set(&mut app, "id", "");
        assert_eq!(select(&mut app, "__save")[0].params["id"], original);
    }
}

#[test]
fn successful_save_clears_submitted_secret_but_retains_newer_edit() {
    for newer in [false, true] {
        let mut app = provider_form();
        set(&mut app, "api_key", "synthetic-old");
        let command = select(&mut app, "__save").remove(0);
        assert!(select(&mut app, "__save").is_empty());
        if newer {
            set(&mut app, "api_key", "synthetic-new");
        }
        app.command_response(&command, &json!({"id":"existing-provider","accepted":true}));
        assert_eq!(
            value(&app, "api_key"),
            if newer { "synthetic-new" } else { "" }
        );
        assert_eq!(
            select(&mut app, "__save")[0].params["id"],
            "existing-provider"
        );
    }
}

#[test]
fn mcp_secret_maps_survive_failure_and_clear_only_after_success() {
    let mut app = mcp_form();
    set(&mut app, "env", "{\"SYNTHETIC_ENV\":\"synthetic-only\"}");
    set(&mut app, "headers", "{\"X-Synthetic\":\"test-only\"}");
    set(&mut app, "token", "synthetic-token");
    let command = select(&mut app, "__save").remove(0);
    assert!(!format!("{command:?}").contains("synthetic-token"));
    app.command_error(&command, "synthetic rejection");
    let retry = select(&mut app, "__save").remove(0);
    assert_eq!(retry, command);
    app.command_response(&retry, &json!({"id":"existing-mcp","accepted":true}));
    for field in ["env", "headers", "token"] {
        assert!(value(&app, field).is_empty());
    }
}

#[test]
fn newly_created_identity_is_retained_and_late_response_cannot_clear_other_form() {
    let mut app = provider_form();
    app.open_settings();
    select(&mut app, "provider.new");
    set(&mut app, "name", "new synthetic");
    let first = select(&mut app, "__save").remove(0);
    assert!(first.params.get("id").is_none());
    app.command_response(&first, &json!({"id":"created-id","accepted":true}));
    set(&mut app, "api_key", "old-form-secret");
    let pending = select(&mut app, "__save").remove(0);
    assert_eq!(pending.params["id"], "created-id");
    app.open_settings();
    select(&mut app, "provider.0");
    set(&mut app, "api_key", "new-form-secret");
    app.command_response(&pending, &json!({"id":"created-id","accepted":true}));
    assert_eq!(value(&app, "id"), "existing-provider");
    assert_eq!(value(&app, "api_key"), "new-form-secret");
}

#[test]
fn unknown_save_queries_state_and_blocks_replay_in_the_old_form() {
    let mut app = provider_form();
    set(&mut app, "api_key", "synthetic-pending");
    let command = select(&mut app, "__save").remove(0);
    app.command_unknown(&command, "synthetic connection lost");
    assert!(select(&mut app, "__save").is_empty());
    assert_eq!(value(&app, "api_key"), "synthetic-pending");
    assert_eq!(app.outbox.len(), 1);
    assert_eq!(app.outbox[0].method, "settings.get");
    assert!(!app.outbox.iter().any(|c| c.method.ends_with(".save")));
}
