"""Recoverable chunk uploads. SQL is the authority for committed byte offsets.

The uploads row is a durable prepare record. Finishing copies (never moves) the
staged bytes to a deterministic destination, then commits document + receipt in
one transaction. Staging is removed only afterwards. A receipt makes a lost
finish response safe to query again without creating another document.
"""

from __future__ import annotations

import base64
import binascii
import os
import re
import shutil
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path


def sync_directory(path: Path) -> None:
    if os.name == "posix":
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


class UploadStore:
    def __init__(
        self,
        db,
        uploads: Path,
        documents: Path,
        *,
        max_bytes: int,
        chunk_bytes: int,
        safe_name,
        checked_path,
        stored,
        now,
        retention_hours: int = 24,
    ):
        self.db = db
        self.uploads = uploads
        self.documents = documents
        self.max_bytes = max_bytes
        self.chunk_bytes = chunk_bytes
        self.safe_name = safe_name
        self.checked_path = checked_path
        self.stored = stored
        self.now = now
        self.retention_hours = retention_hours
        self._last_cleanup = 0.0

    def _destination(self, row):
        if not re.fullmatch(r"upload_[0-9a-f]{32}", row["id"]):
            raise RuntimeError("上传记录标识无效。")
        file_id = "file_" + row["id"][7:]
        return file_id, self.documents / (file_id + Path(row["name"]).suffix.lower())

    def recover(self) -> dict[str, int]:
        counts = {"truncated": 0, "expired": 0, "staging_removed": 0}
        cutoff = (datetime.now(timezone.utc) - timedelta(hours=self.retention_hours)).isoformat()
        with self.db(immediate=True) as db:
            rows = db.execute("SELECT * FROM uploads").fetchall()
            for row in rows:
                path = self.checked_path(row["path"], self.uploads)
                file_id, target = self._destination(row)
                # Only a destination belonging to this recorded upload may be
                # repaired, and a live document always wins over cleanup.
                live = db.execute(
                    "SELECT 1 FROM documents WHERE id=? OR path=?", (file_id, str(target))
                ).fetchone()
                if not live and target.exists():
                    target.unlink()
                if row["created_at"] < cutoff:
                    path.unlink(missing_ok=True)
                    db.execute("DELETE FROM uploads WHERE id=?", (row["id"],))
                    counts["expired"] += 1
                elif path.is_file() and path.stat().st_size > row["received_size"]:
                    with path.open("r+b") as output:
                        output.truncate(row["received_size"])
                        output.flush()
                        os.fsync(output.fileno())
                    counts["truncated"] += 1
            referenced = {
                str(Path(row[0]).resolve()) for row in db.execute("SELECT path FROM uploads")
            }
            # A process can stop after commit but before deleting its staging
            # copy. Never delete arbitrary filenames from a user directory.
            for path in self.uploads.glob("upload_*.part"):
                if (
                    re.fullmatch(r"upload_[0-9a-f]{32}\.part", path.name)
                    and str(path.resolve()) not in referenced
                ):
                    self.checked_path(str(path), self.uploads).unlink(missing_ok=True)
                    counts["staging_removed"] += 1
            db.execute("DELETE FROM upload_receipts WHERE created_at < ?", (cutoff,))
        self._last_cleanup = time.monotonic()
        return counts

    def begin(self, owner, filename, mime_type, size_bytes):
        name = self.safe_name(filename)
        if size_bytes <= 0 or size_bytes > self.max_bytes:
            raise RuntimeError(f"文件大小必须在 1 到 {self.max_bytes} 字节之间。")
        if time.monotonic() - self._last_cleanup > 900:
            self.recover()
        upload_id = f"upload_{uuid.uuid4().hex}"
        path = self.uploads / f"{upload_id}.part"
        try:
            with self.db(immediate=True) as db:
                path.touch(exist_ok=False)
                sync_directory(self.uploads)
                db.execute(
                    "INSERT INTO uploads(id,owner_sub,name,mime_type,expected_size,received_size,path,created_at) "
                    "VALUES (?,?,?,?,?,0,?,?)",
                    (
                        upload_id,
                        owner,
                        name,
                        mime_type.strip() or "application/octet-stream",
                        size_bytes,
                        str(path),
                        self.now(),
                    ),
                )
        except BaseException:
            # Keep an uncertain file for reconciliation rather than deleting
            # bytes after an ambiguous commit acknowledgement.
            raise
        return {"upload_id": upload_id, "offset": 0, "chunk_size_bytes": self.chunk_bytes}

    def append(self, owner, upload_id, chunk_base64, offset):
        if offset < 0 or len(chunk_base64) > ((self.chunk_bytes + 2) // 3) * 4:
            raise RuntimeError("上传分块超过大小上限或 offset 无效。")
        try:
            chunk = base64.b64decode(chunk_base64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise RuntimeError("上传分块不是合法 Base64。") from exc
        if not chunk or len(chunk) > self.chunk_bytes:
            raise RuntimeError("上传分块大小无效。")
        with self.db(immediate=True) as db:
            row = db.execute(
                "SELECT * FROM uploads WHERE id=? AND owner_sub=?", (upload_id, owner)
            ).fetchone()
            if row is None:
                raise RuntimeError("上传会话不存在。")
            received, expected = row["received_size"], row["expected_size"]
            path = self.checked_path(row["path"], self.uploads)
            if not path.is_file() or path.stat().st_size < received:
                raise RuntimeError("上传文件缺少已提交的内容，请中止后重新上传。")
            with path.open("r+b") as output:
                output.truncate(received)
                if offset < received and offset + len(chunk) <= received:
                    output.seek(offset)
                    if output.read(len(chunk)) != chunk:
                        raise RuntimeError("重试的上传分块与已提交内容不同。")
                    next_offset = received
                else:
                    if offset != received:
                        raise RuntimeError(f"上传 offset 不匹配；服务器需要 {received}。")
                    next_offset = received + len(chunk)
                    if next_offset > expected or next_offset > self.max_bytes:
                        raise RuntimeError("上传内容超过声明大小或服务器上限。")
                    output.seek(received)
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            db.execute("UPDATE uploads SET received_size=? WHERE id=?", (next_offset, upload_id))
        return {"upload_id": upload_id, "offset": next_offset, "complete": next_offset == expected}

    def finish(self, owner, upload_id):
        source = None
        with self.db(immediate=True) as db:
            receipt = db.execute(
                "SELECT d.* FROM documents d JOIN upload_receipts r ON d.id=r.file_id "
                "WHERE r.upload_id=? AND r.owner_sub=?",
                (upload_id, owner),
            ).fetchone()
            if receipt is not None:
                path = self.checked_path(receipt["path"], self.documents)
                if not path.is_file():
                    raise RuntimeError("文档文件已丢失，请检查服务器存储。")
                return self.stored(receipt)
            row = db.execute(
                "SELECT * FROM uploads WHERE id=? AND owner_sub=?", (upload_id, owner)
            ).fetchone()
            if row is None:
                raise RuntimeError("上传会话不存在或已过期。")
            if row["received_size"] != row["expected_size"]:
                raise RuntimeError("上传尚未完成。")
            source = self.checked_path(row["path"], self.uploads)
            if not source.is_file() or source.stat().st_size != row["expected_size"]:
                raise RuntimeError("上传临时文件大小不一致。")
            file_id, target = self._destination(row)
            if db.execute(
                "SELECT 1 FROM documents WHERE id=? OR path=?", (file_id, str(target))
            ).fetchone():
                raise RuntimeError("上传目标已被占用，请检查服务器记录。")
            if target.is_symlink():
                raise RuntimeError("上传目标不是普通存储文件。")
            target = self.checked_path(str(target), self.documents)
            with source.open("rb") as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
                dst.flush()
                os.fsync(dst.fileno())
            sync_directory(self.documents)
            created_at = self.now()
            db.execute(
                "INSERT INTO documents(id,owner_sub,name,mime_type,size_bytes,path,created_at) VALUES (?,?,?,?,?,?,?)",
                (
                    file_id,
                    owner,
                    row["name"],
                    row["mime_type"],
                    row["expected_size"],
                    str(target),
                    created_at,
                ),
            )
            db.execute(
                "INSERT INTO upload_receipts(upload_id,owner_sub,file_id,created_at) VALUES (?,?,?,?)",
                (upload_id, owner, file_id, created_at),
            )
            db.execute("DELETE FROM uploads WHERE id=?", (upload_id,))
            result = self.stored(
                db.execute("SELECT * FROM documents WHERE id=?", (file_id,)).fetchone()
            )
        try:
            source.unlink(missing_ok=True)
        except OSError:
            pass  # A committed result must not be reported as failed; startup retries cleanup.
        return result

    def abort(self, owner, upload_id):
        with self.db(immediate=True) as db:
            row = db.execute(
                "SELECT * FROM uploads WHERE id=? AND owner_sub=?", (upload_id, owner)
            ).fetchone()
            if row is not None:
                _, target = self._destination(row)
                if not db.execute(
                    "SELECT 1 FROM documents WHERE path=?", (str(target),)
                ).fetchone():
                    target.unlink(missing_ok=True)
                self.checked_path(row["path"], self.uploads).unlink(missing_ok=True)
                db.execute("DELETE FROM uploads WHERE id=?", (upload_id,))
        return {"upload_id": upload_id, "deleted": row is not None}
