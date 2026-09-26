"""Release stripping must preserve executable bytes, directories and the Wine marker."""
import struct
from optimize_runtime import pe_runtime_signature


def fixture():
    data = bytearray(1024)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 128)
    data[64:80] = b'Wine builtin DLL'
    data[128:132] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', data, 132, 0x14c, 2, 0, 0, 0, 224, 0x2102)
    optional = 152
    struct.pack_into('<H', data, optional, 0x10b)
    struct.pack_into('<I', data, optional+16, 4096)
    struct.pack_into('<I', data, optional+92, 16)
    for index, (name, rva, offset) in enumerate([(b'.text', 4096, 512), (b'.debug', 8192, 768)]):
        at = optional+224+40*index
        data[at:at+len(name)] = name
        struct.pack_into('<IIII', data, at+8, 16, rva, 256, offset)
        struct.pack_into('<I', data, at+36, 0x60000020)
    data[512:528] = bytes(range(16))
    return data


original = fixture()
stripped = bytearray(original)
struct.pack_into('<H', stripped, 134, 1)
stripped[768:] = b'\0'*256
assert pe_runtime_signature(original) == pe_runtime_signature(stripped)
for offset in [64, 152+16, 152+96, 376+36, 512]:
    altered = bytearray(stripped)
    altered[offset] ^= 1
    assert pe_runtime_signature(original) != pe_runtime_signature(altered), offset
for malformed in [b'', b'MZ', original[:400]]:
    try: pe_runtime_signature(malformed)
    except ValueError: pass
    else: raise AssertionError('Malformed PE accepted')
print('Runtime stripping preservation regression passed')
