"""Drive the Android background SSE integration test on a disposable emulator.

Usage: python tool/test_background_generation.py --serial emulator-5566
Requires a booted emulator, adb and flutter on PATH (or explicit CLI paths).
Never runs on a physical phone or accesses a real provider/account.
"""

import argparse
from pathlib import Path
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--flutter', default='flutter')
    args = parser.parse_args()
    if not re.fullmatch(r'emulator-\d+', args.serial):
        parser.error('Use a disposable emulator, not a physical device.')
    root = Path(__file__).resolve().parent.parent
    output = root / 'tmp' / 'background-stream'
    output.mkdir(parents=True, exist_ok=True)

    def adb(*command, check=True):
        return subprocess.run(
            [args.adb, '-s', args.serial, *command], capture_output=True,
            text=True, encoding='utf-8', errors='replace', timeout=15, check=check,
        ).stdout

    if adb('shell', 'getprop', 'sys.boot_completed').strip() != '1':
        raise RuntimeError('Emulator is not booted.')
    log = output / 'android-integration.log'
    with log.open('w', encoding='utf-8') as stream:
        process = subprocess.Popen([
            args.flutter, 'test', 'integration_test/background_generation_test.dart',
            '-d', args.serial, '--no-pub', '--reporter', 'expanded',
        ], cwd=root, stdout=stream, stderr=subprocess.STDOUT)
    background_at = None
    locked = inspected = resumed = False
    deadline = time.monotonic() + 900
    last_grant = 0
    try:
        while process.poll() is None:
            now = time.monotonic()
            if now >= deadline:
                raise TimeoutError('Build/device test exceeded 15 minutes.')
            if now - last_grant >= 3 and background_at is None:
                # Permission is granted only to the disposable test app.
                adb('shell', 'pm', 'grant', 'com.wweiyi.expert_chat',
                    'android.permission.POST_NOTIFICATIONS', check=False)
                last_grant = now
            text = log.read_text(encoding='utf-8', errors='replace')
            if background_at is None and 'BACKGROUND_STREAM_READY' in text:
                adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
                background_at = time.monotonic()
                print('Sent Home; testing background reception.', flush=True)
            if background_at is not None:
                elapsed = time.monotonic() - background_at
                if elapsed >= 3 and not locked:
                    adb('shell', 'input', 'keyevent', 'KEYCODE_SLEEP')
                    locked = True
                    print('Screen locked.', flush=True)
                if elapsed >= 8 and not inspected:
                    services = adb('shell', 'dumpsys', 'activity', 'services',
                                   'com.wweiyi.expert_chat/.GenerationService')
                    power = adb('shell', 'dumpsys', 'power')
                    (output / 'service-locked.txt').write_text(services, encoding='utf-8')
                    (output / 'power-locked.txt').write_text(power, encoding='utf-8')
                    if 'isForeground=true' not in services:
                        raise AssertionError('Generation service was not foreground while locked.')
                    if 'com.wweiyi.expert_chat:generation' not in power:
                        raise AssertionError('Generation CPU wake lock was not held.')
                    inspected = True
                    print('Verified foreground service and CPU wake lock.', flush=True)
                if elapsed >= 30 and not resumed:
                    adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
                    adb('shell', 'wm', 'dismiss-keyguard')
                    adb('shell', 'am', 'start', '-n', 'com.wweiyi.expert_chat/.MainActivity')
                    resumed = True
                    print('Returned to app after 30 seconds.', flush=True)
            time.sleep(0.5)
        text = log.read_text(encoding='utf-8', errors='replace')
        if process.returncode or 'BACKGROUND_STREAM_RESULT' not in text or not inspected:
            raise AssertionError(f'Integration test failed. See {log}')
        services = adb('shell', 'dumpsys', 'activity', 'services',
                       'com.wweiyi.expert_chat/.GenerationService')
        (output / 'service-after.txt').write_text(services, encoding='utf-8')
        if 'isForeground=true' in services:
            raise AssertionError('Generation service remained active after test cleanup.')
        power = adb('shell', 'dumpsys', 'power')
        (output / 'power-after.txt').write_text(power, encoding='utf-8')
        if re.search(r'PARTIAL_WAKE_LOCK[^\n]*com\.wweiyi\.expert_chat:generation', power):
            raise AssertionError('Generation CPU wake lock remained held after cleanup.')
        print('PASS: background SSE, lock/unlock, and service cleanup.', flush=True)
    finally:
        if process.poll() is None:
            # Terminate only the test process tree started above.
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                           capture_output=True, check=False)


if __name__ == '__main__':
    main()
