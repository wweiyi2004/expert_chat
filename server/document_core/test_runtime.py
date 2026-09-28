from pathlib import Path
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
