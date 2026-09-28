"""Enable repository-local secret scanning without replacing an existing hook."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    current = subprocess.run(
        ["git", "config", "--get", "core.hooksPath"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    ).stdout.strip()
    default_hook = Path(
        subprocess.check_output(
            ["git", "rev-parse", "--git-path", "hooks/pre-commit"],
            cwd=ROOT,
            text=True,
        ).strip()
    )
    if not default_hook.is_absolute():
        default_hook = ROOT / default_hook
    if (current and current != ".githooks") or (not current and default_hook.exists()):
        raise SystemExit(
            "An existing hooks configuration was preserved. Add the staged Gitleaks command to that hook manually."
        )
    hook = ROOT / ".githooks/pre-commit"
    hook.chmod(0o755)
    subprocess.run(
        ["git", "config", "--local", "core.hooksPath", ".githooks"],
        cwd=ROOT,
        check=True,
    )
    print("Repository-local pre-commit secret scan enabled.")


if __name__ == "__main__":
    main()
