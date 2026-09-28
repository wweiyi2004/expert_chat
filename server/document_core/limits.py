"""Cheap input checks performed before third-party document parsers run."""

from pathlib import Path
from zipfile import BadZipFile, ZipFile

MAX_FILE_BYTES = 50 * 1024 * 1024
MAX_EXPANDED_BYTES = 64 * 1024 * 1024
MAX_ENTRY_BYTES = 32 * 1024 * 1024
MAX_ENTRIES = 2048
MAX_PAGES = 500
MAX_CELLS = 250_000
MAX_TEXT_CHARS = 2 * 1024 * 1024


class DocumentLimitError(ValueError):
    pass


def validate_input(path: Path, name: str) -> None:
    if path.stat().st_size > MAX_FILE_BYTES:
        raise DocumentLimitError("文档超过 50 MB 处理上限。")
    if Path(name).suffix.lower() not in {".xlsx", ".docx", ".pptx"}:
        return
    try:
        with ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_ENTRIES or sum(e.file_size for e in entries) > MAX_EXPANDED_BYTES:
                raise DocumentLimitError("文档展开大小或项目数量超过上限。")
            names = set()
            for entry in entries:
                if (
                    entry.filename in names
                    or entry.flag_bits & 1
                    or entry.file_size > MAX_ENTRY_BYTES
                    or (
                        entry.compress_size < 65536
                        and entry.file_size > max(1, entry.compress_size) * 1000
                    )
                ):
                    raise DocumentLimitError("文档压缩内容异常或超过安全上限。")
                names.add(entry.filename)
    except BadZipFile as exc:
        raise DocumentLimitError("Office 文档不是有效的 ZIP 容器。") from exc


def validate_workbook(workbook) -> None:
    cells = sum((s.max_row or 0) * (s.max_column or 0) for s in workbook.worksheets)
    if cells > MAX_CELLS:
        raise DocumentLimitError("表格单元格范围超过处理上限。")
