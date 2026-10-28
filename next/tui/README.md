# Expert TUI

Startup validates the Host discovery once and reuses that result for the first
connection. Reconnecting validates again. External session discovery is manual:
use `/import` when needed; ordinary startup does not scan other clients' history.

Closing a GUI or TUI window ends the work started by that window: model tasks,
child agents, commands, pending plan reviews and window-owned schedules. Other
windows keep their own tasks. A normal exit sends `window.close`; an unexpected
disconnect allows five seconds to reconnect before cancelling that window's work.
Closing a side panel only hides that panel; it does not exit the application window.

In work mode, network permission allows `fetch_url` to read any public HTTP(S)
page, including documentation links and URLs introduced in later guidance or
after task recovery. It no longer requires a URL to occur in the initial prompt
or search citations. Network-off, unsafe addresses and invalid protocols remain
blocked; a configured Fetch service is still required. Ordinary chat retains its
explicit user/search URL matching.

The native workbench adds `/btw` (context-linked side chat), `/files` (directory
navigation, real-file editing and run), `/git`, `/split` (pick a second work
session), `/automation`, `/backup`, `/updates`, `/voice`, `/media` and `/jobs`.
These dialogs use the existing host, workspace permissions and model sources.
Side panes use Enter to submit, F6 to change input focus, PageUp/PageDown to read,
Esc to close without stopping work, and Ctrl+C to stop only the selected side
operation. Ctrl+P first copies a side answer into the input for review; a second
Ctrl+P submits the reviewed text to the parent task.

`/files` starts at the current session's workspace and displays its absolute
path. Select a directory, fill in the separate new-file name, then create the
file. `/files <path>` opens a specific directory. Long Markdown table cells wrap
inside their columns; side input uses display-cell cursor positioning and
follows multiline drafts.

File save replies belong to the editor instance that sent them. Closing or
reopening a file cannot redirect a pending save. Side-chat replies retain text
typed after sending. Scheduled commands keep the workspace and directory saved
with the schedule; switching the conversation to another workspace prevents
execution there. Old schedules without a saved directory must be saved again.
Workbench queries are read-only; mutations use `terminal.action`.

In file mode, Ctrl+S saves the actual file, Ctrl+Shift+S opens Save As, and
Ctrl+Enter saves then runs it using the installed Python/Node/Dart/PowerShell or
C/C++ toolchain. Compilation failure does not run an older binary. `/editor`
without a file remains a draft editor. No compiler is bundled. Scheduling and
backup actions do not call a model; media generation/transcription and side chat
use the configured services. `/updates` accepts an HTTPS JSON manifest with
`version`, `url`, and `sha256`, verifies the download, and allows selecting an
installed complete bundle for the next launch.

New tool records include public-text offsets, so progress text and tool groups
can remain in event order. Legacy records keep their fallback layout. Terminal
usage shows only totals; completed tasks no longer repeat every command.
Images in the composer or transcript open their system preview on double-click.
The TUI offers work and plan workflows; existing plain-chat history is viewable,
and `/mode work` explicitly converts a selected legacy conversation.


While a work task is running, ordinary text is saved as guidance for the same
root task. The current tool batch finishes before the next model request picks
it up. The TUI shows submission progress, then `已排队 · 等待工具边界`, and keeps
`已纳入第 N 轮上下文` below the user message after it leaves the queue. This is
context-preparation evidence, not a claim that the model has read or obeyed it.
Withdrawing or cancelling a queued update stays visible as such; failed sends
retain the draft and original session. Child agents cannot consume root guidance
on the root's behalf. No provider-specific mid-response API is required.

The welcome screen has a large animated Megumin at the left and an editable,
theme-colored EXPERT CHAT wordmark at the right on wide terminals. Smaller
terminals use the compact header. The top message strip is pinned during a
conversation; double-click it to jump to that message.

`/effort` uses a horizontal faster/deeper selector. `/context` shows usage bars;
`/context contents` selects history and attachments. Model window/output limits
are in `/settings context`. List searches and editable fields have a subtle
background using the active theme.

`/subagent MODEL high "task"` starts a read-only child with that model and
effort, inherited workspace, tools, permissions and budget. Use a saved model ID
or the full source choice when aliases are ambiguous. An explicit
`--write=src/a.rs,src/b.rs` before the model gives the child responsibility for
those files; shared-workspace command execution remains restricted. `/agents`
shows a swarm grid on large terminals and a compact tree on small ones.

`/editor rust` (also python/javascript/typescript/dart/c/cpp/json/html/markdown)
opens a code draft with syntax colors, bracket pairs, indentation and Tab keyword
completion. Ctrl+L changes language; Ctrl+S saves the draft and Ctrl+Enter sends
it. Draft edits do not change repository files. `/init` requests AGENT.md setup;
existing AGENT.md, AGENTS.md and CLAUDE.md files are automatically read from the
authorized workspace when preparing requests.

After trust, an empty new session offers recent local sessions from Claude Code,
Codex, Grok Build, OpenCode and DeepSeek Harness; `/import` opens the same chooser.
Preview and confirm to copy conversation text into a new session. Credentials,
system prompts, tool grants and live tasks are not imported. Recency does not
prove that another client has closed; changing source text invalidates a prior
preview. Unsupported or oversized artifacts stay untouched.

Startup shows a centered card using the selected theme's accent, text and
background colors. It distinguishes connecting to the local host, preparing the
workspace and restoring a session; no percentage is invented. Ctrl+C exits the
startup screen. Folder trust still requires an explicit choice before entry.
Preview the card without connecting or opening user data with
`expert --snapshot connecting` or `expert --snapshot preparing`.

Prefix composer input with `!` to run a shell command in the selected session
workspace, for example `!git status`. The command does not call a model or consume
attachments. Windows uses PowerShell; an SSH workspace uses its remote shell.
The execution panel shows the immutable target, live output and exit status.
Ctrl+C or the Stop button cancels; Esc returns to chat and `/shell` reopens the
latest result. Each command starts in the selected workspace root; use a single
command such as `cd subdir; ...` for a different directory. Existing workspace
grants apply. Commands use the existing ten-minute execution limit and bounded
output buffer. Closing a remote SSH channel does not guarantee its child process
has exited. This revision was compiled only, without running user shell commands.

The seven-feature revision adds:

- `/context` → 选择上下文内容: include or exclude earlier turns, attachments,
  project notes and memory; optionally include saved tool results as reference.
  The latest user turn remains included. New defaults choose history by token
  budget; existing explicit history limits are retained.
- `/search [query]`: search session text, attachment text and tool results;
  results on another branch open a read-only preview.
- `/login` → account → 套餐与额度: explicit refresh uses supported official
  read-only quota endpoints, and unsupported accounts link to their console.
- `/ssh`: manage profiles, confirm host keys, connect, browse/edit remote files
  and select the remote workspace. `@` completion supports connected SSH.
  Hooks may monitor remote SFTP metadata; updates poll every three seconds,
  require modification times, and can miss same-size changes within one second.
- `/steps` opens an overview, input, output and raw-data view with copy/refresh.
- `/library` offers a clickable management row and F2 for set/file management.
- `/editor` and Alt+E open a native multiline draft editor; Ctrl+S keeps the
  draft and Ctrl+Enter sends it. `/editor external` retains the external editor.

The Rust TUI and Dart host were compiled only. These changes were not exercised
against real subscription accounts, SSH servers, or paid model APIs.

`/login` lists all saved accounts before the add-account catalog. OAuth entries
show the saved nickname/email and authorization state; key-based entries show
their source alias and whether a key is stored. Multiple connections to the same
service remain separate. Account actions open that source's model picker,
settings, or reauthorization; adding an account creates a new source. Returning
from the source editor and completing OAuth refresh the account list. Viewing
accounts only reads local metadata and does not validate credentials online.

Empty assistant placeholders from failed/interrupted history are excluded from
outgoing requests without deleting stored messages. Valid tool calls, tool
results, images and native continuation items remain intact. Tool-call-only Chat
Completions messages use null content; empty native Responses assistant message
items are omitted. Kimi Coding endpoints in automatic mode prefer Responses
when no per-model protocol is reported; explicit protocol choices are retained.

`/login` and Settings → Subscription services share a subscription setup menu.
Kimi Code supports its official device-code OAuth flow and dedicated API keys.
OAuth credentials are held by the shared host in secure storage, refreshed on
demand, and bound to the official Kimi Code endpoint and the original account.
The authorization dialog exposes a verification URL/code and copy buttons.
Discovery reads the account's actual models, limits, reasoning and tool metadata.

Dedicated key presets include BigModel/Z.AI Coding Plan, OpenCode Go, MiniMax
Token Plan, Alibaba Coding/Token Plan, Xiaomi MiMo Token Plan, Tencent Token Plan
and Volcengine Ark Coding Plan, with explicitly separate regional endpoints.
Opening a preset fills the URL/protocol and opens the matching console; keys
are stored through the existing credential service. Suggested model IDs remain
editable and do not assert account entitlements. BigModel account OAuth is not
enabled without separately provisioned application credentials; its plan-key
route is available. No subscription purchase or paid request is automated.

On Windows, the default Notepad draft is an existing `.txt` file with its file
handle closed before launch. The launcher exiting no longer deletes the draft.
Save with Ctrl+S, return to the terminal and press Enter to read the saved draft;
press Enter again in the TUI to send. The file path is shown during editing, and
Notepad drafts are retained to avoid deleting a file still open in another
process. Custom blocking editors (`VISUAL` / `EDITOR`, e.g. `code --wait`) still
return their draft when their process finishes. No editor return sends text by
itself.

The full-diff dialog has a right-side scrollbar: drag its thumb to seek or click
the track to page. Up/down scroll one rendered row; left/right and PageUp/PageDown
move one viewport with a one-row overlap; Home/End jump to the beginning/end.
The footer shows scroll progress and the dialog stays the same size while paging.

Code-block headers, backgrounds and source lines use the full conversation
viewport width, including when the window is wide. Ordinary prose retains its
reading-width limit. Wrapping and cached layouts follow the available width.

File edits now render as inline diff cards with the real file name, added/removed
counts, line numbers and red/green backgrounds. At most three recent cards are
shown per assistant message, each with a three-row preview; click a card for its
complete, scrollable diff, or use Ctrl+G for all changes. Unified hunk line
positions and complete backend line diffs retain their respective numbering.
Binary files and missing originals keep their actual explanatory messages.
Markdown code fences also have a language header, local line numbers and a
separate background; copying the reply still returns the original text.

`/cost` and `/usage` open a structured panel with a fee summary, input/output/cache
totals and task/title/auxiliary request counts. Statistical notes are collapsed
behind a clickable details row (Enter toggles it). Missing data and partial
estimates remain explicit. This revision was compiled only, without tests or
runtime checks, as requested.

The palette/layout revision adds 16 themes, including Explosion Red, with a
keyboard/mouse grid and a separate preview. Selecting a tile previews it;
Enter or Apply saves it. Narrow terminals stack the preview below the grid.
`/skin`, `/effort` and `/context` are visible primary commands.

The composer reserves two footer rows: workspace/model/permissions, then
context/usage. Command completion and status text share the input indentation.
Operation feedback appears at the right of the status row; success messages
expire after five seconds. Incomplete usage is labeled explicitly instead of
asterisks. Synchronized terminal updates and a steady caret avoid redraw flicker.

Tool progress defaults to a summary and at most three recent/current steps.
Click the group or use `/steps` to browse rounds, then individual details.
Skipped calls are distinguished from failed executions; missing exit codes and
raw JSON are omitted from the compact view.

Automatic context defaults to 1,000,000 tokens, capped by reported model limits;
explicit per-model settings are retained. Automatic output uses the reported
model maximum, falling back to provider defaults when unknown. Manual output
limits remain available through the advanced output selector. This revision
was compiled only at the user's request; no tests or runtime checks were run.

Slash completion lists primary entries only. Related shortcuts (provider/login,
model fast mode, attachment actions, usage and navigation) remain available
with their existing arguments. `/help commands` lists the primary entries and
their shortcuts. Enter executes an exact command before considering completion,
so `/attach` still reads the clipboard instead of opening `/attachments`.
`/context` and `/effort` remain primary entries: their settings have independent
panels and are not part of the model selector.

User messages have a subtle background in light and dark themes. A click opens
a searchable list of that conversation's user messages; selecting one positions
the transcript at that message without modifying history, files or the draft.
Dragging still selects text. `/history messages` opens the same list with the
keyboard, and `/latest` returns to live output.

Agent questions open a centered dialog. Left/right switches questions while
choosing options, up/down moves the selection and Space selects or toggles it.
Tab switches between option navigation and text editing (where left/right moves
the cursor). Enter confirms the current answer and advances; on the last
question it submits the complete set. Ctrl+Enter or the Submit button submits
all answers, returning to any missing required answer. Esc closes the dialog
without discarding answers; `/questions` reopens it. Question tabs, options and
buttons support mouse clicks. Drafts stay scoped to their original session and
question request; failures never automatically replay answers.

Model, session, workspace, permission, effort and library list rows accept mouse
clicks using their rendered positions. Full access still requires confirmation.
Clicking a choice field (such as context presets or protocol) cycles its value;
text fields retain normal editing behavior.

`expert` connects to the independent shared Dart host, starting the bundled `host/bin/expert-host.exe` when needed. GUI and TUI use the same sessions, task controller, approvals, model sources and acceptance evidence. Closing the terminal cancels work owned by that window; `/stop`, double Esc, or Ctrl+C can also stop a task while keeping the window open.

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

`/bridge off` disconnects and exits this terminal; its window-owned tasks are cancelled. Other windows continue using the shared Host. During a proposed file write, Ctrl+G shows the full expected-version diff; Ctrl+Y returns to its approval card. A missing verified original is displayed as unavailable rather than invented. Execution still validates the actual file version.

`/model`, `/permissions`, `/sessions`, `/workspace`, `/help`, `/pet`, `/accept`, `/new`, `/stop` and `/quit` are available in the command completion list. `/library` opens the existing library and `/media` opens image generation in the same GUI. Provider settings and MCP are editable directly in `/settings`. Ctrl+J or Alt+J inserts a newline; Shift+Enter also works when reported by the terminal. Pasted content longer than five lines remains intact behind a compact label. `/attach [path]` imports files (without a path it reads the clipboard); Ctrl+V accepts copied files, text or PNG images up to 5 MiB. Pending attachments are labeled `[File n]`, `[Image n]`, `[Video n]`, `[Audio n]`. `/attach cancel` stops pending import; `/detach` removes attachments. Only images are imported as content. `[File n]`, `[Video n]` and `[Audio n]` remain compact labels before and after sending; hover over a label to see its absolute file path. Non-image references carry the address as metadata: documents are not parsed, audio is not transcribed and video frames are not extracted. Pending drafts are restored on errors and never automatically replayed after reconnect.

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

Settings, model selection and other selectors use centered dialogs with an [x] close button, Esc/back navigation, mouse wheel selection, and screen-size-aware margins. Thinking and a single combined tool-step block appear before each assistant reply. Copy visible text by dragging and pressing Ctrl+C (selection takes priority over stop); `/copy` copies the last reply and `/copy all` copies conversation text. Shift-drag still uses terminal-native selection for any screen text. New TUI sessions are prepared automatically; unspoken client-owned drafts are cleaned on exit/switch without deleting existing conversation history.

The P0 reliability revision preserves read-only provider/MCP identity and newly entered credentials on rejected saves. Confirmed saves clear only submitted secret values, preserving edits made while waiting. An unknown save outcome triggers a state query and blocks replay from that form; return to settings, inspect the refreshed entries and reopen the intended object. Model selection remains visible in short windows, and persistent errors/stale-state notices stay outside centered dialogs. Automatic tool approval requires a complete, tool-free reviewer response within a total deadline; uncertain reviews fall back to manual approval.

`/plan` reviews versioned plans; `/plan approve N` approves the exact version already viewed, and `/plan comment N text` invalidates the old approval. `/tasks` groups shared work sessions by execution state while showing acceptance separately. `/rewind` previews a checkpoint before choosing conversation, files, both, or a new branch. File rollback checks recorded SHA values and cannot promise to undo shell, device or external-service effects.

Use `/find text`, `/next`, `/prev`, `/jump user|failure` and `/latest` to navigate history. Scrolling preserves a message anchor while new output arrives. `Alt+E` edits the current draft with `VISUAL` / `EDITOR`; `/editor` starts an editor draft. Arguments are literal, without shell expansion. Use a blocking editor invocation such as `code --wait`; returning from the editor never sends the draft.

See [shared-host architecture and packaging](../../docs/SHARED-HOST.md). Keep the host CLI bundle's `bin` and `lib` directories together.
