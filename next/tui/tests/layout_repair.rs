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
fn input_content_rows(buffer: &Buffer) -> Vec<u16> {
    let right = buffer.area.right() - 1;
    (buffer.area.y..buffer.area.bottom())
        .filter(|&y| {
            let left = buffer[(0, y)].symbol();
            (left == "│" || left == "|") && buffer[(right, y)].symbol() == left
        })
        .collect()
}
#[test]
fn soft_wrapped_input_cursor_tracks_visual_row() {
    let mut a = app();
    a.input = "A".repeat(80);
    a.cursor = 80;
    let (b, c) = render(&a, 80, 24);
    assert_eq!(ui::input_visual_position(&a, 80), (1, 5));
    assert_eq!(c, (9, *input_content_rows(&b).last().unwrap()));
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
    assert_eq!(c, (4, input_content_rows(&b)[0]));
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
    assert!(text(&a, 80, 24).contains(&format!("[文本 · 7 行 · {} 字]", a.input.chars().count())));
    assert_eq!(a.input, "a\nb\nc\nd\ne\nf\nTAIL");
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
        let unwrapped: String = out.chars().filter(|c| !c.is_whitespace()).collect();
        assert!(unwrapped.contains("TAIL_DIFF_MARKER"), "{w}: {out}");
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
        // Effort is edited through /effort; the model drawer only points there.
        for expected in ["MODEL_2", "思考", "/effort"] {
            assert!(out.contains(expected), "{h}: {expected}\n{out}");
        }
    }
}

#[test]
fn every_selected_model_survives_grouping_and_resize() {
    let mut a = app();
    a.open(Drawer::Model);
    a.snapshot["models"] = json!(
        (0..24)
            .map(|i| json!({
                "id":format!("TARGET_{i:02}"), "choice":format!("c{i}"),
                "source":format!("source{}", i / 3), "efforts":["low","high"]
            }))
            .collect::<Vec<_>>()
    );
    for width in [40, 60, 80, 120] {
        for height in [14, 16, 24, 40] {
            for selected in 0..24 {
                a.selected = selected;
                let output = text(&a, width, height);
                assert!(
                    output.contains(&format!("TARGET_{selected:02}")),
                    "{width}x{height} selected {selected}\n{output}"
                );
            }
        }
    }
}

#[test]
fn modal_errors_and_stale_state_stay_outside_all_popups() {
    for drawer in [
        Drawer::Model,
        Drawer::Permissions,
        Drawer::Help,
        Drawer::Sessions,
        Drawer::Workspace,
    ] {
        for (width, height) in [(40, 16), (60, 24), (80, 14), (80, 24), (120, 40)] {
            let mut a = app();
            a.open(drawer);
            a.notice = "ASYNC_ERROR".into();
            let rect = ui::popup_rect(&a, width, height).unwrap();
            assert!(rect.bottom() <= height - 2);
            assert!(text(&a, width, height).contains("ASYNC_ERROR"));
            a.snapshot_stale = true;
            assert!(text(&a, width, height).contains("当前为旧快照"));
            a.open_settings();
            assert!(text(&a, width, height).contains("当前为旧快照"));
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
    let rendered = ui::buffer_text(&b);
    let line = rendered.lines().find(|l| l.contains("运行检查")).unwrap();
    let row = rendered
        .lines()
        .position(|l| l.contains("运行检查"))
        .unwrap() as u16;
    let spinner = ui::width(&line[..line.find('◌').unwrap()], a.ambiguous_width) as u16;
    assert_eq!(b[(spinner, row)].fg, Color::Cyan);
    assert_eq!(b[(spinner + 2, row)].fg, Color::Reset);
    a.snapshot["session"]["status"] = json!("waiting_acceptance");
    a.snapshot["changes"] = json!([{"kind":"M","path":"semantic.rs","added":8,"removed":3}]);
    let (b, _) = render(&a, 80, 24);
    let rendered = ui::buffer_text(&b);
    let line = rendered
        .lines()
        .find(|l| l.contains("semantic.rs"))
        .unwrap();
    let row = rendered
        .lines()
        .position(|l| l.contains("semantic.rs"))
        .unwrap() as u16;
    // Buffer coordinates are display columns, not UTF-8 byte offsets.
    let plus = ui::width(&line[..line.find("+8").unwrap()], a.ambiguous_width) as u16;
    let minus = ui::width(&line[..line.find("-3").unwrap()], a.ambiguous_width) as u16;
    assert_eq!(b[(plus, row)].fg, Color::Green);
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
        Some(ratatui::layout::Rect::new(79, 0, 9, 6))
    );
    a.no_color = true;
    assert_eq!(ui::pet_rect(&a, 140, 36), None);
}

#[test]
fn welcome_art_never_paints_into_expanded_composer_or_completion_menu() {
    for height in [20, 24, 30, 36] {
        for input in ["/", "first line\nsecond line\nthird line\nfourth line"] {
            for action in [0, 1, 3] {
                let mut a = app();
                a.snapshot["messages"] = json!([]);
                a.truecolor = true;
                a.input = input.into();
                a.cursor = a.input.len();
                a.viewport = (120, height);
                a.pet.action = action;
                a.pet.started = Some(std::time::Instant::now());
                let (with_pet, _) = render(&a, 120, height);
                let input_top = input_content_rows(&with_pet)[0] - 1;
                if let Some(rect) = ui::pet_rect(&a, 120, height) {
                    assert!(
                        rect.bottom() <= input_top,
                        "pet {:?} crossed composer row {input_top}",
                        rect
                    );
                }
                a.pet.enabled = false;
                let (without_pet, _) = render(&a, 120, height);
                for y in input_top..height {
                    for x in 0..120 {
                        assert_eq!(
                            with_pet[(x, y)],
                            without_pet[(x, y)],
                            "art changed composer/menu at {x},{y}; height={height}"
                        );
                    }
                }
            }
        }
    }
}
#[test]
fn long_table_cells_and_many_columns_retain_all_data() {
    let mut a = app();
    a.snapshot["steps"] = json!([]);
    a.snapshot["messages"] = json!([{"id":"m","role":"assistant","text":format!("| Key | Value |\n| --- | --- |\n| K | {} TABLE_END_MARKER |","A".repeat(120))}]);
    let rendered = text(&a, 80, 24);
    let cell_content: String = rendered
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    assert!(cell_content.contains("TABLE_END_MARKER"));
    a.snapshot["messages"][0]["text"] = json!(
        "| A | B | C | D | E | F | G | H | I | J | K | L |\n| - | - | - | - | - | - | - | - | - | - | - | - |\n| a | b | c | d | e | f | g | h | i | j | k | LAST_COLUMN_MARKER |"
    );
    assert!(text(&a, 40, 24).contains("LAST_COLUMN_MARKER"));
}

#[test]
fn markdown_tables_wrap_cells_and_accept_optional_edge_pipes() {
    for edge in [false, true] {
        let mut a = app();
        let rows = [
            "项目 | 描述".to_owned(),
            ":--- | ---:".to_owned(),
            format!("文件 | {}结束", "一段很长的说明".repeat(15)),
        ];
        let markdown = rows
            .iter()
            .map(|s| if edge { format!("| {s} |") } else { s.clone() })
            .collect::<Vec<_>>()
            .join("\n");
        a.snapshot["messages"] = json!([{"id":"m","role":"assistant","text":markdown}]);
        a.snapshot["steps"] = json!([]);
        let output = text(&a, 80, 60);
        let rendered: Vec<_> = output.lines().collect();
        assert!(rendered.iter().any(|s| s.contains('┬')));
        assert!(rendered.iter().any(|s| s.contains("结束")));
        assert!(!rendered.iter().any(|s| s.contains("描述:")));
        assert!(
            rendered
                .iter()
                .all(|s| ui::width(s, a.ambiguous_width) <= 80)
        );
    }
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
    assert_eq!(c, (4, *input_content_rows(&b).last().unwrap()));
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
    assert!(out.contains("已完成 10 次工具调用"));
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
    let input_row = input_content_rows(&b)[0];
    assert_eq!(b[(0, input_row)].symbol(), "|");
    assert_eq!(b[(79, input_row)].symbol(), "|");
    for (x, symbol) in [(4, "α"), (5, "b"), (6, "·"), (8, "c")] {
        assert_eq!(b[(x, input_row)].symbol(), symbol);
    }
    assert_eq!(c, (9, input_row));
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
    let plus = (0..120).find(|&x| b[(x, 3)].symbol() == "+").unwrap();
    // The gutter ends in "+ "; the source itself starts with a space.
    assert_eq!(b[(plus + 2, 3)].symbol(), " ");
    let start = plus + 3;
    for (offset, symbol) in [(0, "α"), (1, "b"), (2, "·"), (4, "c")] {
        assert_eq!(b[(start + offset, 3)].symbol(), symbol);
    }
    let links = ui::file_links_from_buffer(&a, &b);
    let link = links
        .iter()
        .find(|l| l.area.x == 30 && l.area.y == 2)
        .unwrap();
    assert_eq!(link.path, "αfile·.rs");
    assert_eq!(usize::from(link.area.width), ui::width("αfile·.rs", 2));
}
