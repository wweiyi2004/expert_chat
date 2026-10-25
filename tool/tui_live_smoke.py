"""Explicit live-model smoke through the packaged GUI's authenticated bridge.

Uses a NEW [TUI测试] session and a fresh temporary workspace only. Does not
change global settings. Exact approved writes/commands are confined to proof.txt.
The normal fake-model/native tests must pass before running this paid smoke.
"""
from pathlib import Path
import argparse
import json
import os
import tempfile
import time
import uuid
import websocket

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "output/tui-build"
DISCOVERY = Path(os.environ["LOCALAPPDATA"]) / "expert-chat/tui/bridge.json"

class Client:
    def __init__(self):
        private = json.loads(DISCOVERY.read_text(encoding="utf-8"))
        assert private["v"] == 1 and 0 < private["port"] < 65536
        self.socket = websocket.create_connection(f"ws://127.0.0.1:{private['port']}/tui", suppress_origin=True, timeout=15)
        self.latest = None
        self.call("hello", {"protocol": 1, "token": private["token"], "client_id": "root-live-smoke-" + uuid.uuid4().hex})

    def call(self, method, params=None):
        ident = uuid.uuid4().hex
        self.socket.send(json.dumps({"v": 1, "id": ident, "method": method, "params": params or {}}))
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            message = json.loads(self.socket.recv())
            if message.get("event") == "snapshot":
                self.latest = message["data"]
            if message.get("id") == ident:
                if not message.get("ok"):
                    error = message.get("error", {})
                    raise RuntimeError(f"{method}: {error.get('code')} {error.get('message')}")
                return message["result"]
        raise TimeoutError(method)

    def close(self):
        self.socket.close()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true", help="Run actual paid model smoke (max 16 observed requests)")
    parser.add_argument("--model-choice")
    args = parser.parse_args()
    client = Client()
    catalog = client.call("models.list")["models"]
    if not args.run:
        print(json.dumps({"models": [{"id": m["id"], "choice": m["choice"]} for m in catalog]}, ensure_ascii=False))
        client.close()
        return
    if args.model_choice:
        model = next(m for m in catalog if m["choice"] == args.model_choice)
    else:
        candidates = [m for m in catalog if "deepseek" in m["id"].lower() and "flash" in m["id"].lower()]
        if not candidates:
            raise RuntimeError("No clearly low-cost DeepSeek Flash model available; choose explicitly after review")
        model = next((m for m in candidates if "v4.1" in m["id"]), candidates[0])
    work = Path(tempfile.mkdtemp(prefix="expert-tui-live-"))
    (work / "proof.txt").write_text("BEFORE\n", encoding="utf-8")
    report = {"workspace": str(work), "model": model["id"], "checks": [], "observed_model_requests": 0, "complete": False}
    session = None
    def save():
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "live-smoke.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    def check(name):
        report["checks"].append(name)
        save()
        print(name, flush=True)
    try:
        registered = client.call("workspace.register", {"path": str(work), "access": "read-write", "confirmed": True})
        workspace = registered.get("workspace", registered)
        session = client.call("session.new", {"title": "[TUI测试] 真实桥接", "workspace_id": workspace["id"]})["session_id"]
        report["session_id"] = session
        snap = client.call("session.open", {"session_id": session})
        assert snap["session"]["workspace_id"] == workspace["id"]
        assert snap["session"]["permission"] == "request"
        check("new isolated workspace and prefixed session, request approval mode")
        effort = "high" if "high" in model["efforts"] else next(iter(model["efforts"]), None)
        client.call("model.set", {"session_id": session, "choice": model["choice"], "thinking": False, "effort": effort})
        prompt = (
            "[TUI测试] 仅验证这个临时工作区。不要派子代理、联网或访问其他目录。"
            "先用 coding_read_file 读取 proof.txt，再用 coding_write_file 将内容改为 AFTER 加一个换行，"
            "最后调用 work_run_command，命令严格为 Get-Content -LiteralPath proof.txt，确认输出 AFTER。"
            "不要运行其他命令；需要批准时等待。完成后用中文简短报告。"
        )
        client.call("message.send", {"session_id": session, "text": prompt})
        check("actual model task submitted through authenticated WebSocket")
        stopped = False
        queued = False
        reconnected = False
        approved = set()
        deadline = time.monotonic() + 420
        while time.monotonic() < deadline:
            snap = client.call("snapshot.get", {"session_id": session})
            state = snap["session"]
            count = state.get("request_count") or 0
            report["observed_model_requests"] = max(report["observed_model_requests"], count)
            save()
            if count >= 16:
                raise RuntimeError("Live smoke request safety limit reached")
            approvals = snap["approvals"]
            if approvals and not stopped:
                client.call("task.stop", {"session_id": session})
                time.sleep(0.4)
                stopped_snapshot = client.call("snapshot.get", {"session_id": session})
                assert stopped_snapshot["session"]["status"] == "stopped"
                check("explicit stop observed before any approved mutation")
                client.call("task.resume", {"session_id": session})
                stopped = True
                continue
            if approvals and not reconnected:
                client.close()
                client = Client()
                reopened = client.call("session.open", {"session_id": session})
                assert reopened["session"]["id"] == session and reopened["approvals"]
                check("disconnect/reconnect retains same task and pending approval")
                reconnected = True
                continue
            if approvals and not queued:
                entry = client.call("queue.add", {"session_id": session, "text": "仅作为撤回测试，不需要执行。"})
                withdrawn = client.call("queue.remove", {"session_id": session, "id": entry["id"]})
                assert "撤回测试" in withdrawn["text"]
                client.call("queue.add", {"session_id": session, "text": "完成后只报告 proof.txt 的最终内容，不添加额外任务。"})
                check("running supplemental request queued, withdrawn, and replaced")
                queued = True
            for approval in approvals:
                if approval["id"] in approved:
                    continue
                values = json.loads(approval["arguments"])
                allowed = False
                if approval["tool"] == "coding_write_file":
                    relative = str(values.get("path", "")).replace("\\", "/").removeprefix("./")
                    allowed = relative == "proof.txt" and values.get("scope", "root") == "root" and values.get("content", "").replace("\r\n", "\n") == "AFTER\n"
                elif approval["tool"] == "work_run_command":
                    allowed = values.get("command", "").strip() == "Get-Content -LiteralPath proof.txt"
                client.call("approval.decide", {"session_id": session, "id": approval["id"], "decision": "once" if allowed else "reject_reason", "reason": "本次测试仅允许指定 proof.txt 写入和精确读取命令。"})
                approved.add(approval["id"])
                if allowed:
                    check("approved exact temporary-workspace operation: " + approval["tool"])
            if state["status"] in {"waiting_acceptance", "accepted"}:
                assert (work / "proof.txt").read_text(encoding="utf-8") == "AFTER\n"
                changes = client.call("changes.list", {"session_id": session})["changes"]
                assert any(c["path"] == "proof.txt" for c in changes)
                change = next(c for c in changes if c["path"] == "proof.txt")
                diff = client.call("changes.diff", {"session_id": session, "id": change["id"]})
                assert any("AFTER" in line for line in diff["diff"])
                check("actual file, changes and text diff agree")
                client.call("task.accept", {"session_id": session})
                final = client.call("snapshot.get", {"session_id": session})
                assert final["session"]["status"] == "accepted"
                client.call("gui.open", {"session_id": session, "page": "session"})
                check("task accepted and same session selected in GUI")
                assert stopped and queued and reconnected
                report["complete"] = True
                save()
                return
            if state["status"] == "failed":
                raise RuntimeError("Backend task failed; inspect new test session")
            time.sleep(0.35)
        raise TimeoutError("Live smoke exceeded seven minutes")
    except Exception as e:
        report["error"] = str(e)
        if session:
            try:
                client.call("task.stop", {"session_id": session})
            except Exception:
                pass
        save()
        raise
    finally:
        client.close()

if __name__ == "__main__":
    main()
