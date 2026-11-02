"""Prepare the reviewed unpacked extension and its narrowly scoped Native Messaging host."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex


def prepare(source=None, home=None):
    source = source or Path(__file__).parent
    home = home or Path.home()
    root = home / 'Library/Application Support/Жмякее/OTPBridge'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    folder = root / 'extension'
    folder.mkdir(exist_ok=True, mode=0o700)
    for name in ('manifest.json', 'worker.js', 'core.js'):
        shutil.copyfile(source / name, folder / name)
        os.chmod(folder / name, 0o600)
    shutil.copyfile(source / 'native_host.py', root / 'native_host.py')
    os.chmod(root / 'native_host.py', 0o600)
    manifest = json.loads((folder / 'manifest.json').read_text())
    extension = ''.join(chr(ord('a') + int(c, 16)) for c in hashlib.sha256(base64.b64decode(manifest['key'])).hexdigest()[:32])
    launcher = root / 'native-host'
    launcher.write_text('#!/bin/sh\nexec /usr/bin/python3 ' + shlex.quote(str(root / 'native_host.py')) + ' "$@"\n')
    os.chmod(launcher, 0o700)
    host = {'name': 'local.zhmakee.otp', 'description': 'Жмякее · OTP test08',
            'path': str(launcher), 'type': 'stdio',
            'allowed_origins': ['chrome-extension://' + extension + '/']}
    for browser in ('Google/Chrome', 'Google/ChromeForTesting'):
        directory = home / ('Library/Application Support/' + browser + '/NativeMessagingHosts')
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / 'local.zhmakee.otp.json'
        path.write_text(json.dumps(host))
        os.chmod(path, 0o600)
    return folder


if __name__ == '__main__':
    try:
        print(prepare())
    except Exception:
        raise SystemExit('Не удалось подготовить мост Chrome')
