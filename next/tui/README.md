# Expert TUI

`expert` is the terminal client for the running Expert desktop application. It uses the same sessions, controller, approvals, model sources and task acceptance evidence. Closing the terminal disconnects the client; `/stop`, double Esc, or Ctrl+C during a running task explicitly stop a task.

The audit repair revision keeps drafts associated with their original conversation and destination. If a failed send conflicts with a newer draft, `/recover` restores the failed draft and retains the current one; it never sends automatically. Pending questions still accept control commands, while paths such as `/home/project` remain valid answers. `/mode work` and `/mode plan` select the named mode explicitly. `/stop` and `/quit` remain available while a send is pending or an image is attached.

`/compact` explicitly summarizes public task context through the configured model and stores a versioned checkpoint using the shared backend. Original messages remain available. It reports progress, success or failure; `/stop` cancels the pending operation. Automatic transient request retries are bounded to three total attempts, only before any response content or tool call exists, and are disabled when channel/model fallback already handles retry. The TUI shows the actual backoff; tools are never replayed by this retry layer.

Long input follows the cursor. Changes and agent lists keep the selected item visible; long diffs wrap, and wide tables switch to complete labeled rows. Enter on an agent opens its scrollable record. Ctrl+L forces a full terminal repaint. Verified visible local file paths use OSC 8 hyperlinks (follow the terminal's link gesture, commonly Ctrl+click); truncated paths and remote targets are not guessed. `/pet on` restores a disabled pet. Invalid local configuration is reported without overwriting it. `ambiguous_width=2` uses ASCII interface decoration to avoid double-width borders.

State-refresh failures remain visibly marked until a successful snapshot arrives. A slow read or compaction cannot block heartbeat/stop, and a late result from another conversation cannot switch the visible conversation back. `/settings` provides native terminal forms for providers, MCP and ASR; `/mcp` opens the native MCP manager. Library, media creation and official OAuth browser authorization retain their existing GUI entry points.

`/resume` opens recent activity in the current project, skipping the new empty input session. `/sessions` lets you choose another session explicitly. `/gui` opens the current session in the same desktop instance, including its existing detailed tool views and workspace previews.

Build from the repository root:

```powershell
cargo build --release --manifest-path next/Cargo.toml -p expert-tui
scripts/expert.ps1 --gui C:\absolute\path\expert_chat.exe
scripts/expert.ps1 E:\project
scripts/expert.ps1 resume SESSION_ID
```

The desktop executable must include the TUI bridge. `--gui` or `EXPERT_CHAT_GUI` supplies its absolute path. Startup connects in the background; there is no demo fallback on connection errors. First use of the current directory requires an explicit read-only/read-write confirmation. Actions against a provisional GUI session are blocked until the selected workspace or resumed session has been bound.

`/bridge off` closes the authenticated bridge and exits the terminal after acknowledgement; hosted tasks continue. Starting `expert` again re-enables the bridge through the same desktop instance. During a proposed file write, Ctrl+G shows the full expected-version diff; Ctrl+Y returns to its approval card. A missing verified original is displayed as unavailable rather than invented. Execution still validates the actual file version.

`/model`, `/permissions`, `/sessions`, `/workspace`, `/help`, `/pet`, `/accept`, `/new`, `/stop` and `/quit` are available in the command completion list. `/library` opens the existing library and `/media` opens image generation in the same GUI. Provider settings and MCP are editable directly in `/settings`. Ctrl+J or Alt+J inserts a newline; Shift+Enter also works when reported by the terminal. Pasted content longer than five lines remains intact behind a compact label. `/attach [path]` imports files (without a path it opens a file picker); Ctrl+V accepts copied files, text or PNG images up to 5 MiB. Pending attachments are labeled `[File n]`, `[Image n]`, `[Video n]`, `[Audio n]`. `/attach cancel` stops pending import; `/detach` removes attachments. Audio uses configured MiMo or OpenAI-compatible ASR; video uses local ffmpeg to sample up to three keyframes from the first 60 seconds, without reading the audio track. Pending drafts are restored on errors and never automatically replayed after reconnect.

Deterministic terminal snapshots use exactly the same reducer and renderer:

```powershell
next/target/release/expert-tui.exe --snapshot running --width 80 --height 24
next/target/release/expert-tui.exe --demo approval
next/target/release/expert-tui.exe --snapshot welcome --ascii
cargo test --manifest-path next/Cargo.toml -p expert-tui
cargo clippy --manifest-path next/Cargo.toml -p expert-tui --all-targets -- -D warnings
```

Every JSONL scene under `design/tui/fixtures` is accepted by `--demo` and `--snapshot`. Goldens cover all 14 scenes at 80/60/40 × 24. To deliberately refresh them, set `UPDATE_SNAPSHOTS=1` for the UI test invocation.

`/skin` chooses terminal/default, midnight, forest, sakura, ink, paper or snow, and offers custom background/accent hex colors plus auto/GitHub/Monokai/Dracula code coloring. Windows Terminal uses RGB so the pet retains its original palette. Other terminals default to ANSI 16; `COLORTERM=truecolor` or `24bit` enables RGB; `NO_COLOR` removes color. `--theme dark|light` takes precedence. On Windows, a nonblocking `GetConsoleScreenBufferInfoEx` query reads the actual console background color table without consuming input. If unavailable, `COLORFGBG` is used, then dark. This native query deliberately substitutes for OSC 11: crossterm 0.29 exposes no OSC color response event, and a competing stdin reader could steal keystrokes. POSIX OSC 11 and physical tmux/SSH terminal behavior have not been verified.

`EXPERT_REDUCE_MOTION` disables spinner animation and idle blinking. Pet frames come directly from `design/tui/pet/megumin.json` and are gated by size, color, UTF-8 mode and ambiguous width. Configuration is stored in `%APPDATA%/expert-chat/tui.json` (or the platform config directory); `EXPERT_TUI_CONFIG` overrides the file. `/pet off` persists `pet: "none"`; `ambiguous_width` accepts 1 or 2. Shift-drag selects text in most mouse-enabled terminals. Idle frames redraw only after data/input/resize or a visible animation changes.

The welcome card shows local date, model source/model and workspace; recent sessions are centered and only shown on the welcome page. Use arrows or click to select, then confirm before opening. Command completion highlights the whole row and shows Chinese descriptions/usage. Generic session names get a meaningful first-sentence fallback and a short background AI title after the first interaction; manual titles take priority. Opening a nonempty legacy generic-title session also requests a title.

This refinement was built with compilation-only validation at the user’s request; the new runtime forms/media paths were not exercised against real services during development.
