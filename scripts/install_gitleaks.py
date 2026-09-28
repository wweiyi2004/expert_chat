"""Fetch a pinned, SHA-256-verified scanner; extract only its executable."""

import hashlib
import io
import os
from pathlib import Path
import sys
import tarfile
import urllib.request
import zipfile

VERSION = "8.30.1"
ASSETS = {
    "win32": (
        "windows_x64.zip",
        "d29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e",
        "gitleaks.exe",
    ),
    "linux": (
        "linux_x64.tar.gz",
        "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb",
        "gitleaks",
    ),
}


def main():
    suffix, digest, name = ASSETS[sys.platform]
    url = f"https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/gitleaks_{VERSION}_{suffix}"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(32 * 1024 * 1024)
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit("Scanner archive checksum mismatch.")
    if suffix.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            binary = archive.read(name)
    else:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            binary = archive.extractfile(name).read()
    destination = Path(__file__).resolve().parents[1] / ".tools" / name
    destination.parent.mkdir(exist_ok=True)
    destination.write_bytes(binary)
    if os.name != "nt":
        destination.chmod(0o755)
    print(destination)


if __name__ == "__main__":
    main()
