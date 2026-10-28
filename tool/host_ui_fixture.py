"""Run a local fake-model fixture for inspecting the candidate GUI and TUI."""
import argparse
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import uuid
from host_e2e import Rpc, wait


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        title = request.get("max_tokens", request.get("max_completion_tokens", 0)) == 64
        text = "界面验收" if title else (
            "这是本地假模型的界面验收样例。\n\n"
            "1. 读取现有文件并核对任务范围。\n2. 完成修改，保留已有会话。\n3. 统一验证后检查结果。\n\n"
            "```dart\nfinal message = '中文输入与代码';\n```\n\n"
            "| 项目 | 样例状态 |\n| --- | --- |\n| GUI / TUI | 共同查看 |\n| 任务验收 | 单独确认 |\n"
        )
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for offset in range(0, len(text), 15):
            payload = {"choices": [{"index": 0, "delta": {"content": text[offset:offset + 15]}, "finish_reason": None}]}
            self.wfile.write(("data: " + json.dumps(payload) + "\n\n").encode()); self.wfile.flush()
            time.sleep(.025)
        self.wfile.write(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--no-gui", action="store_true")
    args = parser.parse_args(); bundle = args.bundle.resolve(); state_file = args.state.resolve()
    profile = state_file.parent / ("ui-profile-" + uuid.uuid4().hex[:10]); profile.mkdir(parents=True)
    project = profile / "project"; project.mkdir()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {k: v for k, v in os.environ.items() if not k.startswith("EXPERT_")}
    env["EXPERT_HOST_DATA_DIR"] = str(profile / "state")
    env["EXPERT_HOST_DISCOVERY"] = str(profile / "state/host/discovery")
    env["EXPERT_CHAT_HOST"] = str(bundle / "host/bin/expert-host.exe")
    log = (profile / "runtime.log").open("wb")
    host = subprocess.Popen([env["EXPERT_CHAT_HOST"], "--idle-seconds", "0"], env=env,
        cwd=bundle, stdout=log, stderr=log, stdin=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    gui = None; client = None
    try:
        discovery = Path(env["EXPERT_HOST_DISCOVERY"])
        wait(lambda: host.poll() is not None or (discovery / "gui.json").exists())
        assert host.poll() is None
        client = Rpc(discovery)
        client.call("provider.save", {"name": "本地验收模型", "api_format": "openAiCompatible", "auth_mode": "apiKey",
            "api_key": "SYNTHETIC_UI_ONLY", "base_url": f"http://127.0.0.1:{server.server_port}/v1",
            "models": ["gpt-4o-mini"], "chat_model": "gpt-4o-mini", "enabled": True})
        workspace = client.call("workspace.register", {"path": str(project), "access": "read-write", "confirmed": True})
        workspace = workspace.get("workspace", workspace)
        choice = next(m["choice"] for m in client.call("models.list")["models"] if m["id"] == "gpt-4o-mini")
        sessions = []
        for title, plan in [("共同会话验收", False), ("计划审核验收", True)]:
            session = client.call("session.new", {"workspace_id": workspace["id"], "title": title})["session_id"]
            sessions.append(session)
            client.call("session.open", {"session_id": session})
            client.call("model.set", {"session_id": session, "choice": choice, "thinking": False, "effort": "high"})
            if plan: client.call("mode.set", {"session_id": session, "mode": "plan"})
            client.call("message.send", {"session_id": session, "text": "请列出修改计划，展示中文与代码；这是本地合成验收。"})
            wait(lambda: (client.call("snapshot.get", {"session_id": session}).get("plan") is not None) if plan else
                 client.call("snapshot.get", {"session_id": session})["session"]["status"] not in {"running", "retrying"})
        if not args.no_gui:
            gui = subprocess.Popen([str(bundle / "expert_chat.exe")], env=env, cwd=bundle,
                stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        state_file.write_text(json.dumps({"profile": str(profile), "discovery": str(discovery),
            "bundle": str(bundle), "host_pid": host.pid, "gui_pid": gui.pid if gui else None, "sessions": sessions,
            "stop_file": str(profile / "stop")}, ensure_ascii=False, indent=2), encoding="utf-8")
        deadline = time.monotonic() + 1800
        while time.monotonic() < deadline and not (profile / "stop").exists():
            if host.poll() is not None: break
            client.call("ping"); time.sleep(3)
    finally:
        if client is not None:
            for session in locals().get("sessions", []):
                try: client.call("task.stop", {"session_id": session})
                except Exception: pass
            client.close()
        if gui is not None and gui.poll() is None: gui.terminate(); gui.wait(timeout=10)
        if host.poll() is None: host.terminate(); host.wait(timeout=10)
        server.shutdown(); server.server_close(); log.close()


if __name__ == "__main__":
    main()
