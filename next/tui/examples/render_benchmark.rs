use expert_tui::{app::App, ui};
use ratatui::{Terminal, backend::TestBackend};
use serde_json::json;
use std::time::Instant;

fn main() {
    let mut app = App::default();
    app.apply_snapshot(json!({"session":{"id":"benchmark","status":"running"},
      "steps":(0..10000).map(|i|json!({"id":format!("s{i}"),"message_id":format!("m{}",i/10),
        "status":"done","verb":"读取","object":format!("file-{i}"),"elapsed_ms":10})).collect::<Vec<_>>(),
      "messages":(0..1000).map(|i|json!({"id":format!("m{i}"),"role":if i%2==0{"user"}else{"assistant"},
        "text":format!("消息 {i}\n{}", "稳定正文与代码 `value`\n".repeat(20))})).collect::<Vec<_>>() }));
    let mut terminal = Terminal::new(TestBackend::new(100, 32)).unwrap();
    let mut samples = vec![];
    for i in 0..64 {
        app.snapshot["messages"][999]["text"] = json!(format!("流式尾部 {i}"));
        let start = Instant::now();
        terminal.draw(|frame| ui::draw(frame, &app)).unwrap();
        if i >= 4 {
            samples.push(start.elapsed().as_secs_f64() * 1000.0);
        }
    }
    samples.sort_by(f64::total_cmp);
    println!(
        "{}",
        json!({"messages":1000,"steps":10000,"lines_per_message":20,"width":100,"height":32,
      "samples":samples.len(),"median_ms":samples[samples.len()/2],"p95_ms":samples[samples.len()*95/100]})
    );
}
