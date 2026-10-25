//! Reproducible rendering workload; excludes networking and terminal transport.
use expert_tui::{app::App, source::fixture_events, ui};
use ratatui::{Terminal, backend::TestBackend};
use serde_json::json;
use std::time::Instant;

fn main() {
    let mut app = App {
        reduce_motion: true,
        ..App::default()
    };
    for event in fixture_events("running").unwrap() {
        app.apply_event(&event).unwrap();
    }
    app.snapshot["messages"] = json!((0..10000).map(|i| json!({
        "id":format!("history-{i}"), "role":if i % 2 == 0 {"user"} else {"assistant"},
        "text":format!("历史记录 {i}：检查源码和任务状态。Inspect source and current task state.")
    })).collect::<Vec<_>>());
    let mut terminal = Terminal::new(TestBackend::new(120, 36)).unwrap();
    let mut samples = vec![];
    for _ in 0..20 {
        let start = Instant::now();
        terminal.draw(|frame| ui::draw(frame, &app)).unwrap();
        samples.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    samples.sort_by(f64::total_cmp);
    println!(
        "{}",
        json!({"messages":10000,"size":"120x36","samples":20,"median_ms":samples[10],"p95_ms":samples[18],"max_ms":samples[19]})
    );
}
