"use client";

import { FormEvent, useState, useSyncExternalStore } from "react";

type TerminalLine = {
  id: number;
  kind: "prompt" | "output" | "muted" | "error" | "success";
  text: string;
};

type AppView = "chat" | "terminal" | "studio" | "settings";

const researchModeStorageKey = "expert-chat-research-mode";
const researchModeListeners = new Set<() => void>();

function readResearchMode() {
  try {
    return window.localStorage.getItem(researchModeStorageKey) === "enabled";
  } catch {
    return false;
  }
}

function subscribeResearchMode(listener: () => void) {
  researchModeListeners.add(listener);
  const onStorage = (event: StorageEvent) => {
    if (event.key === researchModeStorageKey) listener();
  };
  window.addEventListener("storage", onStorage);
  return () => {
    researchModeListeners.delete(listener);
    window.removeEventListener("storage", onStorage);
  };
}

function writeResearchMode(enabled: boolean) {
  try {
    window.localStorage.setItem(
      researchModeStorageKey,
      enabled ? "enabled" : "disabled",
    );
  } catch {
    return false;
  }
  for (const listener of researchModeListeners) listener();
  return true;
}

const initialLines: TerminalLine[] = [
  {
    id: 1,
    kind: "muted",
    text: "Last login: Mon Jul 28 13:42:18 2026 from 10.0.0.24",
  },
  {
    id: 2,
    kind: "prompt",
    text: "research@gpu-lab-01:~/projects/neural-field$ nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv",
  },
  {
    id: 3,
    kind: "output",
    text: "name, memory.used [MiB], memory.total [MiB]",
  },
  {
    id: 4,
    kind: "output",
    text: "NVIDIA RTX 4090, 22794 MiB, 24564 MiB",
  },
  {
    id: 5,
    kind: "prompt",
    text: "research@gpu-lab-01:~/projects/neural-field$ python train.py --config configs/lego.yaml",
  },
  {
    id: 6,
    kind: "output",
    text: "[14:06:31] epoch 42/120  loss 0.0184  psnr 28.71  2.8 it/s",
  },
  {
    id: 7,
    kind: "output",
    text: "[14:06:38] saving checkpoint → runs/lego/checkpoint_0042.pt",
  },
  {
    id: 8,
    kind: "error",
    text: "RuntimeError: CUDA out of memory. Tried to allocate 1.38 GiB",
  },
  {
    id: 9,
    kind: "muted",
    text: "GPU 0 has 1.18 GiB free · process 84213 is using 21.9 GiB",
  },
];

const sessions = [
  {
    name: "train-a",
    status: "运行中",
    detail: "python train.py · 42/120",
    active: true,
  },
  {
    name: "monitor",
    status: "空闲",
    detail: "watch -n 2 nvidia-smi",
    active: false,
  },
  {
    name: "notes",
    status: "已分离",
    detail: "bash · ~/projects",
    active: false,
  },
];

const suggestedCommand =
  "CUDA_VISIBLE_DEVICES=0 python train.py --config configs/lego.yaml --batch-size 4 --gradient-checkpointing";

export default function Home() {
  const researchModeEnabled = useSyncExternalStore(
    subscribeResearchMode,
    readResearchMode,
    () => false,
  );
  const [selectedView, setSelectedView] = useState<AppView | null>(null);
  const requestedView =
    selectedView ?? (researchModeEnabled ? "terminal" : "settings");
  const activeView =
    requestedView === "terminal" && !researchModeEnabled
      ? "settings"
      : requestedView;
  const [mobilePanel, setMobilePanel] = useState<"ai" | "tmux" | null>(null);
  const [lines, setLines] = useState(initialLines);
  const [terminalInput, setTerminalInput] = useState("");
  const [command, setCommand] = useState(suggestedCommand);
  const [editing, setEditing] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [commandStatus, setCommandStatus] = useState<
    "ready" | "running" | "done"
  >("ready");

  function openView(view: AppView) {
    setMobilePanel(null);
    setConfirmOpen(false);
    setSelectedView(view);
  }

  function updateResearchMode(enabled: boolean) {
    if (!writeResearchMode(enabled)) return;
    openView(enabled ? "terminal" : "settings");
  }

  function submitTerminal(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const value = terminalInput.trim();
    if (!value) return;
    const nextId = Date.now();
    setLines((current) => [
      ...current,
      {
        id: nextId,
        kind: "prompt",
        text: `research@gpu-lab-01:~/projects/neural-field$ ${value}`,
      },
      {
        id: nextId + 1,
        kind: "muted",
        text: "原型模式 · 命令未发送到真实服务器",
      },
    ]);
    setTerminalInput("");
  }

  function runSuggestedCommand() {
    setConfirmOpen(false);
    setEditing(false);
    setCommandStatus("running");
    const nextId = Date.now();
    setLines((current) => [
      ...current,
      {
        id: nextId,
        kind: "prompt",
        text: `research@gpu-lab-01:~/projects/neural-field$ ${command}`,
      },
      {
        id: nextId + 1,
        kind: "success",
        text: "[14:09:12] 已启动 · batch_size=4 · gradient_checkpointing=true",
      },
    ]);
    window.setTimeout(() => setCommandStatus("done"), 800);
  }

  return (
    <main className="app-shell">
      {activeView === "terminal" && researchModeEnabled ? (
        <>
          <header className="topbar">
            <div className="brand">
              <span className="brand-mark" aria-hidden="true">
                &gt;_
              </span>
              <div>
                <strong>科研终端</strong>
                <span>Expert Chat</span>
              </div>
            </div>

            <button
              className="host-pill"
              type="button"
              aria-label="查看 SSH 连接"
            >
              <span className="live-dot" />
              <span className="host-copy">
                <strong>gpu-lab-01</strong>
                <small>已连接 · 38 ms</small>
              </span>
              <span className="chevron" aria-hidden="true">
                ⌄
              </span>
            </button>

            <button
              className="icon-button"
              type="button"
              aria-label="打开设置"
              onClick={() => openView("settings")}
            >
              •••
            </button>
          </header>

          <section className="workspace">
        <div className="terminal-column">
          <nav className="session-strip" aria-label="终端会话">
            <button className="session-chip active" type="button">
              <span className="session-status" />
              train-a
              <span className="chip-close" aria-hidden="true">
                ×
              </span>
            </button>
            <button
              className="session-chip"
              type="button"
              onClick={() => setMobilePanel("tmux")}
            >
              monitor
            </button>
            <button
              className="session-add"
              type="button"
              aria-label="新建终端会话"
            >
              +
            </button>
            <div className="session-spacer" />
            <button
              className="tmux-button"
              type="button"
              onClick={() => setMobilePanel("tmux")}
            >
              <span aria-hidden="true">▦</span>
              tmux 3
            </button>
          </nav>

          <div className="terminal-card">
            <div className="terminal-meta">
              <span>~/projects/neural-field</span>
              <span className="secure-label">
                <span aria-hidden="true">◆</span> 端到端 SSH
              </span>
            </div>

            <div className="terminal-output" aria-live="polite">
              {lines.map((line) => (
                <pre key={line.id} className={`terminal-line ${line.kind}`}>
                  {line.text}
                </pre>
              ))}
              <div className="cursor-line" aria-hidden="true">
                <span className="prompt-user">
                  research@gpu-lab-01:~/projects/neural-field$
                </span>
                <span className="cursor-block" />
              </div>
            </div>

            <div className="shortcut-row" aria-label="终端快捷键">
              {["Ctrl", "Esc", "Tab", "|", "~", "↑", "↓", "←", "→"].map(
                (key) => (
                  <button key={key} type="button">
                    {key}
                  </button>
                ),
              )}
            </div>

            <form className="terminal-form" onSubmit={submitTerminal}>
              <span className="terminal-prompt" aria-hidden="true">
                $
              </span>
              <input
                value={terminalInput}
                onChange={(event) => setTerminalInput(event.target.value)}
                placeholder="输入命令…"
                aria-label="终端命令"
                autoComplete="off"
              />
              <button type="submit" aria-label="发送命令">
                ↵
              </button>
            </form>
          </div>

          <button
            className="ai-fab"
            type="button"
            onClick={() => setMobilePanel("ai")}
            aria-label="让 AI 分析终端输出"
          >
            <span aria-hidden="true">✦</span>
            AI 分析
            <b>1</b>
          </button>
        </div>

        <aside
          className={`assistant-pane ${
            mobilePanel === "ai" ? "is-open" : ""
          }`}
          aria-label="AI 科研助手"
        >
          <button
            className="drawer-handle"
            type="button"
            aria-label="收起 AI 助手"
            onClick={() => setMobilePanel(null)}
          >
            <span />
          </button>

          <div className="assistant-header">
            <div>
              <span className="eyebrow">EXPERT CHAT</span>
              <h1>AI 助手</h1>
            </div>
            <div className="context-badge">
              <span aria-hidden="true">◎</span>
              最近 36 行
            </div>
          </div>

          <div className="context-row">
            <button className="context-chip selected" type="button">
              终端输出
            </button>
            <button className="context-chip selected" type="button">
              GPU 状态
            </button>
            <button className="context-chip" type="button">
              环境信息
            </button>
          </div>

          <article className="analysis-card">
            <div className="assistant-avatar" aria-hidden="true">
              ✦
            </div>
            <div>
              <p>
                这次中断来自显存不足，不像显存泄漏。训练已经在第 42
                轮保存检查点，可以降低 batch size 后从检查点继续。
              </p>
              <div className="evidence">
                <span>判断依据</span>
                <code>仅剩 1.18 GiB</code>
                <code>checkpoint_0042.pt</code>
              </div>
            </div>
          </article>

          <article className="command-card">
            <div className="command-heading">
              <div>
                <span className="command-kicker">建议下一步</span>
                <h2>降低批量并开启梯度检查点</h2>
              </div>
              <span className="risk-badge">
                <span aria-hidden="true">●</span> 低风险
              </span>
            </div>

            {editing ? (
              <textarea
                className="command-editor"
                value={command}
                onChange={(event) => setCommand(event.target.value)}
                aria-label="编辑 AI 建议命令"
              />
            ) : (
              <pre className="command-code">{command}</pre>
            )}

            <div className="impact-list">
              <span>
                <b>影响</b> 启动一个新训练进程
              </span>
              <span>
                <b>不会</b> 删除或覆盖现有检查点
              </span>
            </div>

            <div className="command-actions">
              <button
                className="ghost-button"
                type="button"
                onClick={() => {
                  setEditing(false);
                  setCommand(suggestedCommand);
                }}
              >
                拒绝
              </button>
              <button
                className="edit-button"
                type="button"
                onClick={() => setEditing((value) => !value)}
              >
                {editing ? "完成编辑" : "编辑"}
              </button>
              <button
                className="run-button"
                type="button"
                disabled={commandStatus === "running"}
                onClick={() => setConfirmOpen(true)}
              >
                {commandStatus === "running"
                  ? "执行中…"
                  : commandStatus === "done"
                    ? "再次执行"
                    : "确认执行"}
                <span aria-hidden="true">›</span>
              </button>
            </div>
          </article>

          <button className="ask-button" type="button">
            <span aria-hidden="true">✦</span>
            继续询问 AI
            <span aria-hidden="true">⌘K</span>
          </button>

          <p className="privacy-note">
            <span aria-hidden="true">◈</span>
            只发送你选中的终端上下文，密钥与 Token 会在本地过滤
          </p>
        </aside>
          </section>
        </>
      ) : activeView === "settings" ? (
        <section className="settings-page">
          <header className="settings-appbar">
            <div>
              <span className="settings-app-icon" aria-hidden="true">
                ⚙
              </span>
              <strong>设置</strong>
            </div>
            <span className="settings-brand">Expert Chat</span>
          </header>

          <div className="settings-content">
            <div className="settings-heading">
              <span>实验功能</span>
              <h1>让高级能力按需出现</h1>
              <p>默认界面保持简单，只有主动开启的实验功能才会进入主导航。</p>
            </div>

            <article className="research-setting-card">
              <span className="research-setting-icon" aria-hidden="true">
                &gt;_
              </span>
              <div className="research-setting-copy">
                <div>
                  <strong>科研模式</strong>
                  <span>实验性</span>
                </div>
                <p>启用 SSH 终端、tmux 会话和 AI 命令审批。</p>
              </div>
              <button
                className={`setting-switch ${
                  researchModeEnabled ? "is-on" : ""
                }`}
                type="button"
                role="switch"
                aria-label="科研模式"
                aria-checked={researchModeEnabled}
                onClick={() => updateResearchMode(!researchModeEnabled)}
              >
                <span />
              </button>
            </article>

            <div className="setting-note">
              <span aria-hidden="true">◈</span>
              <p>
                关闭时，终端入口不会显示，服务器配置也不会进入普通 AI
                会话。
              </p>
            </div>

            {researchModeEnabled && (
              <button
                className="enter-research-button"
                type="button"
                onClick={() => openView("terminal")}
              >
                进入科研终端
                <span aria-hidden="true">›</span>
              </button>
            )}
          </div>
        </section>
      ) : (
        <section className="placeholder-page">
          <header className="settings-appbar">
            <div>
              <span className="settings-app-icon" aria-hidden="true">
                {activeView === "chat" ? "◌" : "▤"}
              </span>
              <strong>{activeView === "chat" ? "会话" : "创作"}</strong>
            </div>
            <span className="settings-brand">Expert Chat</span>
          </header>
          <div className="placeholder-content">
            <span aria-hidden="true">{activeView === "chat" ? "◌" : "▤"}</span>
            <h1>{activeView === "chat" ? "开始一次新会话" : "继续你的创作"}</h1>
            <p>
              {researchModeEnabled
                ? "科研模式已开启，终端入口现在会出现在底部导航中。"
                : "科研模式未开启，底部导航中不会出现终端入口。"}
            </p>
          </div>
        </section>
      )}

      <nav
        className={`mobile-nav ${
          researchModeEnabled ? "has-research-mode" : ""
        }`}
        aria-label="移动端主导航"
      >
        <button
          className={activeView === "chat" ? "active" : ""}
          type="button"
          onClick={() => openView("chat")}
        >
          <span aria-hidden="true">◌</span>
          会话
        </button>
        {researchModeEnabled && (
          <button
            className={activeView === "terminal" ? "active" : ""}
            type="button"
            onClick={() => openView("terminal")}
          >
            <span aria-hidden="true">&gt;_</span>
            终端
          </button>
        )}
        <button
          className={activeView === "studio" ? "active" : ""}
          type="button"
          onClick={() => openView("studio")}
        >
          <span aria-hidden="true">▤</span>
          创作
        </button>
        <button
          className={activeView === "settings" ? "active" : ""}
          type="button"
          onClick={() => openView("settings")}
        >
          <span aria-hidden="true">⚙</span>
          设置
        </button>
      </nav>

      {researchModeEnabled &&
        activeView === "terminal" &&
        mobilePanel === "tmux" && (
        <div className="sheet-backdrop" role="presentation">
          <section className="tmux-sheet" role="dialog" aria-modal="true">
            <button
              className="drawer-handle"
              type="button"
              aria-label="关闭 tmux 会话"
              onClick={() => setMobilePanel(null)}
            >
              <span />
            </button>
            <div className="sheet-heading">
              <div>
                <span className="eyebrow">SSH 会话</span>
                <h2>tmux 会话</h2>
              </div>
              <button className="new-session-button" type="button">
                + 新建
              </button>
            </div>
            <div className="tmux-list">
              {sessions.map((session) => (
                <button
                  className={`tmux-session ${
                    session.active ? "active" : ""
                  }`}
                  type="button"
                  key={session.name}
                  onClick={() => setMobilePanel(null)}
                >
                  <span
                    className={`tmux-indicator ${
                      session.active ? "running" : ""
                    }`}
                  />
                  <span className="tmux-copy">
                    <strong>{session.name}</strong>
                    <small>{session.detail}</small>
                  </span>
                  <span className="tmux-status">{session.status}</span>
                  <span aria-hidden="true">›</span>
                </button>
              ))}
            </div>
            <p className="tmux-tip">
              断开 SSH 后，tmux 中的训练仍会继续运行。
            </p>
          </section>
        </div>
        )}

      {researchModeEnabled && activeView === "terminal" && confirmOpen && (
        <div className="confirm-backdrop" role="presentation">
          <section
            className="confirm-dialog"
            role="dialog"
            aria-modal="true"
            aria-labelledby="confirm-title"
          >
            <div className="confirm-icon" aria-hidden="true">
              ↗
            </div>
            <span className="eyebrow">通过 SSH 执行</span>
            <h2 id="confirm-title">确认在 gpu-lab-01 执行？</h2>
            <pre>{command}</pre>
            <div className="confirm-facts">
              <span>目录</span>
              <strong>~/projects/neural-field</strong>
              <span>风险</span>
              <strong className="safe-text">低风险 · 不含删除操作</strong>
            </div>
            <div className="confirm-actions">
              <button
                type="button"
                className="ghost-button"
                onClick={() => setConfirmOpen(false)}
              >
                返回检查
              </button>
              <button
                type="button"
                className="run-button"
                onClick={runSuggestedCommand}
              >
                执行命令
              </button>
            </div>
          </section>
        </div>
      )}
    </main>
  );
}
