"""Cross-platform local/CI checks. Every subprocess failure stops the check."""

from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def run(command, cwd=ROOT):
    executable = shutil.which(command[0])
    if executable is None:
        raise RuntimeError(f"Missing tool: {command[0]}")
    print("+ " + " ".join(command), flush=True)
    subprocess.run([executable, *command[1:]], cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scope", choices=["all", "client", "server", "web", "desktop"], default="all"
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Static checks only; does not replace release checks.",
    )
    parser.add_argument(
        "--security",
        action="store_true",
        help="Query advisory services; network failure is a failure.",
    )
    parser.add_argument(
        "--native",
        action="store_true",
        help="Run host-native reliability test and Android debug build.",
    )
    args = parser.parse_args()
    os.chdir(ROOT)
    started = time.monotonic()
    result = {
        "scope": args.scope,
        "quick": args.quick,
        "security": args.security,
        "native": args.native,
        "passed": False,
    }
    try:
        run([sys.executable, "scripts/check_repository.py"])
        if args.scope in ("all", "client"):
            run(
                [
                    "dart",
                    "format",
                    "--output=none",
                    "--set-exit-if-changed",
                    "lib",
                    "test",
                    "integration_test",
                    "tool",
                ]
            )
            run(["flutter", "analyze", "--no-pub"])
            if not args.quick:
                run(["flutter", "test", "--no-pub", "--coverage"])
            if args.security:
                data = subprocess.check_output(
                    [shutil.which("flutter"), "pub", "outdated", "--json"], cwd=ROOT
                )
                outdated = json.loads(data)
                flagged = [
                    p["package"]
                    for p in outdated.get("packages", [])
                    if p.get("isCurrentAffectedByAdvisory")
                    or p.get("isCurrentRetracted")
                ]
                if flagged:
                    raise RuntimeError(
                        "Dart dependencies require review: " + ", ".join(flagged)
                    )
        if args.scope in ("all", "server"):
            run(["uv", "sync", "--project", "server", "--frozen"])
            run(
                [
                    "uv",
                    "run",
                    "--project",
                    "server",
                    "--frozen",
                    "ruff",
                    "check",
                    "server",
                ]
            )
            # Export without a command/header so working directory and OS do not
            # alter the lock comparison. Never silently refresh a release lock.
            exported = subprocess.check_output(
                [
                    shutil.which("uv"),
                    "export",
                    "--project",
                    "server",
                    "--frozen",
                    "--no-dev",
                    "--no-emit-project",
                    "--no-header",
                ]
            )
            if exported.decode("utf-8").replace("\r\n", "\n") != (
                ROOT / "server/requirements.lock"
            ).read_text(encoding="utf-8"):
                raise RuntimeError(
                    "server/requirements.lock is stale; regenerate it from uv.lock."
                )
            if not args.quick:
                run(
                    [
                        "uv",
                        "run",
                        "--project",
                        "server",
                        "--frozen",
                        "pytest",
                        "-c",
                        "server/pyproject.toml",
                        "server/gateway",
                        "server/mcp_server",
                        "server/document_core",
                        "-q",
                    ]
                )
            if args.security:
                run(
                    [
                        "uv",
                        "run",
                        "--project",
                        "server",
                        "--frozen",
                        "pip-audit",
                        "-r",
                        "server/requirements.lock",
                        "--disable-pip",
                        "--no-deps",
                    ]
                )
        if args.scope in ("all", "desktop"):
            manifest = "next/Cargo.toml"
            run(["cargo", "fmt", "--manifest-path", manifest, "--", "--check"])
            run(["cargo", "clippy", "--manifest-path", manifest, "--locked", "--all-targets", "--", "-D", "warnings"])
            if not args.quick:
                run(["cargo", "test", "--manifest-path", manifest, "--locked"])
                run(["cargo", "build", "--manifest-path", manifest, "--locked"])
                run([sys.executable, "-X", "utf8", "next/verification/test_workspace_mcp.py"])
        if args.scope in ("all", "web"):
            for name in ["typecheck", "lint"]:
                run(["npm", "run", name], ROOT / "remote_lab_ui")
            if not args.quick:
                run(["npm", "test"], ROOT / "remote_lab_ui")
            if args.security:
                run(["npm", "run", "audit"], ROOT / "remote_lab_ui")
        if args.native:
            device = (
                "windows"
                if sys.platform == "win32"
                else "macos"
                if sys.platform == "darwin"
                else "linux"
            )
            run(
                [
                    "flutter",
                    "test",
                    "integration_test/reliability_smoke_test.dart",
                    "-d",
                    device,
                    "--no-pub",
                ]
            )
            run(
                [
                    "flutter",
                    "build",
                    "apk",
                    "--debug",
                    "--target-platform",
                    "android-arm64",
                    "--no-pub",
                ]
            )
        result["passed"] = True
    finally:
        result["seconds"] = round(time.monotonic() - started, 2)
        out = ROOT / "output/checks"
        out.mkdir(parents=True, exist_ok=True)
        (out / f"{args.scope}.json").write_text(
            json.dumps(result, indent=2) + "\n", encoding="utf-8"
        )


if __name__ == "__main__":
    main()
