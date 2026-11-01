#!/usr/bin/env python3
"""Read local APK/IPA metadata; safely unpack an existing signed IPA without resigning."""
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import zipfile


class BuildError(Exception):
    pass


def ipa_root(archive):
    roots = [name for name in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name)]
    if len(roots) != 1:
        raise BuildError('В IPA должно быть одно основное приложение')
    info = archive.getinfo(roots[0])
    if info.file_size > 4 * 1024 * 1024:
        raise BuildError('Некорректный Info.plist в IPA')
    return str(PurePosixPath(roots[0]).parent)


def inspect(path, aapt=None):
    path = Path(path)
    if path.suffix.lower() == '.ipa':
        with zipfile.ZipFile(path) as archive:
            root = ipa_root(archive)
            info = plistlib.loads(archive.read(root + '/Info.plist'))
            result = {'platform': 'ios', 'package': info.get('CFBundleIdentifier', ''),
                      'name': info.get('CFBundleDisplayName') or info.get('CFBundleName') or PurePosixPath(root).stem,
                      'version': str(info.get('CFBundleShortVersionString', '')),
                      'build': str(info.get('CFBundleVersion', '')), 'minimumOS': info.get('MinimumOSVersion', ''), 'flavor': ''}
    elif path.suffix.lower() == '.apk':
        if not aapt or not Path(aapt).is_file():
            raise BuildError('Для чтения APK нужны Android SDK Build Tools (aapt2)')
        process = subprocess.run([aapt, 'dump', 'badging', str(path)], capture_output=True, text=True, timeout=20)
        line = next((line for line in process.stdout.splitlines() if line.startswith('package: ')), '')
        values = dict(re.findall(r"(\w+)='([^']*)'", line))
        if process.returncode or not values.get('name'):
            raise BuildError('Не удалось прочитать AndroidManifest.xml в APK')
        version = values.get('versionName', '')
        label = next((line[len("application-label:'"):-1] for line in process.stdout.splitlines() if line.startswith("application-label:'")), values['name'])
        minimum = re.search(r"(?m)^sdkVersion:'([^']*)'", process.stdout)
        flavor = 'HMS' if 'hms' in (version + path.name).lower() else 'GMS' if 'gms' in (version + path.name).lower() else ''
        result = {'platform': 'android', 'package': values['name'], 'name': label, 'version': version,
                  'build': values.get('versionCode', ''), 'minimumOS': minimum.group(1) if minimum else '', 'flavor': flavor}
    else:
        raise BuildError('Поддерживаются файлы APK и IPA')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,200}', result['package']) or not result['version'] or not result['build']:
        raise BuildError('В сборке не найдены корректные идентификатор и версия приложения')
    return result


def extract_ipa(path, destination):
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path) as archive:
        root = ipa_root(archive)
        entries = []
        total = 0
        seen = set()
        for item in archive.infolist():
            # Validate every path, including entries outside Payload, before writing anything.
            name = PurePosixPath(item.filename)
            if name.is_absolute() or '..' in name.parts or '\\' in item.filename or '\x00' in item.filename:
                raise BuildError('В IPA обнаружен небезопасный путь')
            if item.filename != root and not item.filename.startswith(root + '/'):
                continue
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise BuildError('IPA с символическими ссылками не поддерживается')
            if item.flag_bits & 1:
                raise BuildError('IPA зашифрован')
            relative = PurePosixPath(PurePosixPath(root).name, *name.parts[2:])
            target = destination.joinpath(*relative.parts)
            if not target.resolve().is_relative_to(destination) or target in seen:
                raise BuildError('В IPA обнаружен повторяющийся или небезопасный путь')
            seen.add(target)
            total += item.file_size
            entries.append((item, target, mode))
        if total > 8 * 1024**3 or len(entries) > 100000:
            raise BuildError('IPA превышает допустимый размер распаковки')
        for item, target, mode in entries:
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                os.chmod(target, mode & 0o777 if mode & 0o777 else 0o644)
        return str(destination / PurePosixPath(root).name)


def main():
    try:
        action, path = sys.argv[1:3]
        if action == 'inspect':
            result = inspect(path, sys.argv[3] if len(sys.argv) > 3 else None)
        elif action == 'extract':
            result = {'app': extract_ipa(path, sys.argv[3])}
        else:
            raise BuildError('Неизвестная операция со сборкой')
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except BuildError as error:
        message = str(error)
    except Exception:
        message = 'Не удалось прочитать файл сборки. Проверьте, что он скачан полностью'
    print(json.dumps({'error': message}, ensure_ascii=False))
    return 1


if __name__ == '__main__':
    sys.exit(main())
