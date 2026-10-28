use crossterm::event::{KeyCode as K, KeyEvent, KeyModifiers};
use expert_tui::{
    app::{App, StartupPhase},
    source::fixture_events,
    ui,
};
use ratatui::{Terminal, backend::TestBackend};

/// A populated app, so anything leaking past the gate would be visible.
fn app() -> App {
    let mut app = App {
        reduce_motion: true,
        ..Default::default()
    };
    for e in fixture_events("welcome").unwrap() {
        app.apply_event(&e).unwrap();
    }
    app
}
fn text(a: &App, w: u16, h: u16) -> String {
    let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
    t.draw(|f| ui::draw(f, a)).unwrap();
    ui::buffer_text(t.backend().buffer())
}
fn key(a: &mut App, code: K) -> Vec<expert_tui::app::Command> {
    a.trust_key(KeyEvent::from(code))
}

#[test]
fn new_folder_shows_only_the_trust_question() {
    let mut a = app();
    // Long enough to need wrapping at every tested width.
    a.ask_trust("/home/me/projects/clients/very-long-client-name/new-project");
    for (w, h) in [(120, 40), (80, 24), (40, 24)] {
        let out = text(&a, w, h);
        for expected in [
            "是否信任此文件夹",
            "new-project",
            "1. 信任此文件夹（读写）",
            "3. 不信任，退出",
        ] {
            assert!(out.contains(expected), "{w}x{h} missing {expected}:\n{out}");
        }
        // Header, recent sessions, input box and footer must all stay hidden.
        for hidden in ["expert", "最近会话", "描述任务", "请求批准", "上下文"] {
            assert!(!out.contains(hidden), "{w}x{h} leaked {hidden}:\n{out}");
        }
        for row in out.lines() {
            assert!(ui::width(row, 1) <= w as usize, "{w}x{h} overflow: {row}");
        }
    }
}

#[test]
fn startup_card_shows_real_phase_without_exposing_workspace_content() {
    let mut a = app();
    a.workspace_pending = true;
    for (phase, status) in [
        (StartupPhase::Connecting, "正在连接本地服务"),
        (StartupPhase::Workspace, "正在准备工作区"),
        (StartupPhase::Session, "正在恢复会话"),
    ] {
        a.startup_phase = Some(phase);
        for (w, h) in [(120, 40), (80, 24), (40, 24), (28, 12)] {
            let out = text(&a, w, h);
            assert!(out.contains(status), "{w}x{h}: {out}");
            assert!(out.contains("Ctrl+C 退出"), "{out}");
            for hidden in ["最近会话", "fixture-", "image-lab", "上下文", "描述任务"] {
                assert!(!out.contains(hidden), "leaked {hidden}: {out}");
            }
            for row in out.lines() {
                assert!(ui::width(row, 1) <= w as usize, "{row}");
            }
        }
    }
}

#[test]
fn startup_card_uses_selected_theme_and_honors_no_color() {
    use ratatui::style::Color;
    let mut a = app();
    a.startup_phase = Some(StartupPhase::Connecting);
    a.truecolor = true;
    for accent in ["#ff9900", "#2288ee"] {
        a.accent = Some(accent.into());
        let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
        terminal.draw(|f| ui::draw(f, &a)).unwrap();
        let title = terminal
            .backend()
            .buffer()
            .content
            .iter()
            .find(|cell| cell.symbol() == "E")
            .unwrap();
        assert_eq!(title.fg, expert_tui::theme::parse_color(accent).unwrap());
    }
    a.no_color = true;
    a.ascii = true;
    let mut terminal = Terminal::new(TestBackend::new(80, 24)).unwrap();
    terminal.draw(|f| ui::draw(f, &a)).unwrap();
    for cell in &terminal.backend().buffer().content {
        assert_eq!(cell.fg, Color::Reset);
        assert_eq!(cell.bg, Color::Reset);
    }
    assert!(ui::buffer_text(terminal.backend().buffer()).contains("+---"));
}

#[test]
fn trust_choices_register_with_the_chosen_access() {
    let mut a = app();
    a.ask_trust("/p");
    let c = key(&mut a, K::Enter);
    assert_eq!(c[0].method, "workspace.register");
    assert_eq!(c[0].params["access"], "read-write");
    assert_eq!(c[0].params["path"], "/p");
    assert!(a.trust_prompt.is_none() && a.workspace_pending);

    let mut a = app();
    a.ask_trust("/p");
    assert!(key(&mut a, K::Down).is_empty());
    let c = key(&mut a, K::Enter);
    assert_eq!(c[0].params["access"], "read-only");

    let mut a = app();
    a.ask_trust("/p");
    assert_eq!(key(&mut a, K::Char('2'))[0].params["access"], "read-only");
}

#[test]
fn declining_trust_exits_without_registering() {
    for code in [K::Esc, K::Char('3')] {
        let mut a = app();
        a.ask_trust("/p");
        assert!(key(&mut a, code).is_empty());
        assert!(a.exit);
    }
    let mut a = app();
    a.ask_trust("/p");
    key(&mut a, K::Up);
    assert!(key(&mut a, K::Enter).is_empty());
    assert!(a.exit, "wrapping up from the first choice lands on 不信任");
    let mut a = app();
    a.ask_trust("/p");
    assert!(
        a.trust_key(KeyEvent::new(K::Char('c'), KeyModifiers::CONTROL))
            .is_empty()
    );
    assert!(a.exit);
}

#[test]
fn no_color_ascii_trust_screen_stays_plain() {
    let mut a = app();
    a.no_color = true;
    a.ascii = true;
    a.ask_trust("/p");
    let mut t = Terminal::new(TestBackend::new(60, 24)).unwrap();
    t.draw(|f| ui::draw(f, &a)).unwrap();
    for cell in &t.backend().buffer().content {
        assert_eq!(cell.fg, ratatui::style::Color::Reset);
        assert_eq!(cell.bg, ratatui::style::Color::Reset);
    }
    let out = ui::buffer_text(t.backend().buffer());
    assert!(out.contains("+---") && !out.contains('╭'), "{out}");
}
