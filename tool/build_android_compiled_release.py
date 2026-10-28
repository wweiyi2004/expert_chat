"""Build and verify a signed Android package without installing or running it."""
from pathlib import Path
import datetime
import json
import re
import shutil
import subprocess
import zipfile
import build_tui_release as base

ROOT = base.ROOT
OUT = ROOT / 'output/android-sync-build'


def run_capture(command, filename):
    result = subprocess.run(command, capture_output=True, text=True,
                            encoding='utf-8', errors='replace')
    (OUT / filename).write_text(result.stdout + result.stderr, encoding='utf-8')
    if result.returncode:
        raise RuntimeError(f'{filename}: command exited {result.returncode}')
    return result.stdout + result.stderr


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    base.OUT = OUT
    assert base.STAGE.resolve() == Path('E:/wweiyi/tmp/expert-chat-ui-redesign-build-20261025-022630').resolve()
    manifest = base.snapshot()
    rel = 'tool/build_android_compiled_release.py'
    manifest[rel] = {'sha256': base.digest(ROOT / rel), 'bytes': (ROOT / rel).stat().st_size}
    base.write('sources.json', manifest)
    for rel, info in manifest.items():
        target = base.STAGE / rel
        assert target.resolve().is_relative_to(base.STAGE.resolve())
        if target.is_file() and base.digest(target) == info['sha256']:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, target)
    base.run('android-pub', base.FLUTTER + ['pub', 'get', '--offline', '--enforce-lockfile'], base.STAGE)
    # The shared checkout also runs Flutter integration tests. Pub generates
    # their registrant entry, while the release Gradle graph excludes the
    # development plugin. Remove only that generated block in the build copy.
    registrant = base.STAGE / 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
    assert registrant.resolve().is_relative_to(base.STAGE.resolve())
    lines = registrant.read_text(encoding='utf-8').splitlines(keepends=True)
    matches = [i for i, line in enumerate(lines)
               if 'add(new dev.flutter.plugins.integration_test.IntegrationTestPlugin())' in line]
    for index in reversed(matches):
        assert lines[index - 1].strip() == 'try {'
        assert lines[index + 1].strip() == '} catch (Exception e) {'
        assert 'Error registering plugin integration_test,' in lines[index + 2]
        assert lines[index + 3].strip() == '}'
        del lines[index - 1:index + 4]
    registrant.write_text(''.join(lines), encoding='utf-8')
    assert 'integration_test' not in registrant.read_text(encoding='utf-8')
    signing = (ROOT / 'android/key.properties').read_text(encoding='utf-8')
    match = re.search(r'(?m)^storeFile\s*=\s*(.*)$', signing)
    if match is None:
        raise RuntimeError('Release signing is not configured')
    store = Path(match[1].strip().replace('\\\\', '\\').replace('\\:', ':'))
    if not store.is_absolute():
        store = (ROOT / 'android' / store).resolve()
    assert store.is_file()
    private = base.STAGE / 'android/key.properties'
    assert not private.exists(), 'Staging already has a signing configuration'
    try:
        private.write_text(re.sub(r'(?m)^storeFile\s*=.*$',
            lambda _: 'storeFile=' + store.as_posix(), signing), encoding='utf-8')
        base.run('android-build', base.FLUTTER + ['build', 'apk', '--release', '--no-pub', '--target', 'lib/main.dart'], base.STAGE)
    finally:
        private.unlink(missing_ok=True)
    changed = [rel for rel, info in manifest.items() if base.digest(ROOT / rel) != info['sha256']]
    assert not changed, f'Source changed during build: {changed}'
    assert base.digest(base.STAGE / 'pubspec.lock') == manifest['pubspec.lock']['sha256']
    version = re.search(r'(?m)^version:\s*(\S+)', (ROOT / 'pubspec.yaml').read_text(encoding='utf-8'))[1]
    release = ROOT / 'output/releases' / ('android-sync-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    release.mkdir()
    apk = release / f'expert-chat-android-{version}.apk'
    shutil.copy2(base.STAGE / 'build/app/outputs/flutter-apk/app-release.apk', apk)
    preflight = json.loads((ROOT / 'output/redesign-review/build-preflight.json').read_text(encoding='utf-8'))
    tools = Path(preflight['android_sdk']) / 'build-tools/36.1.0'
    signature = run_capture([str(tools / 'apksigner.bat'), 'verify', '--verbose', '--print-certs', str(apk)], 'signature.txt')
    certificate = re.search(r'certificate SHA-256 digest:\s*([0-9a-fA-F]+)', signature)[1].upper()
    previous = json.loads((ROOT / 'output/task-core-review/android-package-verification.json').read_text(encoding='utf-8'))
    assert certificate == previous['certificate_sha256']
    assert re.search(r'Verified using v2 scheme.*true', signature)
    badging = run_capture([str(tools / 'aapt.exe'), 'dump', 'badging', str(apk)], 'badging.txt')
    package = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    name, code = version.split('+')
    assert package.groups() == ('com.wweiyi.expert_chat', code, name)
    assert 'application-debuggable' not in badging
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        assert not any('integration_test' in n or n.endswith('kernel_blob.bin') for n in names)
        abis = sorted(n.split('/')[1] for n in names if n.startswith('lib/') and n.endswith('/libapp.so'))
        assert abis == ['arm64-v8a', 'armeabi-v7a', 'x86_64']
    result = {'apk': str(apk), 'version': version, 'bytes': apk.stat().st_size,
        'sha256': base.digest(apk), 'signature_v2_verified': True,
        'certificate_matches_previous': True, 'native_abis': abis,
        'source_manifest_sha256': base.digest(OUT / 'sources.json'),
        'installed': False, 'device_tests_run': False, 'private_signing_copy_removed': not private.exists()}
    result['test_plugin_registration_excluded'] = True
    base.write('release.json', result)
    (release / 'release-manifest.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    shutil.copy2(OUT / 'sources.json', release / 'source-manifest.json')
    print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    main()
