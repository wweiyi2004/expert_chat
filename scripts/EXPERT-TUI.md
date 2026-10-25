# expert terminal launcher

Build with `cargo build --release --manifest-path next/Cargo.toml -p expert-tui`.
Add this repository's `scripts` directory to your user PATH, then run `expert` from your project directory. The launcher preserves that directory and the process exit code. You can also place `expert.cmd`, `expert.ps1`, and `expert-tui.exe` together in a dedicated user bin directory.

Specify the trusted desktop executable using `expert --gui C:\absolute\path\expert_chat.exe`, or set `EXPERT_CHAT_GUI` to that absolute path. When installed beside the desktop executable, `expert-tui` discovers that sibling. The launcher does not execute a GUI found through the project directory or PATH. If a GUI is already running, the same executable's native single-instance handler enables its bridge; it does not restart the existing process.

`expert --demo welcome` works offline; demo names also include first_run, default_workspace, startup_error, prompt, resume, running, approval, retrying, failed, stopped, waiting_acceptance, accepted, and agents. Demo actions affect local in-memory state only.

Live discovery is `%LOCALAPPDATA%\expert-chat\tui\bridge.json`, owned privately by the current user and SYSTEM. Never copy its token into reports. An updated desktop GUI creates and secures it when started with `--tui-bridge --background`. Closing the TUI disconnects only its client; running GUI tasks continue. Explicit task stop cancels a task. Closing the desktop application ends its hosted tasks.

Use `/bridge off` inside the TUI to close only the bridge. The terminal exits after acknowledgement and existing tasks keep running. A later `expert` launch enables the bridge again without creating another desktop instance.

After a connection loss, uncertain mutations are never replayed automatically. The client reconnects, authenticates again, opens the previous session and requests its current state. Inspect the restored state before repeating any operation whose result was unknown.
