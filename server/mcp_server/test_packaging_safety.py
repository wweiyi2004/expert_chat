from pathlib import Path
import pytest
from mcp_server.packaging.check_output import check_output


@pytest.mark.parametrize("entry", ["mcp.env", "mcp_data", "custom-user-files"])
def test_packaging_refuses_runtime_data_without_touching_it(tmp_path, entry):
    target = tmp_path / entry
    target.write_text("preserved")
    with pytest.raises(RuntimeError):
        check_output(tmp_path)
    assert target.read_text() == "preserved"


def test_packaging_accepts_only_managed_output(tmp_path):
    (tmp_path / "_internal").mkdir()
    (tmp_path / "expert-chat-mcp.exe").write_bytes(b"fixture")
    check_output(tmp_path)
