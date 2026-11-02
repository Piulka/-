"""Native Messaging transport. Never reads browser profiles, credentials or cookies."""
import fcntl
import json
import os
from pathlib import Path
import queue
import re
import struct
import sys
import threading
import time

MAX_FRAME = 16384
ROOT = Path.home() / 'Library/Application Support/Жмякее/OTPBridge'


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        chunk = stream.read(count - len(result))
        if not chunk:
            raise EOFError()
        result.extend(chunk)
    return bytes(result)


def read_message(stream):
    size, = struct.unpack('<I', read_exact(stream, 4))
    if not 0 < size <= MAX_FRAME:
        raise ValueError('frame')
    value = json.loads(read_exact(stream, size))
    if not isinstance(value, dict):
        raise ValueError('object')
    return value


def write_message(stream, value):
    data = json.dumps(value, separators=(',', ':')).encode()
    stream.write(struct.pack('<I', len(data)) + data)
    stream.flush()


def valid_task(value, now):
    return (isinstance(value, dict) and
            isinstance(value.get('id'), str) and re.fullmatch(r'[a-fA-F0-9-]{36}', value['id']) is not None and
            value.get('stand') == '08' and value.get('operation') in ('ping', 'inspect', 'reset') and
            isinstance(value.get('created'), (int, float)) and 0 <= now - value['created'] < 5 and
            (value['operation'] == 'ping' or
             isinstance(value.get('phone'), str) and re.fullmatch(r'258[0-9]{8}', value['phone']) is not None))


def safe_result(value):
    result = {'ok': value.get('ok') is True}
    code = value.get('code', 'connection_error')
    result['code'] = code if isinstance(code, str) and re.fullmatch(r'[a-z_]{1,40}', code) else 'connection_error'
    for key in ('found', 'deleted', 'remaining'):
        n = value.get(key)
        if type(n) is int and 0 <= n <= 3:
            result[key] = n
    return result


def private_write(path, value):
    temporary = path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as target:
        os.fchmod(target.fileno(), 0o600)
        json.dump(value, target)
    os.replace(temporary, path)


def main():
    os.umask(0o077)
    config = json.loads((Path(__file__).parent / 'extension/manifest.json').read_text())
    import base64
    import hashlib
    extension = ''.join(chr(ord('a') + int(c, 16)) for c in hashlib.sha256(base64.b64decode(config['key'])).hexdigest()[:32])
    if len(sys.argv) < 2 or sys.argv[1] != 'chrome-extension://' + extension + '/':
        return
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    messages = ROOT / 'queue'
    messages.mkdir(exist_ok=True, mode=0o700)
    lock = open(ROOT / 'host.lock', 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    incoming = queue.Queue()

    def read():
        try:
            while True:
                incoming.put(read_message(sys.stdin.buffer))
        except (EOFError, ValueError, OSError):
            incoming.put(None)

    threading.Thread(target=read, daemon=True).start()
    pending, heartbeat = None, 0
    while True:
        now = time.time()
        if now - heartbeat >= 2:
            private_write(ROOT / 'state.json', {'time': now})
            heartbeat = now
        try:
            reply = incoming.get_nowait()
            if reply is None:
                return
            if pending and reply.get('id') == pending['id']:
                private_write(messages / ('response-' + pending['id'] + '.json'), safe_result(reply))
                pending = None
        except queue.Empty:
            pass
        if pending and now - pending['created'] > 32:
            private_write(messages / ('response-' + pending['id'] + '.json'), {'ok': False, 'code': 'timeout'})
            pending = None
        if not pending:
            for request in sorted(messages.glob('request-*.json')):
                try:
                    value = json.loads(request.read_text()) if request.stat().st_size <= MAX_FRAME else {}
                    request.unlink()
                    if valid_task(value, now) and request.name == 'request-' + value['id'] + '.json':
                        pending = value
                        write_message(sys.stdout.buffer, value)
                        break
                except (OSError, ValueError):
                    continue
        time.sleep(0.1)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        sys.exit(1)  # No payloads or exception text in Chrome logs.
