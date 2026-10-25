# Expert TUI

`expert` is the terminal client for the running Expert desktop application. It uses the same sessions, controller, approvals, model sources and task acceptance evidence. Closing the terminal disconnects the client; `/stop`, double Esc, or Ctrl+C during a running task explicitly stop a task.

Build from the repository root:

```powershell
cargo build --release --manifest-path next/Cargo.toml -p expert-tui
scripts/expert.ps1 --gui C:\absolute\path\expert_chat.exe
scripts/expert.ps1 E:\project
scripts/expert.ps1 resume SESSION_ID
```

The desktop executable must include the TUI bridge. `--gui` or `EXPERT_CHAT_GUI` supplies its absolute path. Startup connects in the background; there is no demo fallback on connection errors. First use of the current directory requires an explicit read-only/read-write confirmation. Actions against a provisional GUI session are blocked until the selected workspace or resumed session has been bound.

`/model`, `/permissions`, `/sessions`, `/workspace`, `/help`, `/pet`, `/accept`, `/new`, `/stop` and `/quit` are available in the command completion list. `/library` opens the existing library and `/media` opens image generation in the same GUI. Login, provider settings and complex configuration also open the same desktop GUI. Ctrl+J inserts a newline; pasted content longer than five lines remains intact behind a compact label. Ctrl+V imports a Windows clipboard image as an explicit PNG attachment, limited to 512 KiB; larger images and other platform clipboards use the GUI attachment flow. Pending drafts are restored on errors and never automatically replayed after reconnect.

Deterministic terminal snapshots use exactly the same reducer and renderer:

```powershell
next/target/release/expert-tui.exe --snapshot running --width 80 --height 24
next/target/release/expert-tui.exe --demo approval
next/target/release/expert-tui.exe --snapshot welcome --ascii
cargo test --manifest-path next/Cargo.toml -p expert-tui
cargo clippy --manifest-path next/Cargo.toml -p expert-tui --all-targets -- -D warnings
```

Every JSONL scene under `design/tui/fixtures` is accepted by `--demo` and `--snapshot`. Goldens cover all 14 scenes at 80/60/40 × 24. To deliberately refresh them, set `UPDATE_SNAPSHOTS=1` for the UI test invocation.

Colors default to ANSI 16. `COLORTERM=truecolor` or `24bit` enables the RGB palette; `NO_COLOR` removes color. `--theme dark|light` takes precedence. On Windows, a nonblocking `GetConsoleScreenBufferInfoEx` query reads the actual console background color table without consuming input. If unavailable, `COLORFGBG` is used, then dark. This native query deliberately substitutes for OSC 11: crossterm 0.29 exposes no OSC color response event, and a competing stdin reader could steal keystrokes. POSIX OSC 11 and physical tmux/SSH terminal behavior have not been verified.

`EXPERT_REDUCE_MOTION` disables spinner animation and idle blinking. Pet frames come directly from `design/tui/pet/megumin.json` and are gated by size, color, UTF-8 mode and ambiguous width. Configuration is stored in `%APPDATA%/expert-chat/tui.json` (or the platform config directory); `EXPERT_TUI_CONFIG` overrides the file. `/pet off` persists `pet: "none"`; `ambiguous_width` accepts 1 or 2. Shift-drag selects text in most mouse-enabled terminals. Idle frames redraw only after data/input/resize or a visible animation changes.
