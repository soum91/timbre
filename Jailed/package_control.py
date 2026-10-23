#!/usr/bin/env python3
"""Produce a decryption/signing control: no injected code or DSP library."""
import gzip
import io
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path


def package(source, output):
    raw = Path(source).read_bytes()
    if raw[:2] == b'\x1f\x8b':
        raw = gzip.decompress(raw)
    with zipfile.ZipFile(io.BytesIO(raw)) as original:
        info = next(n for n in original.namelist() if n.count('/') == 2 and n.endswith('.app/Info.plist'))
        root = info.rsplit('/', 1)[0] + '/'
        d = plistlib.loads(original.read(info))
        if d['CFBundleIdentifier'] != 'com.amazon.mp3.AmazonCloudPlayer':
            raise ValueError('Expected the original decrypted Amazon Music export')
        executable = root + d['CFBundleExecutable']
        original_executable = original.read(executable)
        assert original_executable[:4] == b'\xcf\xfa\xed\xfe'
        offset = 32
        for _ in range(struct.unpack_from('<I', original_executable, 16)[0]):
            command, size = struct.unpack_from('<II', original_executable, offset)
            if command == 0x2C:
                assert struct.unpack_from('<I', original_executable, offset+16)[0] == 0
            assert not (command == 0xC and b'TimbreNative' in original_executable[offset:offset+size])
            offset += size
        # Matches the explicit application ID already present in the supplied
        # FlareStore profile. The user re-signs locally with that same profile.
        d['CFBundleIdentifier'] = 'app.cancer9725.turquoise1323'
        d['CFBundleDisplayName'] = 'Amazon Control'
        d['CFBundleName'] = 'Amazon Control'
        d['CFBundleVersion'] = '26.37.3'
        d['TimbreControlBuild'] = True
        for key in ['WKCompanionAppBundleIdentifier', 'WKWatchKitApp', 'NSExtension']:
            d.pop(key, None)
        Path(output).parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as out:
            for item in original.infolist():
                if any(item.filename.startswith(root+p) for p in ['PlugIns/', 'Watch/', 'com.apple.WatchPlaceholder/', 'AppClips/']):
                    continue
                if '/_CodeSignature/' in item.filename or '/SC_Info/' in item.filename or item.filename.endswith('embedded.mobileprovision'):
                    continue
                data = plistlib.dumps(d) if item.filename == info else original.read(item)
                out.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
    with zipfile.ZipFile(output) as out:
        assert out.testzip() is None
        assert out.read(executable) == original_executable
        assert not any('TimbreNative' in n or '.appex/' in n for n in out.namelist())
    return {'path': str(Path(output).resolve()), 'bytes': Path(output).stat().st_size, 'injection': False, 'executable_unchanged': True, 'signing_required': True}


if __name__ == '__main__':
    print(json.dumps(package(sys.argv[1], sys.argv[2])))
