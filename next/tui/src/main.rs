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
    path::{Path, PathBuf},
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
    let (config, config_warning) = expert_tui::config::load_with_warning();
    let terminal_light = expert_tui::theme::light(args.theme.as_deref());
    let mut app = App {
        ascii: args.ascii,
        config_warning,
        skin: config.skin.clone(),
        background: config.background.clone(),
        accent: config.accent.clone(),
        code_style: config.code_style.clone(),
        no_color: std::env::var_os("NO_COLOR").is_some(),
        truecolor: std::env::var_os("WT_SESSION").is_some()
            || matches!(
                std::env::var("COLORTERM").as_deref(),
                Ok("truecolor" | "24bit")
            ),
        color256: std::env::var_os("WT_SESSION").is_some()
            || std::env::var("TERM").is_ok_and(|term| term.contains("256color")),
        light: expert_tui::theme::appearance_is_light(
            &config.skin,
            config.background.as_deref(),
            terminal_light,
        ),
        terminal_light: args.theme.as_ref().map(|_| terminal_light),
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
    let (workspace, initial) = resolve_target(args.target.as_deref(), &std::env::current_dir()?)?;
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
    let hyperlinks = expert_tui::links::LinkState::default();
    let backend = expert_tui::links::HyperlinkBackend::new(io::stdout(), hyperlinks.clone());
    let mut term = ratatui::Terminal::new(backend)?;
    let mut last_title = String::new();
    let mut width = 80;
    let (clipboard_tx, clipboard_rx) = std::sync::mpsc::channel();
    let mut clipboard_pending = false;
    let mut clipboard_images: Vec<(Command, tempfile::TempPath)> = vec![];
    let mut dirty = true;
    let mut last_size = term.size()?;
    let mut last_animation = Instant::now();
    let mut last_pet = (String::new(), String::new());
    while !app.exit {
        for command in std::mem::take(&mut app.outbox) {
            send(&mut *source, &mut app, command);
        }
        if app.clipboard_requested || app.file_picker_requested {
            let picker = app.file_picker_requested;
            app.file_picker_requested = false;
            app.clipboard_requested = false;
            if !clipboard_pending {
                clipboard_pending = true;
                app.notice = if picker {
                    "选择附件…"
                } else {
                    "读取剪贴板…"
                }
                .into();
                dirty = true;
                let tx = clipboard_tx.clone();
                let session = app.session_id().map(str::to_owned);
                let agent = app.agent_message_id.clone();
                let form = app
                    .form
                    .as_ref()
                    .map(|f| (f.kind, f.selected, app.form_revision));
                std::thread::spawn(move || {
                    let _ = tx.send((
                        session,
                        agent,
                        form,
                        picker,
                        if picker {
                            expert_tui::clipboard::select_files()
                        } else {
                            expert_tui::clipboard::read()
                        }
                        .map_err(|e| e.to_string()),
                    ));
                });
            }
        }
        if let Ok((session, agent, form, picker, result)) = clipboard_rx.try_recv() {
            dirty = true;
            clipboard_pending = false;
            match result {
                Ok(expert_tui::clipboard::ClipboardData::ImageFile(path)) => {
                    if form.is_none() {
                        match expert_tui::attachment::import_params(path.as_ref()) {
                            Ok(mut params) => {
                                if let Some(id) = &session {
                                    params["session_id"] = json!(id);
                                }
                                let command = Command {
                                    method: "attachment.import".into(),
                                    params,
                                };
                                app.attachment_targets
                                    .push((command.clone(), agent.clone()));
                                match source.send(command.clone()) {
                                    Ok(()) => {
                                        clipboard_images.push((command, path));
                                        app.notice = "正在导入剪贴板图片…".into();
                                    }
                                    Err(error) => app.command_error(&command, &error.to_string()),
                                }
                            }
                            Err(error) => app.notice = format!("无法导入剪贴板图片：{error}"),
                        }
                    } else {
                        app.notice = "当前表单字段仅支持文本，图片请使用 /attach".into();
                    }
                }
                Ok(expert_tui::clipboard::ClipboardData::Files(paths)) => {
                    if paths.is_empty() && picker {
                        app.notice = "已取消附件选择".into();
                    }
                    if form.is_some() && !picker {
                        app.notice = "当前表单字段仅支持文本，文件请使用 /attach".into();
                        continue;
                    }
                    for path in paths {
                        match expert_tui::attachment::import_params(&path) {
                            Ok(mut params) => {
                                if let Some(id) = &session {
                                    params["session_id"] = json!(id);
                                }
                                let command = Command {
                                    method: "attachment.import".into(),
                                    params,
                                };
                                app.attachment_targets
                                    .push((command.clone(), agent.clone()));
                                send(&mut *source, &mut app, command);
                            }
                            Err(error) => app.notice = error.to_string(),
                        }
                    }
                }
                Ok(expert_tui::clipboard::ClipboardData::Text(text)) => {
                    if session.as_deref() == app.session_id()
                        && form
                            == app
                                .form
                                .as_ref()
                                .map(|f| (f.kind, f.selected, app.form_revision))
                    {
                        app.paste(&text);
                    } else {
                        app.notice = "输入焦点已改变，未将剪贴板文字写入其他字段".into();
                    }
                }
                Err(error) => app.notice = error,
            }
        }
        let events = source.poll();
        if !events.is_empty() {
            dirty = true;
        }
        for event in events {
            let event = match event {
                SourceEvent::CommandResponse { command, result } => {
                    clipboard_images.retain(|(pending, _)| pending != &command);
                    app.command_response(&command, &result);
                    if !command.params["session_id"].is_null()
                        && command.params["session_id"] != app.snapshot["session"]["id"]
                        && !matches!(command.method.as_str(), "session.open" | "snapshot.get")
                    {
                        continue;
                    }
                    SourceEvent::Response {
                        method: command.method,
                        result,
                    }
                }
                SourceEvent::CommandError { command, message } => {
                    clipboard_images.retain(|(pending, _)| pending != &command);
                    app.command_error(&command, &message);
                    continue;
                }
                SourceEvent::SnapshotError(message) => {
                    app.set_snapshot_error(&message);
                    continue;
                }
                event => event,
            };
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
                    "queue.remove" | "message.send" | "queue.add" | "agent.message"
                    | "question.answer" => {}
                    "bridge.stop" => app.exit = true,
                    "models.list" => app.snapshot["models"] = result["models"].clone(),
                    "session.list" => app.snapshot["sessions"] = result["sessions"].clone(),
                    "workspace.list" => app.snapshot["workspaces"] = result["workspaces"].clone(),
                    "session.open" | "snapshot.get" if result.get("messages").is_some() => {
                        app.apply_snapshot(result);
                    }
                    _ => {}
                },
                SourceEvent::CommandResponse { .. }
                | SourceEvent::CommandError { .. }
                | SourceEvent::SnapshotError(_) => unreachable!("source events normalized above"),
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
        app.viewport = (size.width, size.height);
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
        if app.redraw_requested {
            term.clear()?;
            app.redraw_requested = false;
            dirty = true;
        }
        if dirty {
            term.draw(|f| {
                ui::draw(f, &app);
                let paths = ui::file_links_from_buffer(&app, f.buffer_mut());
                hyperlinks.prepare(&app, f.buffer_mut(), paths);
            })?;
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
                    app.paste(&s);
                }
                Event::Mouse(mouse) => match mouse.kind {
                    MouseEventKind::ScrollUp => app.scroll_by(-3),
                    MouseEventKind::ScrollDown => app.scroll_by(3),
                    MouseEventKind::Down(event::MouseButton::Left) => {
                        if ui::pet_rect(&app, size.width, size.height).is_some_and(|rect| {
                            rect.contains(ratatui::layout::Position::new(mouse.column, mouse.row))
                        }) {
                            app.pet.click(Instant::now(), app.reduce_motion);
                        } else if let Some(index) =
                            ui::recent_session_rects(&app, size.width, size.height)
                                .iter()
                                .position(|(rect, _)| {
                                    rect.contains(ratatui::layout::Position::new(
                                        mouse.column,
                                        mouse.row,
                                    ))
                                })
                        {
                            for command in app.click_recent(index) {
                                expected_session =
                                    command.params["session_id"].as_str().map(str::to_owned);
                                prepared = true;
                                send(&mut *source, &mut app, command);
                            }
                        } else if ui::footer_at(&app, size.width, size.height).is_some_and(|rect| {
                            rect.contains(ratatui::layout::Position::new(mouse.column, mouse.row))
                        }) {
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
    if let Err(e) = source.send(c.clone()) {
        app.command_error(&c, &e.to_string());
    }
}

fn resolve_target(target: Option<&str>, cwd: &Path) -> Result<(PathBuf, Option<String>)> {
    anyhow::ensure!(cwd.is_absolute(), "当前工作目录必须是绝对路径");
    let Some(target) = target else {
        return Ok((cwd.to_owned(), None));
    };
    let path = Path::new(target);
    let resolved = if path.is_absolute() {
        path.to_owned()
    } else {
        cwd.join(path)
    };
    if resolved.is_dir() {
        return Ok((resolved, None));
    }
    let bytes = target.as_bytes();
    let drive = bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':';
    let explicit = path.is_absolute()
        || drive
        || target == "."
        || target == ".."
        || ["./", "../", ".\\", "..\\", "\\\\"]
            .iter()
            .any(|p| target.starts_with(p))
        || (!target.chars().any(char::is_whitespace) && target.contains('\\'));
    anyhow::ensure!(
        !explicit && !resolved.exists(),
        "工作区目录不存在或不是目录：{target}"
    );
    Ok((cwd.to_owned(), Some(target.to_owned())))
}

#[cfg(test)]
mod cli_tests {
    use super::resolve_target;
    #[test]
    fn existing_relative_workspaces_are_absolute() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::create_dir(temp.path().join("subdir")).unwrap();
        for name in [".", "subdir"] {
            let (workspace, task) = resolve_target(Some(name), temp.path()).unwrap();
            assert!(workspace.is_absolute());
            assert!(workspace.is_dir());
            assert!(task.is_none());
        }
        let absolute = temp.path().join("subdir");
        assert_eq!(
            resolve_target(absolute.to_str(), temp.path()).unwrap().0,
            absolute
        );
    }
    #[test]
    fn colon_prose_remains_an_initial_task() {
        let temp = tempfile::tempdir().unwrap();
        let task = "fix: preserve SVG aspect ratio";
        assert_eq!(
            resolve_target(Some(task), temp.path()).unwrap(),
            (temp.path().to_owned(), Some(task.into()))
        );
        assert_eq!(
            resolve_target(None, temp.path()).unwrap(),
            (temp.path().to_owned(), None)
        );
    }
    #[test]
    fn explicit_missing_paths_and_files_are_rejected_before_launch() {
        let temp = tempfile::tempdir().unwrap();
        for target in [
            "./missing",
            "../missing",
            ".\\missing",
            "C:\\missing",
            "\\\\server\\missing",
        ] {
            assert!(
                resolve_target(Some(target), temp.path()).is_err(),
                "{target}"
            );
        }
        std::fs::write(temp.path().join("file.txt"), "file").unwrap();
        assert!(resolve_target(Some("file.txt"), temp.path()).is_err());
    }
}
