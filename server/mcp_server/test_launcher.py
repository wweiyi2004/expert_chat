from pathlib import Path

from mcp_server.__main__ import load_env_file, parse_args, write_env_file


def test_load_env_file_ignores_comments(tmp_path: Path) -> None:
    path = tmp_path / "mcp.env"
    path.write_text(
        "# comment\nMCP_API_TOKEN=abc\nMCP_PORT=8791\n",
        encoding="utf-8",
    )
    values = load_env_file(path)
    assert values["MCP_API_TOKEN"] == "abc"
    assert values["MCP_PORT"] == "8791"


def test_write_env_file_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "mcp.env"
    write_env_file(
        path,
        {
            "MCP_API_TOKEN": "tok",
            "MCP_HOST": "0.0.0.0",
            "MCP_PORT": "9000",
            "MCP_DATA_DIR": "/data",
            "MCP_PUBLIC_URL": "http://127.0.0.1:9000/mcp",
        },
    )
    values = load_env_file(path)
    assert values["MCP_API_TOKEN"] == "tok"
    assert values["MCP_HOST"] == "0.0.0.0"
    assert values["MCP_PORT"] == "9000"


def test_parse_args_version() -> None:
    args = parse_args(["--version"])
    assert args.version is True
