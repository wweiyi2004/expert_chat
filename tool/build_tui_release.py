"""Freeze, validate and build the TUI revision without overwriting a release.

Run --freeze after all writers finish, --validate, then --build. No signing,
private settings, tokens, or live user data are copied into the source cache.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "output/tui-build"
STAGE = Path("E:/wweiyi/tmp/expert-chat-ui-redesign-build-20261025-022630")
EXCLUDE = {".git", ".dart_tool", "build", ".gradle", ".cxx", "ephemeral", ".symlinks", "output", "node_modules", "target", "__pycache__"}
FLUTTER = ["C:/src/flutter/bin/flutter.bat", "--no-version-check", "--suppress-analytics"]
ENV = {**os.environ, "FLUTTER_SUPPRESS_ANALYTICS": "true", "CI": "true", "CARGO_BUILD_JOBS": "4"}
ENV["PATH"] = str(ROOT / ".tools") + os.pathsep + ENV.get("PATH", "")
ENV["EXPERT_MEDIA_PYTHON"] = str(ROOT / "server/.venv/Scripts/python.exe")

def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def snapshot():
    files = []
    for folder in ["bin", "lib", "test", "integration_test", "assets", "third_party", "windows", "android", "next", "design/tui"]:
        for path in (ROOT / folder).rglob("*"):
            if path.is_file() and not EXCLUDE.intersection(path.relative_to(ROOT).parts) and path.name not in {"local.properties", "key.properties", "BUILD-LOG.md"} and path.suffix.lower() not in {".jks", ".keystore"}:
                files.append(path)
    for name in ["pubspec.yaml", "pubspec.lock", "analysis_options.yaml", "shorebird.yaml", ".metadata", ".fvmrc", "scripts/expert.cmd", "scripts/expert.ps1", "scripts/EXPERT-TUI.md", "tool/check_tui_contract.py", "tool/test_tui_single_instance.py", "tool/tui_live_smoke.py", "tool/build_tui_release.py"]:
        if (ROOT / name).is_file():
            files.append(ROOT / name)
    files.extend(path for path in (ROOT / "tool").glob("*.dart") if path.is_file())
    for name in ["tool/build_desktop_host.ps1", "tool/host_e2e.py", "tool/host_ui_fixture.py", "tool/host_load_test.py", "server/desktop_media_worker.py", "server/test_desktop_media_worker.py", "server/pyproject.toml", "server/uv.lock", "docs/SHARED-HOST.md"]:
        if (ROOT / name).is_file():
            files.append(ROOT / name)
    return {p.relative_to(ROOT).as_posix(): {"sha256": digest(p), "bytes": p.stat().st_size} for p in sorted(set(files))}

def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def run(label, args, cwd=ROOT):
    start = time.monotonic()
    with (OUT / f"{label}.log").open("w", encoding="utf-8") as log:
        p = subprocess.run(args, cwd=cwd, env=ENV, stdout=log, stderr=subprocess.STDOUT)
    result = {"label": label, "exit_code": p.returncode, "seconds": round(time.monotonic() - start, 2), "command": [str(a) for a in args]}
    write(f"{label}.result.json", result)
    print(json.dumps(result), flush=True)
    if p.returncode:
        raise RuntimeError(f"{label} failed; inspect {OUT / (label + '.log')}")
    return result

def load_freeze():
    manifest = json.loads((OUT / "sources.json").read_text(encoding="utf-8"))
    current = snapshot()
    changed = [p for p in sorted(set(manifest) | set(current)) if manifest.get(p) != current.get(p)]
    if changed:
        raise RuntimeError(f"Frozen source changed; review and freeze again: {changed}")
    return manifest

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["freeze", "validate", "build"])
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.action == "freeze":
        data = snapshot()
        write("sources.json", data)
        write("freeze.json", {"files": len(data), "sha256": digest(OUT / "sources.json"), "created": datetime.datetime.now(datetime.timezone.utc).isoformat()})
        print(f"Frozen {len(data)} files")
        return
    manifest = load_freeze()
    if args.action == "validate":
        checks = []
        prior_file = OUT / "validation-sources.json"
        prior_result = OUT / "validation.json"
        def flutter_inputs(values):
            return {p: v for p, v in values.items() if p.startswith(("lib/", "test/", "integration_test/", "assets/", "third_party/", "android/", "windows/")) or "/" not in p}
        if prior_file.exists() and prior_result.exists():
            prior = json.loads(prior_file.read_text(encoding="utf-8"))
            previous = json.loads(prior_result.read_text(encoding="utf-8"))
            if previous["manifest_sha256"] == digest(prior_file) and flutter_inputs(prior) == flutter_inputs(manifest):
                checks = [{**item, "reused_unchanged_flutter_inputs": True, "validated_manifest_sha256": previous["manifest_sha256"]}
                          for item in previous["checks"] if item["label"] in {"final-flutter-analyze", "final-flutter-tests"} and item["exit_code"] == 0]
                assert len(checks) == 2
                print("Reusing passed Flutter checks: all Flutter source, tests, assets and platform inputs are byte-identical", flush=True)
        if not checks:
            checks = [
                run("final-flutter-analyze", FLUTTER + ["analyze", "--no-pub"]),
                run("final-flutter-tests", FLUTTER + ["test", "--no-pub", "--reporter", "expanded"]),
            ]
        checks.extend([
            run("final-cargo-build", ["cargo", "build", "--manifest-path", "next/Cargo.toml", "--locked"]),
            run("final-cargo-tests", ["cargo", "test", "--manifest-path", "next/Cargo.toml", "--locked"]),
            run("final-cargo-clippy", ["cargo", "clippy", "--manifest-path", "next/Cargo.toml", "--locked", "--all-targets", "--", "-D", "warnings"]),
            run("final-native-single-instance", ["python", "tool/test_tui_single_instance.py"]),
        ])
        load_freeze()
        write("validation.json", {"manifest_sha256": digest(OUT / "sources.json"), "checks": checks})
        write("validation-sources.json", manifest)
        return
    validation = json.loads((OUT / "validation.json").read_text(encoding="utf-8"))
    assert validation["manifest_sha256"] == digest(OUT / "sources.json"), "Validate this exact freeze first"
    assert STAGE.resolve() == Path("E:/wweiyi/tmp/expert-chat-ui-redesign-build-20261025-022630").resolve()
    # This is the owned, unpublished cache. Remove only previously manifest-owned
    # source files that are absent from the current frozen revision.
    previous_file = OUT / "staged-sources.json"
    previous = json.loads(previous_file.read_text(encoding="utf-8")) if previous_file.exists() else json.loads((ROOT / "output/task-core-review/task-core-final-sources.json").read_text(encoding="utf-8"))
    for rel in set(previous) - set(manifest):
        target = (STAGE / rel).resolve()
        assert target.is_relative_to(STAGE.resolve())
        if target.is_file():
            target.unlink()
    for rel, info in manifest.items():
        target = STAGE / rel
        assert target.resolve().is_relative_to(STAGE.resolve())
        if target.is_file() and digest(target) == info["sha256"]:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, target)
    write("staged-sources.json", manifest)
    run("windows-pub", FLUTTER + ["pub", "get", "--offline", "--enforce-lockfile"], STAGE)
    run("windows-build", FLUTTER + ["build", "windows", "--release", "--target", "lib/main.dart"], STAGE)
    run("tui-release-build", ["cargo", "build", "--manifest-path", "next/Cargo.toml", "--release", "--locked", "-p", "expert-tui"], ROOT)
    load_freeze()
    for rel, info in manifest.items():
        if rel.startswith(("lib/", "assets/", "next/", "design/tui/")):
            assert digest(STAGE / rel) == info["sha256"], f"Build changed source {rel}"
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    release = ROOT / "output/releases" / ("tui-" + stamp)
    assert not release.exists()
    package = release / "ExpertChat-TUI"
    shutil.copytree(STAGE / "build/windows/x64/runner/Release", package)
    for name in ["expert_chat.exe", "expert-desktop.exe", "flutter_windows.dll", "data/app.so"]:
        assert (package / name).is_file(), name
    shutil.copy2(ROOT / "next/target/release/expert-tui.exe", package / "expert-tui.exe")
    for name in ["expert.cmd", "expert.ps1"]:
        path = ROOT / "scripts" / name
        if path.exists():
            shutil.copy2(path, package / name)
    archive = release / "ExpertChat-TUI-windows.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(package.rglob("*")):
            if path.is_file():
                z.write(path, str(path.relative_to(release)))
    result = {"directory": str(release), "package": str(package), "gui": str(package / "expert_chat.exe"), "tui": str(package / "expert-tui.exe"), "zip": str(archive), "zip_sha256": digest(archive), "sources_sha256": digest(OUT / "sources.json")}
    write("release.json", result)
    print(json.dumps(result, indent=2), flush=True)

if __name__ == "__main__":
    main()
