"""Bounded, one-request PDF/image worker for the standalone desktop host."""
import base64
import io
import json
import os
from pathlib import Path
import sys
import threading

_job_handle = None


def limit_resources():
    """Bound parser memory in the OS; this is resource control, not a sandbox."""
    global _job_handle
    budget = 512 * 1024 * 1024
    if os.name != "nt":
        import resource
        resource.setrlimit(resource.RLIMIT_AS, (budget, budget))
        resource.setrlimit(resource.RLIMIT_CPU, (15, 15))
        return
    import ctypes
    from ctypes import wintypes

    class BasicLimits(ctypes.Structure):
        _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
                    ("flags", wintypes.DWORD), ("min_working", ctypes.c_size_t),
                    ("max_working", ctypes.c_size_t), ("active_processes", wintypes.DWORD),
                    ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD),
                    ("scheduling", wintypes.DWORD)]

    class IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in
                    ("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [("basic", BasicLimits), ("io", IoCounters),
                    ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                    ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    _job_handle = kernel.CreateJobObjectW(None, None)
    limits = ExtendedLimits()
    limits.basic.flags = 0x100 | 0x8 | 0x2000  # Process memory, process count, kill on close.
    limits.basic.active_processes = 1
    limits.process_memory = budget
    if not _job_handle or not kernel.SetInformationJobObject(_job_handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
        raise RuntimeError("resource limit unavailable")
    if not kernel.AssignProcessToJobObject(_job_handle, kernel.GetCurrentProcess()):
        raise RuntimeError("resource limit unavailable")


def main():
    # Parser diagnostics may contain document text and may be unbounded.
    # Only the small structured result is part of this worker's protocol.
    sys.stderr = open(os.devnull, "w", encoding="utf-8")
    deadline = threading.Timer(15, lambda: os._exit(124))
    deadline.daemon = True
    deadline.start()
    try:
        limit_resources()
        if len(sys.argv) != 2:
            raise ValueError("request path required")
        source = Path(sys.argv[1])
        if source.stat().st_size > 24 * 1024 * 1024:
            raise ValueError("request too large")
        request = json.loads(source.read_text(encoding="utf-8"))
        data = base64.b64decode(request["data"], validate=True)
        if len(data) > 15 * 1024 * 1024:
            raise ValueError("input too large")
        if request["op"] == "pdf_text":
            from pypdf import PdfReader
            reader = PdfReader(io.BytesIO(data), strict=False)
            if reader.is_encrypted or len(reader.pages) > 2000:
                raise ValueError("unsupported PDF")
            parts, count = [], 0
            for page in reader.pages:
                text = page.extract_text() or ""
                parts.append(text[:60001 - count])
                count += len(parts[-1]) + 1
                if count > 60000:
                    break
            result = {"text": "\n".join(parts)}
        elif request["op"] == "session_zstd":
            import zstandard
            with zstandard.ZstdDecompressor().stream_reader(io.BytesIO(data)) as reader:
                expanded = reader.read(16 * 1024 * 1024 + 1)
            if len(expanded) > 16 * 1024 * 1024:
                raise ValueError("session exceeds decompression limit")
            result = {"text": expanded.decode("utf-8")}
        elif request["op"] == "image_resize":
            from PIL import Image, ImageOps
            Image.MAX_IMAGE_PIXELS = 40_000_000
            image = Image.open(io.BytesIO(data))
            limit = int(request.get("max_side", 1536))
            if not 1 <= limit <= 4096 or image.width * image.height > 40_000_000:
                raise ValueError("image dimensions exceed limit")
            orientation = image.getexif().get(274, 1)
            if max(image.size) <= limit and orientation == 1:
                result = {"changed": False}
            else:
                image = ImageOps.exif_transpose(image)
                if image.mode not in ("RGB", "RGBA", "L", "LA", "P"):
                    image = image.convert("RGB")
                image.thumbnail((limit, limit))
                output = io.BytesIO()
                image.save(output, format="PNG")
                if output.tell() > 15 * 1024 * 1024:
                    raise ValueError("output too large")
                result = {"changed": True, "data": base64.b64encode(output.getvalue()).decode("ascii")}
            image.close()
        else:
            raise ValueError("unsupported operation")
        print(json.dumps({"ok": True, **result}, ensure_ascii=True))
    except Exception as error:
        # No document text, credential, filesystem path or raw parser error.
        print(json.dumps({"ok": False, "error": type(error).__name__}))
        sys.exit(1)
    finally:
        deadline.cancel()


if __name__ == "__main__":
    main()
