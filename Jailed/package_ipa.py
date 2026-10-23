#!/usr/bin/env python3
"""Add the app-local Timbre library to a decrypted IPA; signing is external."""
import argparse
import gzip
import io
import plistlib
import struct
import zipfile
from pathlib import Path


def commands(data):
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin arm64 Mach-O executable')
    offset = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        cmd, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('Invalid Mach-O load command')
        yield cmd, offset, size
        offset += size


def inject(data):
    data = bytearray(data)
    rows = list(commands(data))
    for cmd, offset, size in rows:
        if cmd == 0x2C and struct.unpack_from('<I', data, offset + 16)[0]:
            raise ValueError('Executable must be decrypted before packaging')
    name = b'@executable_path/Frameworks/TimbreNative.dylib\0'
    for cmd, offset, size in rows:
        if cmd == 0xC and b'TimbreNative.dylib' in data[offset:offset+size]:
            raise ValueError('Timbre already injected')
    first_section = len(data)
    for cmd, offset, size in rows:
        if cmd != 0x19:
            continue
        nsects = struct.unpack_from('<I', data, offset + 64)[0]
        for i in range(nsects):
            pos = offset + 72 + i * 80
            file_offset = struct.unpack_from('<I', data, pos + 48)[0]
            if file_offset:
                first_section = min(first_section, file_offset)
    # Remove the obsolete executable signature command. The sideloading signer
    # must sign the modified executable and every nested library before install.
    kept = [bytes(data[o:o+s]) for c, o, s in rows if c != 0x1D]
    size = (24 + len(name) + 7) & ~7
    added = struct.pack('<IIIIII', 0xC, size, 24, 0, 0, 0) + name
    added += b'\0' * (size - len(added))
    payload = b''.join(kept) + added
    if 32 + len(payload) > first_section:
        raise ValueError('Insufficient header padding; no section relocation attempted')
    old_end = 32 + struct.unpack_from('<I', data, 20)[0]
    # Guard padding before altering it. Existing section bytes stay at the same offsets.
    if 32 + len(payload) > old_end and any(data[old_end:32+len(payload)]):
        raise ValueError('Header growth would overwrite nonzero data')
    data[32:max(old_end,32+len(payload))] = payload + b'\0' * max(0,old_end-32-len(payload))
    struct.pack_into('<II', data, 16, len(kept)+1, len(payload))
    return bytes(data)


def package(source, library, output):
    raw = Path(source).read_bytes()
    if raw[:2] == b'\x1f\x8b':
        raw = gzip.decompress(raw)
    lib = Path(library).read_bytes()
    if lib[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Invalid Timbre library')
    with zipfile.ZipFile(io.BytesIO(raw)) as original:
        info = next(n for n in original.namelist() if n.count('/') == 2 and n.endswith('.app/Info.plist'))
        root = info.rsplit('/', 1)[0] + '/'
        plist = plistlib.loads(original.read(info))
        if plist['CFBundleIdentifier'] != 'com.amazon.mp3.AmazonCloudPlayer':
            raise ValueError('This test adapter is only for Amazon Music')
        exe = root + plist['CFBundleExecutable']
        modified = inject(original.read(exe))
        # Use a stable standalone identity. This avoids attempting to replace an
        # installed/offloaded App Store app signed by a different developer team.
        plist['CFBundleIdentifier'] = 'app.cancer9725.turquoise1323'
        plist['CFBundleDisplayName'] = 'Amazon Timbre'
        plist['CFBundleName'] = 'Amazon Timbre'
        plist['CFBundleVersion'] = '26.37.4'
        plist['TimbreNativeTestBuild'] = 3
        # App Store thinning can leave a device whitelist from the source phone.
        # Keep architectural/minimum OS requirements, but remove that whitelist.
        for key in ['UISupportedDevices', 'WKCompanionAppBundleIdentifier', 'WKWatchKitApp', 'NSExtension']:
            plist.pop(key, None)
        Path(output).parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as out:
            for entry in original.infolist():
                # This first iPhone test needs no notification or Watch extension.
                # Removing these also removes nested provisioning requirements
                # and avoids parent/extension version and identity mismatches.
                if any(entry.filename.startswith(root+prefix) for prefix in ['PlugIns/', 'Watch/', 'com.apple.WatchPlaceholder/', 'AppClips/']):
                    continue
                if '/_CodeSignature/' in entry.filename or '/SC_Info/' in entry.filename or entry.filename.endswith('embedded.mobileprovision'):
                    continue
                content = modified if entry.filename == exe else plistlib.dumps(plist) if entry.filename == info else original.read(entry)
                out.writestr(entry, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
            item = zipfile.ZipInfo(root + 'Frameworks/TimbreNative.dylib')
            item.create_system = 3
            item.external_attr = 0o100755 << 16
            out.writestr(item, lib, compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
    with zipfile.ZipFile(output) as out:
        if out.testzip():
            raise ValueError('ZIP integrity check failed')
        packaged_executable = out.read(exe)
        parsed = list(commands(packaged_executable))
        assert any(c == 0xC and b'TimbreNative.dylib' in packaged_executable[o:o+s] for c,o,s in parsed)
        assert out.read(root+'Frameworks/TimbreNative.dylib') == lib
        assert not any('.appex/' in n or '/com.apple.WatchPlaceholder/' in n for n in out.namelist())
        verified = plistlib.loads(out.read(info))
        assert verified['CFBundleIdentifier'] == 'app.cancer9725.turquoise1323'
        assert verified['CFBundleVersion'] == '26.37.4'
        assert 'UISupportedDevices' not in verified
    return {'output': str(Path(output).resolve()), 'bytes': Path(output).stat().st_size, 'build': plist['CFBundleVersion'], 'bundle_id': plist['CFBundleIdentifier'], 'signing_required': True}


if __name__ == '__main__':
    import json
    p = argparse.ArgumentParser()
    p.add_argument('source'); p.add_argument('library'); p.add_argument('output')
    args = p.parse_args()
    print(json.dumps(package(args.source, args.library, args.output)))
