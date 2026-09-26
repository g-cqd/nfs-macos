"""Remove release-only overhead while preserving PE runtime contents."""
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


def pe_runtime_signature(data):
    def read(fmt, offset):
        if offset < 0 or offset + struct.calcsize(fmt) > len(data):
            raise ValueError("Truncated PE image")
        return struct.unpack_from(fmt, data, offset)

    if len(data) > 512 * 1024 * 1024 or data[:2] != b"MZ":
        raise ValueError("Unsupported PE image")
    pe, = read('<I', 0x3c)
    if data[pe:pe+4] != b'PE\0\0': raise ValueError("Missing PE header")
    machine, count, _, symbols, symbol_count, optional_size, flags = read('<HHIIIHH', pe+4)
    optional_at = pe+24
    magic, = read('<H', optional_at)
    directories = 96 if magic == 0x10b else 112 if magic == 0x20b else 0
    if not directories or optional_size < directories or count > 96:
        raise ValueError("Unsupported PE headers")
    optional = bytearray(data[optional_at:optional_at+optional_size])
    if len(optional) != optional_size: raise ValueError("Truncated optional header")
    directory_count, = read('<I', optional_at+directories-4)
    if directory_count > 16 or directories+directory_count*8 > optional_size:
        raise ValueError("Invalid PE directory count")
    # Debug stripping may change initialized-data/header/image sizes and checksum.
    for offset in [8, 12, 56, 60, 64]: optional[offset:offset+4] = b'\0'*4
    if directory_count > 6: optional[directories+48:directories+56] = b'\0'*8
    string_table = symbols+symbol_count*18
    runtime = []
    for index in range(count):
        at = optional_at+optional_size+40*index
        raw_name, virtual_size, rva, raw_size, raw_at, _, _, _, _, characteristics = read('<8s6I2HI', at)
        name = raw_name.split(b'\0')[0]
        if name.startswith(b'/'):
            try: offset = int(name[1:])
            except ValueError as error: raise ValueError("Invalid long section name") from error
            table_size, = read('<I', string_table)
            if offset < 4 or offset >= table_size or string_table+table_size > len(data):
                raise ValueError("Invalid COFF string table")
            start = string_table+offset
            end = data.find(b'\0', start, min(string_table+table_size, start+256))
            if end < 0: raise ValueError("Unterminated section name")
            name = bytes(data[start:end])
        if raw_at+raw_size > len(data): raise ValueError("Truncated section")
        if name.startswith((b'.debug', b'.zdebug')): continue
        digest = hashlib.sha256(data[raw_at:raw_at+min(raw_size, virtual_size)]).digest()
        runtime.append((name, virtual_size, rva, characteristics, digest))
    return (bytes(data[:pe]), machine, flags & ~0x200, bytes(optional), runtime)


def optimize(wine):
    strip = shutil.which('llvm-strip')
    report = {'beforeBytes': 0, 'afterBytes': 0, 'strippedPEFiles': 0,
              'removedDebugBytes': 0, 'retainedPEFiles': [], 'stripAvailable': strip is not None}
    files = [p for p in wine.rglob('*') if p.is_file() and not p.is_symlink()]
    report['beforeBytes'] = sum(p.stat().st_size for p in files)
    for path in files:
        if path.suffix.lower() == '.pdb' or any(part.endswith('.dSYM') for part in path.parts):
            report['removedDebugBytes'] += path.stat().st_size
            path.unlink()
            continue
        if strip is None: continue
        with path.open('rb') as stream: magic = stream.read(2)
        if magic != b'MZ' or path.stat().st_size > 512*1024*1024: continue
        original = path.read_bytes()
        descriptor, temporary = tempfile.mkstemp(prefix='.release-', dir=path.parent)
        os.close(descriptor)
        temporary = Path(temporary)
        try:
            shutil.copyfile(path, temporary)
            result = subprocess.run([strip, '--strip-debug', str(temporary)], capture_output=True, text=True)
            if result.returncode:
                raise ValueError("LLVM could not strip this file")
            reduced = temporary.read_bytes()
            if pe_runtime_signature(original) != pe_runtime_signature(reduced):
                raise ValueError("Runtime bytes changed")
            if len(reduced) < len(original):
                temporary.chmod(path.stat().st_mode)
                temporary.replace(path)
                report['strippedPEFiles'] += 1
        except ValueError as error:
            report['retainedPEFiles'].append({'path': str(path.relative_to(wine)), 'reason': str(error)})
        finally:
            if temporary.exists(): temporary.unlink()
    report['afterBytes'] = sum(p.stat().st_size for p in wine.rglob('*') if p.is_file() and not p.is_symlink())
    return report
