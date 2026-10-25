"""Verify actual compiled host TLS, auth, five-minute disconnect and idempotence.

Uses only a temporary workspace, an ephemeral self-signed test CA and its own
process. Never loads the user's model credentials or contacts a paid provider.
"""
import argparse
import datetime
import ipaddress
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='output/remote-host.exe')
    parser.add_argument('--offline-seconds', type=int, default=300)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='expert-host-transport-') as tmp:
        root = Path(tmp)
        work = root / 'work'
        work.mkdir()
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=1)).not_valid_after(now + datetime.timedelta(days=1)).add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost'), x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False).sign(key, hashes.SHA256())
        cert_path, key_path = root / 'cert.pem', root / 'key.pem'
        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        env = {k: v for k, v in os.environ.items() if not k.startswith('EXPERT_REMOTE_')}
        env.update(EXPERT_REMOTE_TLS_CERT=str(cert_path), EXPERT_REMOTE_TLS_KEY=str(key_path))
        env['EXPERT_REMOTE_MODEL_KEY'] = 'fixture-host-private-value-123456'
        env['HOST_SECRET_ALIAS'] = env['EXPERT_REMOTE_MODEL_KEY']
        process = subprocess.Popen([str(Path(args.host).resolve()), str(root / 'private'), str(work), '0'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        try:
            line = process.stdout.readline()
            match = re.search(r'port (\d+)', line)
            assert match, 'Host did not announce a listener'
            base = f'https://127.0.0.1:{match.group(1)}/v1/'
            token = (root / 'private/credential').read_text()
            trusted = ssl.create_default_context(cafile=str(cert_path))

            def request(path, data=None, authorized=True, context=trusted):
                headers = {'Content-Type': 'application/json'}
                if authorized:
                    headers['Authorization'] = f'Bearer {token}'
                req = urllib.request.Request(base + path, data=None if data is None else json.dumps(data).encode(), headers=headers)
                with urllib.request.urlopen(req, context=context, timeout=10) as response:
                    return json.load(response)

            try:
                request('tasks', context=ssl.create_default_context())
                raise AssertionError('Untrusted certificate was accepted')
            except urllib.error.URLError as error:
                assert isinstance(error.reason, ssl.SSLCertVerificationError)
            try:
                request('tasks', authorized=False)
                raise AssertionError('Missing token was accepted')
            except urllib.error.HTTPError as error:
                assert error.code == 401
            command = "if ($env:EXPERT_REMOTE_MODEL_KEY -or $env:EXPERT_REMOTE_TLS_KEY -or $env:HOST_SECRET_ALIAS) { throw 'Host credentials inherited' }; Start-Sleep -Seconds 1; Add-Content once.txt 'offline-verified'" if os.name == 'nt' else "test -z \"$EXPERT_REMOTE_MODEL_KEY$EXPERT_REMOTE_TLS_KEY$HOST_SECRET_ALIAS\" && sleep 1 && echo offline-verified >> once.txt"
            task = request('tasks', {'id': 'offline-fixture', 'command': command})
            request('tasks/offline-fixture/approve', {'version': task.get('version', task['updatedAt'])})
            print(f'TLS, certificate rejection, authenticated approval passed; disconnecting for {args.offline_seconds}s', flush=True)
            time.sleep(args.offline_seconds)
            tasks = request('tasks')['tasks']
            assert tasks[0]['state'] == 'completed'
            replay = request('tasks', {'id': 'offline-fixture', 'command': command})
            assert replay['id'] == task['id']
            assert (work / 'once.txt').read_text().splitlines() == ['offline-verified']
            events = request('events?after=1')['events']
            assert events and events[0]['cursor'] == 2
            print('PASS: same task completed without client; reconnect cursor and submission dedupe preserved', flush=True)
        finally:
            process.terminate()
            process.wait(timeout=10)


if __name__ == '__main__':
    main()
