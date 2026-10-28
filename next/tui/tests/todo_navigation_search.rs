use expert_tui::{
    app::{App, Drawer},
    presentation, todo, ui,
};
use serde_json::json;

fn app() -> App {
    let mut a = App::default();
    a.apply_snapshot(json!({"session":{"id":"s","status":"running"},"messages":(0..20).map(|i|json!({"id":format!("m{i}"),"role":if i%2==0{"user"}else{"assistant"},"text":format!("Message {i}\ntext\ntext\ntext")})).collect::<Vec<_>>()}));
    a
}
#[test]
fn pinned_turn_tracks_reading_and_repeated_jumps_walk_backward() {
    let mut a = app();
    assert_eq!(presentation::pinned_user(&a).unwrap().0, "m18");
    for id in ["m18", "m16", "m14", "m12"] {
        ui::jump_pinned_user(&mut a);
        assert_eq!(
            a.reading_anchor.as_ref().unwrap().message_id.as_deref(),
            Some(id)
        );
        assert_eq!(presentation::pinned_user(&a).unwrap().0, id);
    }
    ui::jump_user_turn(&mut a, 1);
    assert_eq!(presentation::pinned_user(&a).unwrap().0, "m14");
    a.latest_output();
    assert_eq!(presentation::pinned_user(&a).unwrap().0, "m18");
}
#[test]
fn model_filter_is_case_insensitive_literal_substring() {
    let mut a = app();
    a.open(Drawer::Model);
    a.snapshot["models"] =
        json!([{"id":"DeepSeek-V4.1-Flash","source":"API"},{"id":"DS-other-v4","source":"Local"}]);
    a.search = "v4.1-fLASH".into();
    assert_eq!(a.drawer_items().len(), 1);
    a.search = "dsv4".into();
    assert!(a.drawer_items().is_empty());
    a.search = "v4 flash".into();
    assert!(a.drawer_items().is_empty());
}
#[test]
fn todo_auto_shows_checked_items_updates_and_closes_when_done() {
    let mut a = app();
    a.snapshot["plan"] = json!({"is_current":true,"status":"tracking","steps":[{"title":"READ_SOURCE","status":"completed"},{"title":"REPAIR_CODE","status":"running"}]});
    assert!(todo::active(&a));
    let mut t = ratatui::Terminal::new(ratatui::backend::TestBackend::new(100, 30)).unwrap();
    t.draw(|f| ui::draw(f, &a)).unwrap();
    let text = ui::buffer_text(t.backend().buffer());
    assert!(text.contains("[✓] READ_SOURCE") && text.contains("[>] REPAIR_CODE"));
    a.snapshot["plan"]["steps"][1]["status"] = json!("completed");
    assert!(!todo::active(&a));
    t.draw(|f| ui::draw(f, &a)).unwrap();
    assert!(!ui::buffer_text(t.backend().buffer()).contains("待办"));
    a.snapshot["plan"]["steps"][1]["status"] = json!("pending");
    a.snapshot["plan"]["is_current"] = json!(false);
    assert!(!todo::active(&a));
}
