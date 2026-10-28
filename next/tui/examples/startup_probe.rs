//! Read-only timing of an existing Host connection and its first snapshot.
use expert_tui::{
    launcher::LauncherOptions,
    source::{BridgeSource, DataSource, SourceEvent},
};
use std::time::{Duration, Instant};

fn main() -> anyhow::Result<()> {
    let start = Instant::now();
    let mut source = BridgeSource::launch(LauncherOptions {
        auto_start: false,
        ..Default::default()
    });
    loop {
        for event in source.poll() {
            match event {
                SourceEvent::Snapshot(_) => {
                    println!("{}", start.elapsed().as_millis());
                    return Ok(());
                }
                SourceEvent::Error(error) => anyhow::bail!(error),
                _ => {}
            }
        }
        anyhow::ensure!(start.elapsed() < Duration::from_secs(15), "Host timed out");
        std::thread::sleep(Duration::from_millis(5));
    }
}
