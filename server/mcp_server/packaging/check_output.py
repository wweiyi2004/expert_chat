"""Refuse to let PyInstaller clean a directory containing runtime/user data."""

from pathlib import Path
import sys


def check_output(path: Path) -> None:
    if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
        raise RuntimeError("Packaging output must not be a symlink or junction.")
    if path.exists():
        allowed = {"expert-chat-mcp", "expert-chat-mcp.exe", "_internal", "mcp.env.example"}
        if any(entry.name not in allowed for entry in path.iterdir()):
            raise RuntimeError(
                "Packaging output contains runtime configuration/data or unknown files. Choose a fresh dist directory; existing files will not be cleaned."
            )


if __name__ == "__main__":
    check_output(Path(sys.argv[1]))
