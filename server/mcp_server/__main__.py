"""Run Expert Chat MCP Server as a standalone process.

Works as `python -m mcp_server` from the `server` directory, and as the
PyInstaller entry point on Windows and Linux.
"""

from __future__ import annotations

import argparse
import os
import multiprocessing
import secrets
import sys
from pathlib import Path


SERVER_VERSION = "1.0.0"
_DEFAULT_HOST = "127.0.0.1"
_DEFAULT_PORT = 8790


def install_server_path() -> Path:
    """Put `server/` on sys.path so `mcp_server`, `doc_edit` and `gateway` import."""
    if getattr(sys, "frozen", False):
        # PyInstaller extracts to _MEIPASS; packages are compiled in.
        return Path(sys.executable).resolve().parent
    here = Path(__file__).resolve().parent
    server_root = here.parent
    root = str(server_root)
    if root not in sys.path:
        sys.path.insert(0, root)
    return server_root


def app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path.cwd()


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key:
            values[key] = value
    return values


def write_env_file(path: Path, values: dict[str, str]) -> None:
    lines = [
        "# Expert Chat MCP Server",
        f"MCP_API_TOKEN={values.get('MCP_API_TOKEN', '')}",
        f"MCP_HOST={values.get('MCP_HOST', _DEFAULT_HOST)}",
        f"MCP_PORT={values.get('MCP_PORT', str(_DEFAULT_PORT))}",
        f"MCP_DATA_DIR={values.get('MCP_DATA_DIR', './mcp_data')}",
        f"MCP_PUBLIC_URL={values.get('MCP_PUBLIC_URL', '')}",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def apply_env(values: dict[str, str]) -> None:
    for key, value in values.items():
        if key and key not in os.environ:
            os.environ[key] = value


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="expert-chat-mcp",
        description="Expert Chat 文档 MCP Server（Windows / Linux 独立进程）",
    )
    parser.add_argument("--host", help="监听地址，默认 127.0.0.1")
    parser.add_argument("--port", type=int, help="监听端口，默认 8790")
    parser.add_argument("--token", help="MCP_API_TOKEN；省略则读配置或自动生成")
    parser.add_argument(
        "--data-dir",
        help="文件与 SQLite 目录，默认程序目录下 mcp_data",
    )
    parser.add_argument(
        "--env-file",
        help="配置文件路径，默认程序目录 mcp.env",
    )
    parser.add_argument("--version", action="store_true", help="打印版本后退出")
    return parser.parse_args(argv)


def resolve_runtime(args, root: Path, environ):
    """CLI > environment > config file > defaults, with no writes here."""
    env_path = Path(args.env_file) if args.env_file else root / "mcp.env"
    values = load_env_file(env_path)
    values.update(
        {key: value for key, value in environ.items() if key.startswith(("MCP_", "DOCUMENT_"))}
    )
    for option, key in [
        (args.token, "MCP_API_TOKEN"),
        (args.host, "MCP_HOST"),
        (args.port, "MCP_PORT"),
        (args.data_dir, "MCP_DATA_DIR"),
    ]:
        if option is not None:
            values[key] = str(option)
    values.setdefault("MCP_HOST", _DEFAULT_HOST)
    values.setdefault("MCP_PORT", str(_DEFAULT_PORT))
    values.setdefault("MCP_DATA_DIR", str((root / "mcp_data").resolve()))
    generated = not values.get("MCP_API_TOKEN", "").strip()
    if generated:
        values["MCP_API_TOKEN"] = secrets.token_urlsafe(24)
    else:
        values["MCP_API_TOKEN"] = values["MCP_API_TOKEN"].strip()
    if not values.get("MCP_PUBLIC_URL"):
        values["MCP_PUBLIC_URL"] = f"http://{values['MCP_HOST']}:{values['MCP_PORT']}/mcp"
    # Environment-only deployments must not persist their credentials or create
    # a config file beside an executable. Explicit --token and generated keys
    # retain the standalone launcher's established persistence behavior.
    return values, env_path, generated or args.token is not None


def main(argv: list[str] | None = None) -> int:
    install_server_path()
    args = parse_args(argv)
    if args.version:
        print(f"expert-chat-mcp {SERVER_VERSION}")
        return 0
    values, env_path, persist = resolve_runtime(args, app_dir(), os.environ)
    apply_env(values)
    for key, value in values.items():
        if key.startswith(("MCP_", "DOCUMENT_")):
            os.environ[key] = value
    host, port = values["MCP_HOST"], int(values["MCP_PORT"])
    if persist:
        env_path.parent.mkdir(parents=True, exist_ok=True)
        write_env_file(env_path, values)
        if os.name == "posix":
            env_path.chmod(0o600)
        print(f"配置已写入 {env_path}")

    import uvicorn
    from mcp_server.app.main import app

    print(f"Expert Chat MCP Server {SERVER_VERSION}")
    print(f"Endpoint: {os.environ['MCP_PUBLIC_URL']}")
    print(f"Data dir: {os.environ['MCP_DATA_DIR']}")
    print("在 App 设置中填写上述地址和已配置的 MCP_API_TOKEN。")
    uvicorn.run(app, host=host, port=port, workers=1)
    return 0


if __name__ == "__main__":
    multiprocessing.freeze_support()
    raise SystemExit(main())
