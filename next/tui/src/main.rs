use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use crossterm::{
    event::{
        self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
        Event, KeyCode, KeyEventKind, MouseEventKind,
    },
    execute,
    terminal::{self, EnterAlternateScreen, LeaveAlternateScreen, SetTitle},
};
use expert_tui::{
    app::{App, Command, items, text},
    launcher::LauncherOptions,
    source::{BridgeSource, DataSource, DemoSource, SourceEvent},
    ui,
};
use serde_json::json;
use std::{
    io::{self, IsTerminal, Write},
    path::PathBuf,
    time::{Duration, Instant},
};
#[derive(Parser)]
#[command(
    name = "expert",
    version,
    about = "Expert terminal client · shared desktop tasks"
)]
struct Args {
    #[arg(long)]
    demo: Option<String>,
    #[arg(long)]
    snapshot: Option<String>,
    #[arg(long, default_value_t = 80)]
    width: u16,
    #[arg(long, default_value_t = 24)]
    height: u16,
    #[arg(long)]
    ascii: bool,
    #[arg(long)]
    gui: Option<PathBuf>,
    #[arg(long)]
    no_auto_start: bool,
    #[arg(long,value_parser=["dark","light"])]
    theme: Option<String>,
    #[arg(long,value_parser=clap::value_parser!(u8).range(1..=2))]
    ambiguous_width: Option<u8>,
    #[command(subcommand)]
    command: Option<StartCommand>,
    /// Workspace directory, or an initial task (quote tasks containing spaces)
    target: Option<String>,
}
#[derive(Subcommand)]
enum StartCommand {
    Resume { id: String },
}
struct Restore;
impl Drop for Restore {
    fn drop(&mut self) {
        let _ = execute!(
            io::stdout(),
            DisableMouseCapture,
            DisableBracketedPaste,
            LeaveAlternateScreen
        );
        let _ = terminal::disable_raw_mode();
    }
}
fn main() {
    if let Err(e) = run() {
        eprintln!("expert: {e:#}");
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let args = Args::parse();
    let config = expert_tui::config::load();
    let mut app = App {
        ascii: args.ascii,
        no_color: std::env::var_os("NO_COLOR").is_some(),
        truecolor: matches!(
            std::env::var("COLORTERM").as_deref(),
            Ok("truecolor" | "24bit")
        ),
        light: expert_tui::theme::light(args.theme.as_deref()),
        reduce_motion: std::env::var_os("EXPERT_REDUCE_MOTION").is_some()
            || std::env::var("TERM").as_deref() == Ok("dumb")
            || !io::stdout().is_terminal(),
        ambiguous_width: args
            .ambiguous_width
            .unwrap_or(config.ambiguous_width)
            .clamp(1, 2),
        ..Default::default()
    };
    app.pet.enabled = config.pet != "none";
    if let Some(scene) = &args.snapshot {
        for event in expert_tui::source::fixture_events(scene)? {
            app.apply_event(&event)?;
        }
        app.reduce_motion = true;
        let backend = ratatui::backend::TestBackend::new(args.width, args.height);
        let mut term = ratatui::Terminal::new(backend)?;
        term.draw(|f| ui::draw(f, &app))?;
        print!("{}", ui::buffer_text(term.backend().buffer()));
        return Ok(());
    }
    anyhow::ensure!(
        io::stdin().is_terminal() && io::stdout().is_terminal(),
        "Interactive TUI needs a terminal. Use --snapshot <scene> for text output."
    );
    let demo = args.demo.is_some();
    let mut source: Box<dyn DataSource> = if let Some(name) = args.demo.as_deref() {
        Box::new(DemoSource::new(name)?)
    } else {
        eprintln!("Connecting to Expert desktop…");
        Box::new(BridgeSource::launch(LauncherOptions {
            gui: args.gui,
            auto_start: !args.no_auto_start,
        }))
    };
    let target = args.target.as_deref();
    if let Some(target) = target
        && (target.contains(':')
            || target.starts_with('.')
            || target.starts_with('/')
            || target.contains('\\'))
        && !std::path::Path::new(target).is_dir()
    {
        anyhow::bail!("工作区目录不存在：{target}");
    }
    let workspace = target
        .filter(|s| std::path::Path::new(s).is_dir())
        .map(PathBuf::from)
        .unwrap_or(std::env::current_dir()?);
    let initial = target
        .filter(|s| !std::path::Path::new(s).is_dir())
        .map(str::to_owned);
    let mut boot = !demo;
    let resume = args.command.map(|StartCommand::Resume { id }| id);
    app.suppress_welcome = resume.is_some() || initial.is_some();
    let mut prepared = false;
    let mut bound = demo;
    let mut expected_session: Option<String> = None;
    let mut workspace_confirmation: Option<String> = None;
    let mut selected_access = false;
    let mut initial = initial;
    terminal::enable_raw_mode()?;
    let restore = Restore;
    execute!(
        io::stdout(),
        EnterAlternateScreen,
        EnableMouseCapture,
        EnableBracketedPaste
    )?;
    let backend = ratatui::backend::CrosstermBackend::new(io::stdout());
    let mut term = ratatui::Terminal::new(backend)?;
    let mut last_title = String::new();
    let mut width = 80;
    let (clipboard_tx, clipboard_rx) = std::sync::mpsc::channel();
    let mut clipboard_pending = false;
    let mut dirty = true;
    let mut last_size = term.size()?;
    let mut last_animation = Instant::now();
    let mut last_pet = (String::new(), String::new());
    while !app.exit {
        if app.clipboard_requested {
            app.clipboard_requested = false;
            if !clipboard_pending {
                clipboard_pending = true;
                app.notice = "读取剪贴板图片…".into();
                dirty = true;
                let tx = clipboard_tx.clone();
                std::thread::spawn(move || {
                    let _ = tx.send(expert_tui::clipboard::read_image().map_err(|e| e.to_string()));
                });
            }
        }
        if let Ok(result) = clipboard_rx.try_recv() {
            dirty = true;
            clipboard_pending = false;
            match result {
                Ok(attachment) => {
                    app.attachments.push(attachment);
                    app.notice = "已添加剪贴板图片".into();
                }
                Err(error) => app.notice = error,
            }
        }
        let events = source.poll();
        if !events.is_empty() {
            dirty = true;
        }
        for event in events {
            match event {
                SourceEvent::Event(v) => {
                    if let Err(e) = app.apply_event(&v) {
                        app.notice = e.to_string();
                    }
                }
                SourceEvent::Snapshot(v) => app.apply_snapshot(v),
                SourceEvent::Connection { connected, message } => {
                    app.notice = if connected { String::new() } else { message };
                    if connected && boot {
                        if let Some(id) = &resume {
                            expected_session = Some(id.clone());
                            prepared = true;
                            send(
                                &mut *source,
                                &mut app,
                                Command {
                                    method: "session.open".into(),
                                    params: json!({"session_id":id}),
                                },
                            );
                            boot = false;
                        } else {
                            send(
                                &mut *source,
                                &mut app,
                                Command {
                                    method: "workspace.prepare".into(),
                                    params: json!({"path":workspace}),
                                },
                            );
                            boot = false;
                        }
                    }
                }
                SourceEvent::Error(e) => {
                    app.restore_draft();
                    app.notice = e;
                }
                SourceEvent::Response { method, result } => match method.as_str() {
                    "workspace.prepare" => {
                        if result["confirmation_required"] == true {
                            workspace_confirmation = Some(text(&result, "path").to_owned());
                            app.notice = format!(
                                "首次使用 {} · r 只读 / w 读写 · enter 确认 · esc 取消",
                                text(&result, "path")
                            );
                        } else {
                            let w = result.get("workspace").unwrap_or(&result);
                            send(
                                &mut *source,
                                &mut app,
                                Command {
                                    method: "session.new".into(),
                                    params: json!({"workspace_id":w["id"]}),
                                },
                            );
                            prepared = true;
                        }
                    }
                    "workspace.register" => {
                        let workspace = result.get("workspace").unwrap_or(&result);
                        send(
                            &mut *source,
                            &mut app,
                            Command {
                                method: "session.new".into(),
                                params: json!({"workspace_id":workspace["id"]}),
                            },
                        );
                        prepared = true;
                    }
                    "session.new" => {
                        expected_session = result["session_id"].as_str().map(str::to_owned);
                    }
                    "files.list" => {
                        app.files = items(&result, "files")
                            .iter()
                            .map(|f| text(f, "path").to_owned())
                            .collect()
                    }
                    "changes.diff" => {
                        if let Some(changes) = app.snapshot["changes"].as_array_mut()
                            && let Some(change) =
                                changes.iter_mut().find(|c| c["id"] == result["id"])
                        {
                            change["diff"] = result["diff"].clone();
                        }
                    }
                    "queue.remove" => {
                        app.input = text(&result, "text").into();
                        app.cursor = app.input.len();
                    }
                    "message.send" | "queue.add" | "agent.message" => {
                        app.pending_draft = None;
                        app.notice.clear();
                    }
                    "models.list" => app.snapshot["models"] = result["models"].clone(),
                    "session.list" => app.snapshot["sessions"] = result["sessions"].clone(),
                    "workspace.list" => app.snapshot["workspaces"] = result["workspaces"].clone(),
                    "session.open" | "snapshot.get" if result.get("messages").is_some() => {
                        app.apply_snapshot(result);
                    }
                    _ => {}
                },
            }
        }
        if prepared
            && expected_session
                .as_deref()
                .is_some_and(|id| app.session_id() == Some(id))
        {
            bound = true;
            if let Some(task) = initial.take() {
                app.input = task;
                app.cursor = app.input.len();
                let commands = app.key(
                    crossterm::event::KeyEvent::new(KeyCode::Enter, event::KeyModifiers::NONE),
                    Instant::now(),
                    width,
                );
                for c in commands {
                    send(&mut *source, &mut app, c);
                }
            }
            prepared = false;
        }
        let title = format!(
            "expert · {}",
            ui::clean(text(&app.snapshot["session"], "title"))
        );
        if title != last_title {
            execute!(io::stdout(), SetTitle(&title))?;
            last_title = title;
        }
        let size = term.size()?;
        if size != last_size {
            last_size = size;
            dirty = true;
        }
        width = size.width;
        app.pet.visible = ui::pet_visible(&app, size.width, size.height);
        app.pet.tick(Instant::now(), app.reduce_motion);
        if app.active()
            && !app.reduce_motion
            && last_animation.elapsed() >= Duration::from_millis(80)
        {
            app.tick = app.tick.wrapping_add(1);
            last_animation = Instant::now();
            dirty = true;
        }
        if app.pet.visible {
            let now = Instant::now();
            let visual = (app.pet.frame(now).to_owned(), app.pet.quote(now).to_owned());
            if visual != last_pet {
                last_pet = visual;
                dirty = true;
            }
        }
        if app
            .esc_at
            .is_some_and(|t| t.elapsed() >= Duration::from_millis(1500))
        {
            app.esc_at = None;
            dirty = true;
        }
        if dirty {
            term.draw(|f| ui::draw(f, &app))?;
            dirty = false;
        }
        if event::poll(Duration::from_millis(if app.pet.visible {
            50
        } else if app.active() && !app.reduce_motion {
            80
        } else {
            100
        }))? {
            dirty = true;
            match event::read()? {
                Event::Key(key) if key.kind != KeyEventKind::Release => {
                    if let Some(path) = workspace_confirmation.clone() {
                        match key.code {
                            KeyCode::Char('r') => {
                                selected_access = false;
                                app.notice = format!("{path} · 只读 · enter 确认");
                            }
                            KeyCode::Char('w') => {
                                selected_access = true;
                                app.notice = format!("{path} · 读写 · enter 确认");
                            }
                            KeyCode::Enter => {
                                send(
                                    &mut *source,
                                    &mut app,
                                    Command {
                                        method: "workspace.register".into(),
                                        params: json!({"path":path,"access":if selected_access{"read-write"}else{"read-only"},"confirmed":true}),
                                    },
                                );
                                workspace_confirmation = None;
                            }
                            KeyCode::Esc => {
                                workspace_confirmation = None;
                                app.notice = "已取消工作区登记 · /workspace 选择已有项目".into();
                            }
                            _ => {}
                        }
                    } else {
                        let commands = app.key(key, Instant::now(), width);
                        for c in commands {
                            if c.method == "session.open" {
                                expected_session =
                                    c.params["session_id"].as_str().map(str::to_owned);
                                prepared = true;
                                send(&mut *source, &mut app, c);
                            } else if !bound && c.method == "workspace.set" {
                                prepared = true;
                                send(
                                    &mut *source,
                                    &mut app,
                                    Command {
                                        method: "session.new".into(),
                                        params: json!({"workspace_id":c.params["workspace_id"]}),
                                    },
                                );
                            } else if !bound
                                && c.params.get("session_id").is_some()
                                && c.method != "gui.open"
                            {
                                app.restore_draft();
                                app.notice = "请先确认工作区或选择会话".into();
                            } else {
                                send(&mut *source, &mut app, c);
                            }
                        }
                    }
                }
                Event::Paste(s) => {
                    app.insert(&ui::clean(&s));
                }
                Event::Mouse(mouse) => match mouse.kind {
                    MouseEventKind::ScrollUp => app.scroll = app.scroll.saturating_add(3),
                    MouseEventKind::ScrollDown => app.scroll = app.scroll.saturating_sub(3),
                    MouseEventKind::Down(event::MouseButton::Left) => {
                        if ui::pet_visible(&app, size.width, size.height)
                            && mouse.column >= size.width.saturating_sub(22)
                            && mouse.column < size.width.saturating_sub(2)
                            && mouse.row < 6
                        {
                            app.pet.click(Instant::now(), app.reduce_motion);
                        } else if mouse.row == size.height.saturating_sub(1) {
                            app.open(ui::footer_hit(
                                &app,
                                size.width as usize,
                                mouse.column as usize,
                            ));
                        }
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    }
    drop(term);
    drop(restore);
    let s = &app.snapshot["session"];
    let changes = items(&app.snapshot, "changes");
    println!(
        "expert · {} · {} 个文件 +{} -{} · expert resume {}",
        ui::clean(text(s, "title")),
        changes.len(),
        changes
            .iter()
            .map(|v| v["added"].as_u64().unwrap_or(0))
            .sum::<u64>(),
        changes
            .iter()
            .map(|v| v["removed"].as_u64().unwrap_or(0))
            .sum::<u64>(),
        text(s, "id")
    );
    io::stdout().flush().context("flush terminal")?;
    Ok(())
}
fn send(source: &mut dyn DataSource, app: &mut App, c: Command) {
    if let Err(e) = source.send(c) {
        app.restore_draft();
        app.notice = e.to_string();
    }
}
