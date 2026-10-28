use crossterm::event::{KeyCode as K, KeyEvent};
use expert_tui::{
    app::{App, Command, Drawer},
    ui::{self, PopupAction},
};
use ratatui::{Terminal, backend::TestBackend};
use serde_json::json;
use std::time::Instant;

fn app() -> App {
    let mut a = App {
        binding_ready: true,
        reduce_motion: true,
        ..Default::default()
    };
    a.apply_snapshot(json!({"session":{"id":"s1","status":"running","model_choice":"m","thinking":true,"effort":"high"},
        "messages":[],"models":[{"id":"alpha","choice":"m","source":"Source","efforts":["low","high"]}],
        "sessions":[{"id":"s1","title":"first"},{"id":"s2","title":"second"}],
        "workspaces":[{"id":"w1","name":"first","path":"/first"},{"id":"w2","name":"second","path":"/second"}]}));
    a
}
fn questions(a: &mut App) {
    let mut snapshot = a.snapshot.clone();
    snapshot["questions"] = json!([{"id":"req","questions":[
        {"id":"q1","question":"选择颜色","options":["红色","蓝色"],"required":true},
        {"id":"q2","question":"选择平台","options":["Windows","Linux","macOS"],"multiple":true,"required":true},
        {"id":"q3","question":"补充说明","options":[],"required":false}
    ]}]);
    a.apply_snapshot(snapshot);
}
fn key(a: &mut App, key: K) -> Vec<Command> {
    a.key(KeyEvent::from(key), Instant::now(), 80)
}
fn render(a: &App, w: u16, h: u16) -> String {
    let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
    terminal.draw(|f| ui::draw(f, a)).unwrap();
    ui::buffer_text(terminal.backend().buffer())
}
fn hit(a: &App, action: PopupAction, w: u16, h: u16) -> (u16, u16) {
    for y in 0..h {
        for x in 0..w {
            if ui::popup_action_at(a, w, h, x, y) == Some(action) {
                return (x, y);
            }
        }
    }
    panic!("missing {action:?}\n{}", render(a, w, h));
}
fn click(a: &mut App, action: PopupAction) -> Vec<Command> {
    let (x, y) = hit(a, action, 80, 24);
    a.click_popup_action(ui::popup_action_at(a, 80, 24, x, y).unwrap())
}

#[test]
fn arrows_preserve_each_answer_and_submit_one_scoped_request() {
    let mut a = app();
    questions(&mut a);
    assert!(a.question_popup_visible());
    key(&mut a, K::Down);
    key(&mut a, K::Char(' '));
    key(&mut a, K::Right);
    assert_eq!(a.question_index, 1);
    key(&mut a, K::Char(' '));
    key(&mut a, K::Down);
    key(&mut a, K::Char(' '));
    key(&mut a, K::Left);
    assert_eq!(a.input, "2");
    key(&mut a, K::Right);
    assert_eq!(a.input, "1,2");
    key(&mut a, K::Right);
    for c in "中文补充".chars() {
        key(&mut a, K::Char(c));
    }
    key(&mut a, K::Left);
    key(&mut a, K::Char('新'));
    assert_eq!(a.input, "中文补新充");
    key(&mut a, K::Tab);
    key(&mut a, K::Left);
    key(&mut a, K::Right);
    assert_eq!(a.input, "中文补新充");
    let c = key(&mut a, K::Enter).remove(0);
    assert_eq!(c.method, "question.answer");
    assert_eq!(c.params["session_id"], "s1");
    assert_eq!(c.params["answers"]["q1"]["selected"], json!(["蓝色"]));
    assert_eq!(
        c.params["answers"]["q2"]["selected"],
        json!(["Windows", "Linux"])
    );
    assert_eq!(c.params["answers"]["q3"]["text"], "中文补新充");
    assert!(key(&mut a, K::Enter).is_empty());
}

#[test]
fn missing_required_answer_is_not_implicitly_selected() {
    let mut a = app();
    questions(&mut a);
    assert!(key(&mut a, K::Enter).is_empty());
    a.switch_question(2);
    a.paste("comment");
    assert!(a.submit_question_answers().is_empty());
    assert_eq!(a.question_index, 0);
    assert!(a.notice.contains("必答"));
    assert!(a.pending_inputs.is_empty());
    a.switch_question(2);
    assert_eq!(a.input, "comment");
}

#[test]
fn arriving_and_completed_questions_preserve_the_chat_draft() {
    let mut a = app();
    a.paste("原会话草稿");
    questions(&mut a);
    assert!(a.input.is_empty());
    a.choose_question_option(0);
    a.switch_question(1);
    a.choose_question_option(0);
    let command = a.submit_question_answers().remove(0);
    a.command_response(&command, &json!({"accepted":true}));
    let mut snapshot = a.snapshot.clone();
    snapshot["questions"] = json!([]);
    a.apply_snapshot(snapshot);
    assert_eq!(a.input, "原会话草稿");
    assert!(!a.question_popup_visible());
}

#[test]
fn questions_keep_progress_separate_across_sessions_even_with_same_request_id() {
    let mut a = app();
    questions(&mut a);
    a.choose_question_option(1);
    a.switch_question(1);
    a.choose_question_option(2);
    let first = a.snapshot.clone();
    let mut second = first.clone();
    second["session"]["id"] = json!("s2");
    a.apply_snapshot(second);
    assert!(a.input.is_empty());
    assert_eq!(a.question_index, 0);
    a.choose_question_option(0);
    a.apply_snapshot(first);
    assert_eq!(a.question_index, 1);
    assert_eq!(a.input, "3");
    a.switch_question(0);
    assert_eq!(a.input, "2");
}

#[test]
fn dismissal_and_reconnect_keep_answers_without_auto_submission() {
    let mut a = app();
    questions(&mut a);
    a.paste("custom");
    key(&mut a, K::Esc);
    assert!(!a.question_popup_visible());
    a.apply_snapshot(a.snapshot.clone());
    a.paste("/questions");
    key(&mut a, K::Enter);
    assert!(a.question_popup_visible());
    assert_eq!(a.input, "custom");
    assert!(a.pending_inputs.is_empty());
    a.choose_question_option(0);
    a.switch_question(1);
    a.choose_question_option(1);
    let c = a.submit_question_answers().remove(0);
    a.command_error(&c, "offline");
    assert_eq!(a.input, "2");
    let retried = a.submit_question_answers().remove(0);
    assert_eq!(retried.params, c.params);
}

#[test]
fn question_mouse_tabs_choices_and_submit_match_keyboard_protocol() {
    let mut a = app();
    questions(&mut a);
    click(&mut a, PopupAction::AnswerOption(1));
    click(&mut a, PopupAction::Question(1));
    click(&mut a, PopupAction::AnswerOption(0));
    click(&mut a, PopupAction::AnswerOption(1));
    let commands = click(&mut a, PopupAction::AnswerSubmit);
    assert_eq!(
        commands[0].params["answers"]["q1"]["selected"],
        json!(["蓝色"])
    );
    assert_eq!(
        commands[0].params["answers"]["q2"]["selected"],
        json!(["Windows", "Linux"])
    );
}

#[test]
fn question_layout_and_hit_targets_stay_inside_short_and_narrow_dialogs() {
    let mut a = app();
    questions(&mut a);
    for (w, h) in [(40, 16), (60, 24), (80, 14), (80, 24), (120, 40)] {
        let out = render(&a, w, h);
        if let Some(directory) = std::env::var_os("EXPERT_QUESTION_SNAPSHOTS") {
            let directory = std::path::PathBuf::from(directory);
            std::fs::create_dir_all(&directory).unwrap();
            std::fs::write(directory.join(format!("questions-{w}x{h}.txt")), &out).unwrap();
        }
        assert!(out.contains("选择颜色"), "{out}");
        assert!(out.contains("[提交]"), "{out}");
        let rect = ui::popup_rect(&a, w, h).unwrap();
        assert!(rect.right() <= w && rect.bottom() <= h);
        let (x, y) = hit(&a, PopupAction::AnswerOption(1), w, h);
        assert!(out.lines().nth(y as usize).unwrap().contains("蓝色"));
        assert!(rect.contains((x, y).into()));
    }
    a.snapshot["questions"][0]["questions"][0]["question"] = json!("很长的问题内容".repeat(80));
    a.snapshot["questions"][0]["questions"][0]["options"] =
        json!((0..40).map(|i| format!("选项{i}")).collect::<Vec<_>>());
    for _ in 0..39 {
        key(&mut a, K::Down);
    }
    let out = render(&a, 40, 16);
    let (_, y) = hit(&a, PopupAction::AnswerOption(39), 40, 16);
    assert!(out.lines().nth(y as usize).unwrap().contains("选项39"));
    key(&mut a, K::PageDown);
    assert_eq!(a.question_ui.scroll, 4);
}

#[test]
fn mouse_model_and_session_rows_use_rendered_item_indices() {
    let mut a = app();
    a.snapshot["session"]["status"] = json!("idle");
    a.snapshot["models"]=json!((0..30).map(|i|json!({"id":format!("model-{i:02}"),"choice":format!("c{i}"),"source":format!("source-{}",i/5),"efforts":["low","high"]})).collect::<Vec<_>>());
    for (w, h) in [(40, 16), (80, 14), (100, 30)] {
        a.open(Drawer::Model);
        a.selected = 24;
        let (_, y) = hit(&a, PopupAction::Item(24), w, h);
        let out = render(&a, w, h);
        assert!(
            out.lines().nth(y as usize).unwrap().contains("model-24"),
            "{out}"
        );
        let c = a.click_popup_action(PopupAction::Item(24));
        assert_eq!(c[0].params["choice"], "c24");
    }
    a.open(Drawer::Sessions);
    let c = click(&mut a, PopupAction::Item(1));
    assert_eq!(c[0].params["session_id"], "s2");
    a.open(Drawer::Workspace);
    let c = click(&mut a, PopupAction::Item(1));
    assert_eq!(c[0].params["workspace_id"], "w2");
}

#[test]
fn mouse_permissions_keep_full_access_confirmation_and_effort_is_clickable() {
    let mut a = app();
    a.snapshot["session"]["status"] = json!("idle");
    a.open(Drawer::Permissions);
    assert!(click(&mut a, PopupAction::Item(2)).is_empty());
    assert!(a.full_confirm);
    let c = click(&mut a, PopupAction::Item(2));
    assert_eq!(c[0].params["confirmed"], true);
    a.open(Drawer::Effort);
    click(&mut a, PopupAction::Thinking);
    assert!(!a.thinking);
    let c = click(&mut a, PopupAction::Apply);
    assert_eq!(c[0].params["thinking"], false);
    a.open(Drawer::Effort);
    let c = click(&mut a, PopupAction::Item(0));
    assert_eq!(c[0].params["effort"], "low");
}

#[test]
fn mouse_cycles_context_preset_and_updates_the_window_field() {
    let mut a = app();
    let command = a.open_context_settings().remove(0);
    a.extra_response(&command,&json!({"context":{"contextWindowTokens":64000,"reservedOutputTokens":4096,"maxHistoryMessages":24,"maxOutputTokens":0},"lines":[]}));
    let index = a
        .form
        .as_ref()
        .unwrap()
        .fields
        .iter()
        .position(|f| f.key == "preset")
        .unwrap();
    a.click_form_field(index);
    let form = a.form.as_ref().unwrap();
    assert_eq!(
        form.fields
            .iter()
            .find(|f| f.key == "preset")
            .unwrap()
            .value,
        "128k"
    );
    assert_eq!(
        form.fields
            .iter()
            .find(|f| f.key == "window")
            .unwrap()
            .value,
        "128k"
    );
    let save = form.fields.iter().position(|f| f.key == "__save").unwrap();
    let commands = a.click_form_field(save);
    assert_eq!(commands[0].params["window"], 128000);
}

#[test]
fn library_tabs_and_scrolled_items_support_mouse_clicks() {
    let mut a = app();
    a.open(Drawer::Library);
    a.library = json!({"assets":[{"id":"a1","name":"one.png","path":"/one.png"},{"id":"a2","name":"two.png","path":"/two.png"}],
        "sets":[{"id":"set1","name":"资料集一"}]});
    let c = click(&mut a, PopupAction::Item(1));
    assert_eq!(c[0].params["path"], "/two.png");
    a.open(Drawer::Library);
    click(&mut a, PopupAction::LibraryTab(true));
    assert!(a.library_sets);
    let c = click(&mut a, PopupAction::Item(0));
    assert_eq!(c[0].params["set_id"], "set1");
}

#[test]
fn pending_answers_are_read_only_and_a_hidden_new_draft_is_preserved() {
    let mut a = app();
    a.paste("原始草稿");
    questions(&mut a);
    a.choose_question_option(0);
    a.switch_question(1);
    a.choose_question_option(0);
    assert_eq!(a.submit_question_answers().len(), 1);
    a.paste("不能修改已提交答案");
    key(&mut a, K::Char('a'));
    assert!(a.input.is_empty());
    key(&mut a, K::Esc);
    a.paste("后续草稿");
    let mut next = a.snapshot.clone();
    next["questions"] = json!([]);
    a.apply_snapshot(next);
    assert_eq!(a.input, "原始草稿\n后续草稿");
}
