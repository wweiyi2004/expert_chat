use expert_tui::{
    app::{App, Drawer, View},
    source::fixture_events,
    ui,
};
use ratatui::{Terminal, backend::TestBackend, buffer::Buffer, style::Color};
use serde_json::json;
fn app() -> App {
    let mut a = App {
        reduce_motion: true,
        ..Default::default()
    };
    for e in fixture_events("running").unwrap() {
        a.apply_event(&e).unwrap();
    }
    a
}
fn render(a: &App, w: u16, h: u16) -> (Buffer, (u16, u16)) {
    let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
    t.draw(|f| ui::draw(f, a)).unwrap();
    let c = t.get_cursor_position().unwrap();
    (t.backend().buffer().clone(), (c.x, c.y))
}
fn text(a: &App, w: u16, h: u16) -> String {
    ui::buffer_text(&render(a, w, h).0)
}
#[test]
fn soft_wrapped_input_cursor_tracks_visual_row() {
    let mut a = app();
    a.input = "A".repeat(80);
    a.cursor = 80;
    let (_, c) = render(&a, 80, 24);
    assert_eq!(ui::input_visual_position(&a, 80), (1, 5));
    assert_eq!(c, (9, 21));
}
#[test]
fn long_input_follows_end_and_then_home() {
    let mut a = app();
    a.input = format!("{}END_MARKER", "A".repeat(451));
    a.cursor = a.input.len();
    let out = text(&a, 80, 24);
    assert!(out.contains("END_MARKER"), "{out}");
    a.cursor = 0;
    let (b, c) = render(&a, 80, 24);
    assert_eq!(c, (4, 16));
    assert!(!ui::buffer_text(&b).contains("END_MARKER"));
}
#[test]
fn manual_multiline_is_not_mislabelled_as_paste() {
    let mut a = app();
    a.input = "a\nb\nc\nd\ne\nf\nTAIL".into();
    a.cursor = a.input.len();
    assert!(!text(&a, 80, 24).contains("已粘贴"));
    assert!(text(&a, 80, 24).contains("TAIL"));
    a.paste_collapsed = true;
    assert!(text(&a, 80, 24).contains("已粘贴 7 行"));
}
#[test]
fn long_agent_tree_shows_selection_and_scrollable_detail() {
    let mut a = app();
    a.view = View::Agents;
    a.snapshot["agents"]=json!((0..30).map(|i|json!({"id":format!("a{i}"),"name":format!("AGENT_{i}"),"status":"running","task":"TASK","output":format!("{}\nDETAIL_END",(0..40).map(|j|format!("line{j}")).collect::<Vec<_>>().join("\n"))})).collect::<Vec<_>>());
    a.selected = 25;
    assert!(text(&a, 80, 24).contains("AGENT_25"));
    a.agent_detail_id = Some("a25".into());
    a.scroll = 30;
    assert!(text(&a, 80, 24).contains("DETAIL_END"));
}
fn changes() -> App {
    let mut a = app();
    a.view = View::Changes;
    a.snapshot["changes"]=json!((0..30).map(|i|json!({"id":format!("c{i}"),"path":format!("FILE_{i}"),"kind":"M","added":1,"removed":0,"diff":[format!("+ {} TAIL_DIFF_MARKER","A".repeat(120))]})).collect::<Vec<_>>());
    a.selected = 26;
    a
}
#[test]
fn file_list_follows_selection_at_both_layouts() {
    for w in [40, 80, 120] {
        let a = changes();
        let out = text(&a, w, 24);
        assert!(out.contains("› M FILE_26"), "{w}: {out}");
        assert!(out.contains("TAIL_DIFF_MARKER"), "{w}: {out}");
    }
}
#[test]
fn short_model_drawer_retains_selected_model_and_controls() {
    let mut a = app();
    a.drawer = Some(Drawer::Model);
    a.selected = 2;
    a.snapshot["models"]=json!((0..3).map(|i|json!({"id":format!("MODEL_{i}"),"choice":format!("choice{i}"),"source":format!("SOURCE_{i}"),"efforts":["low","high"]})).collect::<Vec<_>>());
    for h in [14, 24] {
        let out = text(&a, 80, h);
        for expected in ["MODEL_2", "思考", "强度", "space"] {
            assert!(out.contains(expected), "{h}: {expected}\n{out}");
        }
    }
}
#[test]
fn every_tiny_height_prioritizes_full_access() {
    let mut a = app();
    a.snapshot["session"]["permission"] = json!("full");
    for h in 1..16 {
        for slash in [false, true] {
            a.input = if slash { "/".into() } else { String::new() };
            let out = text(&a, 40, h);
            assert!(out.contains("完全访问"), "{h}: {out}");
        }
    }
}
#[test]
fn double_width_ambiguity_uses_ascii_chrome() {
    let mut a = app();
    a.ambiguous_width = 2;
    let out = text(&a, 80, 24);
    assert!(out.contains("+---"));
    for c in ['╭', '╮', '╯', '╰', '─', '│', '◇', '·', '−'] {
        assert!(!out.contains(c), "{c}: {out}");
    }
    for row in out.lines() {
        assert!(ui::width(row, 2) <= 80, "{row}");
    }
}
#[test]
fn thinking_duration_only_uses_real_backend_time() {
    let mut a = app();
    a.snapshot["messages"] = json!([{"id":"m","role":"assistant","text":"ANSWER","thinking":"THOUGHT","thinking_elapsed_ms":12340}]);
    assert!(text(&a, 80, 24).contains("思考  12s"));
    a.snapshot["messages"][0]["thinking_elapsed_ms"] = json!(null);
    assert!(!text(&a, 80, 24).contains("思考  0s"));
}
#[test]
fn prose_body_is_capped_at_one_hundred_columns() {
    let mut a = app();
    a.snapshot["steps"] = json!([]);
    a.snapshot["messages"] = json!([{"id":"m","role":"assistant","text":"X".repeat(500)}]);
    let out = text(&a, 140, 36);
    for row in out.lines().filter(|r| r.contains('X')) {
        assert!(ui::width(row, 1) <= 102, "{row}");
    }
    let out = text(&a, 80, 24);
    for row in out.lines().filter(|r| r.contains('X')) {
        assert!(ui::width(row, 1) <= 78);
    }
}
#[test]
fn status_spinner_is_accent_and_summary_counts_are_semantic() {
    let mut a = app();
    let (b, _) = render(&a, 80, 24);
    let row = ui::buffer_text(&b)
        .lines()
        .position(|l| l.contains("运行检查"))
        .unwrap() as u16;
    assert_eq!(b[(0, row)].fg, Color::Cyan);
    assert_eq!(b[(2, row)].fg, Color::Reset);
    a.snapshot["session"]["status"] = json!("waiting_acceptance");
    a.snapshot["changes"] = json!([{"kind":"M","path":"semantic.rs","added":8,"removed":3}]);
    let (b, _) = render(&a, 80, 24);
    let row = ui::buffer_text(&b)
        .lines()
        .position(|l| l.contains("semantic.rs"))
        .unwrap() as u16;
    assert_eq!(b[(4, row)].fg, Color::Yellow);
    assert_eq!(b[(6, row)].fg, Color::Reset);
    let rendered = ui::buffer_text(&b);
    let line = rendered.lines().nth(row as usize).unwrap();
    let plus = line.find('+').unwrap() as u16;
    assert_eq!(b[(plus, row)].fg, Color::Green);
    let minus = plus + 3;
    assert_eq!(b[(minus, row)].fg, Color::Red);
}
#[test]
fn pet_hit_rect_matches_sidebar_render_position() {
    let mut a = app();
    a.snapshot["messages"] = json!([]);
    a.truecolor = true;
    a.sidebar = true;
    assert_eq!(
        ui::pet_rect(&a, 140, 36),
        Some(ratatui::layout::Rect::new(74, 0, 20, 6))
    );
    a.no_color = true;
    assert_eq!(ui::pet_rect(&a, 140, 36), None);
}
#[test]
fn long_table_cells_and_many_columns_retain_all_data() {
    let mut a = app();
    a.snapshot["steps"] = json!([]);
    a.snapshot["messages"] = json!([{"id":"m","role":"assistant","text":format!("| Key | Value |\n| --- | --- |\n| K | {} TABLE_END_MARKER |","A".repeat(120))}]);
    assert!(text(&a, 80, 24).contains("TABLE_END_MARKER"));
    a.snapshot["messages"][0]["text"] = json!(
        "| A | B | C | D | E | F | G | H | I | J | K | L |\n| - | - | - | - | - | - | - | - | - | - | - | - |\n| a | b | c | d | e | f | g | h | i | j | k | LAST_COLUMN_MARKER |"
    );
    assert!(text(&a, 40, 24).contains("LAST_COLUMN_MARKER"));
}
#[test]
fn file_link_rects_only_include_complete_file_objects() {
    let mut a = app();
    a.expanded = true;
    a.snapshot["steps"] = json!([{"id":"s","verb":"读取","object":"src/sample.rs","status":"done"},{"id":"q","verb":"搜索","object":"query.rs","status":"done"}]);
    let (b, _) = render(&a, 80, 24);
    let links = ui::file_links_from_buffer(&a, &b);
    assert!(links.iter().any(|l| l.path == "src/sample.rs"));
    assert!(!links.iter().any(|l| l.path == "query.rs"));
    a.snapshot["session"]["remote"] = json!(true);
    assert!(ui::file_links_from_buffer(&a, &b).is_empty());
}
#[test]
fn stale_state_and_configuration_warning_persist_in_fullscreen() {
    let mut a = app();
    a.view = View::Agents;
    a.snapshot_stale = true;
    assert!(text(&a, 80, 24).contains("当前为旧快照"));
    a.snapshot_stale = false;
    a.config_warning = Some("CONFIG_PARSE_WARNING".into());
    assert!(text(&a, 80, 24).contains("CONFIG_PARSE_WARNING"));
}

#[test]
fn exact_wrap_boundary_reserves_a_visible_cursor_row() {
    let mut a = app();
    a.input = "A".repeat(75);
    a.cursor = 75;
    let (b, c) = render(&a, 80, 24);
    assert!(ui::buffer_text(&b).contains(&"A".repeat(75)));
    assert_eq!(c, (4, 21));
}

#[test]
fn indexed_tool_history_preserves_last_round_and_orphan_order() {
    let mut a = app();
    a.snapshot["messages"] = json!(
        (0..1000)
            .map(|i| json!({"id":format!("m{i}"),"role":"assistant","text":format!("MESSAGE_{i}")}))
            .collect::<Vec<_>>()
    );
    a.snapshot["steps"]=json!((0..10000).map(|i|json!({"id":format!("s{i}"),"message_id":format!("m{}",i/10),"round_id":i/10,"verb":"读取","object":format!("FILE_{i}"),"status":"done"})).collect::<Vec<_>>());
    a.snapshot["steps"].as_array_mut().unwrap().extend([json!({"id":"o1","message_id":"missing","verb":"读取","object":"ORPHAN_FIRST","status":"running"}),json!({"id":"o2","message_id":"missing","verb":"读取","object":"ORPHAN_SECOND","status":"running"})]);
    let out = text(&a, 120, 36);
    assert!(out.contains("MESSAGE_999"));
    assert!(out.contains("10 个步骤"));
    assert!(out.find("ORPHAN_FIRST").unwrap() < out.find("ORPHAN_SECOND").unwrap());
}

#[test]
fn configuration_warning_does_not_swallow_runtime_errors() {
    let mut a = app();
    a.config_warning = Some("CONFIG_PARSE_WARNING".into());
    a.notice = "REQUEST_FAILED_MARKER".into();
    assert!(text(&a, 80, 24).contains("REQUEST_FAILED_MARKER"));
    a.drawer = Some(Drawer::Help);
    let out = text(&a, 80, 24);
    assert!(out.contains("REQUEST_FAILED_MARKER"));
    assert!(out.contains("CONFIG_PARSE_WARNING"));
    assert!(out.contains("/recover"));
    a.drawer = None;
    a.snapshot["messages"] = json!([]);
    let out = text(&a, 80, 24);
    assert!(out.contains("CONFIG_PARSE_WARNING"));
    assert!(out.contains("REQUEST_FAILED_MARKER"));
    a.snapshot_stale = true;
    assert!(text(&a, 80, 24).contains("当前为旧快照"));
}

#[test]
fn invisible_fullscreen_pet_has_no_mouse_hit_rect_or_timer_visibility() {
    let mut a = app();
    a.snapshot["messages"] = json!([]);
    a.truecolor = true;
    assert!(ui::pet_rect(&a, 80, 24).is_some());
    a.view = View::Agents;
    assert!(ui::pet_rect(&a, 80, 24).is_none());
    assert!(!ui::pet_visible(&a, 80, 24));
}

#[test]
fn ambiguous_chrome_fallback_never_rewrites_original_content() {
    let mut a = app();
    a.ambiguous_width = 2;
    a.expanded = true;
    a.snapshot["messages"] = json!([{"id":"m","role":"assistant","text":"file·name.txt a−b\n```text\nfile·name.txt a−b … │\n```"}]);
    a.snapshot["steps"] =
        json!([{"id":"s","message_id":"m","verb":"读取","object":"file·name.txt","status":"done"}]);
    a.input = "file·name.txt a−b".into();
    a.cursor = a.input.len();
    let (buffer, _) = render(&a, 80, 24);
    let out = ui::buffer_text(&buffer);
    assert!(out.contains("file·name.txt a−b"), "{out}");
    assert!(
        out.contains("a−b … │"),
        "code contents were rewritten: {out}"
    );
    assert!(
        out.contains("读取  file·name.txt"),
        "file path was rewritten: {out}"
    );
    assert!(out.contains("+---"));
    assert!(!out.contains('╭'));
}
fn frame_buffer(a: &App, w: u16, h: u16) -> Buffer {
    let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
    let mut captured = None;
    t.draw(|f| {
        ui::draw(f, a);
        captured = Some(f.buffer_mut().clone());
    })
    .unwrap();
    captured.unwrap()
}
#[test]
fn ambiguous_paragraph_reserves_physical_columns_without_changing_symbols() {
    use ratatui::buffer::CellDiffOption;
    use unicode_width::UnicodeWidthChar;
    for c in ['α', '·', '│', '中', 'a', '−', '…'] {
        assert_eq!(
            c.width_cjk().unwrap_or(0),
            ui::width(&c.to_string(), 2),
            "char/string CJK widths disagree: {c}"
        );
    }
    assert_eq!(ui::width("α", 2), 1);
    assert_eq!(ui::width("·", 2), 2);
    let mut a = app();
    a.ambiguous_width = 2;
    a.snapshot["steps"] = json!([]);
    a.snapshot["messages"] = json!([{"id":"m","role":"assistant","text":"αb·c\n中α文·b"}]);
    let b = frame_buffer(&a, 80, 24);
    println!("alpha width {}", ui::width("α", 2));
    for x in 0..12 {
        println!("{} {:?}", x, b[(x, 0)]);
    }
    for (x, symbol) in [(2, "α"), (3, "b"), (4, "·"), (6, "c")] {
        assert_eq!(b[(x, 0)].symbol(), symbol);
    }
    assert_eq!(b[(5, 0)].diff_option, CellDiffOption::Skip);
    for (x, symbol) in [(2, "中"), (4, "α"), (5, "文"), (7, "·"), (9, "b")] {
        assert_eq!(b[(x, 1)].symbol(), symbol);
    }
    for x in [3, 6, 8] {
        assert_eq!(b[(x, 1)].diff_option, CellDiffOption::Skip);
    }
    assert!(ui::buffer_text(&b).contains("αb·c"));
    assert!(ui::buffer_text(&b).contains("中α文·b"));
}
#[test]
fn ambiguous_input_preserves_fixed_borders_and_true_cursor_column() {
    let mut a = app();
    a.ambiguous_width = 2;
    a.input = "αb·c".into();
    a.cursor = a.input.len();
    let (b, c) = render(&a, 80, 24);
    assert_eq!(b[(0, 21)].symbol(), "|");
    assert_eq!(b[(79, 21)].symbol(), "|");
    for (x, symbol) in [(4, "α"), (5, "b"), (6, "·"), (8, "c")] {
        assert_eq!(b[(x, 21)].symbol(), symbol);
    }
    assert_eq!(c, (9, 21));
}
#[test]
fn ambiguous_diff_expands_only_inside_its_own_column() {
    let mut a = changes();
    a.ambiguous_width = 2;
    a.selected = 0;
    a.snapshot["changes"] =
        json!([{"id":"c","kind":"M","path":"αfile·.rs","added":1,"removed":0,"diff":["+ αb·c"]}]);
    let b = frame_buffer(&a, 120, 24);
    for y in 2..23 {
        assert_eq!(b[(28, y)].symbol(), "|", "separator y={y}");
    }
    assert_eq!(b[(30, 2)].symbol(), "α");
    assert_eq!(b[(31, 2)].symbol(), "f");
    for (x, symbol) in [(32, "α"), (33, "b"), (34, "·"), (36, "c")] {
        assert_eq!(b[(x, 3)].symbol(), symbol);
    }
    let links = ui::file_links_from_buffer(&a, &b);
    let link = links
        .iter()
        .find(|l| l.area.x == 30 && l.area.y == 2)
        .unwrap();
    assert_eq!(link.path, "αfile·.rs");
    assert_eq!(usize::from(link.area.width), ui::width("αfile·.rs", 2));
}
