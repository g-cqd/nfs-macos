"""Authenticode verification accepts the genuine EA installer and rejects every tampered or malformed input.

The real-installer cases are skipped (with an explicit SKIP line) when the installer is not on this machine;
the parsing and negative tests on synthetic inputs always run.
"""
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile

import authenticode
from authenticode import (Node, SignatureError, parse_signature, pe_authenticode_digest, read_node, check_tree,
                          verify, export_roots)

INSTALLER = Path(os.environ.get('EA_INSTALLER', Path.home() / 'Downloads/EAappInstaller.exe'))
INSTALLER_SHA256 = 'dcbda653c9776320b283157be70def64db73c2b01bf45d5fa78f35d7e4e29320'
PUBLISHER = 'Electronic Arts, Inc.'
failures = 0


def case(name, function):
    """Run one case and print PASS or FAIL."""
    global failures
    try:
        function()
    except Exception as exc:
        failures += 1
        print(f'FAIL {name}: {type(exc).__name__}: {exc}')
    else:
        print(f'PASS {name}')


def raises(kind, function, text=''):
    """Assert that function raises kind whose message contains text."""
    try:
        function()
    except kind as exc:
        assert text in str(exc), f'{exc!r} lacks {text!r}'
        return
    raise AssertionError(f'did not raise {kind.__name__}')


def synthetic_pe(sections=(b'.text-bytes' * 40,), cert: bytes | None = None, magic=0x10b) -> bytes:
    """A small hand-built PE: DOS header, PE32 optional header with 16 directories, raw sections, optional cert table."""
    opt_size = 96 + 16 * 8 if magic == 0x10b else 112 + 16 * 8
    headers = 0x40 + 24 + opt_size + 40 * len(sections)
    headers_size = (headers + 0x1ff) // 0x200 * 0x200
    image = bytearray(headers_size)
    image[:2] = b'MZ'
    struct.pack_into('<I', image, 0x3c, 0x40)
    image[0x40:0x44] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', image, 0x44, 0x14c, len(sections), 0, 0, 0, opt_size, 0x102)
    opt = 0x40 + 24
    struct.pack_into('<H', image, opt, magic)
    struct.pack_into('<I', image, opt + 60, headers_size)
    struct.pack_into('<I', image, opt + 64, 0xDEADBEEF)          # checksum, excluded from the digest
    struct.pack_into('<I', image, opt + (92 if magic == 0x10b else 108), 16)
    table = opt + opt_size
    body = b''
    for index, content in enumerate(sections):
        struct.pack_into('<II', image, table + index * 40 + 16, len(content), headers_size + len(body))
        body += content
    image += body
    if cert is not None:
        padded = cert + b'\0' * (-(8 + len(cert)) % 8)
        dirs = opt + (96 if magic == 0x10b else 112)
        struct.pack_into('<II', image, dirs + 32, len(image), 8 + len(padded))
        image += struct.pack('<IHH', 8 + len(cert), 0x200, 2) + padded
    return bytes(image)


def test_synthetic_digest():
    for magic in (0x10b, 0x20b):
        data = synthetic_pe(sections=(b'a' * 100, b'b' * 37), cert=b'not really pkcs7', magic=magic)
        info = authenticode.read_pe(data)
        expected = hashlib.sha256()
        expected.update(data[:info.checksum_offset] + data[info.checksum_offset + 4:info.cert_entry_offset]
                        + data[info.cert_entry_offset + 8:info.cert_offset])
        assert pe_authenticode_digest(data, 'sha256') == expected.digest()
        # The checksum and the certificate table do not influence the digest.
        other = bytearray(data)
        other[info.checksum_offset] ^= 0xff
        other[info.cert_offset + 9] ^= 0xff
        assert pe_authenticode_digest(bytes(other), 'sha256') == expected.digest()
        other[info.headers_size + 5] ^= 1
        assert pe_authenticode_digest(bytes(other), 'sha256') != expected.digest()


def test_no_cert_table():
    raises(ValueError, lambda: parse_signature(synthetic_pe()), 'no certificate table')
    raises(ValueError, lambda: verify(synthetic_pe(), publisher=PUBLISHER), 'no certificate table')


def test_not_a_pe():
    raises(ValueError, lambda: verify(b'hello world' * 100, publisher=PUBLISHER), 'not a PE')
    raises(ValueError, lambda: verify(b'MZ' + b'\0' * 200, publisher=PUBLISHER), 'not a PE')
    raises(ValueError, lambda: verify(b'', publisher=PUBLISHER), 'not a PE')


def test_garbage_pkcs7_never_raises():
    result = verify(synthetic_pe(cert=b'\x30\x03garbage-not-der'), publisher=PUBLISHER)
    assert not result.ok and any('malformed signature' in p for p in result.problems), result.problems
    result = verify(synthetic_pe(cert=b'\x30\x80\x00\x00'), publisher=PUBLISHER)
    assert not result.ok and any('indefinite length' in p for p in result.problems), result.problems


def test_truncated_synthetic():
    data = synthetic_pe(cert=b'\x30\x00')
    raises(ValueError, lambda: verify(data[:len(data) - 12], publisher=PUBLISHER), 'truncated')


def test_der_limits():
    deep = b'\x05\x00'
    for _ in range(40):
        deep = b'\x30' + bytes([len(deep)]) + deep if len(deep) < 128 else b'\x30\x82' + struct.pack('>H', len(deep)) + deep
    raises(SignatureError, lambda: check_tree(read_node(deep, 0, len(deep))), 'nesting')
    raises(SignatureError, lambda: read_node(b'\x30\x05\x01\x01', 0, 4), 'exceeds')
    raises(SignatureError, lambda: read_node(b'\x30\x84\xff\xff\xff\xff', 0, 6), 'exceeds')
    raises(SignatureError, lambda: read_node(b'\x30\x80\x00\x00', 0, 4), 'indefinite')
    raises(SignatureError, lambda: read_node(b'\x30', 0, 1), 'truncated')
    raises(SignatureError, lambda: read_node(b'\x30\x89' + b'\0' * 9, 0, 11), 'bad DER length')
    node = read_node(b'\x30\x03\x02\x01\x07', 0, 5)
    assert [c.tag for c in node.children()] == [0x02] and node.children()[0].value == b'\x07'
    assert authenticode.oid_of(read_node(bytes.fromhex('06092a864886f70d010101'), 0, 11)) == '1.2.840.113549.1.1.1'


def real_installer_cases():
    data = INSTALLER.read_bytes()
    assert hashlib.sha256(data).hexdigest() == INSTALLER_SHA256, 'installer is not the pinned EAappInstaller.exe'
    work = Path(tempfile.mkdtemp(prefix='check-authenticode-', dir='/tmp'))
    try:
        roots = work / 'roots.pem'
        assert export_roots(roots) is None, 'cannot export the system roots'
        sig = parse_signature(data)
        info = authenticode.read_pe(data)

        def real():
            result = verify(data, publisher=PUBLISHER, roots_pem=roots)
            assert result.ok, result.problems
            assert result.digest_algorithm == 'sha256' and result.file_sha256 == INSTALLER_SHA256
            assert 'Electronic Arts, Inc.' in result.signer_subject and 'DigiCert' in result.issuer
            assert result.digest_hex == sig.indirect_digest.hex()
            assert 'DigiCert Trusted Root G4' in result.chain_root, result.chain_root
        case('real installer verifies for Electronic Arts, Inc.', real)

        def wrong_publisher():
            result = verify(data, publisher='Someone Else', roots_pem=roots)
            assert not result.ok and any('organization' in p for p in result.problems), result.problems
            assert not any('digest' in p or 'signature does not' in p for p in result.problems), result.problems
        case('real installer rejected for publisher Someone Else', wrong_publisher)

        def path_input():
            assert verify(INSTALLER, publisher=PUBLISHER, roots_pem=roots).ok
        case('verify accepts a path', path_input)

        def mutated(offset):
            changed = bytearray(data)
            changed[offset] ^= 0x01
            return verify(bytes(changed), publisher=PUBLISHER, roots_pem=roots)

        def body_flip():
            result = mutated(info.cert_offset // 2)
            assert not result.ok and any('PE digest mismatch' in p for p in result.problems), result.problems
        case('flipped body byte gives a PE digest mismatch', body_flip)

        def attrs_flip():
            start = data.find(b'\xa0' + sig.signed_attrs[1:])
            assert start > 0 and data.count(b'\xa0' + sig.signed_attrs[1:]) == 1
            result = mutated(start + len(sig.signed_attrs) - 1)
            assert not result.ok and any('signature does not verify' in p or 'messageDigest' in p
                                         for p in result.problems), result.problems
            assert any('signature does not verify' in p for p in result.problems), result.problems
        case('flipped signed-attribute byte fails the signature', attrs_flip)

        def signature_flip():
            start = data.find(sig.signature)
            assert start > 0 and data.count(sig.signature) == 1
            result = mutated(start + len(sig.signature) // 2)
            assert not result.ok and any('signature does not verify' in p for p in result.problems), result.problems
            assert not any('digest' in p for p in result.problems), result.problems
        case('flipped signature byte fails the signature', signature_flip)

        def certificate_flip():
            start = data.find(sig.leaf_der)
            result = mutated(start + len(sig.leaf_der) - 8)       # inside the leaf's own signature value
            assert not result.ok and any('chain' in p or 'signature' in p for p in result.problems), result.problems
        case('flipped leaf certificate byte fails verification', certificate_flip)

        def truncated():
            raises(ValueError, lambda: verify(data[:info.cert_offset - 100], publisher=PUBLISHER, roots_pem=roots),
                   'truncated')
            raises(ValueError, lambda: verify(data[:info.cert_offset + 20], publisher=PUBLISHER, roots_pem=roots),
                   'truncated')
        case('truncated file raises ValueError', truncated)

        def before_not_before():
            result = verify(data, publisher=PUBLISHER, roots_pem=roots,
                            at_time=datetime(2025, 1, 1, tzinfo=timezone.utc))
            assert not result.ok
            assert any('not yet valid' in p and 'notBefore' in p for p in result.problems), result.problems
            assert any('chain' in p and 'not yet valid' in p for p in result.problems), result.problems
            assert not any('digest' in p or 'signature does not' in p for p in result.problems), result.problems
        case('leaf checked before notBefore is rejected', before_not_before)

        def after_not_after():
            result = verify(data, publisher=PUBLISHER, roots_pem=roots,
                            at_time=datetime(2030, 1, 1, tzinfo=timezone.utc))
            assert not result.ok and any('expired' in p for p in result.problems), result.problems
        case('leaf checked after notAfter is rejected', after_not_after)

        def untrusted_root():
            empty = work / 'empty.pem'
            empty.write_text('')
            result = verify(data, publisher=PUBLISHER, roots_pem=empty)
            assert not result.ok and any('chain verification failed' in p for p in result.problems), result.problems
        case('chain without the root in the trust store is rejected', untrusted_root)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    case('synthetic PE digest excludes checksum, directory entry and table', test_synthetic_digest)
    case('synthetic PE without certificate table raises ValueError', test_no_cert_table)
    case('non-PE input raises ValueError', test_not_a_pe)
    case('garbage PKCS#7 gives ok=False, not an exception', test_garbage_pkcs7_never_raises)
    case('truncated synthetic PE raises ValueError', test_truncated_synthetic)
    case('DER reader rejects deep nesting, overlong, indefinite and truncated input', test_der_limits)
    if INSTALLER.is_file():
        real_installer_cases()
    else:
        print(f'SKIP real installer cases: {INSTALLER} is absent')
    if failures:
        print(f'{failures} Authenticode check(s) failed')
        sys.exit(1)
    print('Authenticode verification regression passed')


if __name__ == '__main__':
    main()
