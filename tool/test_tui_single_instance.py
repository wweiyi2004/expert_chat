"""Compile and exercise the actual Windows single-instance guard in isolation."""
from pathlib import Path
import ctypes
import json
import queue
import subprocess
import threading
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "output/tui-build/native"
OUT.mkdir(parents=True, exist_ok=True)
VS = Path("C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat")
EXE = OUT / "single_instance_test.exe"
script = OUT / "compile.cmd"
script.write_text(
    f'@echo off\ncall "{VS}" >nul\n'
    f'cl /nologo /EHsc /std:c++17 /W4 /I"{ROOT / "windows/runner"}" '
    f'"{ROOT / "test/native/single_instance_test.cpp"}" '
    f'"{ROOT / "windows/runner/single_instance.cpp"}" '
    f'/Fe:"{EXE}" user32.lib\nexit /b %errorlevel%\n', encoding="utf-8")
subprocess.run(["cmd", "/c", str(script)], cwd=OUT, check=True)
user32 = ctypes.windll.user32
user32.IsWindowVisible.argtypes = [ctypes.c_void_p]
user32.IsWindowVisible.restype = ctypes.c_int
children = []
results = []

def launch(mode, identity, wait=2000, delay=0):
    p = subprocess.Popen([str(EXE), mode, identity, str(wait), str(delay)],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         creationflags=subprocess.CREATE_NO_WINDOW)
    children.append(p)
    lines = queue.Queue()
    def read():
        for line in p.stdout:
            lines.put(line.strip())
    threading.Thread(target=read, daemon=True).start()
    return p, lines

try:
    for delay in (0, 300):
        identity = "com.wweiyi.expert_chat.tui-native-test." + uuid.uuid4().hex
        owner, lines = launch("owner", identity, delay=delay)
        assert lines.get(timeout=5) == "primary"
        if not delay:
            window = int(lines.get(timeout=5))
        second, _ = launch("tui", identity)
        assert second.wait(timeout=8) == 11
        if delay:
            window = int(lines.get(timeout=5))
        assert lines.get(timeout=5) == "tui_enabled_hidden=1"
        assert not user32.IsWindowVisible(window)
        assert owner.poll() is None
        results.append({"case": f"enable existing bridge without showing window, startup delay {delay}ms", "passed": True})
        siblings = [launch("tui", identity)[0] for _ in range(4)]
        assert all(p.wait(timeout=8) == 11 for p in siblings)
        assert owner.poll() is None and not user32.IsWindowVisible(window)
        for _ in siblings:
            assert lines.get(timeout=5) == "tui_enabled_hidden=1"
        results.append({"case": "four simultaneous TUI clients retain one hidden owner", "passed": True})
        regular, _ = launch("secondary", identity)
        assert regular.wait(timeout=8) == 11
        assert lines.get(timeout=5) == "activated"
        assert user32.IsWindowVisible(window)
        results.append({"case": "ordinary GUI launch still restores same window", "passed": True})
    identity = "com.wweiyi.expert_chat.tui-native-test." + uuid.uuid4().hex
    owner, lines = launch("hold", identity)
    assert lines.get(timeout=5) == "primary"
    second, _ = launch("tui", identity, wait=100)
    assert second.wait(timeout=5) == 12
    assert owner.poll() is None
    results.append({"case": "startup timeout never creates a second GUI", "passed": True})
finally:
    for p in children:
        if p.poll() is None:
            p.terminate()
    for p in children:
        p.wait(timeout=5)

report = {"scope": "isolated random identities and synthetic windows; no user GUI touched", "cases": results}
(OUT / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
print(json.dumps(report, indent=2))
