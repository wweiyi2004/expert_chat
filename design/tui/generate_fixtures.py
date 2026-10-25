"""Deterministic protocol examples, shared by Rust and Dart contract tests."""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).parent
SNAPSHOT = {
    "session": {"id": "fixture-task", "title": "自适应图片预览", "status": "running",
        "phase": "运行检查", "round": 4, "round_limit": 24, "elapsed_ms": 102000,
        "mode": "work", "permission": "request", "model": "GPT-6 Sol",
        "model_choice": "fixture:gpt", "thinking": True, "effort": "high",
        "workspace_id": "fixture-workspace", "workspace_label": "image-lab",
        "workspace_path": "~/code/image-lab", "branch": "preview-fix",
        "context_percent": 38, "error": None},
    "startup": {"version": "3.8.1", "workspace": "image-lab", "workspace_path": "~/code/image-lab",
        "branch": "main", "dirty_count": 3, "contexts": ["AGENTS.md", "MCP 2 个", "记忆 14 条"], "issues": []},
    "messages": [
        {"id": "user-1", "role": "user", "text": "让 SVG 预览按窗口大小等比例缩放，保留源码编辑和手动缩放。", "thinking": "", "attachments": []},
        {"id": "assistant-1", "role": "assistant", "text": "我会检查预览容器，调整缩放逻辑，再验证窄窗口和图片比例。", "thinking": "", "attachments": []}],
    "steps": [], "approvals": [], "questions": [], "changes": [], "agents": [], "queued": [],
    "models": [{"choice": "fixture:gpt", "id": "GPT-6 Sol", "source_id": "official", "source": "官方订阅",
        "efforts": ["low", "medium", "high", "xhigh", "max"], "thinking_supported": True},
        {"choice": "fixture:ds", "id": "DeepSeek V4.1 Flash", "source_id": "deepseek", "source": "DeepSeek API",
        "efforts": ["low", "medium", "high"], "thinking_supported": True}],
    "workspaces": [{"id": "fixture-workspace", "name": "image-lab", "path": "~/code/image-lab", "access": "read-write", "remote": False}],
    "sessions": [{"id": "fixture-task", "title": "自适应图片预览", "status": "running", "workspace_id": "fixture-workspace", "updated_at": "2026-10-26T00:00:00Z"}]
}
for i, (verb, obj, status, added, removed) in enumerate([
    ("读取", "lib/preview.dart", "done", 0, 0),
    ("编辑", "lib/preview.dart", "done", 18, 6),
    ("新建", "test/preview_test.dart", "done", 24, 0),
    ("运行", "flutter test test/preview_test.dart", "running", 0, 0),
]):
    SNAPSHOT["steps"].append({"id": f"step-{i}", "message_id": "assistant-1", "round_id": "round-4",
        "verb": verb, "object": obj, "status": status, "tail": ["00:08 +3: preview scales to container", "00:11 +4: keeps manual zoom when resized"] if status == "running" else [],
        "elapsed_ms": 12000 if status == "running" else 1000, "exit_code": None,
        "added": added, "removed": removed, "detail": ""})

CHANGES = [
    {"id": "change-1", "path": "lib/preview.dart", "kind": "M", "added": 18, "removed": 6,
     "diff": ["@@ -38,1 +38,4 @@", "- final scale = size.width / canvas.width;", "+ final scale = min(", "+   size.width / canvas.width,", "+   size.height / canvas.height);"],
     "summary": "自适应比例与手动缩放", "round_id": "round-4", "message_id": "assistant-1"},
    {"id": "change-2", "path": "test/preview_test.dart", "kind": "A", "added": 24, "removed": 0,
     "diff": ["@@ -0,0 +1,2 @@", "+ test('preview scales to container', () {", "+ });"],
     "summary": "窗口尺寸和比例回归", "round_id": "round-4", "message_id": "assistant-1"}]
AGENTS = [
    {"id": "root", "parent_id": None, "name": "主代理", "model": "GPT-6 Sol", "status": "running", "activity": "统筹任务", "elapsed_ms": 102000, "output": ""},
    {"id": "code", "parent_id": "root", "name": "代码实现", "model": "GPT-6 Sol mini", "status": "completed", "activity": "修改 1 个文件", "elapsed_ms": 38000, "output": "已完成自适应比例。"},
    {"id": "test", "parent_id": "root", "name": "回归检查", "model": "DeepSeek V4.1", "status": "running", "activity": "检查布局与图片比例", "elapsed_ms": 12000, "output": ""}]

def event(name, data, seq=1):
    return {"v": 1, "type": "event", "seq": seq, "session_id": "fixture-task", "event": name, "data": data}

fixtures = ROOT / "fixtures"
fixtures.mkdir(exist_ok=True)
for scene in ["welcome", "running", "approval", "waiting_acceptance", "accepted", "failed", "retrying", "stopped", "agents", "first_run", "default_workspace", "startup_error", "resume", "prompt"]:
    state = copy.deepcopy(SNAPSHOT)
    if scene in ("welcome", "first_run", "default_workspace", "startup_error"):
        state["session"]["status"] = "idle"
        state["messages"] = []
        state["steps"] = []
    elif scene not in ("agents", "resume", "prompt"):
        state["session"]["status"] = scene
    if scene == "approval":
        state["steps"][-1].update(status="approval", tail=[], elapsed_ms=0)
        state["approvals"] = [{"id": "approval-1", "tool": "work_run_command", "arguments": '{"command":"flutter test test/preview_test.dart"}', "target": "~/image-lab", "reason": "验证缩放回归", "diff": []}]
    if scene in ("waiting_acceptance", "accepted"):
        state["changes"] = copy.deepcopy(CHANGES)
        state["steps"][-1].update(status="done", tail=[], exit_code=0)
        state["messages"][-1]["text"] = "已完成。预览改为按容器宽高的较小比例缩放；手动缩放仍然优先。"
    if scene == "failed":
        state["steps"][-1].update(status="failed", exit_code=1, tail=["Expected: scale <= 1.0", "Actual: 1.25", "Assertion failed: preview fits viewport"])
        state["session"]["error"] = "检查失败，需要修正缩放比例。"
    if scene == "stopped":
        state["steps"][-1]["status"] = "stopped"
        state["changes"] = copy.deepcopy(CHANGES)
    if scene == "agents":
        state["agents"] = copy.deepcopy(AGENTS)
    if scene == "first_run":
        state["models"] = []
        state["session"]["model"] = ""
    if scene == "default_workspace":
        state["startup"].update(workspace="默认工作区", workspace_path="~/Documents/Expert", branch="", dirty_count=0)
    if scene == "startup_error":
        state["startup"]["issues"] = ["playwright 启动失败 · /mcp 查看"]
    events = [event("snapshot", state)]
    if scene == "retrying":
        events.append(event("request.retry", {"code": "429", "message": "速率限制", "attempt": 2, "max_attempts": 5, "retry_after_ms": 8000}, 2))
    (fixtures / f"{scene}.jsonl").write_text("\n".join(json.dumps(e, ensure_ascii=False) for e in events) + "\n", encoding="utf-8")

obj = {"type": "object"}
schema = {"$schema": "https://json-schema.org/draft/2020-12/schema", "title": "Expert TUI Bridge v1",
    "oneOf": [{"$ref": "#/$defs/request"}, {"$ref": "#/$defs/response"}, {"$ref": "#/$defs/event"}], "$defs": {}}
def envelope(properties, required):
    return {"type": "object", "properties": {"v": {"const": 1}, **properties}, "required": ["v", *required], "additionalProperties": False}
schema["$defs"]["request"] = envelope({"id": {"type": "string", "minLength": 1, "maxLength": 128}, "method": {"type": "string", "minLength": 1}, "params": obj}, ["id", "method", "params"])
schema["$defs"]["response"] = envelope({"id": {"type": "string"}, "ok": {"type": "boolean"}, "result": obj,
    "error": {"type": "object", "properties": {"code": {"type": "string"}, "message": {"type": "string"}, "retryable": {"type": "boolean"}}, "required": ["code", "message", "retryable"]}}, ["id", "ok"])
schema["$defs"]["response"]["allOf"] = [{"if": {"properties": {"ok": {"const": True}}}, "then": {"required": ["result"], "not": {"required": ["error"]}}, "else": {"required": ["error"], "not": {"required": ["result"]}}}]
event_names = ["snapshot", "round.started", "round.ended", "assistant.delta", "thinking.started", "thinking.ended", "step.started", "step.updated", "step.ended", "agent.updated", "approval.requested", "changes.updated", "request.retry", "request.error", "context.updated"]
schema["$defs"]["event"] = envelope({"type": {"const": "event"}, "seq": {"type": "integer", "minimum": 1}, "session_id": {"type": ["string", "null"]}, "event": {"enum": event_names}, "data": obj}, ["type", "seq", "session_id", "event", "data"])
schema["$defs"]["snapshot"] = {"type": "object", "properties": {"session": {"type": ["object", "null"]}, "startup": obj,
    **{key: {"type": "array", "items": obj} for key in ["messages", "steps", "approvals", "questions", "changes", "agents", "queued", "models", "workspaces", "sessions"]}}, "required": list(SNAPSHOT)}
schema["$defs"]["event"]["allOf"] = [{"if": {"properties": {"event": {"const": "snapshot"}}}, "then": {"properties": {"data": {"$ref": "#/$defs/snapshot"}}}}]
(ROOT / "protocol.schema.json").write_text(json.dumps(schema, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"Generated {len(list(fixtures.glob('*.jsonl')))} fixture streams and protocol schema")
