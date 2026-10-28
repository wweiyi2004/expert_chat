"""Isolated shared-host acceptance with a loopback fake model; no paid services."""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from websockets.sync.client import connect


class FakeModel(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    gate = threading.Event()
    entered = threading.Event()
    requests = 0

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        auxiliary = body.get("max_tokens", body.get("max_completion_tokens", 0)) == 64
        if not auxiliary:
            FakeModel.requests += 1
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        def chunk(text, finish=None):
            value = {"id": "synthetic", "model": "gpt-4o-mini", "choices": [{"index": 0,
                     "delta": {"content": text}, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()
        try:
            chunk("TITLE" if auxiliary else "HOST_E2E_STARTED\n")
            if not auxiliary:
                FakeModel.entered.set()
                FakeModel.gate.wait(45)
            chunk("" if auxiliary else "HOST_E2E_FINISHED", "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.close_connection = True


class Rpc:
    def __init__(self, discovery, *, gui=False, client_id=None, features=()):
        info = json.loads((discovery / "bridge.json").read_text())
        self._connection = connect(f"ws://127.0.0.1:{info['port']}/tui", proxy=None, max_size=64 * 1024 * 1024)
        self.socket = self._connection.__enter__()
        self._closed = False
        self.on_event = None
        self.client_id = client_id or str(uuid.uuid4())
        args = {"protocol": 1, "token": info["token"], "client_id": self.client_id}
        if features:
            args["features"] = list(features)
        if gui:
            private = json.loads((discovery / "gui.json").read_text())
            assert private["pid"] == info["pid"]
            args.update(role="gui", gui_token=private["token"])
        hello = self.call("hello", args)
        assert hello["execution_host"] == "dart" and hello["host_version"] == "1"

    def call(self, method, params=None, *, request_id=None, error=None):
        request_id = request_id or str(uuid.uuid4())
        self.socket.send(json.dumps({"v": 1, "id": request_id, "method": method, "params": params or {}}))
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            response = json.loads(self.socket.recv(timeout=max(.1, deadline - time.monotonic())))
            if response.get("id") != request_id:
                if response.get("type") == "event" and self.on_event is not None:
                    self.on_event(response)
                continue
            if error:
                assert not response["ok"] and response["error"]["code"] == error, response
                return response["error"]
            assert response["ok"], response
            return response["result"]
        raise AssertionError(f"No receipt for {method}")

    def close(self):
        if not self._closed:
            self._closed = True
            self._connection.__exit__(None, None, None)


def wait(predicate, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError("Condition did not become true")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    host = bundle / "host/bin/expert-host.exe"
    assert host.is_file() and (bundle / "expert-desktop.exe").is_file()
    scratch = Path(tempfile.mkdtemp(prefix="expert-host-e2e-")).resolve()
    discovery = scratch / "state/host/discovery"
    fake_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeModel)
    threading.Thread(target=fake_server.serve_forever, daemon=True).start()
    clients = []
    process = None
    log = (scratch / "host.log").open("wb")
    checks = []

    def start():
        env = {key: value for key, value in os.environ.items() if not key.startswith("EXPERT_")}
        child = subprocess.Popen([str(host), "--data-dir", str(scratch / "state"),
            "--workspace-cli", str(bundle / "expert-desktop.exe"), "--idle-seconds", "0"],
            cwd=scratch, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        def ready():
            if child.poll() is not None: return True
            try:
                public = json.loads((discovery / "bridge.json").read_text())
                private = json.loads((discovery / "gui.json").read_text())
                return public["pid"] == private["pid"] == child.pid
            except (OSError, ValueError): return False
        wait(ready)
        assert child.poll() is None, "Host exited during startup; inspect isolated log"
        return child

    try:
        process = start()
        contender = subprocess.run([str(host), "--data-dir", str(scratch / "state")], cwd=scratch,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        assert contender.returncode != 0 and process.poll() is None
        checks.append("a second process cannot acquire the same data directory")
        tui = Rpc(discovery); clients.append(tui)
        gui = Rpc(discovery, gui=True); clients.append(gui)
        tui.call("host.preferences.read", error="forbidden")
        tui.call("host.gui.snapshot", error="forbidden")
        checks.append("public client cannot access GUI credentials or raw preferences")
        provider = {"name": "E2E fake", "api_format": "openAiCompatible", "auth_mode": "apiKey",
            "api_key": "SYNTHETIC_HOST_E2E_SECRET", "base_url": f"http://127.0.0.1:{fake_server.server_port}/v1",
            "models": ["gpt-4o-mini"], "chat_model": "gpt-4o-mini", "enabled": True}
        saved = tui.call("provider.save", provider, request_id="save-once")
        replay = tui.call("provider.save", provider, request_id="save-once")
        assert replay["id"] == saved["id"]
        project = scratch / "project"; project.mkdir()
        workspace = tui.call("workspace.register", {"path": str(project), "access": "read-write", "confirmed": True})
        workspace = workspace.get("workspace", workspace)
        session = tui.call("session.new", {"workspace_id": workspace["id"], "title": "E2E task"})["session_id"]
        tui.call("session.open", {"session_id": session})
        models = tui.call("models.list")["models"]
        choice = next(m["choice"] for m in models if m["id"] == "gpt-4o-mini")
        tui.call("model.set", {"session_id": session, "choice": choice, "thinking": False, "effort": "high"})
        tui.call("message.send", {"session_id": session, "text": "HOST_E2E_HOLD, reply only; no tools needed"})
        assert FakeModel.entered.wait(20)
        public = tui.call("snapshot.get", {"session_id": session})
        assert "SYNTHETIC_HOST_E2E_SECRET" not in json.dumps(public)
        gui.call("host.loadSession", {"session_id": session, "selection_revision": 1})
        view = gui.call("host.gui.snapshot", {"session_id": session, "chat_cursor": 0, "known_revision": -1})
        assert view["chat_patch"]["visible"] == session
        tui.call("host.shutdown", {"confirmed": True}, error="busy")
        client_id = tui.client_id
        tui.close(); gui.close()
        assert process.poll() is None
        observer = Rpc(discovery, client_id=client_id); clients.append(observer)
        assert observer.call("snapshot.get", {"session_id": session})["session"]["status"] in {"running", "retrying"}
        FakeModel.gate.set()
        def completed():
            snapshot = observer.call("snapshot.get", {"session_id": session})
            return snapshot if any("HOST_E2E_FINISHED" in m.get("text", "") for m in snapshot["messages"]) else None
        wait(completed)
        wait(lambda: observer.call("snapshot.get", {"session_id": session})["session"]["status"] not in {"running", "retrying", "approval"})
        assert FakeModel.requests == 1
        checks.append("one host task survives both clients disconnecting and is visible after reconnect")
        observer.call("host.shutdown", {"confirmed": True})
        process.wait(timeout=30)
        observer.close()
        process = start()
        restored = Rpc(discovery, client_id=client_id); clients.append(restored)
        restored.call("provider.save", provider, request_id="save-once", error="unknown_result")
        persisted = restored.call("snapshot.get", {"session_id": session})
        assert any("HOST_E2E_FINISHED" in m.get("text", "") for m in persisted["messages"])
        assert FakeModel.requests == 1
        checks.append("restart retains shared history and refuses to replay a prior mutation")
        FakeModel.entered.clear(); FakeModel.gate.clear()
        crash_session = restored.call("session.new", {"workspace_id": workspace["id"], "title": "Crash fixture"})["session_id"]
        restored.call("session.open", {"session_id": crash_session})
        restored.call("model.set", {"session_id": crash_session, "choice": choice, "thinking": False, "effort": "high"})
        restored.call("message.send", {"session_id": crash_session, "text": "HOST_E2E_CRASH, synthetic interruption"})
        assert FakeModel.entered.wait(20)
        requests_before_crash = FakeModel.requests
        process.kill(); process.wait(timeout=10); restored.close(); FakeModel.gate.set()
        process = start()
        restored = Rpc(discovery, client_id=client_id); clients.append(restored)
        interrupted = restored.call("snapshot.get", {"session_id": crash_session})
        assert interrupted["session"]["status"] == "stopped", interrupted["session"]
        assert any("HOST_E2E_CRASH" in m.get("text", "") for m in interrupted["messages"])
        time.sleep(1)
        assert FakeModel.requests == requests_before_crash
        checks.append("process death preserves an interrupted task and restart does not call its model again")
        restored.call("host.shutdown", {"confirmed": True}); process.wait(timeout=30)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({"passed": True, "checks": checks, "paid_requests": 0,
            "fake_task_requests": FakeModel.requests}, ensure_ascii=False, indent=2), encoding="utf-8")
    finally:
        FakeModel.gate.set()
        for client in clients:
            try: client.close()
            except Exception: pass
        if process is not None and process.poll() is None:
            process.terminate(); process.wait(timeout=15)
        fake_server.shutdown(); fake_server.server_close(); log.close()
        # Only this freshly-created isolated profile may be removed.
        if args.report.exists():
            assert scratch.parent == Path(tempfile.gettempdir()).resolve() and scratch.name.startswith("expert-host-e2e-")
            shutil.rmtree(scratch)
        else:
            print(f"Isolated failure evidence retained at {scratch}")


if __name__ == "__main__":
    main()
