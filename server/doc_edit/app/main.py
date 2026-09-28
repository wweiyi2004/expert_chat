"""Document-edit service: xlsx / docx / pptx / txt / md / csv / tsv.

Also supports cross-format conversion via POST /v1/documents/convert.

Contract: docs/document-edit-contract.md
Env: GATEWAY_API_TOKEN (or legacy DOC_API_TOKEN), GATEWAY_MAX_FILE_MB, GATEWAY_DATA_DIR
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import shutil
import tempfile
import uuid
from pathlib import Path
from typing import Any

from fastapi import (
    APIRouter,
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    UploadFile,
)
from fastapi.responses import FileResponse, JSONResponse
from starlette.background import BackgroundTask

APP_VERSION = "0.4.1"
from document_core.operations import (
    CONVERSIONS,
    FORMATS,
    SUPPORTED,
    MAX_PATCH_JSON_BYTES,
    DocumentOperationError,
    DocumentOutput,
)
from document_core.runtime import edit_document_path, convert_document_path


router = APIRouter()
app = FastAPI(title="Expert Chat Document Edit", version=APP_VERSION)


def _token() -> str:
    return (
        os.environ.get("GATEWAY_API_TOKEN", "").strip()
        or os.environ.get("DOC_API_TOKEN", "").strip()
    )


def _max_upload_bytes() -> int:
    mb = float(
        os.environ.get("GATEWAY_MAX_FILE_MB", "").strip() or os.environ.get("MAX_UPLOAD_MB", "20")
    )
    return int(mb * 1024 * 1024)


def _temp_root() -> Path:
    raw = os.environ.get("TEMP_DIR", "").strip()
    gateway_data = os.environ.get("GATEWAY_DATA_DIR", "").strip()
    p = (
        Path(raw)
        if raw
        else Path(gateway_data) / "document_jobs"
        if gateway_data
        else Path(tempfile.gettempdir()) / "expert_chat_doc_edit"
    )
    p.mkdir(parents=True, exist_ok=True)
    return p


def require_auth(authorization: str | None = Header(default=None)) -> None:
    expected = _token()
    if not expected:
        # Match the unified Gateway: tokenless access is allowed only for
        # explicit local development. Production deployments must set a token.
        return
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status_code=401,
            detail=_err("unauthorized", "缺少 Authorization: Bearer"),
        )
    provided = authorization[7:].strip()
    if not hmac.compare_digest(provided.encode("utf-8"), expected.encode("utf-8")):
        raise HTTPException(
            status_code=401,
            detail=_err("unauthorized", "Token 无效"),
        )


def _err(code: str, message: str, details: dict[str, Any] | None = None) -> dict:
    return {"error": {"code": code, "message": message, "details": details or {}}}


async def _spool_upload(file: UploadFile, dest: Path) -> int:
    """Stream an upload to disk in bounded chunks and return its size.

    A single await file.read() would load the whole body into memory before
    the size check runs, so an oversized request could OOM the process (this
    app also runs mounted inside the Gateway process). Chunked spooling
    rejects as soon as the limit is crossed.
    """
    limit = _max_upload_bytes()
    size = 0
    with dest.open("wb") as out:
        while chunk := await file.read(1024 * 1024):
            size += len(chunk)
            if size > limit:
                raise HTTPException(
                    status_code=400,
                    detail=_err(
                        "file_too_large",
                        f"文件超过 {limit // (1024 * 1024)} MB 限制",
                    ),
                )
            out.write(chunk)
    return size


@app.get("/v1/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "version": APP_VERSION,
        "formats": FORMATS,
        "conversions": {k: sorted(v) for k, v in CONVERSIONS.items()},
    }


@router.post("/v1/documents/edit")
async def edit_document(
    file: UploadFile = File(...),
    patch: str = Form(...),
    filename: str | None = Form(default=None),
    _: None = Depends(require_auth),
) -> FileResponse:
    job_id = uuid.uuid4().hex
    job_dir = _temp_root() / job_id
    job_dir.mkdir(parents=True, exist_ok=True)

    def cleanup() -> None:
        shutil.rmtree(job_dir, ignore_errors=True)

    try:
        raw_name = filename or file.filename or "input.bin"
        lower = raw_name.lower()
        ext = Path(lower).suffix
        if ext not in SUPPORTED:
            raise HTTPException(
                status_code=400,
                detail=_err("unsupported_format", f"仅支持 {', '.join(sorted(SUPPORTED))}"),
            )

        in_path = job_dir / f"input{ext}"
        out_path = job_dir / f"output{ext}"
        size = await _spool_upload(file, in_path)
        if size == 0:
            raise HTTPException(
                status_code=400,
                detail=_err("patch_invalid", "上传文件为空"),
            )

        patch_bytes = len(patch.encode("utf-8")) if isinstance(patch, str) else 0
        if patch_bytes > MAX_PATCH_JSON_BYTES:
            raise HTTPException(
                status_code=400,
                detail=_err(
                    "patch_invalid",
                    f"patch 过大（{patch_bytes} 字节，上限 {MAX_PATCH_JSON_BYTES}）",
                ),
            )

        try:
            patch_obj = json.loads(patch)
        except json.JSONDecodeError as e:
            raise HTTPException(
                status_code=400,
                detail=_err("patch_invalid", f"patch 不是合法 JSON：{e}"),
            ) from e

        try:
            # Office parsing/saving is CPU-bound; keep it off the event loop
            # (this router also runs mounted inside the Gateway process).
            output = await asyncio.to_thread(
                edit_document_path,
                in_path,
                out_path,
                raw_name,
                patch_obj,
            )
        except DocumentOperationError as e:
            raise HTTPException(
                status_code=400,
                detail=_err(e.code, e.message),
            ) from e
        except Exception as e:  # noqa: BLE001
            raise HTTPException(
                status_code=500,
                detail=_err("internal", f"写入失败：{e}"),
            ) from e

        return FileResponse(
            path=out_path,
            filename=output.filename,
            media_type=output.media_type,
            background=BackgroundTask(cleanup),
        )
    except HTTPException:
        cleanup()
        raise
    except Exception as e:  # noqa: BLE001
        cleanup()
        raise HTTPException(
            status_code=500,
            detail=_err("internal", f"内部错误：{e}"),
        ) from e


@router.post("/v1/documents/convert")
async def convert_document(
    file: UploadFile = File(...),
    target_format: str = Form(...),
    filename: str | None = Form(default=None),
    output_filename: str | None = Form(default=None),
    _: None = Depends(require_auth),
) -> FileResponse:
    """Convert an uploaded file to another supported format."""
    job_id = uuid.uuid4().hex
    job_dir = _temp_root() / job_id
    job_dir.mkdir(parents=True, exist_ok=True)

    def cleanup() -> None:
        shutil.rmtree(job_dir, ignore_errors=True)

    try:
        raw_name = filename or file.filename or "input.bin"
        src_ext = Path(raw_name.lower()).suffix
        if src_ext not in SUPPORTED:
            raise HTTPException(
                status_code=400,
                detail=_err("unsupported_format", f"仅支持 {', '.join(sorted(SUPPORTED))}"),
            )
        src_fmt = src_ext.lstrip(".")
        tgt_fmt = str(target_format or "").strip().lower().lstrip(".")
        if tgt_fmt not in FORMATS:
            raise HTTPException(
                status_code=400,
                detail=_err("unsupported_format", f'不支持的 target_format="{target_format}"'),
            )
        allowed = CONVERSIONS.get(src_fmt, set())
        if tgt_fmt not in allowed:
            raise HTTPException(
                status_code=400,
                detail=_err(
                    "unsupported_format",
                    f"不支持 {src_fmt} → {tgt_fmt}。可选：{', '.join(sorted(allowed)) or '无'}",
                ),
            )

        in_path = job_dir / f"input{src_ext}"
        out_path = job_dir / f"output.{tgt_fmt}"
        size = await _spool_upload(file, in_path)
        if size == 0:
            raise HTTPException(
                status_code=400,
                detail=_err("patch_invalid", "上传文件为空"),
            )

        try:
            # Parsing/converting documents is CPU-bound; keep it off the event
            # loop (this router also runs mounted inside the Gateway process).
            output = await asyncio.to_thread(
                convert_document_path,
                in_path,
                out_path,
                raw_name,
                tgt_fmt,
                output_filename,
            )
        except DocumentOperationError as e:
            raise HTTPException(
                status_code=400,
                detail=_err(e.code, e.message),
            ) from e
        except Exception as e:  # noqa: BLE001
            raise HTTPException(
                status_code=500,
                detail=_err("internal", f"转换失败：{e}"),
            ) from e

        return FileResponse(
            path=out_path,
            filename=output.filename,
            media_type=output.media_type,
            background=BackgroundTask(cleanup),
        )
    except HTTPException:
        cleanup()
        raise
    except Exception as e:  # noqa: BLE001
        cleanup()
        raise HTTPException(
            status_code=500,
            detail=_err("internal", f"内部错误：{e}"),
        ) from e


@app.exception_handler(HTTPException)
async def http_exception_handler(_request: Any, exc: HTTPException) -> JSONResponse:
    detail = exc.detail
    if isinstance(detail, dict) and "error" in detail:
        return JSONResponse(status_code=exc.status_code, content=detail)
    return JSONResponse(status_code=exc.status_code, content=_err("internal", str(detail)))


# Keep the module runnable on its own for compatibility, while allowing the
# unified Gateway to mount the same router without copying app-internal routes.
app.include_router(router)
