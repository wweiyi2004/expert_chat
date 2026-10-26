use crossterm::event::{KeyCode as K, KeyEvent, KeyModifiers as M};
use expert_tui::app::{App, Command, Drawer, View};
use serde_json::{Value, json};
use std::time::Instant;

fn app() -> App {
    let mut app = App::default();
    app.apply_snapshot(json!({
        "session":{"id":"s1","status":"idle","mode":"work","permission":"request","model_choice":"c1","thinking":true,"effort":"high"},
        "messages":[],"models":[{"id":"model","choice":"c1","efforts":["low","high"]}],
        "agents":[{"id":"worker","name":"worker","task":"task","output":"output"}],
        "workspaces":[{"id":"w1","name":"alpha","path":"/alpha"},{"id":"w2","name":"beta","path":"/beta"}]
    }));
    app
}
fn key(a: &mut App, k: K) -> Vec<Command> {
    a.key(KeyEvent::from(k), Instant::now(), 80)
}
fn ctrl(a: &mut App, c: char) -> Vec<Command> {
    a.key(KeyEvent::new(K::Char(c), M::CONTROL), Instant::now(), 80)
}
fn send(a: &mut App, text: &str) -> Vec<Command> {
    a.paste(text);
    key(a, K::Enter)
}
fn question(a: &mut App) {
    a.snapshot["questions"] = json!([{"id":"request","questions":[{"id":"q","options":["red","blue"],"required":true,"multiple":true}]}]);
}
fn agent_mode(a: &mut App) {
    ctrl(a, 't');
    key(a, K::Char('m'));
}
fn switch(a: &mut App, id: &str) {
    let mut s = a.snapshot.clone();
    s["session"]["id"] = json!(id);
    s["messages"] = json!([]);
    a.apply_snapshot(s);
}

#[test]
fn key01_mode_arguments_are_explicit_and_compact_dispatches_real_method() {
    for current in ["work", "plan"] {
        for desired in ["work", "plan"] {
            let mut a = app();
            a.snapshot["session"]["mode"] = json!(current);
            let c = send(&mut a, &format!("/mode {desired}"));
            assert_eq!(c[0].params["mode"], desired);
        }
    }
    assert_eq!(send(&mut app(), "/compact")[0].method, "context.compact");
}
#[test]
fn key02_agent_retry_preserves_target_and_cancel_clears_it() {
    let mut a = app();
    agent_mode(&mut a);
    let sent = send(&mut a, "followup").remove(0);
    a.command_error(&sent, "offline");
    assert_eq!(a.agent_message_id.as_deref(), Some("worker"));
    let retry = key(&mut a, K::Enter).remove(0);
    assert_eq!(retry.method, "agent.message");
    assert_eq!(retry.params["id"], "worker");
    a.command_error(&retry, "offline");
    ctrl(&mut a, 'c');
    assert!(a.agent_message_id.is_none());
    assert_eq!(send(&mut a, "main task")[0].method, "message.send");
}
#[test]
fn key02_cross_session_followup_and_late_failure_stay_in_origin_session() {
    let mut a = app();
    agent_mode(&mut a);
    let sent = send(&mut a, "origin followup").remove(0);
    switch(&mut a, "s2");
    assert!(a.agent_message_id.is_none());
    a.paste("new draft");
    a.command_error(&sent, "offline");
    assert_eq!(a.input, "new draft");
    switch(&mut a, "s1");
    assert_eq!(a.input, "origin followup");
    assert_eq!(a.agent_message_id.as_deref(), Some("worker"));
}
#[test]
fn key03_rejection_cancel_and_submit_restore_main_draft_and_attachment() {
    let mut a = app();
    a.paste("main draft");
    a.attachments.push(json!({"name":"image.png"}));
    a.snapshot["approvals"] = json!([{"id":"approval"}]);
    key(&mut a, K::Char('e'));
    a.paste("reason");
    key(&mut a, K::Esc);
    assert_eq!(a.input, "main draft");
    assert_eq!(a.attachments.len(), 1);
    ctrl(&mut a, 'y');
    key(&mut a, K::Char('e'));
    a.paste("reason");
    let c = key(&mut a, K::Enter);
    assert_eq!(c[0].params["reason"], "reason");
    assert_eq!(a.input, "main draft");
}
#[test]
fn key04_workspace_query_filters_visible_results() {
    let mut a = app();
    a.open(Drawer::Workspace);
    a.paste("bet");
    assert_eq!(a.drawer_items().len(), 1);
    assert_eq!(key(&mut a, K::Enter)[0].params["workspace_id"], "w2");
}
#[test]
fn key05_controls_work_while_pending_or_attached() {
    let mut a = app();
    let pending = send(&mut a, "task").remove(0);
    assert_eq!(send(&mut a, "/stop")[0].method, "task.stop");
    send(&mut a, "/quit");
    assert!(a.exit);
    assert_eq!(a.pending_inputs[0].command, pending);
    let mut a = app();
    a.snapshot["session"]["status"] = json!("running");
    a.attachments.push(json!({"name":"image.png"}));
    assert_eq!(send(&mut a, "/stop")[0].method, "task.stop");
    assert_eq!(a.attachments.len(), 1);
}
#[test]
fn key06_agent_attachment_is_explicitly_blocked_and_kept() {
    let mut a = app();
    a.attachments.push(json!({"name":"image.png"}));
    agent_mode(&mut a);
    assert!(send(&mut a, "see image").is_empty());
    assert_eq!(a.input, "see image");
    assert_eq!(a.attachments.len(), 1);
    assert!(a.notice.contains("不支持附件"));
}
#[test]
fn key07_history_merges_external_snapshot_without_duplicating_local_send() {
    let mut a = app();
    let c = send(&mut a, "local").remove(0);
    a.command_response(&c, &json!({"accepted":true}));
    let mut snapshot = a.snapshot.clone();
    snapshot["messages"] = json!([{"id":"u1","role":"user","text":"local"},{"id":"u2","role":"user","text":"external"}]);
    a.apply_snapshot(snapshot);
    assert_eq!(a.history, vec!["local", "external"]);
    key(&mut a, K::Up);
    assert_eq!(a.input, "external");
}
#[test]
fn key08_fullscreen_replaces_drawer_and_footer_open_returns_to_chat() {
    let mut a = app();
    a.open(Drawer::Model);
    ctrl(&mut a, 'g');
    assert!(a.drawer.is_none());
    key(&mut a, K::Esc);
    assert_eq!(a.view, View::Chat);
    ctrl(&mut a, 't');
    a.open(Drawer::Permissions);
    assert_eq!(a.view, View::Chat);
    assert_eq!(a.drawer, Some(Drawer::Permissions));
}
#[test]
fn key09_file_selection_resets_scroll_and_pageup_works() {
    let mut a = app();
    a.snapshot["changes"] = json!([{"id":"long"},{"id":"short"}]);
    ctrl(&mut a, 'g');
    key(&mut a, K::PageDown);
    assert_eq!(a.scroll, 8);
    key(&mut a, K::Down);
    assert_eq!(a.scroll, 0);
    key(&mut a, K::PageDown);
    key(&mut a, K::PageUp);
    assert_eq!(a.scroll, 0);
}
#[test]
fn key10_invalid_question_tokens_preserve_input() {
    for input in ["1,99", "1, extra explanation"] {
        let mut a = app();
        question(&mut a);
        assert!(send(&mut a, input).is_empty());
        assert_eq!(a.input, input);
        assert!(a.notice.contains("无效"));
    }
}
#[test]
fn key11_question_error_restores_answers_and_ack_blocks_duplicate() {
    let mut a = app();
    question(&mut a);
    let c = send(&mut a, "2").remove(0);
    assert!(send(&mut a, "1").is_empty());
    ctrl(&mut a, 'c');
    a.command_error(&c, "offline");
    assert_eq!(a.input, "2");
    assert_eq!(a.question_index, 0);
    let retry = key(&mut a, K::Enter).remove(0);
    assert_eq!(retry.params["answers"]["q"]["selected"], json!(["blue"]));
    a.command_response(&retry, &json!({"accepted":true}));
    assert!(send(&mut a, "1").is_empty());
}
#[test]
fn key12_withdrawal_preserves_new_edits_and_suppresses_duplicate_request() {
    let mut a = app();
    a.snapshot["queued"] = json!([{"id":"queued","text":"withdrawn","status":"queued"}]);
    let c = key(&mut a, K::Up).remove(0);
    assert!(key(&mut a, K::Up).is_empty());
    a.paste("new draft");
    a.command_response(&c, &json!({"text":"withdrawn"}));
    assert_eq!(a.input, "withdrawn\nnew draft");
    a.command_response(&c, &json!({"text":"withdrawn"}));
    assert_eq!(a.input, "withdrawn\nnew draft");
}
#[test]
fn key12_late_withdrawal_does_not_write_into_another_session() {
    let mut a = app();
    a.snapshot["queued"] = json!([{"id":"queued","status":"queued"}]);
    let c = key(&mut a, K::Up).remove(0);
    switch(&mut a, "s2");
    a.paste("s2 draft");
    a.command_response(&c, &json!({"text":"s1 recalled"}));
    assert_eq!(a.input, "s2 draft");
    switch(&mut a, "s1");
    assert_eq!(a.input, "s1 recalled");
}
#[test]
fn key13_slash_controls_are_not_question_answers() {
    let mut a = app();
    question(&mut a);
    assert_eq!(send(&mut a, "/stop")[0].method, "task.stop");
    assert_eq!(send(&mut a, "/permissions").len(), 0);
    assert_eq!(a.drawer, Some(Drawer::Permissions));
}
#[test]
fn key14_paste_routes_to_current_focus_and_ignores_noneditable_views() {
    let mut a = app();
    a.paste("main draft");
    a.open(Drawer::History);
    a.paste("query");
    assert_eq!(a.search, "query");
    assert_eq!(a.input, "main draft");
    ctrl(&mut a, 'g');
    a.paste("hidden");
    assert_eq!(a.input, "main draft");
    key(&mut a, K::Esc);
    a.snapshot["approvals"] = json!([{"id":"approval"}]);
    a.paste("hidden approval text");
    assert_eq!(a.input, "main draft");
}
#[test]
fn key15_paste_preserves_tabs_and_original_multiline_payload() {
    let mut a = app();
    let text = "a\tb\n1\n2\n3\n4\n5";
    a.paste(text);
    assert!(a.paste_collapsed);
    let c = key(&mut a, K::Enter);
    assert_eq!(c[0].params["text"], text);
    assert!(!a.paste_collapsed);
}
#[test]
fn key16_readline_search_editing_never_edits_hidden_main_draft() {
    let mut a = app();
    a.paste("keep main draft");
    a.open(Drawer::History);
    a.paste("needle");
    ctrl(&mut a, 'u');
    assert_eq!(a.search, "");
    assert_eq!(a.input, "keep main draft");
    a.paste("abc");
    ctrl(&mut a, 'a');
    key(&mut a, K::Char('X'));
    assert_eq!(a.search, "Xabc");
    ctrl(&mut a, 'c');
    assert_eq!(a.search, "");
    assert_eq!(a.input, "keep main draft");
}
#[test]
fn key17_edited_history_survives_down_and_multiline_cursor_moves() {
    let mut a = app();
    a.history = vec!["first".into(), "second".into()];
    a.history_index = 2;
    key(&mut a, K::Up);
    key(&mut a, K::Char('x'));
    key(&mut a, K::Down);
    assert_eq!(a.input, "secondx");
    ctrl(&mut a, 'c');
    a.paste("中ab\n甲乙\nlast");
    key(&mut a, K::Up);
    assert_eq!(&a.input[..a.cursor], "中ab\n甲乙");
    key(&mut a, K::Home);
    assert_eq!(&a.input[..a.cursor], "中ab\n");
    key(&mut a, K::Up);
    assert_eq!(a.cursor, 0);
}
#[test]
fn key18_wheel_scroll_method_respects_view_direction() {
    let mut a = app();
    a.snapshot["messages"] = json!([{"role":"assistant","text":"record\n".repeat(100)}]);
    a.scroll_by(-3);
    assert_eq!(a.scroll, 3);
    a.scroll_by(3);
    assert_eq!(a.scroll, 0);
    ctrl(&mut a, 'g');
    a.scroll_by(3);
    assert_eq!(a.scroll, 3);
    a.scroll_by(-3);
    assert_eq!(a.scroll, 0);
}
#[test]
fn agent_detail_is_scrollable_and_escape_returns_to_tree() {
    let mut a = app();
    ctrl(&mut a, 't');
    key(&mut a, K::Enter);
    assert_eq!(a.agent_detail_id.as_deref(), Some("worker"));
    key(&mut a, K::PageDown);
    assert_eq!(a.scroll, 8);
    key(&mut a, K::Esc);
    assert!(a.agent_detail_id.is_none());
    assert_eq!(a.view, View::Agents);
    assert_eq!(a.scroll, 0);
}
#[test]
fn aud02_ctrl_l_requests_real_redraw_without_touching_input() {
    let mut a = app();
    a.paste("draft");
    ctrl(&mut a, 'l');
    assert!(a.redraw_requested);
    assert_eq!(a.input, "draft");
}
#[test]
fn aud05_pet_can_be_restored_and_saved_without_touching_user_config() {
    if std::env::var_os("EXPERT_PET_REPAIR_CHILD").is_some() {
        let mut a = app();
        send(&mut a, "/pet off");
        assert!(!a.pet.enabled);
        send(&mut a, "/pet on");
        assert!(a.pet.enabled);
        assert_eq!(expert_tui::config::load().pet, "megumin");
        send(&mut a, "/pet off");
        send(&mut a, "/pet");
        assert!(a.pet.enabled);
        assert_eq!(expert_tui::config::load().pet, "megumin");
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "aud05_pet_can_be_restored_and_saved_without_touching_user_config",
            "--nocapture",
        ])
        .env("EXPERT_PET_REPAIR_CHILD", "1")
        .env("EXPERT_TUI_CONFIG", temp.path().join("tui.json"))
        .status()
        .unwrap();
    assert!(status.success());
}
#[test]
fn snapshot_error_preserves_state_until_successful_snapshot() {
    let mut a = app();
    let before = a.snapshot.clone();
    a.apply_event(
        &json!({"v":1,"event":"request.error","data":{"scope":"snapshot","message":"too large"}}),
    )
    .unwrap();
    assert!(a.snapshot_stale);
    assert_eq!(a.snapshot, before);
    a.apply_snapshot(before);
    assert!(!a.snapshot_stale);
    assert!(a.snapshot_error.is_none());
}
#[test]
fn stale_ack_does_not_clear_current_sessions_pending_message() {
    let mut a = app();
    let s1 = send(&mut a, "s1 message").remove(0);
    switch(&mut a, "s2");
    let s2 = send(&mut a, "s2 message").remove(0);
    a.command_response(&s1, &Value::Null);
    assert_eq!(a.pending_inputs.len(), 1);
    assert_eq!(a.pending_inputs[0].command, s2);
    assert!(a.pending_draft.is_some());
}

#[test]
fn failed_agent_target_does_not_merge_into_new_main_draft_and_recover_swaps_safely() {
    let mut a = app();
    agent_mode(&mut a);
    let c = send(&mut a, "agent draft").remove(0);
    a.paste("main draft");
    a.command_error(&c, "offline");
    assert_eq!(a.input, "main draft");
    assert!(a.agent_message_id.is_none());
    assert_eq!(a.recovered_inputs.len(), 1);
    a.recover_draft();
    assert_eq!(a.input, "agent draft");
    assert_eq!(a.agent_message_id.as_deref(), Some("worker"));
    assert_eq!(a.pending_inputs.len(), 0);
    a.recover_draft();
    assert_eq!(a.input, "main draft");
    assert!(a.agent_message_id.is_none());
}
#[test]
fn late_failure_and_withdrawal_update_saved_main_draft_not_rejection_reason() {
    let mut a = app();
    let c = send(&mut a, "failed main").remove(0);
    a.snapshot["queued"] = json!([{"id":"queued","status":"queued"}]);
    let withdraw = key(&mut a, K::Up).remove(0);
    a.snapshot["approvals"] = json!([{"id":"approval"}]);
    key(&mut a, K::Char('e'));
    a.paste("private rejection reason");
    a.command_error(&c, "offline");
    a.command_response(&withdraw, &json!({"text":"recalled"}));
    assert_eq!(a.input, "private rejection reason");
    key(&mut a, K::Esc);
    assert_eq!(a.input, "recalled\nfailed main");
}
#[test]
fn recovered_question_failure_waits_for_explicit_recovery_in_original_session() {
    let mut a = app();
    question(&mut a);
    let c = send(&mut a, "2").remove(0);
    switch(&mut a, "s2");
    a.paste("other session draft");
    a.command_error(&c, "offline");
    assert_eq!(a.input, "other session draft");
    switch(&mut a, "s1");
    assert!(a.notice.contains("/recover"));
    a.recover_draft();
    assert_eq!(a.input, "2");
    assert_eq!(a.question_index, 0);
}
#[test]
fn up_down_move_across_soft_wrapped_input_at_current_terminal_width() {
    let mut a = app();
    a.paste("abcdefgh");
    a.key(KeyEvent::from(K::Up), Instant::now(), 10);
    assert_eq!(a.cursor, 3);
    a.key(KeyEvent::from(K::Down), Instant::now(), 10);
    assert_eq!(a.cursor, 8);
}
#[test]
fn inactive_retry_metadata_never_overrides_running_snapshot() {
    let mut a = app();
    let mut s = a.snapshot.clone();
    s["session"]["status"] = json!("running");
    s["session"]["retry"] = json!({"active":false,"attempt":1});
    a.apply_snapshot(s.clone());
    assert_eq!(a.status(), "running");
    assert!(a.retry.is_none());
    s["session"]["retry"]["active"] = json!(true);
    a.apply_snapshot(s);
    assert_eq!(a.status(), "retrying");
    a.snapshot["session"]["status"] = json!("running");
    a.apply_event(&json!({"v":1,"event":"request.retry","data":{"active":false,"attempt":1}}))
        .unwrap();
    assert!(a.retry.is_none());
    assert_eq!(a.status(), "running");
}
#[test]
fn delayed_clipboard_image_keeps_original_session_and_target() {
    let mut a = app();
    switch(&mut a, "s2");
    a.add_attachment(Some("s1"), Some("worker"), json!({"name":"old.png"}));
    assert!(a.attachments.is_empty());
    switch(&mut a, "s1");
    a.recover_draft();
    assert_eq!(a.agent_message_id.as_deref(), Some("worker"));
    assert_eq!(a.attachments[0]["name"], "old.png");
}

#[test]
fn compaction_has_separate_pending_progress_success_and_failure() {
    let mut a = app();
    let c = send(&mut a, "/compact").remove(0);
    assert!(a.notice.contains("正在整理"));
    assert!(a.pending_draft.is_none());
    assert!(send(&mut a, "/compact").is_empty());
    assert_eq!(send(&mut a, "/stop")[0].method, "task.stop");
    a.command_response(
        &c,
        &json!({"accepted":true,"result":{"summary":"saved actual summary"}}),
    );
    assert!(a.notice.contains("整理完成"));
    assert!(a.notice.contains("saved actual summary"));
    let retry = send(&mut a, "/compact").remove(0);
    a.command_error(&retry, "context.compact: cancelled");
    assert!(a.notice.contains("cancelled"));
    assert!(a.pending_compactions.is_empty());
}
#[test]
fn control_c_in_fullscreen_or_approval_never_clears_hidden_draft() {
    let mut a = app();
    a.paste("hidden draft");
    a.snapshot["session"]["status"] = json!("running");
    ctrl(&mut a, 'g');
    assert_eq!(ctrl(&mut a, 'c')[0].method, "task.stop");
    assert_eq!(a.input, "hidden draft");
    key(&mut a, K::Esc);
    a.snapshot["approvals"] = json!([{"id":"approval"}]);
    ctrl(&mut a, 'u');
    assert_eq!(a.input, "hidden draft");
    assert_eq!(ctrl(&mut a, 'c')[0].method, "task.stop");
    ctrl(&mut a, 'g');
    assert_eq!(a.view, View::Changes);
}
#[test]
fn withdrawal_during_question_stays_recoverable_without_becoming_an_answer() {
    let mut a = app();
    a.snapshot["queued"] = json!([{"id":"queued","status":"queued"}]);
    let c = key(&mut a, K::Up).remove(0);
    question(&mut a);
    a.paste("answer draft");
    a.command_response(&c, &json!({"text":"main supplemental text"}));
    assert_eq!(a.input, "answer draft");
    assert_eq!(a.recovered_inputs.len(), 1);
    a.recover_draft();
    assert_eq!(a.input, "answer draft");
    assert_eq!(a.recovered_inputs.len(), 1);
}

#[test]
fn question_answers_accept_unix_paths_and_unknown_commands_preserve_text() {
    let mut a = app();
    question(&mut a);
    let c = send(&mut a, "/home/project").remove(0);
    assert_eq!(c.method, "question.answer");
    assert_eq!(c.params["answers"]["q"]["text"], "/home/project");
    let mut a = app();
    assert!(send(&mut a, "/unknown-custom-command").is_empty());
    assert_eq!(a.input, "/unknown-custom-command");
    assert!(a.notice.contains("已保留"));
}

#[test]
fn welcome_scrolling_starts_at_top_and_never_blanks_the_block() {
    let mut a = app();
    key(&mut a, K::PageUp);
    assert_eq!(a.scroll, 0);
    key(&mut a, K::PageDown);
    assert_eq!(
        a.scroll,
        expert_tui::ui::record_scroll_limit(&a, 80, 24).min(8)
    );
    for _ in 0..100 {
        a.scroll_by(3);
    }
    assert_eq!(a.scroll, expert_tui::ui::record_scroll_limit(&a, 80, 24));
}

#[test]
fn disconnect_releases_compaction_and_withdrawal_but_keeps_unknown_result_text_for_recovery() {
    let mut a = app();
    let compact = send(&mut a, "/compact").remove(0);
    a.command_error(
        &compact,
        "Connection lost: result unknown; inspect refreshed state before retrying",
    );
    assert!(a.pending_compactions.is_empty());
    assert!(a.notice.contains("unknown"));
    a.snapshot["queued"] =
        json!([{"id":"queue","status":"queued","text":"original queued requirement"}]);
    let withdrawal = key(&mut a, K::Up).remove(0);
    a.paste("new edit");
    a.command_error(
        &withdrawal,
        "Connection lost: result unknown; inspect refreshed state before retrying",
    );
    assert!(a.pending_withdrawals.is_empty());
    assert!(a.withdrawal_drafts.is_empty());
    assert_eq!(a.input, "new edit");
    assert!(a.notice.contains("unknown"));
    assert!(a.notice.contains("/recover"));
    a.recover_draft();
    assert_eq!(a.input, "original queued requirement");
    assert!(a.pending_inputs.is_empty());
    a.recover_draft();
    assert_eq!(a.input, "new edit");
}

#[test]
fn recovery_rotation_can_reach_all_preserved_drafts() {
    let mut a = app();
    for name in ["one.png", "two.png", "three.png"] {
        a.add_attachment(Some("other"), None, json!({"name":name}));
    }
    switch(&mut a, "other");
    a.paste("current draft");
    for name in ["three.png", "two.png", "one.png"] {
        a.recover_draft();
        assert_eq!(a.attachments[0]["name"], name);
    }
    a.recover_draft();
    assert_eq!(a.input, "current draft");
    assert!(a.attachments.is_empty());
}
