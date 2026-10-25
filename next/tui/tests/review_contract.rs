use expert_tui::{app::App, source::fixture_events, ui};
use ratatui::{Terminal, backend::TestBackend, style::Color};
use serde_json::json;

fn app(scene: &str) -> App {
    let mut a = App {
        reduce_motion: true,
        ..App::default()
    };
    for event in fixture_events(scene).unwrap() {
        a.apply_event(&event).unwrap();
    }
    a
}
fn render(a: &App, width: u16, height: u16) -> String {
    let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
    terminal.draw(|f| ui::draw(f, a)).unwrap();
    ui::buffer_text(terminal.backend().buffer())
}

#[test]
fn full_access_and_plan_remain_visible_during_command_completion() {
    for width in [40, 60, 80] {
        let mut a = app("running");
        a.snapshot["session"]["permission"] = json!("full");
        a.snapshot["session"]["mode"] = json!("plan");
        a.input = "/".into();
        a.cursor = 1;
        let output = render(&a, width, 24);
        assert!(
            output.contains("完全访问"),
            "permission hidden at {width}:\n{output}"
        );
        assert!(output.contains("计划"), "plan hidden at {width}:\n{output}");
    }
}

#[test]
fn narrow_approval_exposes_decision_keys_and_denial_reason_action() {
    let a = app("approval");
    let output = render(&a, 40, 24);
    for expected in ["允许一次", "拒绝并说明", "y", "a", "n", "e"] {
        assert!(
            output.contains(expected),
            "approval action hidden: {expected}\n{output}"
        );
    }
}

#[test]
fn backend_fractional_context_usage_is_rendered_and_warned() {
    let mut a = app("running");
    a.snapshot["session"]["context_percent"] = json!(95.4);
    let output = render(&a, 140, 24);
    assert!(output.contains("95%"), "float usage missing:\n{output}");
    assert!(output.contains("/compact"));
}

#[test]
fn no_color_never_emits_colored_cells_even_with_truecolor_requested() {
    let mut a = app("welcome");
    a.truecolor = true;
    a.no_color = true;
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
    terminal.draw(|f| ui::draw(f, &a)).unwrap();
    for cell in &terminal.backend().buffer().content {
        assert_eq!(cell.fg, Color::Reset);
        assert_eq!(cell.bg, Color::Reset);
    }
}

#[test]
fn failed_tool_keeps_exit_evidence_instead_of_a_successful_fold() {
    let a = app("failed");
    for width in [40, 60, 80] {
        let output = render(&a, width, 24);
        assert!(
            !output.contains("✓ 4 个步骤"),
            "failed round marked successful:\n{output}"
        );
        for expected in ["Expected:", "Actual:", "Assertion failed:"] {
            assert!(
                output.contains(expected),
                "failure evidence hidden at {width}: {expected}\n{output}"
            );
        }
    }
}

#[test]
fn steps_stay_with_their_own_assistant_message_across_turns() {
    let mut a = app("running");
    a.expanded = true;
    a.snapshot["messages"] = json!([
        {"id":"u1","role":"user","text":"USER_FIRST"},
        {"id":"a1","role":"assistant","text":"ANSWER_FIRST"},
        {"id":"u2","role":"user","text":"USER_SECOND"},
        {"id":"a2","role":"assistant","text":"ANSWER_SECOND"}
    ]);
    a.snapshot["steps"] = json!([
        {"id":"s1","message_id":"a1","round_id":"r1","verb":"读取","object":"FIRST_TOOL","status":"done","tail":[]},
        {"id":"s2","message_id":"a2","round_id":"r2","verb":"运行","object":"SECOND_TOOL","status":"running","tail":[]}
    ]);
    let output = render(&a, 80, 40);
    let first_tool = output.find("FIRST_TOOL").unwrap();
    let second_user = output.find("USER_SECOND").unwrap();
    assert!(
        first_tool < second_user,
        "steps separated from their turn:\n{output}"
    );
}
