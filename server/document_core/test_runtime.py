from pathlib import Path
import json
from zipfile import ZIP_DEFLATED, ZipFile

import pytest

from document_core.limits import DocumentLimitError, validate_input
from document_core.operations import DocumentOperationError
from document_core.runtime import extract_document_text, edit_document_path, run_document_job


def test_zip_expansion_rejected_before_parser(tmp_path):
    path = tmp_path / "compressed.docx"
    with ZipFile(path, "w", compression=ZIP_DEFLATED) as archive:
        archive.writestr("word/document.xml", b"a" * 2_000_000)
    with pytest.raises(DocumentLimitError):
        validate_input(path, path.name)
    with pytest.raises(DocumentOperationError) as error:
        extract_document_text(path, path.name)
    assert error.value.code == "resource_limit"


def test_worker_edit_and_extract(tmp_path):
    source, target = tmp_path / "source.txt", tmp_path / "target.txt"
    source.write_text("original", encoding="utf-8")
    output = edit_document_path(
        source,
        target,
        source.name,
        {
            "schema_version": 1,
            "format": "txt",
            "ops": [{"op": "replace_text", "find": "original", "replace": "updated"}],
        },
    )
    assert output.filename.endswith(".txt")
    assert extract_document_text(target, target.name) == "updated"
    assert source.read_text() == "original"


def test_wall_timeout_terminates_worker_and_next_job_can_run(tmp_path):
    source = tmp_path / "source.txt"
    source.write_text("safe")
    with pytest.raises(DocumentOperationError) as error:
        run_document_job("extract", source, source.name, timeout_seconds=0.0001)
    assert error.value.code == "resource_limit"
    assert extract_document_text(source, source.name) == "safe"


def test_text_budget_does_not_corrupt_a_multibyte_boundary(tmp_path, monkeypatch):
    from document_core import extraction

    source = tmp_path / "utf8.txt"
    source.write_text("中文", encoding="utf-8")
    monkeypatch.setattr(extraction, "MAX_TEXT_CHARS", 1)
    assert extraction.extract_text(source, source.name) == "中"


@pytest.mark.parametrize(
    "kind,expected",
    [
        ("parser", "invalid_document"),
        ("limit", "resource_limit"),
        ("memory", "resource_limit"),
        ("bug", "internal_error"),
    ],
)
def test_worker_classifies_errors_without_hiding_programming_bugs(
    tmp_path, monkeypatch, caplog, kind, expected
):
    from pypdf.errors import PdfReadError
    from document_core import extraction, runtime

    errors = {
        "parser": PdfReadError("malformed synthetic PDF"),
        "limit": DocumentLimitError("synthetic size limit"),
        "memory": MemoryError(),
        "bug": AttributeError("synthetic programming error"),
    }

    def fail(*_):
        raise errors[kind]

    monkeypatch.setattr(runtime, "_limit_resources", lambda *_: None)
    monkeypatch.setattr(extraction, "extract_text", fail)
    result_path = tmp_path / "result.json"
    runtime._worker(
        "extract", (tmp_path / "synthetic.pdf", "synthetic.pdf"), result_path, 512 * 1024 * 1024, 30
    )
    result = json.loads(result_path.read_text())
    assert result["ok"] is False
    assert result["code"] == expected
    if kind == "bug":
        assert "synthetic programming error" not in result["message"]
        assert any(
            record.exc_info and record.exc_info[0] is AttributeError for record in caplog.records
        )


def test_worker_setup_failure_is_logged_as_internal_error(tmp_path, monkeypatch, caplog):
    from document_core import runtime

    def fail(*_):
        raise OSError("synthetic job object setup error")

    monkeypatch.setattr(runtime, "_limit_resources", fail)
    result_path = tmp_path / "result.json"
    runtime._worker("extract", (), result_path, 512 * 1024 * 1024, 30)
    assert json.loads(result_path.read_text())["code"] == "internal_error"
    assert any(record.exc_info and record.exc_info[0] is OSError for record in caplog.records)


def test_worker_does_not_misclassify_interrupt_as_resource_limit(tmp_path, monkeypatch):
    from document_core import runtime

    def interrupt(*_):
        raise KeyboardInterrupt()

    monkeypatch.setattr(runtime, "_limit_resources", interrupt)
    result_path = tmp_path / "result.json"
    with pytest.raises(KeyboardInterrupt):
        runtime._worker("extract", (), result_path, 512 * 1024 * 1024, 30)
    assert not result_path.exists()


def test_unknown_worker_operation_reports_internal_error_across_process_boundary():
    with pytest.raises(DocumentOperationError) as error:
        run_document_job("unknown")
    assert error.value.code == "internal_error"
