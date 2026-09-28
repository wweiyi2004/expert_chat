"""Record provenance for review; dirty builds are rejected by default."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="+", type=Path)
    parser.add_argument(
        "--output", type=Path, default=ROOT / "output/release-manifest.json"
    )
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        help="Review evidence only; never marks a build releasable.",
    )
    args = parser.parse_args()
    dirty = bool(git("status", "--porcelain"))
    if dirty and not args.allow_dirty:
        raise SystemExit(
            "Release provenance requires a clean commit. Commit reviewed changes first."
        )
    files = []
    for path in args.artifacts:
        with path.open("rb") as source:
            hasher = hashlib.sha256()
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                hasher.update(chunk)
            digest = hasher.hexdigest()
        files.append(
            {"name": path.name, "bytes": path.stat().st_size, "sha256": digest}
        )
    data = {
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "commit": git("rev-parse", "HEAD"),
        "dirty": dirty,
        "eligibleForReleaseReview": not dirty,
        "version": re.search(
            r"^version:\s*(.+)$",
            (ROOT / "pubspec.yaml").read_text(encoding="utf-8"),
            re.M,
        )[1],
        "flutter": json.loads((ROOT / ".fvmrc").read_text())["flutter"],
        "schema": int(
            re.search(
                r"schemaVersion => (\d+)",
                (ROOT / "lib/data/db/app_database.dart").read_text(encoding="utf-8"),
            )[1]
        ),
        "backupFormat": int(
            re.search(
                r"static const version = (\d+)",
                (ROOT / "lib/data/backup_codec.dart").read_text(encoding="utf-8"),
            )[1]
        ),
        "pubLockSha256": hashlib.sha256(
            (ROOT / "pubspec.lock").read_bytes()
        ).hexdigest(),
        "artifacts": files,
        "note": "Provenance only. Signing, device acceptance and Shorebird baseline still require release evidence.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(args.output)


if __name__ == "__main__":
    main()
