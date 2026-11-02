import importlib.util
import io
import json
import os
import base64
import hashlib
from pathlib import Path
import struct
import subprocess
import select
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'ChromeOTPBridge' / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


host, installer = module('native_host'), module('install')


class OTPBridgeTests(unittest.TestCase):
    def test_protocol_round_trip(self):
        stream = io.BytesIO()
        expected = {'id': 'abc', 'ok': True, 'code': 'checked'}
        host.write_message(stream, expected)
        stream.seek(0)
        self.assertEqual(host.read_message(stream), expected)
        for raw in [b'', b'\x01\x00', struct.pack('<I', host.MAX_FRAME + 1), struct.pack('<I', 4) + b'[]  ']:
            with self.assertRaises((EOFError, ValueError)):
                host.read_message(io.BytesIO(raw))

    def test_scope_and_expiry(self):
        now = time.time()
        task = {'id': 'a' * 36, 'stand': '08', 'operation': 'reset', 'phone': '258' + '12345678', 'created': now}
        self.assertTrue(host.valid_task(task, now))
        for patch in [{'stand': '09'}, {'phone': '*'}, {'phone': task['phone'] + '*'}, {'operation': 'eval'}, {'created': now - 36}, {'created': now + 1}, {'id': '../other'}]:
            self.assertFalse(host.valid_task(dict(task, **patch), now))
        result = host.safe_result({'ok': True, 'code': 'reset', 'found': 3, 'deleted': 3, 'phone': task['phone'], 'cookies': 'secret', 'remaining': 10})
        self.assertEqual(result, {'ok': True, 'code': 'reset', 'found': 3, 'deleted': 3})

    def test_private_installer_and_extension_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            folder = installer.prepare(ROOT / 'ChromeOTPBridge', home)
            manifest = json.loads((folder / 'manifest.json').read_text())
            self.assertEqual(manifest['permissions'], ['scripting', 'nativeMessaging'])
            self.assertEqual(manifest['host_permissions'], ['https://redis-insight.dev.indels.tech/*'])
            self.assertEqual(os.stat(folder.parent).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(folder.parent / 'native-host').st_mode & 0o777, 0o700)
            native = home / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/local.zhmakee.otp.json'
            config = json.loads(native.read_text())
            self.assertEqual(len(config['allowed_origins']), 1)
            self.assertNotIn('*', config['allowed_origins'][0])
            self.assertEqual(os.stat(native).st_mode & 0o777, 0o600)
            target = folder.parent / 'response.json'
            host.private_write(target, {'ok': True})
            self.assertEqual(os.stat(target).st_mode & 0o777, 0o600)

    def test_native_exchange_and_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = installer.prepare(ROOT / 'ChromeOTPBridge', Path(directory))
            native_root = folder.parent
            manifest = json.loads((folder / 'manifest.json').read_text())
            extension = ''.join(chr(ord('a') + int(c, 16)) for c in hashlib.sha256(base64.b64decode(manifest['key'])).hexdigest()[:32])
            messages = native_root / 'queue'
            messages.mkdir(mode=0o700)
            task = {'id': 'a' * 36, 'operation': 'inspect', 'stand': '08', 'phone': '258' + '12345678', 'created': time.time()}
            request = messages / ('request-' + task['id'] + '.json')
            host.private_write(request, task)
            # Inject only the test root; never change HOME or touch a live Chrome profile.
            code = "import importlib.util,sys;from pathlib import Path;s=importlib.util.spec_from_file_location('bridge',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.ROOT=Path(sys.argv[2]);sys.argv=['host',sys.argv[3]];m.main()"
            process = subprocess.Popen(['/usr/bin/python3', '-c', code, str(native_root / 'native_host.py'), str(native_root), 'chrome-extension://' + extension + '/'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'Native host did not connect')
                self.assertEqual(host.read_message(process.stdout), task)
                host.write_message(process.stdin, {'id': task['id'], 'ok': True, 'code': 'checked', 'found': 2, 'cookie': 'must-not-leave-host'})
                response = messages / ('response-' + task['id'] + '.json')
                until = time.time() + 3
                while not response.exists() and time.time() < until:
                    time.sleep(0.05)
                self.assertEqual(json.loads(response.read_text()), {'ok': True, 'code': 'checked', 'found': 2})
                self.assertFalse(request.exists())
                self.assertEqual(os.stat(response).st_mode & 0o777, 0o600)
                self.assertTrue((native_root / 'state.json').exists())
                process.stdin.close()
                self.assertEqual(process.wait(timeout=3), 0)
                self.assertEqual(process.stderr.read(), b'')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()
                process.stderr.close()


if __name__ == '__main__':
    unittest.main()
