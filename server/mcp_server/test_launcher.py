from pathlib import Path

from mcp_server.__main__ import load_env_file, parse_args, write_env_file, resolve_runtime


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


def test_environment_data_directory_and_token_override_file_without_persisting(tmp_path):
    config = tmp_path / "mcp.env"
    config.write_text("MCP_DATA_DIR=old-data\nMCP_API_TOKEN=file-token\n")
    values, path, persist = resolve_runtime(
        parse_args([]),
        tmp_path,
        {
            "MCP_DATA_DIR": str(tmp_path / "environment-data"),
            "MCP_API_TOKEN": "environment-token",
        },
    )
    assert values["MCP_DATA_DIR"] == str(tmp_path / "environment-data")
    assert values["MCP_API_TOKEN"] == "environment-token"
    assert path == config and not persist
    assert "file-token" in config.read_text()


def test_cli_has_final_precedence_and_environment_only_launch_does_not_create_config(tmp_path):
    values, _, persist = resolve_runtime(
        parse_args(["--data-dir", "explicit-data", "--port", "9001"]),
        tmp_path,
        {
            "MCP_API_TOKEN": "synthetic-env-token",
            "MCP_DATA_DIR": "env-data",
            "MCP_PORT": "9002",
        },
    )
    assert values["MCP_DATA_DIR"] == "explicit-data"
    assert values["MCP_PORT"] == "9001"
    assert not persist
    assert not (tmp_path / "mcp.env").exists()


def test_first_launch_generates_a_token_and_requests_persistence(tmp_path):
    values, _, persist = resolve_runtime(parse_args([]), tmp_path, {})
    assert len(values["MCP_API_TOKEN"]) >= 24
    assert values["MCP_DATA_DIR"] == str((tmp_path / "mcp_data").resolve())
    assert persist
