use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use crossterm::{
    cursor::SetCursorStyle,
    event::{
        self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
        Event, KeyCode, KeyEventKind, MouseEventKind,
    },
    execute,
    terminal::{
        self, BeginSynchronizedUpdate, EndSynchronizedUpdate, EnterAlternateScreen,
        LeaveAlternateScreen, SetTitle,
    },
};
use expert_tui::{
    app::{App, Command, StartupPhase, items, text},
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
    about = "Expert terminal client · independent shared task host"
)]
struct Args {
    /// Run a prompt without opening the TUI; omitted value reads stdin.
    #[arg(short='p',long="print",num_args=0..=1,default_missing_value="")]
    print: Option<String>,
    #[arg(long,default_value="text",value_parser=["text","json"])]
    output_format: String,
    #[arg(long)]
    workspace: Option<PathBuf>,
    #[arg(long,value_parser=["read-only","read-write"])]
    allow_workspace: Option<String>,
    #[arg(long)]
    model: Option<String>,
    #[arg(long, default_value_t = 3600)]
    timeout: u64,
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
            EndSynchronizedUpdate,
            SetCursorStyle::DefaultUserShape,
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
    if let Some(mut prompt) = args.print.clone() {
        if !io::stdin().is_terminal() {
            use std::io::Read;
            let mut incoming = String::new();
            io::stdin()
                .take(1024 * 1024 + 1)
                .read_to_string(&mut incoming)?;
            anyhow::ensure!(incoming.len() <= 1024 * 1024, "stdin 超过 1 MiB");
            if !prompt.is_empty() {
                prompt.push('\n');
            }
            prompt.push_str(&incoming);
        }
        anyhow::ensure!(
            !prompt.trim().is_empty(),
            "请使用 expert -p \"任务\" 或通过 stdin 输入任务"
        );
        let workspace = args.workspace.clone().unwrap_or(std::env::current_dir()?);
        return expert_tui::headless::run(
            &LauncherOptions {
                gui: args.gui,
                auto_start: !args.no_auto_start,
            },
            &prompt,
            &workspace,
            args.allow_workspace.as_deref(),
            args.model.as_deref(),
            &args.output_format,
            args.timeout,
        );
    }
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
        if scene == "connecting" || scene == "preparing" {
            app.startup_phase = Some(if scene == "connecting" {
                StartupPhase::Connecting
            } else {
                StartupPhase::Workspace
            });
        } else {
            for event in expert_tui::source::fixture_events(scene)? {
                app.apply_event(&event)?;
            }
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
    app.startup_phase = (!demo).then_some(StartupPhase::Connecting);
    app.binding_ready = demo;
    let mut source: Box<dyn DataSource> = if let Some(name) = args.demo.as_deref() {
        Box::new(DemoSource::new(name)?)
    } else {
        eprintln!("Connecting to Expert host…");
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
    // Folder whose trust registration is in flight; restored on failure.
    let mut registering: Option<String> = None;
    app.workspace_pending = !demo && resume.is_none();
    let mut initial = initial;
    terminal::enable_raw_mode()?;
    let restore = Restore;
    execute!(
        io::stdout(),
        EnterAlternateScreen,
        EnableMouseCapture,
        EnableBracketedPaste
    )?;
    execute!(io::stdout(), SetCursorStyle::SteadyBar)?;
    let hyperlinks = expert_tui::links::LinkState::default();
    let backend = expert_tui::links::HyperlinkBackend::new(io::stdout(), hyperlinks.clone());
    let mut term = ratatui::Terminal::new(backend)?;
    let mut last_title = String::new();
    let mut width = 80;
    let (clipboard_tx, clipboard_rx) = std::sync::mpsc::channel();
    let mut clipboard_pending = false;
    let mut clipboard_images: Vec<(Command, tempfile::TempPath)> = vec![];
    let mut unbound_images: Vec<tempfile::TempPath> = vec![];
    let (copy_tx, copy_rx) = std::sync::mpsc::channel();
    let mut last_frame: Option<ratatui::buffer::Buffer> = None;
    let mut attachment_click: Option<(String, Instant)> = None;
    let mut attachment_hover: Option<(u16, u16)> = None;
    let mut message_click: Option<(String, String, u16, u16)> = None;
    let mut approval_press: Option<(String, usize)> = None;
    let mut pinned_click: Option<(String, String, Instant)> = None;
    let mut tool_click: Option<(String, String, u16, u16)> = None;
    let mut diff_click: Option<(String, String, u16, u16)> = None;
    let mut diff_scroll_drag: Option<u16> = None;
    let mut dirty = true;
    let mut notice_seen = String::new();
    let mut notice_at = Instant::now();
    let mut last_size = term.size()?;
    let mut last_animation = Instant::now();
    let mut last_progress = Instant::now();
    let mut native_path_paste = expert_tui::attachment::NativePathPaste::default();
    let mut last_login_poll = Instant::now();
    let mut last_shell_poll = Instant::now();
    let mut last_pet = (String::new(), String::new());
    let mut editing: Option<(
        expert_tui::editor::Editor,
        Option<String>,
        expert_tui::app::Draft,
    )> = None;
    while !app.exit {
        if native_path_paste.ready()
            && !event::poll(Duration::ZERO)?
            && native_path_paste.finish(&mut app)
        {
            dirty = true;
        }
        if last_login_poll.elapsed() >= Duration::from_millis(500) && !app.login_poll_pending {
            if let Some(job) = app.login_job.clone() {
                app.login_poll_pending = true;
                let command = app.command("provider.login.status", json!({"job_id":job}));
                send(&mut *source, &mut app, command);
            }
            last_login_poll = Instant::now();
        }
        if last_shell_poll.elapsed() >= Duration::from_millis(400) {
            if let Some(command) = app.shell_poll_command() {
                send(&mut *source, &mut app, command);
            }
            for c in app.workbench_poll(){send(&mut *source,&mut app,c);}
            last_shell_poll = Instant::now();
        }
        if app.editor_requested {
            app.editor_requested = false;
            app.send_after_binding = false;
            let draft = app.current_draft();
            execute!(
                io::stdout(),
                DisableMouseCapture,
                DisableBracketedPaste,
                LeaveAlternateScreen
            )?;
            terminal::disable_raw_mode()?;
            match expert_tui::editor::Editor::start(&draft.text) {
                Ok(editor) => {
                    if let Some(path) = editor.path() {
                        eprintln!("草稿文件：{}", path.display());
                    }
                    if editor.needs_confirmation() {
                        eprintln!(
                            "在记事本中按 Ctrl+S 保存。保存后回到此终端按 Enter 取回草稿；回到 TUI 后再按 Enter 发送。"
                        );
                    } else {
                        eprintln!("在编辑器中保存并退出，内容将回到 TUI 草稿；不会自动发送。");
                    }
                    editing = Some((editor, app.session_id().map(str::to_owned), draft));
                }
                Err(error) => {
                    terminal::enable_raw_mode()?;
                    execute!(
                        io::stdout(),
                        EnterAlternateScreen,
                        EnableMouseCapture,
                        EnableBracketedPaste
                    )?;
                    term.clear()?;
                    app.notice = error.to_string();
                    dirty = true;
                }
            }
        }
        if app.cancel_attachments_requested {
            unbound_images.clear();
            app.cancel_attachments_requested = false;
        }
        if let Some(text) = app.copy_requested.take() {
            let tx = copy_tx.clone();
            let selection = app.selection.as_ref().map(|s| s.revision);
            std::thread::spawn(move || {
                let _ = tx.send((
                    selection,
                    expert_tui::clipboard::write_text(&text).map_err(|e| e.to_string()),
                ));
            });
        }
        if let Ok((revision, result)) = copy_rx.try_recv() {
            match result {
                Ok(()) => {
                    if app.selection.as_ref().map(|s| s.revision) == revision {
                        app.selection = None;
                    }
                    app.notice = "已复制到系统剪贴板".into();
                }
                Err(error) => app.notice = error,
            }
            dirty = true;
        }
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
                        if !app.binding_ready {
                            unbound_images.push(path);
                            app.notice = "会话就绪后导入剪贴板图片".into();
                            continue;
                        }
                        match expert_tui::attachment::import_params(path.as_ref()) {
                            Ok(mut params) => {
                                if let Some(id) = &session {
                                    params["session_id"] = json!(id);
                                }
                                let mut command = Command {
                                    method: "attachment.import".into(),
                                    params,
                                };
                                app.begin_attachment_import(&mut command, agent.clone());
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
                    if !app.binding_ready {
                        app.deferred_paths.extend(paths);
                        app.notice = "会话就绪后导入附件".into();
                        continue;
                    }
                    for path in paths {
                        match expert_tui::attachment::import_params(&path) {
                            Ok(mut params) => {
                                if let Some(id) = &session {
                                    params["session_id"] = json!(id);
                                }
                                let mut command = Command {
                                    method: "attachment.import".into(),
                                    params,
                                };
                                app.begin_attachment_import(&mut command, agent.clone());
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
                SourceEvent::CommandError {
                    command,
                    message,
                    outcome_unknown,
                } => {
                    clipboard_images.retain(|(pending, _)| pending != &command);
                    if outcome_unknown {
                        app.command_unknown(&command, &message);
                    } else {
                        app.command_error(&command, &message);
                    }
                    if command.method == "attachment.import" {
                        app.send_after_binding = false;
                    }
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
                    if !connected && !bound {
                        boot = true;
                    }
                    app.notice = if connected { String::new() } else { message };
                    if connected && boot {
                        app.startup_phase = Some(if resume.is_some() {
                            StartupPhase::Session
                        } else {
                            StartupPhase::Workspace
                        });
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
                    app.startup_phase = None;
                    app.restore_draft();
                    if let Some(path) = registering.take() {
                        // Registration failed: ask again instead of entering the folder.
                        app.ask_trust(&path);
                    } else if app.workspace_pending && !bound {
                        // The folder could not be checked; fall back to the normal screen.
                        app.workspace_pending = false;
                    }
                    app.notice = e;
                }
                SourceEvent::Response { method, result } => match method.as_str() {
                    "workspace.prepare" => {
                        if result["confirmation_required"] == true {
                            app.ask_trust(text(&result, "path"));
                        } else {
                            let w = result.get("workspace").unwrap_or(&result);
                            send(
                                &mut *source,
                                &mut app,
                                Command {
                                    method: "session.ensure".into(),
                                    params: json!({"workspace_id":w["id"]}),
                                },
                            );
                            prepared = true;
                        }
                    }
                    "workspace.register" => {
                        registering = None;
                        let workspace = result.get("workspace").unwrap_or(&result);
                        send(
                            &mut *source,
                            &mut app,
                            Command {
                                method: "session.ensure".into(),
                                params: json!({"workspace_id":workspace["id"]}),
                            },
                        );
                        prepared = true;
                    }
                    "session.new" | "session.ensure" => {
                        app.binding_ready = false;
                        bound = false;
                        prepared = true;
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
        if let Some((editor, _, _)) = editing.as_mut() {
            if editor.needs_confirmation()
                && event::poll(Duration::ZERO)?
                && let Event::Key(key) = event::read()?
                && key.kind == KeyEventKind::Press
                && key.code == KeyCode::Enter
            {
                editor.confirm();
            }
            let result = editor.poll();
            if matches!(result, Ok(None)) {
                std::thread::sleep(Duration::from_millis(30));
                continue;
            }
            let (_, session, mut draft) = editing.take().unwrap();
            terminal::enable_raw_mode()?;
            execute!(
                io::stdout(),
                EnterAlternateScreen,
                EnableMouseCapture,
                EnableBracketedPaste
            )?;
            term.clear()?;
            dirty = true;
            match result {
                Ok(Some(text)) => {
                    draft.text = text;
                    draft.cursor = draft.text.len();
                    if session.as_deref() == app.session_id() {
                        app.input = draft.text;
                        app.cursor = app.input.len();
                        app.notice = "编辑内容已回到草稿，尚未发送".into();
                    } else if let Some(id) = session {
                        app.session_drafts.insert(id, draft);
                        app.notice = "编辑内容已保存在原会话草稿".into();
                    }
                }
                Err(error) => app.notice = error.to_string(),
                Ok(None) => unreachable!(),
            }
        }
        if prepared
            && expected_session
                .as_deref()
                .is_some_and(|id| app.session_id() == Some(id))
        {
            bound = true;
            app.binding_ready = true;
            app.startup_phase = None;
            app.workspace_pending = false;
            let deferred = std::mem::take(&mut app.deferred_paths);
            for command in app.import_paths(deferred) {
                send(&mut *source, &mut app, command);
            }
            for path in unbound_images.drain(..) {
                match expert_tui::attachment::import_params(path.as_ref()) {
                    Ok(params) => {
                        let mut command = app.command("attachment.import", params);
                        app.begin_attachment_import(&mut command, None);
                        match source.send(command.clone()) {
                            Ok(()) => clipboard_images.push((command, path)),
                            Err(error) => {
                                app.command_error(&command, &error.to_string());
                                app.send_after_binding = false;
                            }
                        }
                    }
                    Err(error) => {
                        app.notice = error.to_string();
                        app.send_after_binding = false;
                    }
                }
            }
            if let Some(task) = initial.take() {
                app.input = if app.input.is_empty() {
                    task
                } else {
                    format!("{task}\n{}", app.input)
                };
                app.cursor = app.input.len();
                app.send_after_binding = true;
            }
            prepared = false;
        }
        if bound
            && app.binding_ready
            && app.send_after_binding
            && app
                .attachment_targets
                .iter()
                .all(|(c, _)| c.params["session_id"] != app.snapshot["session"]["id"])
        {
            app.send_after_binding = false;
            let commands = app.key(
                crossterm::event::KeyEvent::from(KeyCode::Enter),
                Instant::now(),
                width,
            );
            for command in commands {
                send(&mut *source, &mut app, command);
            }
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
            app.selection = None;
            last_size = size;
            dirty = true;
        }
        width = size.width;
        app.viewport = (size.width, size.height);
        app.pet.visible = ui::pet_visible(&app, size.width, size.height);
        if app.active()
            && app.thinking_updated_at.is_some()
            && last_progress.elapsed() >= Duration::from_secs(1)
        {
            last_progress = Instant::now();
            dirty = true;
        }
        app.pet.tick(Instant::now(), app.reduce_motion);
        if (app.active() || app.startup_phase.is_some() || app.workspace_pending)
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
        if app.notice != notice_seen {
            notice_seen = app.notice.clone();
            notice_at = Instant::now();
        }
        if notice_at.elapsed() >= Duration::from_secs(5)
            && (app.notice.starts_with("已") || app.notice.ends_with("已保存"))
            && !app.notice.contains("失败")
            && !app.notice.contains("错误")
        {
            app.notice.clear();
            notice_seen.clear();
            dirty = true;
        }
        if dirty && !native_path_paste.buffering() {
            execute!(io::stdout(), BeginSynchronizedUpdate)?;
            let drawn = term.draw(|f| {
                ui::draw(f, &app);
                expert_tui::workbench::draw(f,&app);
                if let Some(selection) = &app.selection {
                    let current = f.buffer_mut();
                    let area = current.area.intersection(selection.buffer.area);
                    for y in area.y..area.bottom().saturating_sub(1) {
                        for x in area.x..area.right() {
                            current[(x, y)] = selection.buffer[(x, y)].clone();
                            if selection.contains(x, y) {
                                current[(x, y)].set_style(
                                    ratatui::style::Style::default()
                                        .add_modifier(ratatui::style::Modifier::REVERSED),
                                );
                            }
                        }
                    }
                }
                last_frame = Some(f.buffer_mut().clone());
                if let Some((x, y)) = attachment_hover {
                    ui::draw_attachment_tooltip(f, &app, x, y);
                }
                let paths = ui::file_links_from_buffer(&app, f.buffer_mut());
                hyperlinks.prepare(&app, f.buffer_mut(), paths);
            });
            execute!(io::stdout(), EndSynchronizedUpdate)?;
            drawn?;
            dirty = false;
        }
        if event::poll(Duration::from_millis(if native_path_paste.buffering() {
            4
        } else if app.pet.visible {
            50
        } else if app.active() && !app.reduce_motion {
            80
        } else {
            100
        }))? {
            dirty = true;
            match event::read()? {
                Event::Key(key) if key.kind != KeyEventKind::Release => {
                    attachment_hover = None;
                    if key.modifiers.contains(event::KeyModifiers::CONTROL)
                        && key.code == KeyCode::Char('c')
                        && app.selection.is_some()
                    {
                        app.key(key, Instant::now(), width);
                        continue;
                    }
                    app.selection = None;
                    if let Some(path) = app.trust_prompt.clone() {
                        for command in app.trust_key(key) {
                            registering = Some(path.clone());
                            send(&mut *source, &mut app, command);
                        }
                    } else if app.workspace_pending || app.startup_phase.is_some() {
                        // Nothing is interactive until the folder is resolved.
                        if key.modifiers.contains(event::KeyModifiers::CONTROL)
                            && key.code == KeyCode::Char('c')
                        {
                            app.exit = true;
                        }
                    } else {
                        let plain = matches!(key.code, KeyCode::Char(_))
                            && !key.modifiers.intersects(
                                event::KeyModifiers::CONTROL | event::KeyModifiers::ALT,
                            );
                        if !plain {
                            native_path_paste.finish(&mut app);
                        }
                        let before = app.cursor;
                        let old_len = app.input.len();
                        let now = Instant::now();
                        let commands = app.key(key, now, width);
                        if plain && let KeyCode::Char(c) = key.code {
                            native_path_paste.track(&app, before, old_len, c, now);
                        }
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
                                        method: "session.ensure".into(),
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
                Event::Paste(_) | Event::Mouse(_)
                    if app.trust_prompt.is_some()
                        || app.workspace_pending
                        || app.startup_phase.is_some() => {}
                Event::Paste(s) => {
                    native_path_paste.clear();
                    app.selection = None;
                    app.paste(&s);
                }
                Event::Mouse(mouse) if expert_tui::workbench::side_rect(&app).is_some_and(|r|r.contains((mouse.column,mouse.row).into())) && mouse.kind==MouseEventKind::Down(event::MouseButton::Left) => {
                    if let Some(commands)=expert_tui::workbench::click(&mut app,mouse.column,mouse.row){for c in commands{send(&mut *source,&mut app,c);}}
                }
                Event::Mouse(mouse) if expert_tui::workbench::side_rect(&app).is_some_and(|r|r.contains((mouse.column,mouse.row).into())) && matches!(mouse.kind,MouseEventKind::ScrollUp|MouseEventKind::ScrollDown) => {
                    if let Some(p)=app.side_panel.as_mut(){if mouse.kind==MouseEventKind::ScrollUp{p.scroll+=3;}else{p.scroll=p.scroll.saturating_sub(3);}}
                }
                Event::Mouse(mouse) if mouse.kind == MouseEventKind::Moved => {
                    attachment_hover = Some((mouse.column, mouse.row));
                }
                Event::Mouse(mouse) if mouse.modifiers.contains(event::KeyModifiers::SHIFT) => {
                    app.selection = None;
                }
                Event::Mouse(mouse)
                    if app.form.is_some()
                        || app.drawer.is_some()
                        || app.question_popup_visible() =>
                {
                    let commands = match mouse.kind {
                        MouseEventKind::Drag(event::MouseButton::Left)
                            if diff_scroll_drag.is_some() =>
                        {
                            ui::drag_diff_scrollbar(
                                &mut app,
                                size.width,
                                size.height,
                                mouse.row,
                                diff_scroll_drag.unwrap_or(0),
                            );
                            vec![]
                        }
                        MouseEventKind::Up(event::MouseButton::Left) => {
                            diff_scroll_drag = None;
                            vec![]
                        }
                        MouseEventKind::ScrollUp | MouseEventKind::ScrollDown => app.key(
                            crossterm::event::KeyEvent::from(if app.question_popup_visible() {
                                if mouse.kind == MouseEventKind::ScrollUp {
                                    KeyCode::PageUp
                                } else {
                                    KeyCode::PageDown
                                }
                            } else if mouse.kind == MouseEventKind::ScrollUp {
                                KeyCode::Up
                            } else {
                                KeyCode::Down
                            }),
                            Instant::now(),
                            width,
                        ),
                        MouseEventKind::Down(event::MouseButton::Left) => {
                            diff_scroll_drag = None;
                            let scrollbar = ui::diff_scrollbar(&app, size.width, size.height)
                                .filter(|bar| {
                                    mouse.column >= bar.track.x.saturating_sub(1)
                                        && mouse.column <= bar.track.x
                                        && mouse.row >= bar.track.y
                                        && mouse.row < bar.track.bottom()
                                });
                            if let Some(bar) = scrollbar {
                                if mouse.row >= bar.thumb.y && mouse.row < bar.thumb.bottom() {
                                    diff_scroll_drag = Some(mouse.row - bar.thumb.y);
                                } else if mouse.row < bar.thumb.y {
                                    app.selected = bar.position.saturating_sub(bar.page);
                                } else {
                                    app.selected =
                                        bar.position.saturating_add(bar.page).min(bar.maximum);
                                }
                                vec![]
                            } else if ui::popup_close_rect(&app, size.width, size.height)
                                .is_some_and(|r| {
                                    r.contains(ratatui::layout::Position::new(
                                        mouse.column,
                                        mouse.row,
                                    ))
                                })
                            {
                                app.close_popup();
                                vec![]
                            } else if let Some(index) = ui::popup_field_at(
                                &app,
                                size.width,
                                size.height,
                                mouse.column,
                                mouse.row,
                            ) {
                                app.click_form_field(index)
                            } else if let Some(action) = ui::popup_action_at(
                                &app,
                                size.width,
                                size.height,
                                mouse.column,
                                mouse.row,
                            ) {
                                app.click_popup_action(action)
                            } else {
                                vec![]
                            }
                        }
                        _ => vec![],
                    };
                    for command in commands {
                        send(&mut *source, &mut app, command);
                    }
                }
                Event::Mouse(mouse) => match mouse.kind {
                    MouseEventKind::ScrollUp => {
                        app.selection = None;
                        if mouse.row == 0 && ui::show_pinned_user(&app,size.width,size.height) {
                            ui::jump_user_turn(&mut app, -1);
                        } else {
                            app.scroll_by(-3);
                        }
                    }
                    MouseEventKind::ScrollDown => {
                        app.selection = None;
                        if mouse.row == 0 && ui::show_pinned_user(&app,size.width,size.height) {
                            ui::jump_user_turn(&mut app, 1);
                        } else {
                            app.scroll_by(3);
                        }
                    }
                    MouseEventKind::Drag(event::MouseButton::Left) => {
                        approval_press = None;
                        message_click = None;
                        tool_click = None;
                        diff_click = None;
                        app.update_selection(mouse.column, mouse.row, true)
                    }
                    MouseEventKind::Up(event::MouseButton::Left) => {
                        if let Some((id, index)) = approval_press.take()
                            && ui::approval_button_at(
                                &app,
                                size.width,
                                size.height,
                                mouse.column,
                                mouse.row,
                            ) == Some((id.clone(), index))
                        {
                            for command in app.choose_approval(&id, index) {
                                send(&mut *source, &mut app, command);
                            }
                        }
                        app.update_selection(mouse.column, mouse.row, false);
                        if let Some((session, id, x, y)) = diff_click.take()
                            && app.session_id() == Some(session.as_str())
                            && (x, y) == (mouse.column, mouse.row)
                        {
                            app.open_diff_card(&id);
                        }
                        if let Some((session, id, x, y)) = tool_click.take()
                            && app.session_id() == Some(session.as_str())
                            && (x, y) == (mouse.column, mouse.row)
                        {
                            app.open_tool_rounds((!id.is_empty()).then_some(id));
                        }
                        if let Some((session, id, x, y)) = message_click.take()
                            && app.session_id() == Some(session.as_str())
                            && (x, y) == (mouse.column, mouse.row)
                        {
                            app.open_message_history(&id);
                        }
                        if app.selection.as_ref().is_some_and(|s| s.start == s.end) {
                            app.selection = None;
                        }
                    }
                    MouseEventKind::Down(event::MouseButton::Left) => {
                        if let Some(p)=app.side_panel.as_mut(){p.focused=false;}
                        message_click = None;
                        tool_click = None;
                        diff_click = None;
                        app.selection = None;
                        approval_press = None;
                        if let Some((id, index)) = ui::approval_button_at(
                            &app,
                            size.width,
                            size.height,
                            mouse.column,
                            mouse.row,
                        ) {
                            app.approval_focus = Some((id.clone(), index));
                            approval_press = Some((id, index));
                        } else if app.view == expert_tui::app::View::Agents
                            && app.agent_detail_id.is_none()
                            && expert_tui::swarm::enabled(size.width, size.height.saturating_sub(1))
                        {
                            if let Some(index) = expert_tui::swarm::hit(
                                &app,
                                size.width,
                                size.height,
                                mouse.column,
                                mouse.row,
                            ) {
                                if app.selected == index {
                                    app.key(
                                        event::KeyEvent::from(KeyCode::Enter),
                                        Instant::now(),
                                        width,
                                    );
                                } else {
                                    app.selected = index;
                                }
                            }
                        } else if mouse.row == 0
                            && size.height >= 12
                            && ui::show_pinned_user(&app,size.width,size.height)
                        {
                            let (id, _) = expert_tui::presentation::pinned_user(&app).unwrap();
                            let id = id.to_owned();
                            let session = app.session_id().unwrap_or("").to_owned();
                            if pinned_click.as_ref().is_some_and(|(s, m, at)| {
                                s == &session
                                    && m == &id
                                    && at.elapsed() < Duration::from_millis(450)
                            }) {
                                ui::jump_pinned_user(&mut app);
                                pinned_click = None;
                            } else {
                                pinned_click = Some((session, id, Instant::now()));
                            }
                        } else if ui::latest_button_rect(&app, size.width, size.height).is_some_and(
                            |r| r.contains(ratatui::layout::Position::new(mouse.column, mouse.row)),
                        ) {
                            app.latest_output();
                        } else if let Some(index) = last_frame.as_ref().and_then(|frame| {
                            ui::attachment_hit(&app, frame, mouse.column, mouse.row)
                        }) {
                            let key=format!("{}:draft:{index}",app.session_id().unwrap_or(""));
                            let double=attachment_click.as_ref().is_some_and(|(last,at)|last==&key&&at.elapsed()<Duration::from_millis(450));
                            attachment_click=Some((key,Instant::now()));
                            if double || text(&app.attachments[index],"kind")!="image" {for command in app.preview_attachment(index){send(&mut *source,&mut app,command);}}
                        } else if let Some((message,attachment))=last_frame.as_ref().and_then(|frame|ui::image_message_hit(&app,frame,mouse.column,mouse.row)) {
                            let key=format!("{message}:{attachment}");
                            let double=attachment_click.as_ref().is_some_and(|(last,at)|last==&key&&at.elapsed()<Duration::from_millis(450));
                            attachment_click=Some((key,Instant::now()));
                            if double {let c=app.command("terminal.action",json!({"action":"attachment.message.preview","message_id":message,"attachment_id":attachment}));send(&mut *source,&mut app,c);}
                        } else if ui::pet_rect(&app, size.width, size.height).is_some_and(|rect| {
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
                            if let Some(topic) =
                                ui::footer_action(&app, size.width as usize, mouse.column as usize)
                            {
                                for command in app.terminal_query(topic) {
                                    send(&mut *source, &mut app, command);
                                }
                            } else {
                                app.open(ui::footer_hit(
                                    &app,
                                    size.width as usize,
                                    mouse.column as usize,
                                ));
                            }
                        } else if ui::statistics_at(&app, size.width, size.height)
                            .is_some_and(|r| r.contains((mouse.column, mouse.row).into()))
                        {
                            let topic = ui::statistics_action(
                                &app,
                                size.width as usize,
                                mouse.column as usize,
                            );
                            for command in app.terminal_query(topic) {
                                send(&mut *source, &mut app, command);
                            }
                        } else if let Some(frame) = &last_frame
                            && frame.area.height > 1
                            && mouse.row < frame.area.bottom().saturating_sub(1)
                        {
                            if mouse.modifiers.is_empty()
                                && let Some(id) = ui::user_message_at(
                                    &app,
                                    size.width,
                                    size.height,
                                    mouse.column,
                                    mouse.row,
                                )
                            {
                                message_click = Some((
                                    app.session_id().unwrap_or("").into(),
                                    id,
                                    mouse.column,
                                    mouse.row,
                                ));
                            }
                            if mouse.modifiers.is_empty()
                                && let Some(id) = ui::tool_record_at(
                                    &app,
                                    size.width,
                                    size.height,
                                    mouse.column,
                                    mouse.row,
                                )
                            {
                                tool_click = Some((
                                    app.session_id().unwrap_or("").into(),
                                    id,
                                    mouse.column,
                                    mouse.row,
                                ));
                            }
                            if mouse.modifiers.is_empty()
                                && let Some(id) = ui::diff_card_at(
                                    &app,
                                    size.width,
                                    size.height,
                                    mouse.column,
                                    mouse.row,
                                )
                            {
                                diff_click = Some((
                                    app.session_id().unwrap_or("").into(),
                                    id,
                                    mouse.column,
                                    mouse.row,
                                ));
                            }
                            app.start_selection(frame.clone(), mouse.column, mouse.row);
                        }
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    }
    source.close();
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
