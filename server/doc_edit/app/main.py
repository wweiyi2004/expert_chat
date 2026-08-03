"""Document-edit service: xlsx / docx / pptx / txt / md / csv / tsv.

Contract: docs/document-edit-contract.md
Env: DOC_API_TOKEN, MAX_UPLOAD_MB, TEMP_DIR
"""

from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import uuid
from pathlib import Path
from typing import Any

from docx import Document
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from openpyxl import Workbook, load_workbook
from openpyxl.utils import coordinate_to_tuple
from pptx import Presentation
from starlette.background import BackgroundTask

APP_VERSION = "0.3.0"
MAX_OPS = 200
MAX_CELLS_PER_OP = 5000
MAX_SET_TEXT_CHARS = 2 * 1024 * 1024
A1_RE = re.compile(r"^[A-Z]{1,3}[1-9][0-9]{0,6}$")
SUPPORTED = {".xlsx", ".docx", ".pptx", ".txt", ".md", ".csv", ".tsv"}
FORMATS = ["xlsx", "docx", "pptx", "txt", "md", "csv", "tsv"]

app = FastAPI(title="Expert Chat Document Edit", version=APP_VERSION)


def _token() -> str:
    return os.environ.get("DOC_API_TOKEN", "").strip()


def _max_upload_bytes() -> int:
    mb = float(os.environ.get("MAX_UPLOAD_MB", "20"))
    return int(mb * 1024 * 1024)


def _temp_root() -> Path:
    raw = os.environ.get("TEMP_DIR", "").strip()
    p = Path(raw) if raw else Path(tempfile.gettempdir()) / "expert_chat_doc_edit"
    p.mkdir(parents=True, exist_ok=True)
    return p


def require_auth(authorization: str | None = Header(default=None)) -> None:
    expected = _token()
    if not expected:
        raise HTTPException(
            status_code=500,
            detail=_err("internal", "服务器未配置 DOC_API_TOKEN"),
        )
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status_code=401,
            detail=_err("unauthorized", "缺少 Authorization: Bearer"),
        )
    if authorization[7:].strip() != expected:
        raise HTTPException(
            status_code=401,
            detail=_err("unauthorized", "Token 无效"),
        )


def _err(code: str, message: str, details: dict[str, Any] | None = None) -> dict:
    return {"error": {"code": code, "message": message, "details": details or {}}}


@app.get("/v1/health")
def health() -> dict[str, Any]:
    return {"ok": True, "version": APP_VERSION, "formats": FORMATS}


@app.post("/v1/documents/edit")
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

        data = await file.read()
        if len(data) > _max_upload_bytes():
            raise HTTPException(
                status_code=400,
                detail=_err(
                    "file_too_large",
                    f"文件超过 {_max_upload_bytes() // (1024 * 1024)} MB 限制",
                ),
            )
        if not data:
            raise HTTPException(
                status_code=400,
                detail=_err("patch_invalid", "上传文件为空"),
            )

        try:
            patch_obj = json.loads(patch)
        except json.JSONDecodeError as e:
            raise HTTPException(
                status_code=400,
                detail=_err("patch_invalid", f"patch 不是合法 JSON：{e}"),
            ) from e

        try:
            validated = _validate_patch(patch_obj, ext)
        except ValueError as e:
            raise HTTPException(
                status_code=400,
                detail=_err("patch_invalid", str(e)),
            ) from e

        in_path = job_dir / f"input{ext}"
        out_path = job_dir / f"output{ext}"
        in_path.write_bytes(data)

        try:
            if ext == ".xlsx":
                _apply_xlsx(in_path, out_path, validated)
            elif ext == ".docx":
                _apply_docx(in_path, out_path, validated)
            elif ext == ".pptx":
                _apply_pptx(in_path, out_path, validated)
            else:
                _apply_text(in_path, out_path, validated)
        except ValueError as e:
            raise HTTPException(
                status_code=400,
                detail=_err("patch_invalid", str(e)),
            ) from e
        except Exception as e:  # noqa: BLE001
            raise HTTPException(
                status_code=500,
                detail=_err("internal", f"写入失败：{e}"),
            ) from e

        out_name = validated.get("output_filename") or _default_out_name(raw_name, ext)
        media = {
            ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            ".txt": "text/plain; charset=utf-8",
            ".md": "text/markdown; charset=utf-8",
            ".csv": "text/csv; charset=utf-8",
            ".tsv": "text/tab-separated-values; charset=utf-8",
        }[ext]
        return FileResponse(
            path=out_path,
            filename=out_name,
            media_type=media,
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


def _default_out_name(raw: str, ext: str) -> str:
    base = Path(raw).stem or "edited"
    return f"{base}_edited{ext}"


def _validate_patch(obj: Any, file_ext: str) -> dict[str, Any]:
    if not isinstance(obj, dict):
        raise ValueError("patch 必须是对象")
    if obj.get("schema_version") != 1:
        raise ValueError(f"不支持的 schema_version={obj.get('schema_version')}（需要 1）")
    fmt = str(obj.get("format", "")).lower()
    expected = file_ext.lstrip(".")
    if fmt not in set(FORMATS):
        raise ValueError(f'不支持的 format="{fmt}"')
    if fmt != expected:
        raise ValueError(f'format="{fmt}" 与上传文件扩展名 {file_ext} 不一致')
    ops = obj.get("ops")
    if not isinstance(ops, list) or not ops:
        raise ValueError("ops 必须是非空数组")
    if len(ops) > MAX_OPS:
        raise ValueError(f"ops 超过上限 {MAX_OPS}")

    out = obj.get("output_filename")
    if out is not None:
        out_s = str(out).strip()
        if not out_s or "/" in out_s or "\\" in out_s or ".." in out_s:
            raise ValueError("output_filename 非法")
        if len(out_s) > 180:
            raise ValueError("output_filename 过长")
        obj = {**obj, "output_filename": out_s}

    text_ops = {"replace_text", "set_text"}
    allowed = {
        "xlsx": {"set_cells", "set_range", "add_sheet", "ensure_sheet"},
        "docx": {"replace_text"},
        "pptx": {"set_shape_text"},
        "txt": text_ops,
        "md": text_ops,
        "csv": text_ops,
        "tsv": text_ops,
    }[fmt]

    for i, op in enumerate(ops):
        if not isinstance(op, dict):
            raise ValueError(f"ops[{i}] 必须是对象")
        kind = str(op.get("op", "")).lower()
        if kind not in allowed:
            raise ValueError(f'format={fmt} 不支持 op="{kind}"（ops[{i}]）')
        if kind == "set_cells":
            cells = op.get("cells")
            if not isinstance(cells, dict) or not cells:
                raise ValueError(f"ops[{i}].cells 必须是非空对象")
            if len(cells) > MAX_CELLS_PER_OP:
                raise ValueError(f"ops[{i}].cells 过多")
            for addr in cells:
                if not A1_RE.match(str(addr).strip().upper()):
                    raise ValueError(f"ops[{i}] 非法地址 {addr}")
        elif kind == "set_range":
            start = str(op.get("start", "")).strip().upper()
            if not A1_RE.match(start):
                raise ValueError(f"ops[{i}].start 非法")
            values = op.get("values")
            if not isinstance(values, list) or not values:
                raise ValueError(f"ops[{i}].values 必须是非空二维数组")
            n = sum(len(r) if isinstance(r, list) else 0 for r in values)
            if n > MAX_CELLS_PER_OP:
                raise ValueError(f"ops[{i}].values 单元格过多")
        elif kind in {"add_sheet", "ensure_sheet"}:
            name = str(op.get("name", "")).strip()
            if not name or len(name) > 31:
                raise ValueError(f"ops[{i}].name 非法")
            if re.search(r"[\\/*?:\[\]]", name):
                raise ValueError(f"ops[{i}].name 含非法字符")
        elif kind == "replace_text":
            find = str(op.get("find", ""))
            if not find:
                raise ValueError(f"ops[{i}].find 不能为空")
        elif kind == "set_text":
            if "text" not in op or op.get("text") is None:
                raise ValueError(f"ops[{i}].text 不能为 null")
            text = op.get("text")
            text_s = text if isinstance(text, str) else str(text)
            if len(text_s) > MAX_SET_TEXT_CHARS:
                raise ValueError(f"ops[{i}].text 过长（>{MAX_SET_TEXT_CHARS}）")
        elif kind == "set_shape_text":
            slide = int(op.get("slide", 1))
            if slide < 1:
                raise ValueError(f"ops[{i}].slide 必须 ≥ 1")
            shape = int(op.get("shape", 0))
            if shape < 0:
                raise ValueError(f"ops[{i}].shape 必须 ≥ 0")
    return obj


def _apply_xlsx(in_path: Path, out_path: Path, patch: dict[str, Any]) -> None:
    try:
        wb = load_workbook(in_path)
    except Exception:
        wb = Workbook()

    for op in patch["ops"]:
        kind = str(op["op"]).lower()
        if kind == "add_sheet":
            name = str(op["name"]).strip()
            if name in wb.sheetnames:
                raise ValueError(f'工作表已存在："{name}"')
            wb.create_sheet(name)
        elif kind == "ensure_sheet":
            name = str(op["name"]).strip()
            if name not in wb.sheetnames:
                wb.create_sheet(name)
        elif kind == "set_cells":
            ws = _sheet(wb, op.get("sheet"))
            for addr, value in op["cells"].items():
                ws[str(addr).strip().upper()] = _cell_py(value)
        elif kind == "set_range":
            ws = _sheet(wb, op.get("sheet"))
            start = str(op["start"]).strip().upper()
            row0, col0 = coordinate_to_tuple(start)
            for r, row in enumerate(op["values"]):
                if not isinstance(row, list):
                    raise ValueError("set_range 行必须是数组")
                for c, value in enumerate(row):
                    ws.cell(row=row0 + r, column=col0 + c, value=_cell_py(value))
    wb.save(out_path)


def _apply_docx(in_path: Path, out_path: Path, patch: dict[str, Any]) -> None:
    doc = Document(str(in_path))
    for op in patch["ops"]:
        if str(op["op"]).lower() != "replace_text":
            continue
        find = str(op["find"])
        replace = str(op.get("replace", ""))
        all_occ = bool(op.get("all", True))
        _docx_replace(doc, find, replace, all_occ)
    doc.save(str(out_path))


def _docx_replace(doc: Document, find: str, replace: str, all_occ: bool) -> None:
    replaced = 0

    def do_para(p: Any) -> None:
        nonlocal replaced
        if find not in p.text:
            return
        if all_occ or replaced == 0:
            # Simple full-paragraph text rewrite keeps runs minimal but robust.
            new_text = p.text.replace(find, replace) if all_occ else p.text.replace(find, replace, 1)
            if new_text != p.text:
                for run in p.runs:
                    run.text = ""
                if p.runs:
                    p.runs[0].text = new_text
                else:
                    p.add_run(new_text)
                replaced += 1 if not all_occ else p.text.count(replace)  # best-effort

    for p in doc.paragraphs:
        do_para(p)
        if not all_occ and replaced:
            break
    if all_occ or not replaced:
        for table in doc.tables:
            for row in table.rows:
                for cell in row.cells:
                    for p in cell.paragraphs:
                        do_para(p)
                        if not all_occ and replaced:
                            return


def _read_text_file(path: Path) -> str:
    raw = path.read_bytes()
    if not raw:
        return ""
    # Strip UTF-8 BOM if present.
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        # Best-effort for Chinese Windows exports.
        try:
            return raw.decode("gb18030")
        except UnicodeDecodeError:
            return raw.decode("utf-8", errors="replace")


def _write_text_file(path: Path, text: str) -> None:
    path.write_bytes(text.encode("utf-8"))


def _apply_text(in_path: Path, out_path: Path, patch: dict[str, Any]) -> None:
    content = _read_text_file(in_path)
    for op in patch["ops"]:
        kind = str(op["op"]).lower()
        if kind == "set_text":
            text = op.get("text")
            content = text if isinstance(text, str) else str(text)
        elif kind == "replace_text":
            find = str(op["find"])
            replace = str(op.get("replace", ""))
            all_occ = bool(op.get("all", True))
            if all_occ:
                content = content.replace(find, replace)
            else:
                content = content.replace(find, replace, 1)
    _write_text_file(out_path, content)


def _apply_pptx(in_path: Path, out_path: Path, patch: dict[str, Any]) -> None:
    prs = Presentation(str(in_path))
    for op in patch["ops"]:
        if str(op["op"]).lower() != "set_shape_text":
            continue
        slide_i = int(op.get("slide", 1)) - 1
        shape_i = int(op.get("shape", 0))
        text = str(op.get("text", ""))
        if slide_i < 0 or slide_i >= len(prs.slides):
            raise ValueError(f"幻灯片不存在：slide={slide_i + 1}")
        slide = prs.slides[slide_i]
        text_shapes = [s for s in slide.shapes if getattr(s, "has_text_frame", False)]
        if shape_i < 0 or shape_i >= len(text_shapes):
            raise ValueError(
                f"幻灯片 {slide_i + 1} 没有 shape 索引 {shape_i}（共 {len(text_shapes)} 个文本框）"
            )
        shape = text_shapes[shape_i]
        tf = shape.text_frame
        if tf.paragraphs:
            # Clear then set first paragraph.
            for pi, para in enumerate(tf.paragraphs):
                if pi == 0:
                    if para.runs:
                        para.runs[0].text = text
                        for run in para.runs[1:]:
                            run.text = ""
                    else:
                        para.text = text
                else:
                    para.text = ""
        else:
            tf.text = text
    prs.save(str(out_path))


def _sheet(wb: Any, name: Any) -> Any:
    if name is None or str(name).strip() == "":
        return wb[wb.sheetnames[0]]
    n = str(name).strip()
    if n not in wb.sheetnames:
        raise ValueError(f'找不到工作表："{n}"')
    return wb[n]


def _cell_py(value: Any) -> Any:
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    raise ValueError("单元格值类型无效")


@app.exception_handler(HTTPException)
async def http_exception_handler(_request: Any, exc: HTTPException) -> JSONResponse:
    detail = exc.detail
    if isinstance(detail, dict) and "error" in detail:
        return JSONResponse(status_code=exc.status_code, content=detail)
    return JSONResponse(status_code=exc.status_code, content=_err("internal", str(detail)))
