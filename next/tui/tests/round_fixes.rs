use crossterm::event::{KeyCode as K, KeyEvent};
use expert_tui::{
    app::{App, Command, Drawer, FormKind},
    ui,
};
use ratatui::{Terminal, backend::TestBackend};
use serde_json::{Value, json};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

fn iso(ago_secs: i64) -> String {
    // Seconds-precision UTC timestamp, formatted without external crates.
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
        - ago_secs;
    let (days, rem) = (t.div_euclid(86_400), t.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.000Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}
fn app() -> App {
    let mut app = App {
        reduce_motion: true,
        binding_ready: true,
        ..Default::default()
    };
    app.apply_snapshot(json!({
        "session":{"id":"s1","status":"idle","mode":"work","permission":"request",
            "model":"gpt-5.1","model_choice":"c1","thinking":true,"effort":"high","fast":false,"fast_supported":true},
        "messages":[],
        "models":[{"id":"gpt-5.1","choice":"c1","source":"OpenAI","efforts":["low","high"],"fast_supported":true},
                  {"id":"deepseek-v4","choice":"c2","source":"DeepSeek","efforts":["high"]}],
        "sessions":[
            {"id":"s1","title":"当前任务","updated_at":iso(30)},
            {"id":"old","title":"修复图片预览缩放","updated_at":iso(3 * 86_400 + 5 * 3600 + 60)},
            {"id":"mid","title":"整理发布说明","updated_at":iso(2 * 3600 + 120)},
            {"id":"noise","title":"预算审核与图形","updated_at":iso(60)}
        ]
    }));
    app
}
fn key(a: &mut App, code: K) -> Vec<Command> {
    a.key(KeyEvent::from(code), Instant::now(), 100)
}
fn send(a: &mut App, text: &str) -> Vec<Command> {
    a.paste(text);
    key(a, K::Enter)
}
fn render(a: &App, w: u16, h: u16) -> (String, (u16, u16)) {
    let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
    t.draw(|f| ui::draw(f, a)).unwrap();
    let cursor = t.get_cursor_position().unwrap();
    (ui::buffer_text(t.backend().buffer()), (cursor.x, cursor.y))
}

#[test]
fn slash_completion_is_in_dictionary_order() {
    let mut a = app();
    a.input = "/".into();
    let names = a.completion();
    let mut sorted = names.clone();
    sorted.sort();
    assert_eq!(names, sorted);
    assert!(names.contains(&"/model".to_owned()) && names.contains(&"/settings".to_owned()));
    assert!(
        names.contains(&"/context".to_owned()),
        "context has its own settings panel"
    );
    assert!(
        names.contains(&"/effort".to_owned()),
        "effort has its own settings panel"
    );
    for (shortcut, primary) in expert_tui::commands::COMMAND_SHORTCUTS {
        assert!(
            !names.iter().any(|name| name == shortcut),
            "{shortcut} is a shortcut"
        );
        assert!(
            names.iter().any(|name| name == primary),
            "missing primary {primary}"
        );
    }
    a.input = "/m".into();
    assert_eq!(a.completion(), ["/media", "/memory", "/mode", "/model"]);
}

#[test]
fn hidden_shortcuts_still_execute_without_being_replaced_by_completion() {
    let mut a = app();
    // /attach is a prefix of the primary /attachments command.
    a.input = "/attach".into();
    a.cursor = a.input.len();
    assert_eq!(a.completion(), ["/attachments"]);
    assert!(key(&mut a, K::Enter).is_empty());
    assert!(a.clipboard_requested);
    assert_eq!(a.drawer, None);
    for (shortcut, method, param, value) in [
        ("/clear", "session.new", "session_id", "s1"),
        ("/usage", "terminal.query", "topic", "usage"),
        ("/doctor", "terminal.query", "topic", "doctor"),
    ] {
        let mut a = app();
        let commands = send(&mut a, shortcut);
        assert_eq!(commands[0].method, method);
        assert_eq!(commands[0].params[param], value);
    }
    let mut a = app();
    send(&mut a, "/help commands");
    assert_eq!(a.drawer, Some(Drawer::Info));
    for shortcut in ["/effort", "/context", "/attach", "/login"] {
        assert!(a.info_lines.iter().any(|line| line.contains(shortcut)));
    }
}

#[test]
fn model_search_shows_its_cursor_and_edits_in_place() {
    let mut a = app();
    a.open(Drawer::Model);
    let (out, cursor) = render(&a, 100, 30);
    let row = out
        .lines()
        .position(|l| l.contains("输入以筛选模型"))
        .unwrap();
    assert_eq!(
        cursor.1 as usize, row,
        "cursor sits on the search row:\n{out}"
    );
    for c in "dee".chars() {
        key(&mut a, K::Char(c));
    }
    key(&mut a, K::Left);
    key(&mut a, K::Left);
    key(&mut a, K::Char('X'));
    assert_eq!(a.search, "dXee");
    key(&mut a, K::Home);
    key(&mut a, K::Delete);
    assert_eq!(a.search, "Xee");
    key(&mut a, K::End);
    key(&mut a, K::Backspace);
    a.search = "deep".into();
    a.search_cursor = 4;
    let list = a.drawer_items();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["id"], "deepseek-v4");
    let (_, cursor) = render(&a, 100, 30);
    let (out, _) = render(&a, 100, 30);
    let line = out.lines().nth(cursor.1 as usize).unwrap();
    assert!(line.contains("deep"), "{line}");
}

#[test]
fn sessions_show_age_newest_first_and_match_contiguously() {
    let mut a = app();
    let refresh = send(&mut a, "/session");
    assert_eq!(a.drawer, Some(Drawer::Sessions), "/session is an alias");
    assert!(refresh.is_empty());
    assert!(
        a.outbox.iter().any(|c| c.method == "session.list"),
        "the host list is refreshed on open"
    );
    let ids: Vec<Value> = a.drawer_items().iter().map(|s| s["id"].clone()).collect();
    assert_eq!(
        ids,
        [json!("s1"), json!("noise"), json!("mid"), json!("old")]
    );
    let (out, _) = render(&a, 100, 30);
    assert!(out.contains("3 天 5 小时前"), "{out}");
    assert!(out.contains("2 小时前"), "{out}");
    assert!(out.contains("刚刚"), "{out}");
    // A CJK query must not match titles that merely contain its characters apart.
    a.search = "图片".into();
    let hits: Vec<Value> = a.drawer_items().iter().map(|s| s["id"].clone()).collect();
    assert_eq!(hits, [json!("old")]);
    a.search = "图审".into();
    assert!(
        a.drawer_items().is_empty(),
        "scattered characters are not a match"
    );
}

#[test]
fn relative_time_reads_as_days_and_hours() {
    let now = 1_793_000_000;
    let at = |ago: i64| {
        let t = now - ago;
        let mut a = app();
        let _ = &mut a;
        t
    };
    let _ = at(0);
    assert_eq!(ui::relative_time("", now), "");
    assert_eq!(ui::relative_time("not-a-date", now), "");
    assert_eq!(
        ui::relative_time("2026-10-27T00:00:00Z", 1_793_059_200),
        "刚刚"
    );
    assert_eq!(
        ui::relative_time("2026-10-27T00:00:00Z", 1_793_059_200 + 600),
        "10 分钟前"
    );
    assert_eq!(
        ui::relative_time("2026-10-27T00:00:00+08:00", 1_793_059_200),
        "8 小时前"
    );
    assert_eq!(
        ui::relative_time("2026-10-24T19:00:00Z", 1_793_059_200),
        "2 天 5 小时前"
    );
    assert_eq!(
        ui::relative_time("2026-10-20T00:00:00.123Z", 1_793_059_200),
        "7 天前"
    );
}

#[test]
fn context_presets_fill_the_window_and_follow_typing() {
    let mut a = app();
    a.open(Drawer::Info);
    a.extra_generation = 7;
    let query = Command {
        method: "terminal.query".into(),
        params: json!({"topic":"context","ui_generation":7,"session_id":"s1","view":"settings"}),
    };
    let result = json!({"context":{"contextWindowTokens":128000,"reservedOutputTokens":4096,
        "maxHistoryMessages":24,"maxOutputTokens":0},"lines":["窗口 128k"],"model_key":"k"});
    assert!(a.extra_response(&query, &result));
    let form = a.form.as_ref().unwrap();
    assert_eq!(form.kind, FormKind::Context);
    let value = |a: &App, k: &str| {
        a.form
            .as_ref()
            .unwrap()
            .fields
            .iter()
            .find(|f| f.key == k)
            .unwrap()
            .value
            .clone()
    };
    assert_eq!(value(&a, "preset"), "128k");
    let preset = a
        .form
        .as_ref()
        .unwrap()
        .fields
        .iter()
        .position(|f| f.key == "preset")
        .unwrap();
    a.click_form_field(preset);
    assert_eq!(value(&a, "preset"), "200k");
    assert_eq!(value(&a, "window"), "200k");
    key(&mut a, K::Right);
    assert_eq!(value(&a, "preset"), "256k");
    assert_eq!(value(&a, "window"), "256k");
    let window = a
        .form
        .as_ref()
        .unwrap()
        .fields
        .iter()
        .position(|f| f.key == "window")
        .unwrap();
    a.click_form_field(window);
    key(&mut a, K::Backspace);
    key(&mut a, K::Backspace);
    key(&mut a, K::Backspace);
    key(&mut a, K::Backspace);
    for c in "64k".chars() {
        key(&mut a, K::Char(c));
    }
    assert_eq!(value(&a, "preset"), "64k");
    key(&mut a, K::Char('1'));
    assert_eq!(value(&a, "preset"), "custom");
    let (out, _) = render(&a, 100, 30);
    assert!(out.contains("常用预设") && out.contains("自定义"), "{out}");
}

#[test]
fn fast_toggles_only_where_supported() {
    let mut a = app();
    let c = send(&mut a, "/fast");
    assert_eq!(c[0].method, "terminal.action");
    assert_eq!(c[0].params["action"], "fast.set");
    assert_eq!(c[0].params["enabled"], true);
    a.snapshot["session"]["fast"] = json!(true);
    assert_eq!(send(&mut a, "/fast")[0].params["enabled"], false);
    assert_eq!(send(&mut a, "/fast on")[0].params["enabled"], true);
    let (out, _) = render(&a, 100, 24);
    assert!(out.contains("快速"), "footer shows fast mode:\n{out}");
    let mut a = app();
    a.snapshot["session"]["fast_supported"] = json!(false);
    assert!(send(&mut a, "/fast").is_empty());
    assert!(a.notice.contains("不支持快速模式"), "{}", a.notice);
    assert_eq!(
        send(&mut a, "/fast off")[0].params["enabled"],
        false,
        "turning off is always allowed"
    );
}

fn library() -> Value {
    json!({"title":"资料库",
        "assets":[{"id":"a1","name":"产品截图.png","kind":"image","size":2_400_000,"path":"/lib/images/a1.png","last_used_at":iso(3600)},
                  {"id":"a2","name":"需求说明.pdf","kind":"file","size":52_000,"path":"/lib/files/a2.pdf","last_used_at":iso(86_400 * 2)}],
        "sets":[{"id":"p1","name":"发布资料","count":3,"updated_at":iso(600)}]})
}
fn open_library(a: &mut App) {
    let c = send(a, "/library");
    assert_eq!(c.len(), 1);
    assert_eq!(c[0].params["topic"], "library", "native view, not the GUI");
    assert_eq!(a.drawer, Some(Drawer::Library));
    assert!(a.extra_response(&c[0], &library()));
}

#[test]
fn library_lists_assets_and_sets_natively() {
    let mut a = app();
    open_library(&mut a);
    let (out, _) = render(&a, 100, 30);
    for expected in [
        "资料库",
        "素材 2",
        "资料集 1",
        "产品截图.png",
        "图片 · 2.3 MB",
        "需求说明.pdf",
        "Enter 加入草稿附件",
    ] {
        assert!(out.contains(expected), "missing {expected}:\n{out}");
    }
    key(&mut a, K::Tab);
    let (out, _) = render(&a, 100, 30);
    assert!(out.contains("发布资料") && out.contains("3 份"), "{out}");
    let c = key(&mut a, K::Enter);
    assert_eq!(c[0].params["topic"], "library.set");
    assert_eq!(c[0].params["set_id"], "p1");
}

#[test]
fn library_asset_attaches_with_its_real_name() {
    let mut a = app();
    open_library(&mut a);
    for c in "需求".chars() {
        key(&mut a, K::Char(c));
    }
    let c = key(&mut a, K::Enter);
    assert_eq!(c[0].method, "attachment.import");
    assert_eq!(c[0].params["path"], "/lib/files/a2.pdf");
    assert_eq!(c[0].params["display_name"], "需求说明.pdf");
    assert_eq!(a.drawer, None);
    assert!(
        a.attachments.iter().any(|v| v["name"] == "需求说明.pdf"),
        "{:?}",
        a.attachments
    );
}

#[test]
fn library_delete_needs_a_second_press() {
    let mut a = app();
    open_library(&mut a);
    assert!(key(&mut a, K::Delete).is_empty());
    assert!(a.notice.contains("再按 Delete"), "{}", a.notice);
    key(&mut a, K::Down);
    assert!(
        key(&mut a, K::Delete).is_empty(),
        "moving away cancels the pending delete"
    );
    let c = key(&mut a, K::Delete);
    assert_eq!(c[0].params["action"], "library.delete");
    assert_eq!(c[0].params["item_id"], "a2");
    assert_eq!(c[0].params["confirmed"], true);
    assert_eq!(
        c[1].params["topic"], "library",
        "the list reloads after deleting"
    );
}

#[test]
fn wide_glyph_trailers_share_the_glyph_style() {
    // Selection tint on CJK text must cover both columns in ratatui's own model.
    let mut a = app();
    a.truecolor = true;
    a.open_settings();
    let mut t = Terminal::new(TestBackend::new(100, 30)).unwrap();
    let frame = t.draw(|f| ui::draw(f, &a)).unwrap().buffer.clone();
    let mut checked = 0;
    for y in 0..30 {
        for x in 0..99 {
            let cell = &frame[(x, y)];
            if unicode_width::UnicodeWidthStr::width(cell.symbol()) == 2 {
                assert_eq!(frame[(x + 1, y)].bg, cell.bg, "({x},{y}) {}", cell.symbol());
                checked += 1;
            }
        }
    }
    assert!(checked > 10);
}

#[test]
fn footer_click_targets_survive_the_plan_mode_marker() {
    for mode in ["work", "plan"] {
        let mut a = app();
        a.snapshot["session"]["mode"] = json!(mode);
        a.snapshot["session"]["context_percent"] = json!(40.0);
        let line: String = ui::footer(&a, 100)
            .spans
            .iter()
            .map(|s| s.content.to_string())
            .collect();
        assert_eq!(line.contains("计划模式"), mode == "plan", "{line}");
        let statistics: String = ui::footer_statistics(&a, 100)
            .spans
            .iter()
            .map(|s| s.content.to_string())
            .collect();
        let at = ui::width(&statistics[..statistics.find("上下文").unwrap()], 1);
        assert_eq!(
            ui::statistics_action(&a, 100, at + 1),
            "context",
            "{mode}: {statistics}"
        );
        let bar_end = statistics.rfind('▱').unwrap();
        assert_eq!(
            ui::statistics_action(&a, 100, ui::width(&statistics[..bar_end], 1)),
            "context",
            "the whole meter should open context settings"
        );
        assert_eq!(
            ui::statistics_action(&a, 100, 100),
            "usage",
            "{mode}: {statistics}"
        );
        assert_eq!(
            ui::footer_action(&a, 100, 2),
            None,
            "{mode}: left side is not clickable"
        );
    }
}

#[test]
fn context_meter_keeps_small_usage_visible_and_fits_narrow_terminals() {
    let mut a = app();
    for ascii in [false, true] {
        a.ascii = ascii;
        for percent in [0, 1, 80, 96, 100] {
            a.snapshot["session"]["context_percent"] = json!(percent);
            for width in [1, 8, 20, 40, 60, 80, 140] {
                let line = ui::footer_statistics(&a, width);
                let text: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
                assert!(
                    ui::width(&text, a.ambiguous_width) <= width,
                    "{width}: {text}"
                );
                if width >= 40 {
                    assert!(text.contains(&format!("{percent}%")), "{text}");
                }
                if width >= 60 {
                    let filled = if ascii { '#' } else { '▰' };
                    assert_eq!(text.contains(filled), percent > 0, "{text}");
                }
                if width >= 40 {
                    assert_eq!(text.contains("/compact"), percent >= 95, "{text}");
                }
            }
        }
    }
}
