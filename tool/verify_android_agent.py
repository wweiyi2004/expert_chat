"""Run integration verification only on our named, isolated emulator.

The helper reenables consent after Flutter installs its disposable test package,
collects owned screenshots, and presses the actual notification STOP control.
It refuses to run against physical devices or a differently named emulator.
"""
from pathlib import Path
import re
import shutil
import subprocess
import time
import json
import sys
import argparse
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ROOT = Path(__file__).resolve().parents[1]
SERIAL = 'emulator-5580'
OUT = ROOT / 'output/device-agent-evidence'


def adb(*args, binary=False):
    result = subprocess.run([shutil.which('adb'), '-s', SERIAL, *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.stdout if binary else result.stdout.decode('utf-8', errors='replace')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--target', default='integration_test/device_agent_integration_test.dart')
    args = parser.parse_args()
    assert 'ExpertChat_Verification_35' in adb('emu', 'avd', 'name'), 'Not the owned verification emulator'
    adb('shell', 'cmd', 'statusbar', 'collapse')
    OUT.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen([shutil.which('flutter'), 'test', args.target, '-d', SERIAL, '--no-pub'], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
    consent = False
    for line in process.stdout:
        print(line, end='', flush=True)
        if re.search(r'\d\d:\d\d \+0: (?!loading)', line) and not consent:
            adb('shell', 'pm', 'grant', 'com.wweiyi.expert_chat', 'android.permission.POST_NOTIFICATIONS')
            adb('shell', 'settings', 'put', 'secure', 'enabled_accessibility_services', 'com.wweiyi.expert_chat/com.wweiyi.expert_chat.DeviceAgentService')
            adb('shell', 'settings', 'put', 'secure', 'accessibility_enabled', '1')
            adb('shell', 'cmd', 'statusbar', 'collapse')
            consent = True
        if 'CONTROLLER_NATIVE_IMAGE_OK ' in line:
            report = json.loads(line.split('CONTROLLER_NATIVE_IMAGE_OK ', 1)[1].strip())
            (OUT / 'controller-native-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
            (OUT / 'controller-native-image.png').write_bytes(adb('exec-out', 'run-as', 'com.wweiyi.expert_chat', 'cat', 'files/controller-native-image.png', binary=True))
        if 'DEVICE_EVIDENCE_READY' in line:
            print('Collecting live native evidence and notification metadata', flush=True)
            (OUT / 'notification-state.txt').write_text(adb('shell', 'dumpsys', 'notification', '--noredact'), encoding='utf-8')
            for name in ['agent-before', 'agent-after']:
                (OUT / f'{name}.png').write_bytes(adb('exec-out', 'run-as', 'com.wweiyi.expert_chat', 'cat', f'files/{name}.png', binary=True))
            adb('shell', 'cmd', 'statusbar', 'expand-notifications')
        if 'DEVICE_STOP_BOUNDS ' in line:
            bounds = json.loads(line.split('DEVICE_STOP_BOUNDS ', 1)[1].strip())
            (OUT / 'stop-bounds.json').write_text(json.dumps(bounds), encoding='utf-8')
            (OUT / 'notification.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))
            x1, y1, x2, y2 = bounds
            adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
            adb('shell', 'cmd', 'statusbar', 'collapse')
            print('Pressed real notification STOP while demo app was foreground', flush=True)
    code = process.wait()
    assert code == 0, f'Integration test exited {code}'
    print(f'PASS evidence directory: {OUT}')


if __name__ == '__main__':
    main()
