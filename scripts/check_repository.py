"""Small repository policy checks, independent of third-party Python packages."""

import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    errors = []
    for path in [
        "server/mcp.env",
        "server/mcp_data/documents.sqlite3",
        "mcp.env",
        "mcp_data/example.txt",
        "remote_lab_ui/tsconfig.tsbuildinfo",
    ]:
        if subprocess.run(
            ["git", "check-ignore", "-q", "--no-index", path], cwd=ROOT
        ).returncode:
            errors.append("Runtime file is not ignored: " + path)
    for path in (ROOT / "lib/domain").rglob("*.dart"):
        if re.search(
            r"(?:import|export)\s+['\"][^'\"]*(?:/state/|/features/)",
            path.read_text(encoding="utf-8"),
        ):
            errors.append(
                "Domain depends on a controller/UI: " + str(path.relative_to(ROOT))
            )
    for path in (ROOT / "test").glob("*_test.dart"):
        text = path.read_text(encoding="utf-8")
        if re.search(r"\bskip:\s*true\b", text):
            errors.append(
                "Unconditional skipped test needs removal or a dated reason: "
                + path.name
            )
    sdk = json.loads((ROOT / ".fvmrc").read_text())["flutter"]
    for path in (ROOT / ".github/workflows").glob("*.yaml"):
        text = path.read_text(encoding="utf-8")
        if "uses:" in text and not re.search(
            r"permissions:\s*\n\s+contents: read", text
        ):
            errors.append(
                "Workflow must request minimal contents permission: " + path.name
            )
        for match in re.finditer(r"uses:\s+([^\s#]+)", text):
            if not re.search(r"@[0-9a-f]{40}$", match[1]):
                errors.append("Action is not pinned to a commit: " + match[1])
        for version in re.findall(r"flutter-version:\s*[\"\']?([\d.]+)", text):
            if version != sdk:
                errors.append("Flutter version differs from .fvmrc: " + path.name)
    if errors:
        raise SystemExit("\n".join(errors))
    print("Repository policies passed.")


if __name__ == "__main__":
    main()
