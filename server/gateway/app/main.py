from __future__ import annotations

import asyncio
import json
import os
import re
import sqlite3
import time
import uuid
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from docx import Document
from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, Request, UploadFile
from fastapi.responses import JSONResponse
from openpyxl import load_workbook
from pydantic import BaseModel, Field
from pptx import Presentation
from pypdf import PdfReader

from doc_edit.app.main import (
    CONVERSIONS as DOCUMENT_CONVERSIONS,
    FORMATS as DOCUMENT_FORMATS,
    router as document_router,
)

from .module_registry import (
    GatewayCapability,
    GatewayModule,
    GatewayModuleRegistry,
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


DATA_DIR = Path(os.getenv("GATEWAY_DATA_DIR", "./data")).resolve()
UPLOAD_DIR = DATA_DIR / "uploads"
DB_PATH = DATA_DIR / "gateway.sqlite3"
API_TOKEN = os.getenv("GATEWAY_API_TOKEN", "").strip()
LLM_BASE_URL = os.getenv("LLM_BASE_URL", "").strip().rstrip("/")
LLM_API_KEY = os.getenv("LLM_API_KEY", "").strip()
LLM_MODEL = os.getenv("LLM_MODEL", "").strip()
MAX_FILE_BYTES = int(os.getenv("GATEWAY_MAX_FILE_MB", "50")) * 1024 * 1024
CHUNK_CHARS = max(2000, int(os.getenv("GATEWAY_CHUNK_CHARS", "12000")))
CONCURRENCY = max(1, int(os.getenv("GATEWAY_CONCURRENCY", "2")))

MODULES = GatewayModuleRegistry(
    (
        GatewayModule(
            name="long_tasks",
            capabilities=(
                GatewayCapability(
                    id="long_tasks",
                    metadata={
                        "file_limit_bytes": MAX_FILE_BYTES,
                        "durable_events": True,
                        "idempotent_create": True,
                    },
                ),
            ),
        ),
        GatewayModule(
            name="documents",
            router=document_router,
            capabilities=(
                GatewayCapability(
                    id="document_edit",
                    metadata={
                        "formats": DOCUMENT_FORMATS,
                        "patch_schema_versions": [1],
                    },
                ),
                GatewayCapability(
                    id="document_convert",
                    metadata={
                        "conversions": {
                            key: sorted(value)
                            for key, value in DOCUMENT_CONVERSIONS.items()
                        },
                    },
                ),
            ),
        ),
    )
)

_running: dict[str, asyncio.Task[None]] = {}
_semaphore = asyncio.Semaphore(CONCURRENCY)
_shutting_down = False


def _connect() -> sqlite3.Connection:
    connection = sqlite3.connect(DB_PATH, timeout=30)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA foreign_keys=ON")
    return connection


@contextmanager
def _db():
    connection = _connect()
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def _init_db() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    with _db() as db:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS files (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                path TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                client_request_id TEXT,
                status TEXT NOT NULL,
                prompt TEXT NOT NULL,
                instructions TEXT NOT NULL,
                messages_json TEXT NOT NULL,
                file_ids_json TEXT NOT NULL,
                model TEXT NOT NULL,
                output_text TEXT NOT NULL DEFAULT '',
                progress REAL NOT NULL DEFAULT 0,
                detail TEXT,
                error TEXT,
                cancel_requested INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL,
                type TEXT NOT NULL,
                data_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_events_task_id_id
                ON events(task_id, id);
            """
        )
        columns = {
            row["name"] for row in db.execute("PRAGMA table_info(tasks)").fetchall()
        }
        if "client_request_id" not in columns:
            db.execute("ALTER TABLE tasks ADD COLUMN client_request_id TEXT")
        db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_client_request_id "
            "ON tasks(client_request_id) WHERE client_request_id IS NOT NULL"
        )


def _auth(authorization: str | None = Header(default=None)) -> None:
    if not API_TOKEN:
        return
    if authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="Gateway Token 无效。")


class InputMessage(BaseModel):
    role: str
    text: str


class CreateTaskRequest(BaseModel):
    prompt: str = Field(min_length=1)
    file_ids: list[str] = Field(min_length=1)
    instructions: str = ""
    messages: list[InputMessage] = Field(default_factory=list)
    model: str | None = None
    client_request_id: str | None = Field(default=None, max_length=200)


def _task_row(task_id: str) -> sqlite3.Row:
    with _db() as db:
        row = db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="任务不存在。")
    return row


def _task_json(row: sqlite3.Row) -> dict[str, Any]:
    with _db() as db:
        latest = db.execute(
            "SELECT COALESCE(MAX(id), 0) AS id FROM events WHERE task_id = ?",
            (row["id"],),
        ).fetchone()["id"]
    return {
        "id": row["id"],
        "status": row["status"],
        "output_text": row["output_text"],
        "progress": row["progress"],
        "detail": row["detail"],
        "error": row["error"],
        "last_event_id": latest,
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def _event(task_id: str, event_type: str, data: dict[str, Any]) -> int:
    with _db() as db:
        cursor = db.execute(
            "INSERT INTO events(task_id, type, data_json, created_at) VALUES (?, ?, ?, ?)",
            (task_id, event_type, json.dumps(data, ensure_ascii=False), _now()),
        )
        return int(cursor.lastrowid)


def _update_task(task_id: str, **values: Any) -> None:
    if not values:
        return
    values["updated_at"] = _now()
    columns = ", ".join(f"{key} = ?" for key in values)
    with _db() as db:
        db.execute(
            f"UPDATE tasks SET {columns} WHERE id = ?",  # noqa: S608; keys are internal constants
            (*values.values(), task_id),
        )


def _set_progress(task_id: str, progress: float, detail: str) -> None:
    bounded = max(0.0, min(1.0, progress))
    _update_task(task_id, status="running", progress=bounded, detail=detail)
    _event(task_id, "progress", {"progress": bounded, "detail": detail})


def _cancel_requested(task_id: str) -> bool:
    with _db() as db:
        row = db.execute(
            "SELECT cancel_requested FROM tasks WHERE id = ?", (task_id,)
        ).fetchone()
    return row is None or bool(row["cancel_requested"])


def _read_text_file(path: Path) -> str:
    raw = path.read_bytes()
    for encoding in ("utf-8-sig", "utf-8", "gb18030", "latin-1"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def _extract_text(path: Path, original_name: str) -> str:
    suffix = Path(original_name).suffix.lower()
    if suffix == ".pdf":
        return "\n\n".join(page.extract_text() or "" for page in PdfReader(path).pages)
    if suffix == ".docx":
        document = Document(path)
        blocks = [paragraph.text for paragraph in document.paragraphs]
        for table in document.tables:
            blocks.extend("\t".join(cell.text for cell in row.cells) for row in table.rows)
        return "\n".join(blocks)
    if suffix == ".xlsx":
        workbook = load_workbook(path, read_only=True, data_only=True)
        blocks: list[str] = []
        try:
            for sheet in workbook.worksheets:
                blocks.append(f"## Sheet: {sheet.title}")
                for row in sheet.iter_rows(values_only=True):
                    blocks.append("\t".join("" if value is None else str(value) for value in row))
        finally:
            workbook.close()
        return "\n".join(blocks)
    if suffix == ".pptx":
        deck = Presentation(path)
        blocks = []
        for index, slide in enumerate(deck.slides, start=1):
            blocks.append(f"## Slide {index}")
            for shape in slide.shapes:
                if hasattr(shape, "text") and shape.text:
                    blocks.append(shape.text)
        return "\n".join(blocks)
    return _read_text_file(path)


def _chunks(text: str, size: int = CHUNK_CHARS) -> list[str]:
    normalized = re.sub(r"\r\n?", "\n", text).strip()
    if not normalized:
        return []
    chunks: list[str] = []
    cursor = 0
    while cursor < len(normalized):
        end = min(len(normalized), cursor + size)
        if end < len(normalized):
            boundary = normalized.rfind("\n", cursor + size // 2, end)
            if boundary > cursor:
                end = boundary
        chunks.append(normalized[cursor:end].strip())
        cursor = end
        while cursor < len(normalized) and normalized[cursor] == "\n":
            cursor += 1
    return [chunk for chunk in chunks if chunk]


def _chat_url() -> str:
    if not LLM_BASE_URL:
        raise RuntimeError("服务器未配置 LLM_BASE_URL。")
    if LLM_BASE_URL.endswith("/chat/completions"):
        return LLM_BASE_URL
    return f"{LLM_BASE_URL}/chat/completions"


def _headers() -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if LLM_API_KEY:
        headers["Authorization"] = f"Bearer {LLM_API_KEY}"
    return headers


async def _completion(model: str, messages: list[dict[str, str]]) -> str:
    async with httpx.AsyncClient(timeout=httpx.Timeout(300.0, connect=30.0)) as client:
        response = await client.post(
            _chat_url(),
            headers=_headers(),
            json={"model": model, "messages": messages, "stream": False},
        )
        response.raise_for_status()
        payload = response.json()
    try:
        return str(payload["choices"][0]["message"]["content"] or "").strip()
    except (KeyError, IndexError, TypeError) as error:
        raise RuntimeError("上游模型没有返回可识别的文本。") from error


async def _stream_completion(
    task_id: str, model: str, messages: list[dict[str, str]]
) -> str:
    output = ""
    pending = ""
    last_flush = time.monotonic()
    async with httpx.AsyncClient(timeout=httpx.Timeout(600.0, connect=30.0)) as client:
        async with client.stream(
            "POST",
            _chat_url(),
            headers=_headers(),
            json={"model": model, "messages": messages, "stream": True},
        ) as response:
            response.raise_for_status()
            async for line in response.aiter_lines():
                if _cancel_requested(task_id):
                    raise asyncio.CancelledError
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if not data or data == "[DONE]":
                    continue
                try:
                    payload = json.loads(data)
                    delta = payload["choices"][0]["delta"].get("content") or ""
                except (json.JSONDecodeError, KeyError, IndexError, TypeError):
                    continue
                if not delta:
                    continue
                output += delta
                pending += delta
                now = time.monotonic()
                if len(pending) >= 256 or now - last_flush >= 0.5:
                    _update_task(task_id, output_text=output, progress=0.98, detail="正在生成结果")
                    _event(task_id, "output_delta", {"delta": pending})
                    pending = ""
                    last_flush = now
    if pending:
        _update_task(task_id, output_text=output, progress=0.99, detail="正在保存结果")
        _event(task_id, "output_delta", {"delta": pending})
    return output.strip()


async def _reduce_material(
    task_id: str,
    model: str,
    prompt: str,
    material: list[str],
) -> str:
    """Hierarchically reduce map outputs so extremely long files stay bounded."""
    round_number = 0
    target_chars = CHUNK_CHARS * 4
    current = material
    while sum(len(item) for item in current) > target_chars:
        round_number += 1
        groups: list[list[str]] = []
        group: list[str] = []
        group_chars = 0
        for item in current:
            if group and group_chars + len(item) > CHUNK_CHARS * 3:
                groups.append(group)
                group = []
                group_chars = 0
            group.append(item)
            group_chars += len(item)
        if group:
            groups.append(group)

        reduced: list[str] = []
        for index, batch in enumerate(groups):
            if _cancel_requested(task_id):
                raise asyncio.CancelledError
            progress = 0.76 + 0.14 * (index + 1) / max(1, len(groups))
            _set_progress(
                task_id,
                progress,
                f"正在合并超长文档材料 {index + 1}/{len(groups)}",
            )
            reduced.append(
                await _completion(
                    model,
                    [
                        {
                            "role": "system",
                            "content": "合并下列文档阅读笔记。去重但保留与用户目标有关的事实、数字、证据出处、冲突和不确定性。",
                        },
                        {
                            "role": "user",
                            "content": f"用户目标：{prompt}\n\n" + "\n\n".join(batch),
                        },
                    ],
                )
            )
        if len(reduced) >= len(current):
            return "\n\n".join(reduced)[:target_chars]
        current = reduced
    return "\n\n".join(current)


def _history_messages(row: sqlite3.Row) -> list[dict[str, str]]:
    history: list[dict[str, str]] = []
    for item in json.loads(row["messages_json"]):
        role = item.get("role")
        text = str(item.get("text") or "").strip()
        if role in {"user", "assistant"} and text:
            history.append({"role": role, "content": text})
    return history[-12:]


async def _process_task(task_id: str) -> None:
    async with _semaphore:
        try:
            row = _task_row(task_id)
            if _cancel_requested(task_id):
                raise asyncio.CancelledError
            model = row["model"] or LLM_MODEL
            if not model:
                raise RuntimeError("服务器未配置 LLM_MODEL，任务也没有指定 model。")

            _set_progress(task_id, 0.03, "正在解析文件")
            file_ids: list[str] = json.loads(row["file_ids_json"])
            documents: list[tuple[str, str]] = []
            with _db() as db:
                for file_id in file_ids:
                    file_row = db.execute(
                        "SELECT * FROM files WHERE id = ?", (file_id,)
                    ).fetchone()
                    if file_row is None:
                        raise RuntimeError(f"文件 {file_id} 不存在或已被删除。")
                    text = await asyncio.to_thread(
                        _extract_text, Path(file_row["path"]), file_row["name"]
                    )
                    if text.strip():
                        documents.append((file_row["name"], text))
            if not documents:
                raise RuntimeError("上传文件中没有提取到可处理的文字。")

            all_chunks: list[tuple[str, str]] = []
            for name, text in documents:
                all_chunks.extend((name, chunk) for chunk in _chunks(text))
            if not all_chunks:
                raise RuntimeError("文档分段结果为空。")

            prompt = row["prompt"]
            summaries: list[str] = []
            for index, (name, chunk) in enumerate(all_chunks):
                if _cancel_requested(task_id):
                    raise asyncio.CancelledError
                progress = 0.08 + 0.62 * index / max(1, len(all_chunks))
                _set_progress(
                    task_id,
                    progress,
                    f"正在阅读文档片段 {index + 1}/{len(all_chunks)}",
                )
                summary = await _completion(
                    model,
                    [
                        {
                            "role": "system",
                            "content": "你负责长文档分析的分段阅读。只保留与用户目标有关的事实、证据、数字、结论和不确定性，不要编造。",
                        },
                        {
                            "role": "user",
                            "content": f"用户目标：{prompt}\n\n文件：{name}\n片段 {index + 1}/{len(all_chunks)}：\n{chunk}",
                        },
                    ],
                )
                summaries.append(f"### {name} / 片段 {index + 1}\n{summary}")

            _set_progress(task_id, 0.75, "已完成全文阅读，正在组织回答")
            reduced_material = await _reduce_material(
                task_id, model, prompt, summaries
            )
            instructions = row["instructions"].strip()
            final_messages: list[dict[str, str]] = [
                {
                    "role": "system",
                    "content": instructions
                    or "你正在完成长时间文档处理任务。严格依据材料，给出结构清晰、证据充分、可执行的最终结果。",
                },
                *_history_messages(row),
                {
                    "role": "user",
                    "content": f"用户当前目标：{prompt}\n\n以下是完整文档逐段阅读后的材料：\n\n"
                    + reduced_material,
                },
            ]
            output = await _stream_completion(task_id, model, final_messages)
            if not output:
                raise RuntimeError("上游模型完成了请求，但没有生成文本。")
            _update_task(
                task_id,
                status="completed",
                output_text=output,
                progress=1.0,
                detail="处理完成",
                error=None,
            )
            _event(task_id, "completed", {"output_text": output})
        except asyncio.CancelledError:
            if _shutting_down and not _cancel_requested(task_id):
                _update_task(
                    task_id,
                    status="queued",
                    detail="服务已停止，等待重启后恢复",
                    error=None,
                )
                _event(task_id, "interrupted", {"reason": "gateway_shutdown"})
            else:
                _update_task(
                    task_id,
                    status="cancelled",
                    detail="已取消",
                    error=None,
                    cancel_requested=1,
                )
                _event(task_id, "cancelled", {})
        except Exception as error:  # Persist failures so clients can retry later.
            message = str(error).strip() or error.__class__.__name__
            _update_task(task_id, status="failed", detail="处理失败", error=message)
            _event(task_id, "failed", {"error": message})
        finally:
            _running.pop(task_id, None)


def _schedule(task_id: str) -> None:
    if task_id in _running:
        return
    _running[task_id] = asyncio.create_task(_process_task(task_id))


@asynccontextmanager
async def _lifespan(_: FastAPI):
    global _shutting_down
    _shutting_down = False
    _init_db()
    with _db() as db:
        db.execute(
            "UPDATE tasks SET status = 'queued', detail = '服务已恢复，任务重新排队', updated_at = ? "
            "WHERE status IN ('queued', 'running') AND cancel_requested = 0",
            (_now(),),
        )
        task_ids = [
            row["id"]
            for row in db.execute(
                "SELECT id FROM tasks WHERE status = 'queued' AND cancel_requested = 0"
            ).fetchall()
        ]
    for task_id in task_ids:
        _schedule(task_id)
    yield
    _shutting_down = True
    for task in list(_running.values()):
        task.cancel()
    if _running:
        await asyncio.gather(*_running.values(), return_exceptions=True)


app = FastAPI(title="Expert Chat Gateway", version="0.2.0", lifespan=_lifespan)


@app.exception_handler(HTTPException)
async def http_exception_handler(_request: Request, exc: HTTPException) -> JSONResponse:
    # Document capabilities expose a structured error contract. Preserve it
    # when mounted here; retain FastAPI's normal {"detail": ...} shape for all
    # other Gateway endpoints.
    if isinstance(exc.detail, dict) and "error" in exc.detail:
        return JSONResponse(
            status_code=exc.status_code,
            content=exc.detail,
            headers=exc.headers,
        )
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail},
        headers=exc.headers,
    )


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "version": app.version,
        "upstream_configured": bool(LLM_BASE_URL and LLM_MODEL),
        "model": LLM_MODEL or None,
        "active_tasks": len(_running),
    }


@app.get("/v1/health")
def versioned_health() -> dict[str, Any]:
    return health()


@app.get("/v1/capabilities", dependencies=[Depends(_auth)])
def capabilities() -> dict[str, Any]:
    return {
        "protocol_version": 1,
        "gateway_version": app.version,
        "capabilities": MODULES.manifest(),
    }


@app.post("/files", dependencies=[Depends(_auth)], include_in_schema=False)
@app.post("/v1/files", dependencies=[Depends(_auth)])
async def upload_file(file: UploadFile = File(...)) -> dict[str, Any]:
    file_id = f"file_{uuid.uuid4().hex}"
    safe_suffix = Path(file.filename or "upload.bin").suffix[:16]
    path = UPLOAD_DIR / f"{file_id}{safe_suffix}"
    size = 0
    try:
        with path.open("wb") as target:
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_FILE_BYTES:
                    raise HTTPException(status_code=413, detail="文件超过 Gateway 单文件上限。")
                target.write(chunk)
    except Exception:
        path.unlink(missing_ok=True)
        raise
    with _db() as db:
        db.execute(
            "INSERT INTO files(id, name, mime_type, size_bytes, path, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (
                file_id,
                file.filename or "upload.bin",
                file.content_type or "application/octet-stream",
                size,
                str(path),
                _now(),
            ),
        )
    return {"id": file_id, "name": file.filename, "size_bytes": size}


@app.delete(
    "/files/{file_id}", dependencies=[Depends(_auth)], include_in_schema=False
)
@app.delete("/v1/files/{file_id}", dependencies=[Depends(_auth)])
def delete_file(file_id: str) -> dict[str, Any]:
    with _db() as db:
        row = db.execute("SELECT path FROM files WHERE id = ?", (file_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="文件不存在。")
        active = db.execute(
            "SELECT 1 FROM tasks WHERE status IN ('queued', 'running') AND file_ids_json LIKE ? LIMIT 1",
            (f'%"{file_id}"%',),
        ).fetchone()
        if active is not None:
            raise HTTPException(status_code=409, detail="文件仍被运行中的任务使用。")
        db.execute("DELETE FROM files WHERE id = ?", (file_id,))
    Path(row["path"]).unlink(missing_ok=True)
    return {"deleted": True, "id": file_id}


@app.post("/tasks", dependencies=[Depends(_auth)], include_in_schema=False)
@app.post("/v1/tasks", dependencies=[Depends(_auth)])
async def create_task(request: CreateTaskRequest) -> dict[str, Any]:
    with _db() as db:
        client_request_id = (request.client_request_id or "").strip() or None
        if client_request_id is not None:
            existing_task = db.execute(
                "SELECT * FROM tasks WHERE client_request_id = ?",
                (client_request_id,),
            ).fetchone()
            if existing_task is not None:
                return _task_json(existing_task)
        existing = {
            row["id"]
            for row in db.execute(
                f"SELECT id FROM files WHERE id IN ({','.join('?' for _ in request.file_ids)})",
                request.file_ids,
            ).fetchall()
        }
        missing = [file_id for file_id in request.file_ids if file_id not in existing]
        if missing:
            raise HTTPException(status_code=400, detail=f"文件不存在：{', '.join(missing)}")
        task_id = f"task_{uuid.uuid4().hex}"
        now = _now()
        db.execute(
            """
            INSERT INTO tasks(
                id, client_request_id, status, prompt, instructions, messages_json, file_ids_json,
                model, output_text, progress, detail, created_at, updated_at
            ) VALUES (?, ?, 'queued', ?, ?, ?, ?, ?, '', 0, '已排队', ?, ?)
            """,
            (
                task_id,
                client_request_id,
                request.prompt.strip(),
                request.instructions.strip(),
                json.dumps([item.model_dump() for item in request.messages], ensure_ascii=False),
                json.dumps(request.file_ids),
                (request.model or LLM_MODEL).strip(),
                now,
                now,
            ),
        )
    _event(task_id, "queued", {"detail": "已排队"})
    _schedule(task_id)
    return _task_json(_task_row(task_id))


@app.get(
    "/tasks/{task_id}", dependencies=[Depends(_auth)], include_in_schema=False
)
@app.get("/v1/tasks/{task_id}", dependencies=[Depends(_auth)])
def get_task(task_id: str) -> dict[str, Any]:
    return _task_json(_task_row(task_id))


@app.get(
    "/tasks/{task_id}/events",
    dependencies=[Depends(_auth)],
    include_in_schema=False,
)
@app.get("/v1/tasks/{task_id}/events", dependencies=[Depends(_auth)])
def get_events(
    task_id: str,
    after: int = Query(default=0, ge=0),
    limit: int = Query(default=200, ge=1, le=1000),
) -> dict[str, Any]:
    _task_row(task_id)
    with _db() as db:
        rows = db.execute(
            "SELECT * FROM events WHERE task_id = ? AND id > ? ORDER BY id LIMIT ?",
            (task_id, after, limit),
        ).fetchall()
    events = [
        {
            "id": row["id"],
            "type": row["type"],
            "data": json.loads(row["data_json"]),
            "created_at": row["created_at"],
        }
        for row in rows
    ]
    return {"events": events, "next_after": events[-1]["id"] if events else after}


@app.post(
    "/tasks/{task_id}/cancel",
    dependencies=[Depends(_auth)],
    include_in_schema=False,
)
@app.post("/v1/tasks/{task_id}/cancel", dependencies=[Depends(_auth)])
def cancel_task(task_id: str) -> dict[str, Any]:
    row = _task_row(task_id)
    if row["status"] in {"completed", "failed", "cancelled"}:
        raise HTTPException(status_code=409, detail="任务已经结束。")
    _update_task(task_id, cancel_requested=1, detail="正在取消")
    _event(task_id, "cancel_requested", {})
    return _task_json(_task_row(task_id))


# Business modules are mounted through the same registry that publishes the
# capability manifest, so a route cannot silently diverge from discovery.
MODULES.install(app)
