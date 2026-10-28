"""Five-minute shared-host load / idle acceptance with only synthetic streams."""
import argparse
import ctypes
from ctypes import wintypes
import http.server
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import threading
import time
from host_e2e import Rpc, wait

EMITTED = {}
STOP = threading.Event()
STARTED = set()
MARKER = re.compile(r"@([0-7]):(\d+);")


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args): pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        title = body.get("max_tokens", body.get("max_completion_tokens", 0)) == 64
        index = int(re.search(r"STRESS_([0-7])", json.dumps(body)).group(1)) if not title else 0
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        def emit(text, finish=None):
            data = {"choices": [{"index": 0, "delta": {"content": text}, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(data) + "\n\n").encode()); self.wfile.flush()
        try:
            if title: emit("合成负载", "stop")
            else:
                STARTED.add(index); sequence = 0
                while not STOP.is_set():
                    sequence += 1; EMITTED[index, sequence] = time.perf_counter()
                    emit(f"@{index}:{sequence};")
                    STOP.wait(.2)
                emit("END", "stop")
            self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError): pass


def cpu_seconds(process):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    values = [wintypes.FILETIME() for _ in range(4)]
    if not kernel.GetProcessTimes(int(process._handle), *(ctypes.byref(v) for v in values)):
        raise OSError(ctypes.get_last_error())
    return sum((v.dwHighDateTime << 32) | v.dwLowDateTime for v in values[2:]) / 10_000_000


def resident_bytes(process):
    class Counters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("faults", wintypes.DWORD)] + [
            (name, ctypes.c_size_t) for name in ("peak", "working", "pool_peak", "pool", "nonpaged_peak", "nonpaged", "pagefile", "pagefile_peak")]
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
    info = Counters(); info.cb = ctypes.sizeof(info)
    if not psapi.GetProcessMemoryInfo(int(process._handle), ctypes.byref(info), info.cb): raise OSError(ctypes.get_last_error())
    return info.working


def percentile(values):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * .95))] * 1000


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True); parser.add_argument("--duration", type=int, default=300)
    args = parser.parse_args(); bundle = args.bundle.resolve()
    root = Path(tempfile.mkdtemp(prefix="expert-host-load-")).resolve(); project = root / "project"; project.mkdir()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log = (root / "host.log").open("wb")
    env = {k: v for k, v in os.environ.items() if not k.startswith("EXPERT_")}
    process = subprocess.Popen([str(bundle / "host/bin/expert-host.exe"), "--data-dir", str(root / "state"),
        "--workspace-cli", str(bundle / "expert-desktop.exe"), "--idle-seconds", "0"], cwd=root, env=env,
        stdin=subprocess.DEVNULL, stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
    clients = []; sessions = []; report = {"passed": False, "directory": str(root), "platform": platform.platform(), "paid_requests": 0}
    try:
        discovery = root / "state/host/discovery"; wait(lambda: (discovery / "gui.json").exists())
        tui = Rpc(discovery, features=["snapshot.patch"]); gui = Rpc(discovery, gui=True); clients = [tui, gui]
        job = gui.call("settings.call", {"operation": "setTaskBudget", "arguments": {"value": {"workSeconds": 900}}})["job_id"]
        wait(lambda: gui.call("host.operation", {"job_id": job})["done"])
        tui.call("provider.save", {"name": "Synthetic load", "api_format": "openAiCompatible", "auth_mode": "apiKey",
            "api_key": "SYNTHETIC_LOAD", "base_url": f"http://127.0.0.1:{server.server_port}/v1",
            "models": ["gpt-4o-mini"], "chat_model": "gpt-4o-mini", "enabled": True})
        workspace = tui.call("workspace.register", {"path": str(project), "access": "read-write", "confirmed": True})
        workspace = workspace.get("workspace", workspace)
        choice = next(m["choice"] for m in tui.call("models.list")["models"] if m["id"] == "gpt-4o-mini")
        for index in range(8):
            sid = tui.call("session.new", {"workspace_id": workspace["id"], "title": f"Load {index}"})["session_id"]
            sessions.append(sid)
            tui.call("model.set", {"session_id": sid, "choice": choice, "thinking": False, "effort": "high"})
            tui.call("message.send", {"session_id": sid, "text": f"STRESS_{index}: output the synthetic stream; do not call tools"})
        wait(lambda: len(STARTED) == 8)
        snapshot = tui.call("session.open", {"session_id": sessions[0]}); public_cursor = 0
        gui.call("host.loadSession", {"session_id": sessions[0], "selection_revision": 1})
        samples = {"tui": [], "gui": []}; seen = {"tui": set(), "gui": set()}
        started = time.perf_counter(); bytes_received = 0
        def observe(text, client):
            for index, sequence in MARKER.findall(text):
                key = (int(index), int(sequence))
                if key in seen[client] or key not in EMITTED: continue
                seen[client].add(key)
                if EMITTED[key] > started + 5: samples[client].append(time.perf_counter() - EMITTED[key])
        def event(message):
            nonlocal snapshot, public_cursor, bytes_received
            bytes_received += len(json.dumps(message))
            if message.get("session_id") not in (None, sessions[0]): return
            if message["event"] == "snapshot":
                snapshot = message["data"]; public_cursor = message.get("cursor", 0)
                for value in snapshot.get("messages", []): observe(value.get("text", ""), "tui")
            elif message["event"] == "snapshot.patch":
                patch = message["data"]
                if not public_cursor: return
                assert patch["base"] == public_cursor, "TUI patch gap"
                public_cursor = patch["cursor"]
                for value in patch["arrays"].get("messages", {}).get("updates", []):
                    observe(value.get("replace", {}).get("text", "") + value.get("fields", {}).get("text", "") + value.get("append", {}).get("text", ""), "tui")
            elif message["event"] == "request.error": raise AssertionError(message["data"])
        tui.on_event = event
        revision = -1; settings = -1; cursor = 0; runtime = {}; last_ping = started; memory = []
        def cycle(idle=False):
            nonlocal revision, settings, cursor, runtime, last_ping, bytes_received
            refresh = not idle
            if idle:
                try:
                    message = json.loads(gui.socket.recv(timeout=.05))
                    refresh = message.get("event") == "host.changed"
                except TimeoutError: pass
            result = gui.call("host.gui.snapshot", {"known_revision": revision, "known_settings_revision": settings,
                "known_runtime_versions": runtime, "chat_cursor": cursor, "session_id": sessions[0]}) if refresh else {"unchanged": True}
            bytes_received += len(json.dumps(result))
            if not result.get("unchanged"):
                revision = result["revision"]; settings = result["settings_revision"]; runtime = result["runtime_versions"]
                patch = result["chat_patch"]; cursor = patch["cursor"]
                for value in patch["messages"]:
                    observe(value.get("replace", {}).get("content", "") + value.get("fields", {}).get("content", "") + value.get("append", {}).get("content", ""), "gui")
            try: event(json.loads(tui.socket.recv(timeout=.025)))
            except TimeoutError: pass
            if time.perf_counter() - last_ping > 10:
                tui.call("ping"); gui.call("ping"); last_ping = time.perf_counter()
        next_sample = started
        while time.perf_counter() - started < args.duration:
            cycle()
            if time.perf_counter() >= next_sample:
                memory.append(resident_bytes(process)); next_sample += 10
                print(f"load {int(time.perf_counter()-started)}s / {args.duration}s; samples {len(samples['tui'])}/{len(samples['gui'])}", flush=True)
        STOP.set()
        for sid in sessions:
            wait(lambda sid=sid: tui.call("snapshot.get", {"session_id": sid})["session"]["status"] not in {"running", "retrying", "approval"})
        tui.call("session.open", {"session_id": sessions[0]}); public_cursor = 0
        warmup = time.perf_counter()
        while time.perf_counter() - warmup < 30: cycle(idle=True)
        before = cpu_seconds(process); idle_start = time.perf_counter()
        while time.perf_counter() - idle_start < 60: cycle(idle=True)
        idle = (cpu_seconds(process) - before) / (time.perf_counter() - idle_start) * 100
        report.update(duration_seconds=args.duration, tasks=8, events_per_second=40,
            tui_p95_ms=percentile(samples["tui"]), gui_p95_ms=percentile(samples["gui"]),
            visible_session_samples={k: len(v) for k, v in samples.items()},
            idle_single_core_percent=idle, peak_resident_bytes=max(memory), resident_samples=memory,
            received_bytes=bytes_received, measurement="Host event delivery to two client protocol reducers; native drawing measured separately")
        report["passed"] = all(percentile(v) <= 300 and len(v) > (args.duration-5)*4 for v in samples.values()) and idle < 1
        gui.call("host.shutdown", {"confirmed": True}); process.wait(timeout=30)
        assert report["passed"], report
    finally:
        STOP.set()
        for client in clients:
            try: client.close()
            except Exception: pass
        if process.poll() is None: process.terminate(); process.wait(timeout=10)
        server.shutdown(); server.server_close(); log.close()
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__": main()
