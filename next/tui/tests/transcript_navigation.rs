use crossterm::event::{KeyCode, KeyEvent};
use expert_tui::{app::App, ui};
use serde_json::json;
use std::time::Instant;

fn app() -> App {
    let mut a = App::default();
    a.apply_snapshot(json!({"session":{"id":"reading","status":"running"},
        "messages":(0..80).map(|i| json!({"id":format!("m{i}"),"role":if i%2==0{"user"}else{"assistant"},
            "text":format!("MESSAGE_{i:02}\n正文行一\n正文行二")})).collect::<Vec<_>>(), "steps":[]}));
    a
}
fn render(a: &App) -> String {
    let mut terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(80, 24)).unwrap();
    terminal.draw(|f| ui::draw(f, a)).unwrap();
    ui::buffer_text(terminal.backend().buffer())
}
fn command(a: &mut App, value: &str) {
    a.input = value.into();
    a.cursor = a.input.len();
    let actions = a.key(KeyEvent::from(KeyCode::Enter), Instant::now(), 80);
    assert!(
        actions.is_empty(),
        "Local navigation must not issue model requests"
    );
}

#[test]
fn scrolling_stays_on_the_same_message_while_output_and_earlier_rows_grow() {
    let mut a = app();
    a.scroll_by(-24);
    let before = render(&a).lines().take(5).collect::<Vec<_>>().join("\n");
    let mut next = a.snapshot.clone();
    next["messages"][0]["text"] = json!("older content\n".repeat(30));
    next["messages"][79]["text"] = json!("new live output\n".repeat(50));
    a.apply_snapshot(next);
    assert!(a.unseen_output);
    let after = render(&a).lines().take(5).collect::<Vec<_>>().join("\n");
    assert_eq!(before, after);
    assert!(render(&a).contains("有新输出"));
    command(&mut a, "/latest");
    assert!(a.reading_anchor.is_none());
    assert!(!a.unseen_output);
    assert!(render(&a).contains("new live output"));
}

#[test]
fn body_search_and_previous_next_do_not_modify_drafts_or_task_state() {
    let mut a = app();
    command(&mut a, "/find MESSAGE_1");
    assert_eq!(
        a.reading_anchor.as_ref().unwrap().message_id.as_deref(),
        Some("m10")
    );
    assert!(render(&a).contains("MESSAGE_10"));
    command(&mut a, "/next");
    assert_eq!(
        a.reading_anchor.as_ref().unwrap().message_id.as_deref(),
        Some("m11")
    );
    command(&mut a, "/prev");
    assert_eq!(
        a.reading_anchor.as_ref().unwrap().message_id.as_deref(),
        Some("m10")
    );
    command(&mut a, "/jump user");
    assert_eq!(
        a.reading_anchor.as_ref().unwrap().message_id.as_deref(),
        Some("m8")
    );
    assert_eq!(a.snapshot["session"]["status"], "running");
}

#[test]
fn switching_sessions_clears_reading_and_search_state() {
    let mut a = app();
    command(&mut a, "/find MESSAGE_10");
    let mut next = a.snapshot.clone();
    next["session"]["id"] = json!("other");
    a.apply_snapshot(next);
    assert!(a.reading_anchor.is_none());
    assert!(a.transcript_query.is_empty());
    assert!(a.transcript_match.is_none());
}

#[test]
fn clicking_a_user_message_opens_searchable_history_and_only_moves_reading_position() {
    use expert_tui::app::Drawer;
    let mut a = app();
    a.input = "尚未发送的草稿".into();
    a.cursor = a.input.len();
    ui::focus_message(&mut a, "m20");
    let out = render(&a);
    let y = out
        .lines()
        .enumerate()
        .find(|(_, row)| row.contains("MESSAGE_20"))
        .map(|(y, _)| y)
        .unwrap() as u16;
    let id = ui::user_message_at(&a, 80, 24, 3, y).unwrap();
    assert_eq!(id, "m20");
    let assistant_y = out
        .lines()
        .position(|row| row.contains("MESSAGE_21"))
        .unwrap() as u16;
    assert!(ui::user_message_at(&a, 80, 24, 3, assistant_y).is_none());
    let original = a.snapshot.clone();
    a.open_message_history(&id);
    assert_eq!(a.drawer, Some(Drawer::Messages));
    a.paste("MESSAGE_04");
    assert_eq!(a.drawer_items().len(), 1);
    let target = (0..24)
        .find_map(|y| {
            (0..80).find_map(|x| ui::popup_action_at(&a, 80, 24, x, y).map(|action| (x, y, action)))
        })
        .unwrap();
    let actions = a.click_popup_action(target.2);
    assert!(actions.is_empty());
    assert_eq!(
        a.reading_anchor.as_ref().unwrap().message_id.as_deref(),
        Some("m4")
    );
    assert_eq!(a.snapshot, original);
    assert_eq!(a.input, "尚未发送的草稿");
    assert!(render(&a).contains("MESSAGE_04"));
}

#[test]
fn user_message_background_is_subtle_and_covers_wrapped_rows_in_both_themes() {
    use ratatui::style::Color;
    for (skin, light) in [("midnight", false), ("paper", true)] {
        let mut a = app();
        a.skin = skin.into();
        a.light = light;
        a.truecolor = true;
        ui::focus_message(&mut a, "m20");
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(80, 24)).unwrap();
        terminal.draw(|f| ui::draw(f, &a)).unwrap();
        let buffer = terminal.backend().buffer();
        let text = ui::buffer_text(buffer);
        let user = text
            .lines()
            .position(|row| row.contains("MESSAGE_20"))
            .unwrap() as u16;
        let assistant = text
            .lines()
            .position(|row| row.contains("MESSAGE_21"))
            .unwrap() as u16;
        let bg = buffer[(3, user)].bg;
        assert!(matches!(bg, Color::Rgb(_, _, _)));
        assert_eq!(bg, buffer[(79, user)].bg);
        // Inspect the CJK lead cell; Terminal normalizes its trailing placeholder.
        assert_eq!(bg, buffer[(2, user + 1)].bg);
        assert_ne!(bg, buffer[(3, assistant)].bg);
    }
}

#[test]
fn message_hit_testing_tracks_scroll_and_rejects_dialog_or_input_rows() {
    let mut a = app();
    for id in ["m10", "m30", "m50"] {
        ui::focus_message(&mut a, id);
        let out = render(&a);
        let label = format!("MESSAGE_{:02}", id[1..].parse::<usize>().unwrap());
        let y = out
            .lines()
            .enumerate()
            .find(|(_, row)| row.contains(&label))
            .map(|(y, _)| y)
            .unwrap() as u16;
        assert_eq!(ui::user_message_at(&a, 80, 24, 3, y).as_deref(), Some(id));
        assert!(ui::user_message_at(&a, 80, 24, 3, 23).is_none());
        a.open_message_history(id);
        assert!(ui::user_message_at(&a, 80, 24, 3, y).is_none());
    }
}

#[test]
fn failed_steps_are_not_hidden_by_newer_successful_steps() {
    let mut a = App::default();
    a.apply_snapshot(json!({"session":{"id":"f","status":"failed"},
        "messages":[{"id":"m","role":"assistant","text":"reply"}],
        "steps":(0..10).map(|i|json!({"id":format!("s{i}"),"message_id":"m","verb":"运行",
            "object":if i==0{"FAILED_ORIGINAL"}else{"later"},"status":if i==0{"failed"}else{"done"},
            "exit_code":if i==0{1}else{0}})).collect::<Vec<_>>() }));
    assert!(render(&a).contains("FAILED_ORIGINAL"));
}
