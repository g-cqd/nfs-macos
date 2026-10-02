"""Verify a Windows PE file's Authenticode signature without Windows tooling.

The PE and PKCS#7 structures are parsed here with a small bounded DER reader; only the RSA/ECDSA signature
check and the certificate chain check are delegated to the `openssl` binary. A timestamp countersignature is
reported but never verified and never fails the check.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

MAX_DEPTH = 32
MAX_NODES = 200_000
MAX_TABLE = 16 * 1024 * 1024
SYSTEM_ROOTS = '/System/Library/Keychains/SystemRootCertificates.keychain'
OPENSSL_CANDIDATES = ('/opt/homebrew/opt/openssl@3/bin/openssl', 'openssl')

OID_SIGNED_DATA = '1.2.840.113549.1.7.2'
OID_SPC_INDIRECT = '1.3.6.1.4.1.311.2.1.4'
OID_CONTENT_TYPE = '1.2.840.113549.1.9.3'
OID_MESSAGE_DIGEST = '1.2.840.113549.1.9.4'
OID_SIGNING_TIME = '1.2.840.113549.1.9.5'
OID_COUNTER_SIGNATURE = '1.2.840.113549.1.9.6'
OID_MS_TIMESTAMP = '1.3.6.1.4.1.311.3.3.1'
OID_MS_NESTED_SIGNATURE = '1.3.6.1.4.1.311.2.4.1'
OID_ORGANIZATION = '2.5.4.10'
OID_EKU = '2.5.29.37'
OID_CODE_SIGNING = '1.3.6.1.5.5.7.3.3'

DIGESTS = {'1.3.14.3.2.26': 'sha1', '2.16.840.1.101.3.4.2.4': 'sha224', '2.16.840.1.101.3.4.2.1': 'sha256',
           '2.16.840.1.101.3.4.2.2': 'sha384', '2.16.840.1.101.3.4.2.3': 'sha512'}
# signature algorithm OID -> (name, hash fixed by the OID or None to use the SignerInfo digest algorithm)
SIGNATURES = {'1.2.840.113549.1.1.1': ('rsaEncryption', None),
              '1.2.840.113549.1.1.5': ('sha1WithRSAEncryption', 'sha1'),
              '1.2.840.113549.1.1.14': ('sha224WithRSAEncryption', 'sha224'),
              '1.2.840.113549.1.1.11': ('sha256WithRSAEncryption', 'sha256'),
              '1.2.840.113549.1.1.12': ('sha384WithRSAEncryption', 'sha384'),
              '1.2.840.113549.1.1.13': ('sha512WithRSAEncryption', 'sha512'),
              '1.2.840.10045.4.1': ('ecdsa-with-SHA1', 'sha1'),
              '1.2.840.10045.4.3.1': ('ecdsa-with-SHA224', 'sha224'),
              '1.2.840.10045.4.3.2': ('ecdsa-with-SHA256', 'sha256'),
              '1.2.840.10045.4.3.3': ('ecdsa-with-SHA384', 'sha384'),
              '1.2.840.10045.4.3.4': ('ecdsa-with-SHA512', 'sha512')}
NAME_OIDS = {'2.5.4.3': 'CN', '2.5.4.5': 'serialNumber', '2.5.4.6': 'C', '2.5.4.7': 'L', '2.5.4.8': 'ST',
             '2.5.4.9': 'street', '2.5.4.10': 'O', '2.5.4.11': 'OU', '2.5.4.15': 'businessCategory',
             '1.2.840.113549.1.9.1': 'emailAddress', '1.3.6.1.4.1.311.60.2.1.2': 'jurisdictionST',
             '1.3.6.1.4.1.311.60.2.1.3': 'jurisdictionC'}


class SignatureError(ValueError):
    """The PKCS#7 signature structure is malformed (the PE itself was fine)."""


# --------------------------------------------------------------------------------------------- DER reader

class Node:
    """One DER element: tag byte plus the byte ranges of the whole element and its content."""
    __slots__ = ('buf', 'tag', 'start', 'cstart', 'cend')

    def __init__(self, buf: bytes, tag: int, start: int, cstart: int, cend: int) -> None:
        self.buf, self.tag, self.start, self.cstart, self.cend = buf, tag, start, cstart, cend

    @property
    def raw(self) -> bytes:
        """The element with its tag and length."""
        return self.buf[self.start:self.cend]

    @property
    def value(self) -> bytes:
        """The content octets without tag and length."""
        return self.buf[self.cstart:self.cend]

    @property
    def constructed(self) -> bool:
        return bool(self.tag & 0x20)

    def children(self) -> list[Node]:
        """The direct children of a constructed element, read within this element's bounds."""
        if not self.constructed:
            raise SignatureError(f'tag 0x{self.tag:02x} is not constructed')
        out, pos = [], self.cstart
        while pos < self.cend:
            node = read_node(self.buf, pos, self.cend)
            out.append(node)
            pos = node.cend
            if len(out) > MAX_NODES:
                raise SignatureError('too many DER elements')
        return out


def read_node(buf: bytes, pos: int, end: int) -> Node:
    """Read one definite-length DER element at buf[pos:end]; indefinite lengths and high tags are rejected."""
    if pos + 2 > end:
        raise SignatureError('truncated DER element')
    tag = buf[pos]
    if tag & 0x1f == 0x1f:
        raise SignatureError('high tag numbers are not supported')
    first, cursor = buf[pos + 1], pos + 2
    if first < 0x80:
        length = first
    elif first == 0x80:
        raise SignatureError('indefinite length (BER) is not supported')
    else:
        count = first & 0x7f
        if count > 4 or cursor + count > end:
            raise SignatureError('bad DER length')
        length = int.from_bytes(buf[cursor:cursor + count], 'big')
        cursor += count
    if cursor + length > end:
        raise SignatureError('DER length exceeds the enclosing buffer')
    return Node(buf, tag, pos, cursor, cursor + length)


def check_tree(root: Node) -> None:
    """Walk every constructed element once, iteratively, rejecting nesting beyond MAX_DEPTH."""
    stack, seen = [(root, 1)], 0
    while stack:
        node, depth = stack.pop()
        if depth > MAX_DEPTH:
            raise SignatureError(f'DER nesting deeper than {MAX_DEPTH}')
        if node.constructed:
            for child in node.children():
                seen += 1
                if seen > MAX_NODES:
                    raise SignatureError('too many DER elements')
                stack.append((child, depth + 1))


def expect(node: Node, tag: int, what: str) -> Node:
    """Return node when it carries the wanted tag byte."""
    if node.tag != tag:
        raise SignatureError(f'{what}: expected tag 0x{tag:02x}, found 0x{node.tag:02x}')
    return node


def seq(node: Node, what: str, minimum: int = 0) -> list[Node]:
    """Children of a SEQUENCE/SET, with a minimum child count."""
    kids = node.children()
    if len(kids) < minimum:
        raise SignatureError(f'{what}: too few elements')
    return kids


def oid_of(node: Node) -> str:
    """Dotted form of an OBJECT IDENTIFIER element."""
    expect(node, 0x06, 'object identifier')
    data = node.value
    if not data or len(data) > 64 or data[-1] & 0x80:
        raise SignatureError('bad object identifier')
    arcs, acc = [], 0
    for byte in data:
        acc = (acc << 7) | (byte & 0x7f)
        if not byte & 0x80:
            arcs.append(acc)
            acc = 0
    first = arcs[0]
    head = [first // 40, first % 40] if first < 80 else [2, first - 80]
    return '.'.join(str(a) for a in head + arcs[1:])


def text_of(node: Node) -> str:
    """Decode a DER string element."""
    if node.tag == 0x1e:
        return node.value.decode('utf-16-be', 'replace')
    return node.value.decode('utf-8' if node.tag == 0x0c else 'latin-1', 'replace')


def time_of(node: Node) -> datetime:
    """Parse UTCTime or GeneralizedTime (UTC, seconds present)."""
    text = node.value.decode('ascii', 'replace')
    try:
        if node.tag == 0x17 and len(text) == 13 and text[-1] == 'Z':
            year = int(text[:2])
            return datetime.strptime(('19' if year >= 50 else '20') + text[:-1], '%Y%m%d%H%M%S').replace(
                tzinfo=timezone.utc)
        if node.tag == 0x18 and len(text) == 15 and text[-1] == 'Z':
            return datetime.strptime(text[:-1], '%Y%m%d%H%M%S').replace(tzinfo=timezone.utc)
    except ValueError:
        pass
    raise SignatureError(f'bad time value {text!r}')


def name_of(node: Node) -> tuple[str, list[str]]:
    """A distinguished name as 'CN=..., O=...' plus the list of its organization values."""
    parts, orgs = [], []
    for rdn in seq(expect(node, 0x30, 'name'), 'name'):
        for atv in seq(expect(rdn, 0x31, 'RDN'), 'RDN'):
            kids = seq(expect(atv, 0x30, 'attribute'), 'attribute', 2)
            oid, value = oid_of(kids[0]), text_of(kids[1])
            parts.append(f'{NAME_OIDS.get(oid, oid)}={value}')
            if oid == OID_ORGANIZATION:
                orgs.append(value)
    return ', '.join(parts), orgs


# ------------------------------------------------------------------------------------------- certificates

@dataclass
class Cert:
    """The fields of an X.509 certificate that this verifier needs."""
    der: bytes
    serial: bytes
    issuer_raw: bytes
    subject: str
    issuer: str
    organizations: list[str]
    not_before: datetime
    not_after: datetime
    eku: list[str]


def parse_cert(der: bytes) -> Cert:
    """Parse an X.509 certificate's TBSCertificate."""
    root = expect(read_node(der, 0, len(der)), 0x30, 'certificate')
    tbs = seq(expect(seq(root, 'certificate', 1)[0], 0x30, 'tbsCertificate'), 'tbsCertificate')
    base = 1 if tbs and tbs[0].tag == 0xA0 else 0
    if len(tbs) < base + 6:
        raise SignatureError('tbsCertificate: too few elements')
    serial, issuer, validity, subject = tbs[base], tbs[base + 2], tbs[base + 3], tbs[base + 4]
    times = seq(expect(validity, 0x30, 'validity'), 'validity', 2)
    subject_text, orgs = name_of(subject)
    eku: list[str] = []
    for ext in tbs[base + 6:]:
        if ext.tag != 0xA3:
            continue
        for item in seq(seq(ext, 'extensions', 1)[0], 'extensions'):
            parts = seq(expect(item, 0x30, 'extension'), 'extension', 2)
            if oid_of(parts[0]) == OID_EKU:
                body = read_node(parts[-1].value, 0, len(parts[-1].value))
                eku = [oid_of(n) for n in seq(expect(body, 0x30, 'extKeyUsage'), 'extKeyUsage')]
    return Cert(der, serial.value, issuer.raw, subject_text, name_of(issuer)[0], orgs,
                time_of(times[0]), time_of(times[1]), eku)


# ----------------------------------------------------------------------------------------------- PE side

@dataclass
class PEInfo:
    """Offsets inside a PE file that matter for the Authenticode digest."""
    checksum_offset: int
    cert_entry_offset: int
    headers_size: int
    sections: list[tuple[int, int]]
    cert_offset: int
    cert_size: int


def read_pe(data: bytes) -> PEInfo:
    """Locate the checksum, the certificate-table directory entry, the sections and the certificate table."""
    if len(data) < 0x40 or data[:2] != b'MZ':
        raise ValueError('not a PE file: missing MZ header')
    (lfanew,) = struct.unpack_from('<I', data, 0x3c)
    if lfanew < 0x40 or lfanew + 24 > len(data) or data[lfanew:lfanew + 4] != b'PE\0\0':
        raise ValueError('not a PE file: missing PE signature')
    count, opt_size = struct.unpack_from('<H', data, lfanew + 6)[0], struct.unpack_from('<H', data, lfanew + 20)[0]
    opt = lfanew + 24
    if opt + opt_size > len(data):
        raise ValueError('truncated PE: optional header runs past the end of the file')
    magic = struct.unpack_from('<H', data, opt)[0] if opt_size >= 2 else 0
    dirs_at, dir_count_at = {0x10b: (opt + 96, opt + 92), 0x20b: (opt + 112, opt + 108)}.get(magic, (0, 0))
    if not dirs_at:
        raise ValueError(f'not a PE file: unknown optional header magic 0x{magic:x}')
    if opt_size < dirs_at - opt + 8 * 5:
        raise ValueError('PE has no certificate table (no data directories)')
    headers_size = struct.unpack_from('<I', data, opt + 60)[0]
    n_dirs = struct.unpack_from('<I', data, dir_count_at)[0]
    entry = dirs_at + 4 * 8
    cert_offset, cert_size = struct.unpack_from('<II', data, entry)
    if n_dirs <= 4 or cert_offset == 0 or cert_size == 0:
        raise ValueError('PE has no certificate table')
    table = opt + opt_size
    if table + count * 40 > len(data) or headers_size > len(data):
        raise ValueError('truncated PE: section table runs past the end of the file')
    sections = []
    for i in range(count):
        size, ptr = struct.unpack_from('<II', data, table + i * 40 + 16)
        if size and ptr + size > len(data):
            raise ValueError('truncated PE: a section runs past the end of the file')
        if size:
            sections.append((ptr, size))
    if cert_offset + 8 > len(data) or cert_offset + cert_size > len(data) or cert_size > MAX_TABLE:
        raise ValueError('truncated PE: certificate table lies outside the file')
    if cert_offset < headers_size:
        raise ValueError('malformed PE: certificate table overlaps the headers')
    return PEInfo(opt + 64, entry, headers_size, sorted(sections), cert_offset, cert_size)


def pe_authenticode_digest(data: bytes, algorithm: str) -> bytes:
    """Authenticode digest of a PE: everything except checksum, certificate directory entry and the table."""
    info = read_pe(data)
    h = hashlib.new(algorithm)
    h.update(data[:info.checksum_offset])
    h.update(data[info.checksum_offset + 4:info.cert_entry_offset])
    h.update(data[info.cert_entry_offset + 8:info.headers_size])
    hashed = info.headers_size
    for ptr, size in info.sections:
        if ptr < hashed:
            raise ValueError('malformed PE: overlapping sections or headers')
        h.update(data[ptr:ptr + size])
        hashed = ptr + size
    if info.cert_offset < hashed:
        raise ValueError('malformed PE: certificate table overlaps a section')
    h.update(data[hashed:info.cert_offset])
    return h.digest()


# --------------------------------------------------------------------------------------- PKCS#7 parsing

@dataclass
class Signature:
    """The parts of an Authenticode PKCS#7 signature that verification needs."""
    pkcs7: bytes
    digest_algorithm: str            # algorithm of the digest embedded in SpcIndirectDataContent
    indirect_digest: bytes           # that digest (the PE hash the publisher signed)
    leaf_der: bytes | None           # certificate matching SignerInfo issuer+serial, None if not embedded
    certificates: list[bytes]
    signed_attrs: bytes              # DER of the signed attributes with the SET tag 0x31 (what is signed)
    signature: bytes
    signature_algorithm: str         # OID, resolved through SIGNATURES by the verifier
    signer_digest_algorithm: str = ''
    message_digest: bytes = b''      # SignerInfo messageDigest attribute
    indirect_content_hash_input: bytes = b''   # content octets of SpcIndirectDataContent (hashed for messageDigest)
    content_type: str = ''           # contentType attribute, '' when absent
    timestamp: str = ''
    notes: list[str] = field(default_factory=list)
    trailing_after_table: int = 0


def digest_name(oid: str) -> str:
    """hashlib name for a digest OID, or the OID itself when unknown."""
    return DIGESTS.get(oid, oid)


def algorithm_of(node: Node) -> str:
    """OID of an AlgorithmIdentifier."""
    return oid_of(seq(expect(node, 0x30, 'algorithm identifier'), 'algorithm identifier', 1)[0])


def describe_timestamp(info: Node) -> str:
    """Best-effort, unverified description of a SignerInfo's countersignature or RFC 3161 timestamp."""
    try:
        kids = seq(info, 'signerInfo', 5)
        for unauth in (n for n in kids[5:] if n.tag == 0xA1):
            for attr in seq(unauth, 'unauthenticated attributes'):
                parts = seq(attr, 'attribute', 2)
                oid = oid_of(parts[0])
                value = seq(parts[1], 'attribute values', 1)[0]
                if oid == OID_COUNTER_SIGNATURE:
                    return 'countersignature (unverified), signingTime ' + counter_time(value)
                if oid == OID_MS_TIMESTAMP:
                    return 'RFC 3161 timestamp (unverified), genTime ' + tst_time(value)
    except (SignatureError, IndexError):
        return 'unparseable timestamp attribute'
    return ''


def counter_time(signer_info: Node) -> str:
    """signingTime from a countersignature SignerInfo's signed attributes."""
    for node in seq(signer_info, 'countersigner', 4):
        if node.tag == 0xA0:
            for attr in seq(node, 'attrs'):
                parts = seq(attr, 'attribute', 2)
                if oid_of(parts[0]) == OID_SIGNING_TIME:
                    return time_of(seq(parts[1], 'values', 1)[0]).strftime('%Y-%m-%d %H:%M:%SZ')
    return '(none)'


def tst_time(content_info: Node) -> str:
    """genTime of the TSTInfo inside an RFC 3161 timestamp token."""
    outer = seq(content_info, 'timestamp token', 2)
    signed = seq(seq(outer[1], 'timestamp content', 1)[0], 'timestamp signedData', 3)
    encap = seq(signed[2], 'encapsulated content', 2)
    octets = seq(encap[1], 'encapsulated value', 1)[0]
    info = read_node(octets.value, 0, len(octets.value))
    fields = seq(info, 'TSTInfo', 5)
    return time_of(fields[4]).strftime('%Y-%m-%d %H:%M:%SZ')


def pkcs7_table_entry(data: bytes) -> tuple[bytes, int]:
    """First PKCS#7 WIN_CERTIFICATE payload of the certificate table and the byte count after the table."""
    info = read_pe(data)
    length, revision, kind = struct.unpack_from('<IHH', data, info.cert_offset)
    if length < 8 or length > info.cert_size:
        raise SignatureError(f'WIN_CERTIFICATE length {length} is inconsistent with the table size {info.cert_size}')
    if kind != 2:
        raise SignatureError(f'WIN_CERTIFICATE type {kind} is not PKCS#7 (2)')
    after = len(data) - (info.cert_offset + info.cert_size)
    return data[info.cert_offset + 8:info.cert_offset + length], after


def parse_signature(data: bytes) -> Signature:
    """Parse the Authenticode PKCS#7 of a PE. ValueError: not a PE / no table; SignatureError: bad PKCS#7."""
    pkcs7, after = pkcs7_table_entry(data)
    root = read_node(pkcs7, 0, len(pkcs7))
    check_tree(root)
    top = seq(expect(root, 0x30, 'ContentInfo'), 'ContentInfo', 2)
    if oid_of(top[0]) != OID_SIGNED_DATA:
        raise SignatureError('PKCS#7 is not SignedData')
    signed = seq(expect(seq(expect(top[1], 0xA0, 'content'), 'content', 1)[0], 0x30, 'SignedData'),
                 'SignedData', 4)
    encap = seq(expect(signed[2], 0x30, 'encapContentInfo'), 'encapContentInfo', 2)
    if oid_of(encap[0]) != OID_SPC_INDIRECT:
        raise SignatureError('encapsulated content is not SpcIndirectDataContent')
    indirect = expect(seq(expect(encap[1], 0xA0, 'encapsulated content'), 'encapsulated content', 1)[0],
                      0x30, 'SpcIndirectDataContent')
    parts = seq(indirect, 'SpcIndirectDataContent', 2)
    digest_info = seq(expect(parts[1], 0x30, 'DigestInfo'), 'DigestInfo', 2)
    indirect_digest = expect(digest_info[1], 0x04, 'DigestInfo digest').value

    certs_node = next((n for n in signed[3:] if n.tag == 0xA0), None)
    cert_ders = [n.raw for n in seq(certs_node, 'certificates')] if certs_node else []
    signer_set = expect(signed[-1], 0x31, 'signerInfos')
    infos = seq(signer_set, 'signerInfos')
    if len(infos) != 1:
        raise SignatureError(f'expected exactly one SignerInfo, found {len(infos)}')
    kids = seq(expect(infos[0], 0x30, 'SignerInfo'), 'SignerInfo', 5)
    issuer_serial = seq(expect(kids[1], 0x30, 'issuerAndSerialNumber'), 'issuerAndSerialNumber', 2)
    signer_digest = algorithm_of(kids[2])
    if kids[3].tag != 0xA0:
        raise SignatureError('SignerInfo has no signed attributes')
    attrs_der = b'\x31' + kids[3].raw[1:]
    message_digest, content_type = b'', ''
    for attr in seq(kids[3], 'signed attributes'):
        pieces = seq(expect(attr, 0x30, 'attribute'), 'attribute', 2)
        oid, value = oid_of(pieces[0]), seq(expect(pieces[1], 0x31, 'attribute values'), 'attribute values', 1)[0]
        if oid == OID_MESSAGE_DIGEST:
            message_digest = expect(value, 0x04, 'messageDigest').value
        elif oid == OID_CONTENT_TYPE:
            content_type = oid_of(value)
    sig_alg = algorithm_of(kids[4])
    signature = expect(kids[5], 0x04, 'encryptedDigest').value
    leaf = None
    for der in cert_ders:
        try:
            cert = parse_cert(der)
        except SignatureError:
            continue
        if cert.issuer_raw == issuer_serial[0].raw and cert.serial == issuer_serial[1].value:
            leaf = der
    notes = []
    stamp = describe_timestamp(infos[0])
    if any(n.tag == 0xA1 and OID_MS_NESTED_SIGNATURE in oid_list(n) for n in kids[6:]):
        notes.append('contains a nested (additional) signature, not verified')
    return Signature(pkcs7, digest_name(algorithm_of(digest_info[0])), indirect_digest, leaf, cert_ders,
                     attrs_der, signature, sig_alg, digest_name(signer_digest), message_digest,
                     indirect.value, content_type, stamp, notes, after)


def oid_list(unauth: Node) -> list[str]:
    """Attribute OIDs of an unauthenticated-attributes element."""
    try:
        return [oid_of(seq(a, 'attribute', 1)[0]) for a in seq(unauth, 'attributes')]
    except SignatureError:
        return []


# ----------------------------------------------------------------------------------------- verification

@dataclass
class VerifyResult:
    """Outcome of verify(): ok only when every check passed and problems is empty."""
    ok: bool = False
    signer_subject: str = ''
    issuer: str = ''
    not_before: str = ''
    not_after: str = ''
    digest_algorithm: str = ''
    digest_hex: str = ''
    file_sha256: str = ''
    problems: list[str] = field(default_factory=list)
    timestamp: str = ''
    signature_algorithm: str = ''
    chain_root: str = ''
    notes: list[str] = field(default_factory=list)


def find_openssl() -> str:
    """Path of an openssl binary."""
    for candidate in OPENSSL_CANDIDATES:
        found = shutil.which(candidate)
        if found:
            return found
    raise FileNotFoundError('openssl not found')


def run(args: list[str], timeout: int = 60) -> subprocess.CompletedProcess:
    """Run a helper binary with captured text output."""
    return subprocess.run(args, capture_output=True, timeout=timeout, text=True, errors='replace')


def verify_signature_value(sig: Signature, leaf_pem_dir: Path, leaf: Cert) -> str | None:
    """Check the SignerInfo signature with openssl; return a problem string or None."""
    entry = SIGNATURES.get(sig.signature_algorithm)
    if entry is None:
        return f'unsupported signature algorithm {sig.signature_algorithm} (only RSA PKCS#1 v1.5 and ECDSA)'
    name, fixed = entry
    hash_name = fixed or sig.signer_digest_algorithm
    if hash_name not in DIGESTS.values():
        return f'unsupported signature digest {hash_name}'
    openssl = find_openssl()
    (leaf_pem_dir / 'leaf.der').write_bytes(leaf.der)
    key = run([openssl, 'x509', '-pubkey', '-noout', '-inform', 'DER', '-in', str(leaf_pem_dir / 'leaf.der')])
    if key.returncode != 0 or 'PUBLIC KEY' not in key.stdout:
        return 'cannot extract the signer public key: ' + key.stderr.strip()[:200]
    (leaf_pem_dir / 'pub.pem').write_text(key.stdout)
    (leaf_pem_dir / 'sig.bin').write_bytes(sig.signature)
    (leaf_pem_dir / 'attrs.der').write_bytes(sig.signed_attrs)
    out = run([openssl, 'dgst', f'-{hash_name}', '-verify', str(leaf_pem_dir / 'pub.pem'),
               '-signature', str(leaf_pem_dir / 'sig.bin'), str(leaf_pem_dir / 'attrs.der')])
    if out.returncode == 0 and 'Verified OK' in out.stdout:
        return None
    if 'Verification failure' in out.stdout or 'Verification failure' in out.stderr:
        return f'signature does not verify ({name} over the signed attributes with the leaf key)'
    return f'signature check could not run ({name}): ' + (out.stderr.strip() or out.stdout.strip())[:200]


def export_roots(target: Path) -> str | None:
    """Write the macOS system roots to target; return a problem string or None."""
    out = run(['/usr/bin/security', 'find-certificate', '-a', '-p', SYSTEM_ROOTS])
    if out.returncode != 0 or 'BEGIN CERTIFICATE' not in out.stdout:
        return 'cannot export the macOS system roots: ' + out.stderr.strip()[:200]
    target.write_text(out.stdout)
    return None


def pem(der: bytes) -> str:
    """PEM text of a DER certificate."""
    body = base64.encodebytes(der).decode()
    return f'-----BEGIN CERTIFICATE-----\n{body}-----END CERTIFICATE-----\n'


def verify_chain(sig: Signature, leaf: Cert, work: Path, roots_pem: Path | None, epoch: int) -> tuple[str | None, str]:
    """openssl chain verification of the leaf through the embedded intermediates; (problem, root subject)."""
    roots = roots_pem
    if roots is None:
        roots = work / 'roots.pem'
        problem = export_roots(roots)
        if problem:
            return problem, ''
    (work / 'chain-leaf.pem').write_text(pem(leaf.der))
    (work / 'untrusted.pem').write_text(''.join(pem(c) for c in sig.certificates if c != leaf.der))
    # `openssl verify` has no code-signing purpose (-purpose codesigning is rejected as invalid), so the default
    # chain checks run here and the leaf's codeSigning EKU is checked separately by the caller.
    out = run([find_openssl(), 'verify', '-show_chain', '-CAfile', str(roots), '-untrusted', str(work / 'untrusted.pem'),
               '-attime', str(epoch), str(work / 'chain-leaf.pem')])
    text = (out.stdout + out.stderr).strip()
    first = out.stdout.splitlines()[0] if out.stdout.strip() else ''
    if out.returncode != 0 or not first.endswith(': OK'):
        errors = [ln.strip() for ln in text.splitlines() if 'error' in ln.lower()]
        return 'certificate chain verification failed: ' + ('; '.join(errors) or text)[:300], ''
    depths = [ln for ln in out.stdout.splitlines() if ln.startswith('depth=')]
    return None, depths[-1].split(': ', 1)[-1] if depths else ''


def fmt(moment: datetime) -> str:
    """Compact UTC timestamp."""
    return moment.strftime('%Y-%m-%d %H:%M:%SZ')


def verify(path_or_bytes, *, publisher: str, roots_pem: Path | None = None,
           at_time: datetime | None = None) -> VerifyResult:
    """Check a PE's Authenticode signature; never raises for an invalid signature.

    Raises ValueError for a file that is not a (complete) PE or has no certificate table. A naive at_time is
    taken as UTC. Every failure adds a problem string and leaves ok False.
    """
    data = bytes(path_or_bytes) if isinstance(path_or_bytes, (bytes, bytearray)) else Path(path_or_bytes).read_bytes()
    res = VerifyResult(file_sha256=hashlib.sha256(data).hexdigest())
    try:
        sig = parse_signature(data)
    except SignatureError as exc:
        res.problems.append(f'malformed signature: {exc}')
        return res
    res.digest_algorithm, res.signature_algorithm = sig.digest_algorithm, SIGNATURES.get(
        sig.signature_algorithm, (sig.signature_algorithm,))[0]
    res.timestamp, res.notes = sig.timestamp, list(sig.notes)
    if sig.trailing_after_table:
        res.notes.append(f'{sig.trailing_after_table} bytes follow the certificate table (not signed)')
    problems = res.problems
    # (1) PE digest vs the digest embedded in SpcIndirectDataContent
    if sig.digest_algorithm not in DIGESTS.values():
        problems.append(f'unsupported PE digest algorithm {sig.digest_algorithm}')
    else:
        computed = pe_authenticode_digest(data, sig.digest_algorithm)
        res.digest_hex = computed.hex()
        if computed != sig.indirect_digest:
            problems.append(f'PE digest mismatch: file {computed.hex()} but signed {sig.indirect_digest.hex()}')
    # (2) messageDigest attribute vs hash of the SpcIndirectDataContent content octets
    if sig.signer_digest_algorithm not in DIGESTS.values():
        problems.append(f'unsupported SignerInfo digest algorithm {sig.signer_digest_algorithm}')
    elif hashlib.new(sig.signer_digest_algorithm, sig.indirect_content_hash_input).digest() != sig.message_digest:
        problems.append('messageDigest attribute does not match the hash of the signed content')
    if sig.content_type and sig.content_type != OID_SPC_INDIRECT:
        problems.append(f'contentType attribute {sig.content_type} is not SpcIndirectData')
    if sig.leaf_der is None:
        problems.append('signer certificate is not embedded in the signature')
        return finish(res)
    try:
        leaf = parse_cert(sig.leaf_der)
    except SignatureError as exc:
        problems.append(f'malformed signer certificate: {exc}')
        return finish(res)
    res.signer_subject, res.issuer = leaf.subject, leaf.issuer
    res.not_before, res.not_after = fmt(leaf.not_before), fmt(leaf.not_after)
    # (4) publisher and code-signing EKU
    if leaf.organizations != [publisher]:
        problems.append(f'signer organization {leaf.organizations} is not {[publisher]}')
    if OID_CODE_SIGNING not in leaf.eku:
        problems.append('signer certificate lacks the codeSigning extended key usage')
    moment = at_time if at_time is not None else datetime.now(timezone.utc)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    if moment < leaf.not_before:
        problems.append(f'signer certificate is not yet valid at {fmt(moment)} (notBefore {res.not_before})')
    elif moment > leaf.not_after:
        problems.append(f'signer certificate has expired at {fmt(moment)} (notAfter {res.not_after})')
    work = Path(tempfile.mkdtemp(prefix='authenticode-', dir='/tmp' if Path('/tmp').is_dir() else None))
    try:
        # (3) signature over the signed attributes
        try:
            problem = verify_signature_value(sig, work, leaf)
        except (OSError, subprocess.SubprocessError) as exc:
            problem = f'signature check could not run: {exc}'
        if problem:
            problems.append(problem)
        # (5) chain to a system root
        try:
            problem, res.chain_root = verify_chain(sig, leaf, work, roots_pem, int(moment.timestamp()))
        except (OSError, subprocess.SubprocessError) as exc:
            problem = f'certificate chain check could not run: {exc}'
        if problem:
            problems.append(problem)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return finish(res)


def finish(res: VerifyResult) -> VerifyResult:
    """Set ok from the collected problems."""
    res.ok = not res.problems
    return res


def main(argv: list[str] | None = None) -> int:
    """CLI: print a short summary and exit 0 when the signature is valid for the publisher."""
    parser = argparse.ArgumentParser(description='Verify a PE file Authenticode signature without Windows.')
    parser.add_argument('file')
    parser.add_argument('--publisher', required=True, help="exact signer organization, e.g. 'Electronic Arts, Inc.'")
    parser.add_argument('--roots', type=Path, help='PEM bundle of trusted roots (default: macOS system roots)')
    parser.add_argument('--at', help='evaluate certificate validity at this ISO-8601 time (UTC if no zone)')
    args = parser.parse_args(argv)
    try:
        res = verify(args.file, publisher=args.publisher, roots_pem=args.roots,
                     at_time=datetime.fromisoformat(args.at) if args.at else None)
    except (OSError, ValueError) as exc:
        print(f'FAIL: {exc}')
        return 1
    print(f'signer:    {res.signer_subject}')
    print(f'issuer:    {res.issuer}')
    print(f'valid:     {res.not_before} to {res.not_after}')
    print(f'algorithm: digest {res.digest_algorithm}, signature {res.signature_algorithm}')
    print(f'PE digest: {res.digest_hex}')
    print(f'SHA-256:   {res.file_sha256}')
    print(f'root:      {res.chain_root or "(not established)"}')
    print(f'timestamp: {res.timestamp or "none"}')
    for note in res.notes:
        print(f'note:      {note}')
    for problem in res.problems:
        print(f'problem:   {problem}')
    print('OK' if res.ok else 'FAIL')
    return 0 if res.ok else 1


if __name__ == '__main__':
    sys.exit(main())
