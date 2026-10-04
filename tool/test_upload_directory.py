"""Validate the Android directory bridge on a disposable emulator only."""
import argparse
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.serial):
        parser.error('Only disposable emulators are allowed.')
    root = Path(__file__).resolve().parent.parent
    output = root / 'tmp' / 'upload-directory-20261005'
    output.mkdir(parents=True, exist_ok=True)

    def adb(*command, check=True):
        return subprocess.run(['adb', '-s', args.serial, *command], capture_output=True,
                              text=True, encoding='utf-8', errors='replace', timeout=20, check=check).stdout

    if adb('shell', 'getprop', 'sys.boot_completed').strip() != '1':
        raise RuntimeError('The emulator must be booted before running the test.')
    device_root = '/sdcard/Documents/ExpertChatUploadTest20261005'
    adb('shell', 'mkdir', '-p', device_root + '/child')
    for name, content in [('z-new.txt', 'new synthetic document'), ('a-old.txt', 'old synthetic document'), ('nested.txt', 'nested synthetic document')]:
        path = output / name
        path.write_text(content, encoding='utf-8')
        target = device_root + ('/child/' if name == 'nested.txt' else '/') + name
        adb('push', str(path), target)
    adb('shell', 'touch', '-t', '202610010000', device_root + '/a-old.txt')
    adb('shell', 'touch', '-t', '202610050000', device_root + '/z-new.txt')
    large = output / 'too-large.bin'
    with large.open('wb') as stream:
        stream.truncate(11 * 1024 * 1024)
    adb('push', str(large), device_root + '/too-large.bin')
    log = output / 'integration.log'
    with log.open('w', encoding='utf-8') as stream:
        process = subprocess.Popen(['C:/src/flutter/bin/flutter.bat', 'test',
                                    'integration_test/upload_directory_test.dart', '-d', args.serial,
                                    '--no-pub', '--reporter', 'expanded'], cwd=root,
                                   stdout=stream, stderr=subprocess.STDOUT)
    acted = False
    deadline = time.monotonic() + 1200

    def tap_label(labels):
        adb('shell', 'uiautomator', 'dump', '/sdcard/expert-chat-directory-ui.xml')
        xml = adb('shell', 'cat', '/sdcard/expert-chat-directory-ui.xml')
        (output / 'picker.xml').write_text(xml, encoding='utf-8')
        tree = ET.fromstring(xml)
        for node in tree.iter('node'):
            if node.attrib.get('text', '').upper() in {s.upper() for s in labels}:
                match = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.attrib.get('bounds', ''))
                if match:
                    x1, y1, x2, y2 = map(int, match.groups())
                    if x2 > x1 and y2 > y1:
                        adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
                        return True
        return False

    try:
        while process.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError('Android directory validation exceeded 20 minutes.')
            text = log.read_text(encoding='utf-8', errors='replace')
            if not acted and 'UPLOAD_DIRECTORY_READY' in text:
                picker_deadline = time.monotonic() + 120
                while time.monotonic() < picker_deadline:
                    if tap_label(['Documents']):
                        time.sleep(1)
                    if tap_label(['ExpertChatUploadTest20261005']):
                        time.sleep(1)
                        if tap_label(['Use this folder', '使用此文件夹']):
                            time.sleep(1)
                            tap_label(['Allow', '允许'])
                            acted = True
                            print('Selected the synthetic directory through Android SAF.', flush=True)
                            break
                    time.sleep(1)
                if not acted:
                    raise RuntimeError('Could not select the fixture directory; see picker.xml.')
            time.sleep(0.5)
        text = log.read_text(encoding='utf-8', errors='replace')
        if process.returncode or 'UPLOAD_DIRECTORY_RESULT' not in text:
            raise RuntimeError(f'Directory integration test failed; see {log}.')
        for line in text.splitlines():
            if 'UPLOAD_DIRECTORY_RESULT' in line:
                print(line, flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=15)


if __name__ == '__main__':
    main()
