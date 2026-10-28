use crossterm::event::{KeyCode, KeyEvent};
use expert_tui::{
    app::{App, Drawer, FormKind},
    ui,
};
use ratatui::{Terminal, backend::TestBackend};
use serde_json::json;
use std::time::Instant;

fn app(status: &str) -> App {
    let mut a = App::default();
    a.apply_snapshot(json!({"session":{"id":"s","status":status,"workspace_id":"current"},"messages":[],"approvals":[{"id":"approval","tool":"work_run_command","command":"echo test"}]}));
    a
}
fn key(a: &mut App, code: KeyCode) -> Vec<expert_tui::app::Command> {
    a.key(KeyEvent::from(code), Instant::now(), 120)
}

#[test]
fn approval_arrows_then_enter_select_exact_decision_and_prevent_repeat() {
    for (steps, decision) in [(1, "once"), (2, "session"), (3, "reject")] {
        let mut a = app("approval");
        assert!(key(&mut a, KeyCode::Enter).is_empty());
        for _ in 0..steps {
            key(&mut a, KeyCode::Right);
        }
        let commands = key(&mut a, KeyCode::Enter);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].params["decision"], decision);
        assert!(key(&mut a, KeyCode::Enter).is_empty());
    }
}

#[test]
fn approval_left_opens_rejection_editor_and_keeps_draft() {
    let mut a = app("approval");
    a.input = "draft".into();
    a.cursor = 5;
    key(&mut a, KeyCode::Left);
    assert!(key(&mut a, KeyCode::Enter).is_empty());
    assert!(a.rejection);
    assert!(a.choose_approval("approval", 3).is_empty());
    key(&mut a, KeyCode::Esc);
    assert_eq!(a.input, "draft");
    assert!(!a.rejection);
}

#[test]
fn approval_mouse_hits_follow_rendered_buttons_in_wide_and_wrapped_layouts() {
    for (w, h) in [(120, 36), (60, 24), (40, 24), (160, 36)] {
        let mut a = app("approval");
        a.sidebar = w == 160;
        a.snapshot["approvals"][0]["arguments"] = json!("echo verify\n".repeat(80));
        let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
        terminal.draw(|f| ui::draw(f, &a)).unwrap();
        let mut found = [false; 4];
        for y in 0..h {
            for x in 0..w {
                if let Some((id, index)) = ui::approval_button_at(&a, w, h, x, y) {
                    assert_eq!(id, "approval");
                    if !found[index] {
                        assert_eq!(
                            terminal.backend().buffer()[(x, y)].symbol(),
                            "[",
                            "{w}x{h} button {index} at {x},{y}:\n{}",
                            ui::buffer_text(terminal.backend().buffer())
                        );
                    }
                    found[index] = true;
                }
            }
        }
        assert!(found.into_iter().all(|v| v), "missing button at {w}x{h}");
        let text = ui::buffer_text(terminal.backend().buffer());
        assert!(text.contains("[ y"));
    }
    let mut a = app("approval");
    assert!(a.choose_approval("old", 0).is_empty());
    a.snapshot_stale = true;
    assert!(a.choose_approval("approval", 0).is_empty());
}

#[test]
fn workspace_picker_groups_directory_aliases_but_keeps_current_binding_and_paths() {
    let mut a = app("idle");
    a.snapshot["workspaces"] = json!([
        {"id":"old","name":"AI","path":"\\\\?\\E:\\one\\AI"},
        {"id":"current","name":"AI","path":"e:/one/ai/"},
        {"id":"other","name":"AI","path":"E:\\two\\AI"}
    ]);
    a.open(Drawer::Workspace);
    let rows = a.drawer_items();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["id"], "current");
    let mut terminal = Terminal::new(TestBackend::new(120, 36)).unwrap();
    terminal.draw(|f| ui::draw(f, &a)).unwrap();
    let text = ui::buffer_text(terminal.backend().buffer());
    assert!(text.contains("e:/one/ai/") && text.contains("E:\\two\\AI"));
    let selected_y = text
        .lines()
        .position(|line| line.contains("e:/one/ai/"))
        .unwrap() as u16;
    let rect = ui::popup_rect(&a, 120, 36).unwrap();
    let buffer = terminal.backend().buffer();
    assert_eq!(
        buffer[(rect.x + 2, selected_y)].bg,
        buffer[(rect.right() - 3, selected_y)].bg
    );
    assert_ne!(
        buffer[(rect.x + 2, selected_y)].bg,
        ratatui::style::Color::Reset
    );
    a.search = "two".into();
    assert_eq!(a.drawer_items().len(), 1);
}

#[test]
fn external_clients_are_separate_and_back_returns_to_client_picker() {
    let mut a = app("idle");
    let scan = a.scan_external_sessions(false).remove(0);
    a.command_response(
        &scan,
        &json!({"sessions":[
            {"id":"c1","source":"Codex","title":"CODEX_FIRST"},
            {"id":"a1","source":"Claude Code","title":"CLAUDE_ONLY"},
            {"id":"c2","source":"Codex","title":"CODEX_SECOND"}
        ]}),
    );
    let form = a.form.as_ref().unwrap();
    assert_eq!(form.fields.len(), 3);
    assert!(!form.fields.iter().any(|f| f.label.contains("FIRST")));
    a.form.as_mut().unwrap().selected = 2;
    assert!(key(&mut a, KeyCode::Enter).is_empty());
    let form = a.form.as_ref().unwrap();
    assert!(form.title.starts_with("Codex"));
    assert_eq!(form.fields.len(), 3);
    assert!(form.fields[1].label.contains("CODEX_FIRST"));
    assert!(!form.fields.iter().any(|f| f.label.contains("CLAUDE")));
    assert!(key(&mut a, KeyCode::Enter).is_empty());
    assert!(a.form.as_ref().unwrap().title.contains("先选择客户端"));
}

#[test]
fn enter_imports_reviewed_session_and_opens_result() {
    let mut a = app("idle");
    let scan = a.scan_external_sessions(false).remove(0);
    a.command_response(
        &scan,
        &json!({"sessions":[{"id":"external","source":"Codex","title":"old"}]}),
    );
    key(&mut a, KeyCode::Down);
    assert!(key(&mut a, KeyCode::Enter).is_empty());
    key(&mut a, KeyCode::Down);
    let preview = key(&mut a, KeyCode::Enter).remove(0);
    assert_eq!(preview.params["topic"], "session.import.preview");
    a.command_response(&preview,&json!({"id":"external","fingerprint":"hash","source":"Codex","title":"old","messages":2,"preview":"user: hello\nassistant: hi"}));
    assert_eq!(a.form.as_ref().unwrap().kind, FormKind::ImportReview);
    let import = key(&mut a, KeyCode::Enter).remove(0);
    assert_eq!(import.params["action"], "session.import");
    assert_eq!(import.params["fingerprint"], "hash");
    assert!(key(&mut a, KeyCode::Enter).is_empty());
    a.command_response(&import, &json!({"session_id":"imported","notice":"done"}));
    assert!(a.form.is_none());
    let open = a.outbox.pop().unwrap();
    assert_eq!(open.method, "session.open");
    assert_eq!(open.params["session_id"], "imported");
}

#[test]
fn approved_mascot_frames_have_consistent_dimensions_and_palette() {
    let art = expert_tui::pet::Art::load();
    assert_eq!(art.dimensions(), (64, 80));
    for frame in art.frames.values() {
        assert_eq!(frame.len(), 80);
        for row in frame {
            assert_eq!(row.len(), 64);
            assert!(
                row.chars()
                    .all(|c| c == '.' || art.palette.contains_key(&c))
            );
        }
    }
    assert_ne!(art.frames["idle"], art.frames["blink"]);
    assert_ne!(art.frames["chant1"], art.frames["boom1"]);
}
