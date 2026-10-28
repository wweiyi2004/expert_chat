use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use expert_tui::{
    app::{App, Drawer},
    ui,
};
use ratatui::{Terminal, backend::TestBackend};
use serde_json::json;
fn app() -> App {
    let mut a = App::default();
    a.binding_ready = true;
    a.viewport = (100, 32);
    a.apply_snapshot(json!({"session":{"id":"s","mode":"work","status":"running"},"models":[{"id":"m"}],"messages":[],"steps":[],"changes":[],"agents":[]}));
    a
}
fn render(a: &App) -> String {
    let mut t = Terminal::new(TestBackend::new(100, 32)).unwrap();
    t.draw(|f| {
        ui::draw(f, a);
        expert_tui::workbench::draw(f, a);
    })
    .unwrap();
    ui::buffer_text(t.backend().buffer())
}
#[test]
fn native_file_mode_saves_file_and_never_submits_a_chat() {
    let mut a = app();
    let c = a
        .workbench_query("wb.file.open", json!({"path":"a.py"}))
        .remove(0);
    a.command_response(&c,&json!({"editor_file":true,"path":"a.py","sha256":"abc","content":"print(1)","session_id":"s"}));
    let commands = a.native_editor_key(KeyEvent::new(KeyCode::Char('s'), KeyModifiers::CONTROL));
    assert_eq!(commands[0].method, "terminal.action");
    assert_eq!(commands[0].params["action"], "wb.file.save");
    assert_eq!(commands[0].params["content"], "print(1)");
    assert!(a.pending_inputs.is_empty());
}
#[test]
fn side_window_reopens_with_draft_and_does_not_change_main_input() {
    let mut a = app();
    a.input = "main draft".into();
    let c = a.workbench_query("wb.side.open", json!({})).remove(0);
    assert_eq!(c.method, "terminal.action");
    a.command_response(&c,&json!({"side":true,"kind":"side","job_id":"j","session_id":"s","messages":[{"role":"assistant","text":"side answer"}],"status":"idle"}));
    a.side_key(KeyEvent::from(KeyCode::Char('x')));
    assert!(render(&a).contains("side answer"));
    a.side_key(KeyEvent::from(KeyCode::Esc));
    assert_eq!(a.input, "main draft");
    assert!(a.side_panel.is_none());
    let c = a.extra_command("/btw", "").remove(0);
    assert_eq!(c.params["job_id"], "j");
}
#[test]
fn tool_events_follow_public_text_order_and_top_pin_disappears() {
    let mut a = app();
    a.suppress_welcome = true;
    a.snapshot["messages"] = json!([{"id":"u","role":"user","text":"task"},{"id":"a","role":"assistant","text":"BEFORE\nAFTER"}]);
    a.snapshot["steps"] = json!([{"id":"t","message_id":"a","content_offset":7,"verb":"读取","object":"MARKER_FILE","status":"running"}]);
    let out = render(&a);
    assert!(out.find("BEFORE").unwrap() < out.find("MARKER_FILE").unwrap());
    assert!(out.find("MARKER_FILE").unwrap() < out.find("AFTER").unwrap());
    a.reading_anchor = Some(expert_tui::app::ReadingAnchor {
        message_id: None,
        line: 0,
    });
    assert!(!ui::show_pinned_user(&a, 100, 32));
}
#[test]
fn cost_view_has_no_details_control_even_with_old_preference() {
    let mut a = app();
    a.open(Drawer::Usage);
    a.usage_expanded = true;
    a.usage_detail = json!({"usage":{"cost":0.1,"currency":"USD","input":10,"output":2,"cached":3,"requests":1,"estimated":true}});
    let out = render(&a);
    assert!(out.contains("USD"));
    assert!(!out.contains("统计说明"));
    assert!(!out.contains("查看详情"));
}

#[test]
fn side_cursor_tracks_cjk_and_multiline_input() {
    for ambiguous_width in [1, 2] {
        for input in ["中文ab".to_owned(), format!("{}\n第二行", "长".repeat(60))] {
            let mut a = app();
            a.ambiguous_width = ambiguous_width;
            a.side_panel = Some(expert_tui::workbench::SidePanel {
                data: json!({"kind":"side","title":"旁问","messages":[]}),
                cursor: input.len(),
                input: input.clone(),
                focused: true,
                ..Default::default()
            });
            let mut terminal = Terminal::new(TestBackend::new(100, 32)).unwrap();
            terminal
                .draw(|f| expert_tui::workbench::draw(f, &a))
                .unwrap();
            let rect = expert_tui::workbench::side_rect(&a).unwrap();
            let cursor = terminal.get_cursor_position().unwrap();
            let prefix = ui::width("› ", ambiguous_width);
            let last = input.rsplit('\n').next().unwrap();
            assert_eq!(
                cursor.x,
                rect.x + 2 + (prefix + ui::width(last, ambiguous_width)) as u16
            );
            assert_eq!(cursor.y, rect.bottom() - 3);
            assert_eq!(
                terminal.backend().buffer()[(cursor.x - 1, cursor.y)].symbol(),
                if input.contains('\n') { " " } else { "b" }
            );
        }
    }
}

#[test]
fn side_cursor_wraps_at_exact_boundary_and_follows_home() {
    let mut a = app();
    let width = expert_tui::workbench::SidePanel::default();
    a.side_panel = Some(width);
    let rect = expert_tui::workbench::side_rect(&a).unwrap();
    let columns = rect.width as usize - 4 - ui::width("› ", a.ambiguous_width);
    let panel = a.side_panel.as_mut().unwrap();
    panel.input = "x".repeat(columns * 5);
    panel.cursor = panel.input.len();
    panel.focused = true;
    let mut terminal = Terminal::new(TestBackend::new(100, 32)).unwrap();
    terminal
        .draw(|f| expert_tui::workbench::draw(f, &a))
        .unwrap();
    assert_eq!(
        terminal.get_cursor_position().unwrap(),
        (rect.x + 4, rect.bottom() - 3).into()
    );
    a.side_panel.as_mut().unwrap().cursor = 0;
    terminal
        .draw(|f| expert_tui::workbench::draw(f, &a))
        .unwrap();
    assert_eq!(
        terminal.get_cursor_position().unwrap(),
        (rect.x + 4, rect.bottom() - 5).into()
    );
}

#[test]
fn files_argument_and_entry_navigation_preserve_directory() {
    let mut a = app();
    let request = a.extra_command("/files", "E:/项目/sub").remove(0);
    assert_eq!(request.params["path"], "E:/项目/sub");
    a.command_response(
        &request,
        &json!({"workbench":true,"title":"文件",
        "fields":[{"key":"path","label":"路径","value":"E:/项目/sub","editable":true},
        {"key":"entry:0","label":"script.py","action":"wb.files.entry"}],
        "data":{"path":"E:/项目/sub","entries":[{"name":"script.py"}]}}),
    );
    let form = a.form.as_mut().unwrap();
    form.fields[0].value = "other".into();
    form.selected = 1;
    let command = a.workbench_action().unwrap().remove(0);
    assert_eq!(command.params["path"], "E:/项目/sub/script.py");
    assert_eq!(command.params["action"], "wb.file.open");
}

fn open_file(a: &mut App, path: &str, content: &str, hash: &str) {
    let command = a
        .workbench_query("wb.file.open", json!({"path":path}))
        .remove(0);
    a.command_response(
        &command,
        &json!({"editor_file":true,"session_id":"s","path":path,"content":content,"sha256":hash}),
    );
}

#[test]
fn late_save_cannot_retarget_a_new_editor_even_for_the_same_path() {
    for next_path in ["B.txt", "A.txt"] {
        let mut a = app();
        open_file(&mut a, "A.txt", "old A", "ha0");
        a.native_editor.as_mut().unwrap().text = "changed A".into();
        let saved_a = a.finish_native_editor(false).remove(0);
        a.native_editor_key(KeyEvent::from(KeyCode::Esc));
        a.native_editor_key(KeyEvent::from(KeyCode::Esc));
        open_file(&mut a, next_path, "new file", "hb0");
        a.native_editor.as_mut().unwrap().text = "new edit".into();
        a.command_response(
            &saved_a,
            &json!({"file_saved":true,"session_id":"s","path":"A.txt","sha256":"ha1"}),
        );
        let editor = a.native_editor.as_ref().unwrap();
        assert_eq!(editor.file_path.as_deref(), Some(next_path));
        assert_eq!(editor.file_hash, "hb0");
        assert_eq!(editor.text, "new edit");
        let next_save = a.finish_native_editor(false).remove(0);
        assert_eq!(next_save.params["path"], next_path);
        assert_eq!(next_save.params["sha256"], "hb0");
        a.command_error(&saved_a, "late failure");
        assert!(a.native_editor.as_ref().unwrap().save_pending);
    }
}

#[test]
fn saving_keeps_new_edits_and_updates_the_revision_for_the_next_save() {
    let mut a = app();
    open_file(&mut a, "A.txt", "before", "h0");
    a.native_editor.as_mut().unwrap().text = "first edit".into();
    let first = a.finish_native_editor(false).remove(0);
    a.native_editor.as_mut().unwrap().text = "second edit".into();
    assert!(a.finish_native_editor(false).is_empty());
    a.command_response(
        &first,
        &json!({"file_saved":true,"path":"A.txt","sha256":"h1"}),
    );
    let next = a.finish_native_editor(false).remove(0);
    assert_eq!(next.params["content"], "second edit");
    assert_eq!(next.params["sha256"], "h1");
}

#[test]
fn side_receipt_keeps_text_typed_after_sending() {
    for kind in ["side", "agent", "session"] {
        let mut a = app();
        a.side_panel = Some(expert_tui::workbench::SidePanel {
            data: json!({"kind":kind,"job_id":"j","agent_id":"a","session_id":"s"}),
            input: "问题".into(),
            cursor: "问题".len(),
            focused: true,
            ..Default::default()
        });
        let sent = a
            .side_key(KeyEvent::from(KeyCode::Enter))
            .unwrap()
            .remove(0);
        a.side_key(KeyEvent::from(KeyCode::Char('新')));
        a.command_response(
            &sent,
            &json!({"side":true,"kind":kind,"job_id":"j","agent_id":"a","session_id":"s"}),
        );
        assert_eq!(a.side_panel.as_ref().unwrap().input, "新");
        assert_eq!(a.side_panel.as_ref().unwrap().cursor, "新".len());
    }
}

#[test]
fn preview_uses_the_action_endpoint() {
    let mut a = app();
    let request = a.extra_command("/preview", "image.png").remove(0);
    assert_eq!(request.method, "terminal.action");
    assert_eq!(request.params["action"], "wb.preview");
}

#[test]
fn save_as_receipt_releases_only_its_request_without_closing_a_new_panel() {
    let mut a = app();
    open_file(&mut a, "A.txt", "content", "h0");
    a.native_editor_key(KeyEvent::new(
        KeyCode::Char('s'),
        KeyModifiers::CONTROL | KeyModifiers::SHIFT,
    ));
    let form = a.form.as_mut().unwrap();
    form.fields[0].value = "copy.txt".into();
    form.selected = 1;
    let save = a.workbench_action().unwrap().remove(0);
    let browse = a.workbench_query("wb.files", json!({})).remove(0);
    a.command_response(
        &browse,
        &json!({"workbench":true,"title":"Files","fields":[]}),
    );
    assert!(a.wb_action_pending.is_some());
    a.command_response(
        &save,
        &json!({"file_saved":true,"path":"copy.txt","sha256":"h1"}),
    );
    assert!(a.wb_action_pending.is_none());
    assert_eq!(a.form.as_ref().unwrap().title, "Files");
    assert_eq!(
        a.native_editor.as_ref().unwrap().file_path.as_deref(),
        Some("copy.txt")
    );
}
