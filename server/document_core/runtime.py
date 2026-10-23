"""Per-job processes with wall time, memory, concurrency and output budgets."""

from __future__ import annotations
import json
import logging
import math
import multiprocessing
import os
import tempfile
import threading
from pathlib import Path

_slots = threading.BoundedSemaphore(2)
_logger = logging.getLogger(__name__)


def _limit_resources(memory_bytes: int, timeout: float):
    if os.name == "posix":
        import resource

        resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))
        seconds = max(1, math.ceil(timeout))
        resource.setrlimit(resource.RLIMIT_CPU, (seconds, seconds + 1))
        return None
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        size = ctypes.c_size_t

        class Basic(ctypes.Structure):
            _fields_ = [
                ("process_time", ctypes.c_int64),
                ("job_time", ctypes.c_int64),
                ("flags", wintypes.DWORD),
                ("min_ws", size),
                ("max_ws", size),
                ("active", wintypes.DWORD),
                ("affinity", size),
                ("priority", wintypes.DWORD),
                ("scheduling", wintypes.DWORD),
            ]

        class IO(ctypes.Structure):
            _fields_ = [
                (name, ctypes.c_uint64)
                for name in (
                    "read_ops",
                    "write_ops",
                    "other_ops",
                    "read_bytes",
                    "write_bytes",
                    "other_bytes",
                )
            ]

        class Extended(ctypes.Structure):
            _fields_ = [
                ("basic", Basic),
                ("io", IO),
                ("process_memory", size),
                ("job_memory", size),
                ("peak_process", size),
                ("peak_job", size),
            ]

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        kernel.CreateJobObjectW.restype = wintypes.HANDLE
        kernel.SetInformationJobObject.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
        ]
        kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        job = kernel.CreateJobObjectW(None, None)
        info = Extended()
        info.basic.flags = 0x100  # JOB_OBJECT_LIMIT_PROCESS_MEMORY
        info.process_memory = memory_bytes
        if (
            not job
            or not kernel.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info))
            or not kernel.AssignProcessToJobObject(job, kernel.GetCurrentProcess())
        ):
            raise OSError("无法启用文档处理内存限制。")
        return job  # Keep the job handle alive for this worker's lifetime.
    raise OSError("当前系统没有可用的文档资源隔离实现。")


def _worker(operation, arguments, result_path, memory_bytes, timeout):
    try:
        job_handle = _limit_resources(memory_bytes, timeout)
        from .limits import DocumentLimitError
        from .operations import DocumentOperationError
        from docx.opc.exceptions import PackageNotFoundError as DocxPackageError
        from lxml.etree import XMLSyntaxError
        from openpyxl.utils.exceptions import InvalidFileException
        from pptx.exc import InvalidXmlError, PackageNotFoundError as PptxPackageError
        from pypdf.errors import PdfReadError, ParseError
        from zipfile import BadZipFile

        try:
            if operation == "extract":
                from .extraction import extract_text

                value = extract_text(*arguments)
            else:
                from .operations import edit_document_path, convert_document_path

                function = {"edit": edit_document_path, "convert": convert_document_path}[operation]
                output = function(*arguments)
                value = {"filename": output.filename, "media_type": output.media_type}
            result = {"ok": True, "value": value}
        except DocumentOperationError as exc:
            result = {"ok": False, "code": exc.code, "message": exc.message}
        except DocumentLimitError as exc:
            result = {"ok": False, "code": "resource_limit", "message": str(exc)}
        except (
            DocxPackageError,
            PptxPackageError,
            InvalidXmlError,
            XMLSyntaxError,
            InvalidFileException,
            PdfReadError,
            ParseError,
            BadZipFile,
        ):
            result = {
                "ok": False,
                "code": "invalid_document",
                "message": "文档无法解析或处理，请检查格式与内容。",
            }
    except MemoryError:
        result = {"ok": False, "code": "resource_limit", "message": "无法在资源限制内处理文档。"}
    except Exception:
        _logger.exception("Document worker failed during %s", operation)
        result = {"ok": False, "code": "internal_error", "message": "文档服务内部错误。"}
    Path(result_path).write_text(json.dumps(result, ensure_ascii=True), encoding="utf-8")


def run_document_job(operation, *arguments, timeout_seconds=None):
    from .operations import DocumentOperationError

    timeout = (
        timeout_seconds
        if timeout_seconds is not None
        else min(120, max(1, float(os.getenv("DOCUMENT_TIMEOUT_SECONDS", "30"))))
    )
    memory = min(2048, max(128, int(os.getenv("DOCUMENT_MEMORY_MB", "512")))) * 1024 * 1024
    if not _slots.acquire(blocking=False):
        raise DocumentOperationError("service_busy", "文档服务正忙，请稍后重试。")
    try:
        with tempfile.TemporaryDirectory(prefix="expert-document-job-") as temp:
            result_path = Path(temp) / "result.json"
            process = multiprocessing.get_context("spawn").Process(
                target=_worker,
                args=(operation, arguments, str(result_path), memory, timeout),
                daemon=True,
            )
            try:
                process.start()
                process.join(timeout)
                if process.is_alive():
                    raise DocumentOperationError("resource_limit", "文档处理超时，已停止本次任务。")
                if not result_path.is_file():
                    _logger.error(
                        "Document worker exited without a result (exitcode=%s)", process.exitcode
                    )
                    raise DocumentOperationError("internal_error", "文档处理进程意外中断。")
                if result_path.stat().st_size > 16 * 1024 * 1024:
                    raise DocumentOperationError(
                        "resource_limit", "文档处理超过资源限制或执行中断。"
                    )
                result = json.loads(result_path.read_text(encoding="utf-8"))
                if not result["ok"]:
                    raise DocumentOperationError(result["code"], result["message"])
                return result["value"]
            finally:
                if process.pid is not None:
                    if process.is_alive():
                        process.kill()
                    process.join(5)
                    process.close()
    finally:
        _slots.release()


def extract_document_text(path, original_name):
    return run_document_job("extract", Path(path), original_name)


def edit_document_path(in_path, out_path, source_name, patch_obj):
    from .operations import DocumentOutput

    return DocumentOutput(
        **run_document_job("edit", Path(in_path), Path(out_path), source_name, patch_obj)
    )


def convert_document_path(in_path, out_path, source_name, target_format, output_filename=None):
    from .operations import DocumentOutput

    return DocumentOutput(
        **run_document_job(
            "convert", Path(in_path), Path(out_path), source_name, target_format, output_filename
        )
    )
