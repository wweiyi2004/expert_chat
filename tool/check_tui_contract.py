"""Validate shared fixtures and state consistency, independently of either UI."""
from pathlib import Path
import json
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]
DESIGN = ROOT / "design/tui"
schema = json.loads((DESIGN / "protocol.schema.json").read_text(encoding="utf-8"))
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)
scenes = {"welcome", "running", "approval", "waiting_acceptance", "accepted", "failed", "retrying", "stopped", "agents", "first_run", "default_workspace", "startup_error", "resume", "prompt"}
found = {p.stem for p in (DESIGN / "fixtures").glob("*.jsonl")}
assert scenes <= found, scenes - found
checks = []
for path in sorted((DESIGN / "fixtures").glob("*.jsonl")):
    events = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert events and events[0]["event"] == "snapshot", path
    seq = 0
    for event in events:
        validator.validate(event)
        assert event["seq"] > seq, path
        seq = event["seq"]
        if event["event"] != "snapshot":
            continue
        data = event["data"]
        session = data["session"]
        if not session:
            continue
        state = session["status"]
        assert state in {"idle", "running", "approval", "retrying", "waiting_acceptance", "accepted", "stopped", "failed"}
        if state == "approval":
            assert data["approvals"]
            assert all(s["status"] != "running" for s in data["steps"])
            assert all(not s["tail"] for s in data["steps"] if s["status"] == "approval")
        if state in {"accepted", "waiting_acceptance"}:
            assert not data["approvals"]
            assert all(s["status"] == "done" for s in data["steps"])
        if data["changes"]:
            for key in ["added", "removed"]:
                assert sum(c[key] or 0 for c in data["changes"]) == sum(s[key] or 0 for s in data["steps"]), (path, key)
        if state == "failed":
            assert any(s["status"] == "failed" and s["exit_code"] != 0 for s in data["steps"])
        if path.stem == "first_run":
            assert not data["models"]
        checks.append({"scene": path.stem, "status": state, "passed": True})
out = ROOT / "output/tui-build"
out.mkdir(parents=True, exist_ok=True)
(out / "fixture-contract-results.json").write_text(json.dumps(checks, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"{len(checks)} shared snapshots validated; protocol envelopes and task state consistency passed")
