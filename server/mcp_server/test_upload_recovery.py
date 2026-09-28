import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import importlib
from pathlib import Path
from unittest.mock import patch

import pytest


@pytest.fixture
def server(tmp_path, monkeypatch):
    monkeypatch.setenv("MCP_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("MCP_API_TOKEN", "synthetic-upload-test-token")
    from mcp_server.app import main

    return importlib.reload(main)


def begin(server, data=b"abc"):
    return server._begin_upload("single-user", "test.txt", "text/plain", len(data))["upload_id"]


def append(server, upload, data=b"abc", offset=0):
    return server._append_upload("single-user", upload, base64.b64encode(data).decode(), offset)


@contextmanager
def failed_commit(server, *, after=False):
    original = server._db

    @contextmanager
    def broken(**kwargs):
        with original(**kwargs) as db:
            yield db
            if not after:
                raise OSError("synthetic commit failure")
        if after:
            raise OSError("synthetic lost commit acknowledgement")

    with patch.object(server, "_db", broken):
        yield


def test_append_rollback_retry_and_committed_duplicate(server):
    upload = begin(server)
    with failed_commit(server), pytest.raises(OSError):
        append(server, upload)
    assert append(server, upload)["offset"] == 3
    assert append(server, upload)["offset"] == 3
    with pytest.raises(RuntimeError):
        append(server, upload, b"xyz")
    doc = server._finish_upload("single-user", upload)
    assert server._read_binary("single-user", doc.file_id) == b"abc"
    assert server._finish_upload("single-user", upload).file_id == doc.file_id


def test_finish_rollback_keeps_source_and_recovers_destination(server):
    upload = begin(server)
    append(server, upload)
    with failed_commit(server), pytest.raises(OSError):
        server._finish_upload("single-user", upload)
    assert list(server.UPLOAD_DIR.glob("*.part"))[0].read_bytes() == b"abc"
    server._uploads.recover()
    assert list(server.DOCUMENT_DIR.iterdir()) == []
    doc = server._finish_upload("single-user", upload)
    assert server._read_binary("single-user", doc.file_id) == b"abc"


def test_lost_commit_acknowledgement_returns_same_document(server):
    upload = begin(server)
    append(server, upload)
    with failed_commit(server, after=True), pytest.raises(OSError):
        server._finish_upload("single-user", upload)
    doc = server._finish_upload("single-user", upload)
    server._uploads.recover()
    assert not list(server.UPLOAD_DIR.iterdir())
    assert server._read_binary("single-user", doc.file_id) == b"abc"
    assert len(server._list_documents("single-user", 20)) == 1


def test_interrupted_copy_does_not_damage_source(server):
    upload = begin(server)
    append(server, upload)

    def interrupted(src, dst, length):
        dst.write(src.read(1))
        raise OSError("interrupted copy")

    with patch("mcp_server.upload_store.shutil.copyfileobj", interrupted), pytest.raises(OSError):
        server._finish_upload("single-user", upload)
    server._uploads.recover()
    doc = server._finish_upload("single-user", upload)
    assert server._read_binary("single-user", doc.file_id) == b"abc"


def test_startup_reconciles_uncommitted_tail_and_expired_staging(server):
    upload = begin(server)
    with failed_commit(server), pytest.raises(OSError):
        append(server, upload)
    assert server._uploads.recover()["truncated"] == 1
    append(server, upload)
    doc = server._finish_upload("single-user", upload)
    old = begin(server)
    with server._db() as db:
        db.execute("UPDATE uploads SET created_at='2000-01-01T00:00:00+00:00' WHERE id=?", (old,))
    assert server._uploads.recover()["expired"] == 1
    assert server._read_binary("single-user", doc.file_id) == b"abc"


def test_concurrent_finish_has_one_result_and_owner_is_checked(server):
    upload = begin(server)
    append(server, upload)
    with pytest.raises(RuntimeError):
        server._finish_upload("different-owner", upload)
    with ThreadPoolExecutor(max_workers=2) as pool:
        docs = list(pool.map(lambda _: server._finish_upload("single-user", upload), range(2)))
    assert docs[0].file_id == docs[1].file_id
    assert len(server._list_documents("single-user", 20)) == 1
    server._delete("single-user", docs[0].file_id)
    with pytest.raises(RuntimeError):
        server._finish_upload("single-user", upload)


def test_short_committed_file_fails_closed(server):
    upload = begin(server)
    append(server, upload)
    with server._db() as db:
        path = Path(db.execute("SELECT path FROM uploads WHERE id=?", (upload,)).fetchone()[0])
    path.write_bytes(b"a")
    with pytest.raises(RuntimeError):
        append(server, upload)
    with pytest.raises(RuntimeError):
        server._finish_upload("single-user", upload)
