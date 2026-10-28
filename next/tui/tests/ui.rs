use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use expert_tui::{
    app::{App, Drawer},
    source::fixture_events,
    ui,
};
use serde_json::json;
use std::time::{Duration, Instant};
const SCENES: &[&str] = &[
    "welcome",
    "first_run",
    "default_workspace",
    "startup_error",
    "prompt",
    "resume",
    "running",
    "approval",
    "retrying",
    "failed",
    "stopped",
    "waiting_acceptance",
    "accepted",
    "agents",
];
fn scene(name: &str) -> App {
    let mut app = App {
        reduce_motion: true,
        ..Default::default()
    };
    for e in fixture_events(name).unwrap() {
        app.apply_event(&e).unwrap();
    }
    // A local clock must not make checked-in terminal snapshots change daily.
    app.snapshot["startup"]["date"] = json!("2026-10-26");
    app
}
fn render(app: &App, w: u16, h: u16) -> ratatui::buffer::Buffer {
    let mut terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(w, h)).unwrap();
    terminal.draw(|f| ui::draw(f, app)).unwrap();
    terminal.backend().buffer().clone()
}
fn key(app: &mut App, code: KeyCode) -> Vec<expert_tui::app::Command> {
    app.key(KeyEvent::new(code, KeyModifiers::NONE), Instant::now(), 80)
}
#[test]
fn every_scene_has_reviewable_width_bounded_snapshots() {
    for name in SCENES {
        for w in [80, 60, 40] {
            let buffer = render(&scene(name), w, 24);
            let actual = ui::buffer_text(&buffer);
            assert_eq!(actual.lines().count(), 24);
            for row in actual.lines() {
                assert!(
                    ui::width(row, 1) <= w as usize,
                    "{name}:{w} overflow: {row}"
                );
            }
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join(format!("tests/snapshots/{name}-{w}x24.txt"));
            if std::env::var_os("UPDATE_SNAPSHOTS").is_some() {
                std::fs::write(&path, &actual).unwrap();
            }
            let expected =
                std::fs::read_to_string(&path).expect("generate snapshots with UPDATE_SNAPSHOTS=1");
            assert_eq!(actual, expected, "snapshot {name}:{w}");
        }
    }
}
#[test]
fn escapes_never_approve_or_reject() {
    let mut app = scene("approval");
    assert!(key(&mut app, KeyCode::Esc).is_empty());
    assert!(app.approval_collapsed);
    assert!(key(&mut app, KeyCode::Esc).is_empty());
    let stop = key(&mut app, KeyCode::Esc);
    assert_eq!(stop[0].method, "task.stop");
    for c in ['y', 'a', 'n'] {
        let mut app = scene("approval");
        let decision = key(&mut app, KeyCode::Char(c));
        assert_eq!(decision[0].method, "approval.decide");
        assert_eq!(
            decision[0].params["decision"],
            match c {
                'y' => "once",
                'a' => "session",
                _ => "reject",
            }
        );
    }
    let mut app = scene("approval");
    key(&mut app, KeyCode::Char('e'));
    app.insert("不允许写入");
    let decision = key(&mut app, KeyCode::Enter);
    assert_eq!(decision[0].params["reason"], "不允许写入");
}
#[test]
fn stop_requires_two_escapes_within_window() {
    let mut app = scene("running");
    let now = Instant::now();
    assert!(app.key(KeyEvent::from(KeyCode::Esc), now, 80).is_empty());
    assert!(
        app.key(
            KeyEvent::from(KeyCode::Esc),
            now + Duration::from_secs(2),
            80
        )
        .is_empty()
    );
    assert_eq!(
        app.key(
            KeyEvent::from(KeyCode::Esc),
            now + Duration::from_millis(2300),
            80
        )[0]
        .method,
        "task.stop"
    );
}
#[test]
fn full_access_requires_second_enter_and_survives_narrow_footer() {
    let mut app = scene("running");
    app.open(Drawer::Permissions);
    app.selected = 2;
    assert!(key(&mut app, KeyCode::Enter).is_empty());
    let c = key(&mut app, KeyCode::Enter);
    assert_eq!(c[0].params["confirmed"], true);
    app.snapshot["session"]["permission"] = json!("full");
    for w in [80, 60, 40, 20] {
        let b = render(&app, w, 24);
        assert!(ui::buffer_text(&b).contains("完全访问"));
    }
}
#[test]
fn snapshot_and_delta_use_one_reducer_and_approval_wins() {
    let mut app = scene("running");
    app.apply_event(&json!({"v":1,"event":"assistant.delta","data":{"message_id":"assistant-1","text":"\n更新"}})).unwrap();
    assert!(
        app.snapshot["messages"][1]["text"]
            .as_str()
            .unwrap()
            .ends_with("更新")
    );
    app.apply_event(&json!({"v":1,"event":"approval.requested","data":{"id":"a","tool":"shell"}}))
        .unwrap();
    assert_eq!(app.status(), "approval");
    let frame = ui::buffer_text(&render(&app, 80, 24));
    assert!(!frame.contains("00:11 +4"));
    assert!(frame.contains("等待批准"));

    // Pausing for approval must not hide evidence from a failed step.
    app.snapshot["steps"][0]["status"] = json!("failed");
    app.snapshot["steps"][0]["exit_code"] = json!(1);
    app.snapshot["steps"][0]["tail"] = json!(["FAILURE_EVIDENCE"]);
    let frame = ui::buffer_text(&render(&app, 80, 24));
    assert!(frame.contains("FAILURE_EVIDENCE"));
    assert!(frame.contains("退出码 1"));
    assert!(frame.contains("等待批准"));
    assert!(!frame.contains("00:11 +4"));
}
#[test]
fn unicode_editing_paste_history_and_pending_draft_preserve_text() {
    let mut app = scene("running");
    app.insert("中文a");
    key(&mut app, KeyCode::Left);
    key(&mut app, KeyCode::Backspace);
    assert_eq!(app.input, "中a");
    let commands = key(&mut app, KeyCode::Enter);
    assert_eq!(commands[0].method, "queue.add");
    assert_eq!(commands[0].params["text"], "中a");
    app.restore_draft();
    assert_eq!(app.input, "中a");
    app.pending_draft = None;
    app.input.clear();
    app.cursor = 0;
    app.paste("1\n2\n3\n4\n5\n6");
    assert!(ui::buffer_text(&render(&app, 40, 24)).contains("[文本 · 6 行 · 11 字]"));
    assert_eq!(app.input, "1\n2\n3\n4\n5\n6");
}
#[test]
fn control_sequences_are_removed_without_destroying_unicode() {
    assert_eq!(
        ui::clean("中文\x1b[31mred\x1b[0m\x1b]52;c;SECRET\x07text"),
        "中文redtext"
    );
    let mut app = scene("running");
    app.snapshot["messages"][0]["text"] = json!("safe\x1b]0;unsafe\x07text");
    assert!(!ui::buffer_text(&render(&app, 40, 24)).contains('\x1b'));
    assert_eq!(ui::width("中a", 1), 3);
    assert_eq!(ui::truncate("中文a", 3, 1), "中");
    assert_eq!(
        ui::width(&ui::middle("中文/long/path/file.rs", 12, &app), 1),
        12
    );
}
#[test]
fn no_color_and_ascii_decorations_respect_terminal() {
    let mut app = scene("running");
    app.no_color = true;
    app.truecolor = true;
    app.ascii = true;
    let buffer = render(&app, 40, 24);
    for cell in &buffer.content {
        assert_eq!(cell.fg, ratatui::style::Color::Reset);
        assert_eq!(cell.bg, ratatui::style::Color::Reset);
    }
    let text = ui::buffer_text(&buffer);
    for forbidden in ['╭', '╮', '╰', '╯', '│', '─', '◈', '›', '✓', '✗', '◌', '◇']
    {
        assert!(!text.contains(forbidden), "{forbidden}");
    }
}
#[test]
fn pets_follow_sequence_and_stop_when_hidden() {
    let mut app = scene("welcome");
    app.truecolor = true;
    assert!(ui::pet_visible(&app, 80, 24));
    assert!(!ui::pet_visible(&app, 60, 24));
    let now = Instant::now();
    app.pet.visible = true;
    app.pet.click(now, false);
    assert_eq!(app.pet.frame(now), "pose");
    app.pet.click(now, false);
    assert_eq!(app.pet.clicks, 1);
    app.pet.tick(now + Duration::from_millis(1600), false);
    app.pet.click(now + Duration::from_millis(1700), false);
    assert_eq!(app.pet.frame(now + Duration::from_millis(1700)), "chant1");
    assert_eq!(app.pet.frame(now + Duration::from_millis(2500)), "boom1");
    app.pet.tick(now + Duration::from_millis(3670), false);
    assert_eq!(app.pet.frame(now + Duration::from_millis(3670)), "down");
    app.pet.click(now + Duration::from_millis(4000), false);
    assert_eq!(app.pet.action, 0);
    app.pet.visible = false;
    let blink = app.pet.blink_at;
    app.pet.tick(now + Duration::from_secs(100), false);
    assert_eq!(app.pet.blink_at, blink);
}
#[test]
fn required_questions_validate_and_emit_backend_answer_shape() {
    let mut app = scene("running");
    app.snapshot["questions"] = json!([{"id":"req","questions":[{"id":"q","question":"choose","options":["red","blue"],"multiple":false,"required":true}]}]);
    assert!(key(&mut app, KeyCode::Enter).is_empty());
    app.insert("2");
    let answer = key(&mut app, KeyCode::Enter);
    assert_eq!(answer[0].method, "question.answer");
    assert_eq!(
        answer[0].params["answers"]["q"],
        json!({"selected":["blue"],"text":""})
    );
}
#[test]
fn interleaves_tools_with_the_message_that_caused_them() {
    let mut app = scene("running");
    app.snapshot["messages"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id":"user-2","role":"user","text":"NEXT MESSAGE"}));
    app.snapshot["messages"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id":"assistant-2","role":"assistant","text":"LATEST ANSWER"}));
    let rendered = ui::buffer_text(&render(&app, 80, 40));
    assert_eq!(rendered.matches("NEXT MESSAGE").count(), 1);
    assert!(rendered.find("flutter test").unwrap() < rendered.rfind("NEXT MESSAGE").unwrap());
}
#[test]
fn compact_heights_and_fullscreen_views_keep_bounds() {
    for name in SCENES {
        let mut app = scene(name);
        for h in [12, 15] {
            for view in [
                expert_tui::app::View::Chat,
                expert_tui::app::View::Changes,
                expert_tui::app::View::Agents,
            ] {
                app.view = view;
                let text = ui::buffer_text(&render(&app, 40, h));
                assert_eq!(text.lines().count(), h as usize);
                for row in text.lines() {
                    assert!(ui::width(row, 1) <= 40);
                }
            }
        }
        app.view = expert_tui::app::View::Chat;
        for drawer in [
            Drawer::Model,
            Drawer::Permissions,
            Drawer::Help,
            Drawer::History,
            Drawer::Workspace,
        ] {
            app.open(drawer);
            render(&app, 40, 12);
        }
    }
}
#[test]
fn welcome_remains_in_scrollback_without_repeating_hint() {
    let mut app = scene("welcome");
    app.snapshot["messages"] = json!([{"id":"u","role":"user","text":"FIRST TASK"}]);
    let output = ui::buffer_text(&render(&app, 80, 40));
    assert!(output.contains("expert v3.8.1 2026-10-26"));
    assert!(output.contains("FIRST TASK"));
    assert!(!output.contains("? 快捷键"));
}

#[test]
fn welcome_fixture_covers_recent_sessions_and_default_directory() {
    let welcome = ui::buffer_text(&render(&scene("welcome"), 80, 24));
    assert!(welcome.contains("最近会话"));
    assert!(welcome.contains("自适应图片预览"));
    let default = ui::buffer_text(&render(&scene("default_workspace"), 80, 24));
    assert!(default.contains("~/Documents/Expert"));
    assert!(!default.contains("~/code/image-lab"));
}
#[test]
fn markdown_preserves_content_with_native_terminal_styles() {
    let mut app = scene("running");
    app.expanded = true;
    app.snapshot["messages"] = json!([{"id":"m","role":"assistant","text":"# Title\n- bullet `inline`\n```rust\nlet x = 42;\n```\n| a | b |\n|---|---|\n| one | two |"}]);
    app.snapshot["steps"] = json!([]);
    let text = ui::buffer_text(&render(&app, 80, 40));
    assert!(text.contains("Title"));
    assert!(text.contains("• bullet inline"));
    assert!(!text.contains('`'));
    assert!(text.contains("┌"));
    assert!(text.contains("│ let x = 42;"));
}
#[test]
fn introduction_quote_outlives_the_pose_and_then_expires() {
    let now = Instant::now();
    let mut pet = expert_tui::pet::Pet::default();
    pet.visible = true;
    pet.click(now, false);
    pet.tick(now + Duration::from_millis(1600), false);
    assert_eq!(pet.action, 0);
    assert!(matches!(
        pet.frame(now + Duration::from_millis(1600)),
        "idle" | "idle_breath"
    ));
    assert_eq!(
        pet.quote(now + Duration::from_millis(2000)),
        "「吾名惠惠！」"
    );
    assert_eq!(pet.quote(now + Duration::from_millis(2500)), "");
}
#[test]
fn palettes_and_transparent_pet_cells_are_native_terminal_styles() {
    let mut app = scene("welcome");
    app.truecolor = true;
    app.light = true;
    let b = render(&app, 80, 24);
    assert!(
        b.content
            .iter()
            .any(|c| c.fg == ratatui::style::Color::Rgb(31, 98, 131))
    );
    assert_eq!(b[(78, 0)].bg, ratatui::style::Color::Reset);
    assert_eq!(b[(58, 0)].bg, ratatui::style::Color::Reset);
    app.light = false;
    let b = render(&app, 80, 24);
    // The new silhouette still uses its own native palette, without a solid
    // rectangular background. Check actual sprite cells rather than a pixel
    // coordinate tied to the previous artwork.
    let rect = ui::pet_rect(&app, 80, 24).unwrap();
    let palette: Vec<_> = app
        .pet
        .art
        .palette
        .values()
        .map(|hex| {
            let rgb = u32::from_str_radix(&hex[1..], 16).unwrap();
            ratatui::style::Color::Rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8)
        })
        .collect();
    assert!(
        (rect.y..rect.bottom()).any(|y| (rect.x..rect.right()).any(|x| {
            ["▀", "▄"].contains(&b[(x, y)].symbol()) && palette.contains(&b[(x, y)].fg)
        }))
    );
    app.truecolor = false;
    let b = render(&app, 80, 24);
    assert!(
        b.content
            .iter()
            .filter(|c| c.modifier.contains(ratatui::style::Modifier::DIM))
            .all(|c| c.fg != ratatui::style::Color::DarkGray)
    );
}
#[test]
fn repeated_history_keys_cycle_without_overwriting_edits() {
    let mut app = scene("running");
    app.history = vec!["first".into(), "second".into(), "third".into()];
    app.history_index = 3;
    key(&mut app, KeyCode::Up);
    assert_eq!(app.input, "third");
    key(&mut app, KeyCode::Up);
    assert_eq!(app.input, "second");
    key(&mut app, KeyCode::Down);
    assert_eq!(app.input, "third");
    key(&mut app, KeyCode::Down);
    assert!(app.input.is_empty());
}
