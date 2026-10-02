"""The EA client layer: the official EA app, installed once at build time and shipped as plain data.

A bundled Need for Speed (2015) app carries the files and registry entries EA's own installer
creates, so a player never downloads or runs that installer. The layer is made by diffing a pristine
prefix before and after the installer ran, then keeping only what an explicit policy allows. Every
added file and registry key must be classified by a rule below: `keep` goes into the layer, `drop`
is per-machine, per-user or host-derived state that is deliberately left out, and `forbid` or an
unclassified path stops the build so that a new installer version is reviewed by a person.

On disk a layer is one folder:

    client-layer.json          the manifest: client facts, every entry, every registry part and its digest
    blobs/<sha256>             file contents, stored once however many places they are installed to
    registry/<hive>.part       Wine hive text for the kept keys, appended to the new prefix's hive

The layer digest is the SHA-256 of `client-layer.json`. It names every blob and registry part by digest,
so pinning it in a recipe pins every byte. The same input always gives the same bytes: entries and keys
are sorted, per-install values (the Windows Installer cache name, the install date, key timestamps) are
normalized, and nothing is read from the clock.
"""
import argparse
import base64
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

FORMAT = 1
MANIFEST_NAME = 'client-layer.json'
BLOB_DIRECTORY = 'blobs'
REGISTRY_DIRECTORY = 'registry'
HIVES = ('system.reg', 'user.reg')
# The only extended attributes a layer carries. Wine keeps the DOS attribute bits and the target of
# an NTFS junction in them; every `com.apple.*` attribute is macOS bookkeeping of the build Mac.
ALLOWED_XATTRS = ('user.DOSATTRIB', 'user.WINEREPARSE')
MAX_ENTRIES = 20_000
MAX_BYTES = 2 * 1024**3
MAX_PART_BYTES = 8 * 1024 * 1024
# Windows Installer names its cached copy of a package after a random number; a layer uses one fixed name.
CANONICAL_PACKAGE = 'windows/Installer/eaapp.msi'
CANONICAL_INSTALL_DATE = '20260101'
CANONICAL_STAMP = 1767225600
CANONICAL_TIME = format((CANONICAL_STAMP + 11_644_473_600) * 10_000_000, 'x')

GUID = r'\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}'
EA_PROGRAMS = 'Program Files/Electronic Arts'
GAME_ROOT = 'Program Files/EA Games'


class Rule:
    """One classification decision, with the reason it was taken."""

    def __init__(self, ident, action, pattern, reason):
        assert action in {'keep', 'drop', 'forbid'}
        self.ident, self.action, self.reason = ident, action, reason
        self.pattern = re.compile(pattern)

    def matches(self, value):
        return self.pattern.fullmatch(value) is not None


# Paths are relative to `drive_c`, with forward slashes. The first matching rule decides.
FILE_RULES = [
    Rule('F01', 'drop', r'users/[^/]+/AppData(/.*)?',
         'Per-user state: EA telemetry cache, the installer log and temp files, the browser cache. Examined: it names the '
         'build session and the client process that ran, and the client recreates what it needs'),
    Rule('F02', 'drop', r'users/Public(/.*)?',
         'Desktop shortcuts: a .lnk embeds the FAT date and time of the install in its shell item list, so two installs differ'),
    Rule('F03', 'drop', r'ProgramData/EA Desktop(/.*)?',
         'Per-machine state written by the EA background service: machine.ini (random experiment and update buckets, telemetry '
         'stats), the hash-named identifier folder with its IQ token, backgroundservice.ini (process id), PLR, and the logs'),
    Rule('F04', 'drop', r'ProgramData/Microsoft/Windows/Start Menu(/.*)?',
         'Start menu shortcuts: .lnk files with install timestamps; the app shows no Windows start menu'),
    Rule('F05', 'drop', rf'ProgramData/Package Cache/{GUID}[^/]*/state\.rsm',
         'The setup engine\'s resume state: it records where the installer was started from, which is a path on the build Mac'),
    Rule('F06', 'keep', r'ProgramData/Package Cache',
         'Folder of the setup engine\'s package cache'),
    Rule('F07', 'keep', rf'ProgramData/Package Cache/{GUID}[^/]*',
         'The package cache folders the setup engine registers for repair and uninstall'),
    Rule('F08', 'keep', rf'ProgramData/Package Cache/{GUID}[^/]*/[^/]+\.(?:msi|exe)',
         'The cached MSI and the cached setup engine, which the registered repair and uninstall commands run'),
    Rule('F09', 'keep', rf'windows/Installer/{GUID}',
         'Windows Installer product folder'),
    Rule('F10', 'keep', rf'windows/Installer/{GUID}/[^/]+\.ico',
         'The product icon Windows Installer copies beside its cache'),
    Rule('F11', 'keep', r'windows/Installer/[0-9a-f]{1,8}\.msi',
         'Windows Installer\'s cached copy of the package (renamed to a fixed name; the registry value follows)'),
    Rule('F12', 'drop', rf'{EA_PROGRAMS}/.*\.lnk',
         'A shortcut inside the program folder: it embeds install timestamps and only starts an EA tool from a start menu'),
    Rule('F13', 'keep', rf'{EA_PROGRAMS}/EA Desktop/[^/]+/EA Desktop/legacyPM/EACore_App\.ini',
         'The one .ini in the client: a static legacy agent table with placeholders ({clientGUID}); identical in every install'),
    Rule('F14', 'forbid', r'.*\.(?:ini|log|sqlite|db|tmp|bak|pem|p12|pfx|reg|keychain|zip|7z|rar|sha256)',
         'A configuration, log, database, key or registry file nobody has reviewed'),
    Rule('F15', 'keep', rf'{EA_PROGRAMS}(/.*)?',
         'The EA client\'s program files, identical in every install'),
    Rule('F16', 'keep', r'Program Files/Common Files/EAInstaller(/.*)?',
         'The folder the EA installer registers beside its client'),
]

# Registry keys, with the doubled backslashes of a Wine hive file undone, per hive.
KEY_RULES = {
    'system.reg': [
        Rule('R01', 'drop', r'Software\\Microsoft\\SystemCertificates(\\.*)?',
             'Wine\'s own certificate store, filled on first use'),
        Rule('R02', 'drop', r'Software\\(?:Wow6432Node\\)?Wine\\HostImportedCertificates(\\.*)?',
             'Root certificates Wine copies from the host\'s keychain: the building Mac\'s, never the player\'s'),
        Rule('R03', 'drop', r'System\\ControlSet001\\Enum(\\.*)?',
             'Wine\'s device enumeration, rewritten on every start with fresh container identifiers and the host\'s controllers'),
        Rule('R04', 'drop', r'System\\ControlSet001\\Control\\Session Manager',
             'A pending delete of an installer temp file'),
        Rule('R05', 'keep', r'Software\\Classes\\.*',
             'Windows Installer product, feature and dependency records, and the EA URL protocol handlers and COM extension'),
        Rule('R06', 'keep', r'Software\\(?:Wow6432Node\\)?Electronic Arts(\\.*)?',
             'The EA client\'s own paths and install record'),
        Rule('R07', 'keep', r'Software\\Wow6432Node\\Origin',
             'The legacy client path'),
        Rule('R08', 'keep', rf'Software\\(?:Wow6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Uninstall\\{GUID}',
             'The EA app\'s registered uninstall entries'),
        Rule('R09', 'keep', r'Software\\Microsoft\\Windows\\CurrentVersion\\Installer\\UpgradeCodes\\[0-9A-F]{32}',
             'Windows Installer upgrade code'),
        Rule('R10', 'keep',
             r'Software\\Microsoft\\Windows\\CurrentVersion\\Installer\\UserData\\S-1-5-18\\(?:Components|Products)\\[0-9A-F]{32}(?:\\.*)?',
             'Windows Installer\'s component and product database, which repair and upgrade read'),
        Rule('R11', 'keep', r'Software\\Microsoft\\Xbox\\GamingApp\\Extensions\\.*',
             'The client\'s Xbox app extension registration'),
        Rule('R12', 'keep', r'System\\ControlSet001\\Services\\EABackgroundService',
             'The EA background service registration'),
    ],
    'user.reg': [
        Rule('U01', 'drop', r'Software\\Microsoft\\SystemCertificates(\\.*)?',
             'Wine\'s own certificate store, filled on first use'),
        Rule('U02', 'drop', r'Software\\Microsoft\\Windows\\CurrentVersion\\Wintrust(\\.*)?',
             'Wine\'s trust-provider state'),
        Rule('U03', 'keep', r'Software\\Microsoft\\Xbox\\GamingApp\\Extensions\\Data\\[^\\]+',
             'The client\'s Xbox app extension state'),
    ],
}

# Values rewritten so that two independent installs give the same bytes.
LOCAL_PACKAGE = re.compile(r'^("LocalPackage"=")C:\\\\windows\\\\Installer\\\\[0-9a-f]{1,8}\.msi(")$')
INSTALL_DATE = re.compile(r'^("InstallDate"=")[0-9]{8}(")$')

# Text that must never appear in a kept path or kept registry text: a user profile, a host path,
# a drive that Wine maps to the host, a per-user folder.
FORBIDDEN_TEXT = [re.compile(pattern, re.IGNORECASE) for pattern in
                  [r'[\\/]users[\\/]', r'\bz:\\', r'appdata', r'[\\/]temp[\\/]', r'dosdevices', r'/Volumes/',
                   r'machine\.ini']]


# --- Wine hive text -------------------------------------------------------------------------------------

KEY_HEADER = re.compile(r'^\[(.*)\] ([0-9]+)$')


def undouble(key):
    return key.replace('\\\\', '\\')


class Hive:
    """A Wine hive file as text: its header lines and its keys, each with the raw lines of its values."""

    def __init__(self, header, keys):
        self.header, self.keys = header, keys

    @classmethod
    def parse(cls, text):
        header, keys, current = [], {}, None
        for line in text.split('\n'):
            found = KEY_HEADER.match(line)
            if found:
                current = found.group(1)
                if current in keys:
                    raise ValueError('Duplicate registry key: ' + current)
                keys[current] = {'stamp': int(found.group(2)), 'time': None, 'body': []}
            elif current is None:
                header.append(line)
            elif line.startswith('#time='):
                keys[current]['time'] = line
            elif line != '' or keys[current]['body'] and keys[current]['body'][-1].endswith('\\'):
                keys[current]['body'].append(line)
        return cls(header, keys)


def read_hive(path):
    return Hive.parse(Path(path).read_bytes().decode('utf-8', errors='surrogateescape'))


def body_problems(key, body):
    """A key body is value lines only: `"name"=…` or `@=…`, with hex continuations ending in a backslash."""
    problems, continued = [], False
    for line in body:
        if continued:
            continued = line.endswith('\\')
            continue
        if not (line.startswith('"') or line.startswith('@=')):
            problems.append('Unexpected line in registry key ' + key)
            break
        continued = line.endswith('\\') and line.split('=', 1)[1].startswith('hex')
    return problems


def normalized_body(key, body):
    """The key's value lines with per-install values replaced; returns the lines and the rewrites made."""
    out, rewrites = [], {'LocalPackage': 0, 'InstallDate': 0}
    for line in body:
        package, date = LOCAL_PACKAGE.match(line), INSTALL_DATE.match(line)
        if package:
            line = package.group(1) + 'C:\\\\' + CANONICAL_PACKAGE.replace('/', '\\\\') + package.group(2)
            rewrites['LocalPackage'] += 1
        elif date:
            line = date.group(1) + CANONICAL_INSTALL_DATE + date.group(2)
            rewrites['InstallDate'] += 1
        out.append(line)
    return out, rewrites


def part_text(sections):
    """Hive text for already-normalized sections, sorted by key, with fixed timestamps."""
    parts = []
    for key in sorted(sections):
        parts.append('[%s] %d\n#time=%s\n%s\n\n' % (key, CANONICAL_STAMP, CANONICAL_TIME, '\n'.join(sections[key])))
    return ''.join(parts)


def merge_hive(hive_text, part):
    """The hive with the part appended, which is what the app does to a stopped prefix.

    Refuses a part that names a key the hive already has, so two sources of one key never mix silently.
    """
    present = {undouble(key).lower() for key in Hive.parse(hive_text).keys}
    for key in Hive.parse(part).keys:
        if undouble(key).lower() in present:
            raise ValueError('The prefix already has registry key ' + undouble(key))
    separator = '' if hive_text.endswith('\n\n') else ('\n' if hive_text.endswith('\n') else '\n\n')
    return hive_text + separator + part


# --- extended attributes --------------------------------------------------------------------------------

_libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
_libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
_libc.listxattr.restype = ctypes.c_ssize_t
_libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32,
                           ctypes.c_int]
_libc.getxattr.restype = ctypes.c_ssize_t
_XATTR_NOFOLLOW = 1


def xattr_names(path):
    raw = os.fsencode(path)
    size = _libc.listxattr(raw, None, 0, _XATTR_NOFOLLOW)
    if size <= 0:
        return []
    buffer = ctypes.create_string_buffer(size)
    _libc.listxattr(raw, buffer, size, _XATTR_NOFOLLOW)
    return [name.decode() for name in buffer.raw[:size].split(b'\0') if name]


def xattr_value(path, name):
    raw = os.fsencode(path)
    size = _libc.getxattr(raw, name.encode(), None, 0, 0, _XATTR_NOFOLLOW)
    buffer = ctypes.create_string_buffer(max(size, 1))
    _libc.getxattr(raw, name.encode(), buffer, size, 0, _XATTR_NOFOLLOW)
    return buffer.raw[:size]


# --- snapshots and the plan -----------------------------------------------------------------------------

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        while block := stream.read(1 << 22):
            digest.update(block)
    return digest.hexdigest()


def snapshot_tree(prefix, skip=(GAME_ROOT,)):
    """Every file, folder and link below `drive_c`, with size and digest; the game's folder is left out."""
    root = Path(prefix) / 'drive_c'
    entries = {}
    for directory, folders, names in os.walk(root):
        relative = Path(directory).relative_to(root).as_posix()
        if any(relative == item or relative.startswith(item + '/') for item in skip):
            folders[:] = []
            continue
        for name in folders:
            path = Path(directory) / name
            key = path.relative_to(root).as_posix()
            if any(key == item or key.startswith(item + '/') for item in skip):
                continue
            entries[key] = {'kind': 'link', 'target': os.readlink(path)} if path.is_symlink() else {'kind': 'dir'}
        for name in names:
            path = Path(directory) / name
            key = path.relative_to(root).as_posix()
            if path.is_symlink():
                entries[key] = {'kind': 'link', 'target': os.readlink(path)}
            else:
                entries[key] = {'kind': 'file', 'size': path.stat().st_size, 'sha256': sha256_file(path)}
    return entries


def snapshot_prefix(prefix, destination):
    """Record a prefix as a baseline: its tree listing and a copy of each hive."""
    destination = Path(destination)
    destination.mkdir(parents=True)
    tree = snapshot_tree(prefix)
    (destination / 'files.json').write_text(json.dumps(tree, sort_keys=True, indent=1))
    for hive in HIVES:
        shutil.copyfile(Path(prefix) / hive, destination / hive)
    return len(tree)


def load_baseline(directory):
    directory = Path(directory)
    return {'tree': json.loads((directory / 'files.json').read_text()),
            'hives': {hive: read_hive(directory / hive) for hive in HIVES}}


def classify(rules, value):
    for rule in rules:
        if rule.matches(value):
            return rule
    return None


class Plan:
    """What a capture found, classified: what is kept, what is dropped and why, and what needs a person."""

    def __init__(self):
        self.files, self.dropped, self.problems = {}, {}, []
        self.registry = {hive: {} for hive in HIVES}
        self.dropped_keys = {}
        self.unclassified = {}
        self.rewrites = {'LocalPackage': 0, 'InstallDate': 0}

    def drop(self, table, rule, item):
        table.setdefault(rule.ident, []).append(item)


def build_plan(baseline, prefix):
    """Diff the installed prefix against the baseline and classify every difference."""
    plan = Plan()
    current = snapshot_tree(prefix)
    before = baseline['tree']
    for path in sorted(before):
        if path not in current:
            plan.problems.append('A baseline path was removed by the install: ' + path)
        elif current[path] != before[path]:
            plan.problems.append('A baseline path was changed by the install: ' + path)
    for path in sorted(set(current) - set(before)):
        rule = classify(FILE_RULES, path)
        if rule is None:
            plan.problems.append('Unclassified new path (decide keep or drop in client_layer.py): ' + path)
        elif rule.action == 'forbid':
            plan.problems.append('Forbidden new path (%s): %s' % (rule.ident, path))
        elif rule.action == 'drop':
            plan.drop(plan.dropped, rule, path)
        elif current[path]['kind'] == 'link':
            plan.problems.append('A link cannot be part of a layer: ' + path)
        else:
            plan.files[path] = current[path]
    for hive in HIVES:
        after = read_hive(Path(prefix) / hive)
        old = baseline['hives'][hive]
        rules = KEY_RULES[hive]
        for key in sorted(set(old.keys) | set(after.keys)):
            plain = undouble(key)
            rule = classify(rules, plain)
            if key in old.keys and key in after.keys and old.keys[key]['body'] == after.keys[key]['body']:
                continue
            if rule is None:
                plan.problems.append('Unclassified registry key in %s: %s' % (hive, plain))
                plan.unclassified[hive + ':' + plain] = after.keys[key]['body'] if key in after.keys else []
            elif rule.action != 'keep':
                plan.drop(plan.dropped_keys, rule, hive + ':' + plain)
            elif key in old.keys:
                plan.problems.append('A kept registry key already existed or changed in %s: %s' % (hive, plain))
            elif key not in after.keys:
                plan.problems.append('A kept registry key was removed in %s: %s' % (hive, plain))
            else:
                body = after.keys[key]['body']
                plan.problems += body_problems(plain, body)
                lines, counts = normalized_body(plain, body)
                for name, count in counts.items():
                    plan.rewrites[name] += count
                plan.registry[hive][key] = lines
    if plan.rewrites['LocalPackage'] != 1:
        plan.problems.append('Expected exactly one LocalPackage value, found %d' % plan.rewrites['LocalPackage'])
    return plan


# --- writing a layer ------------------------------------------------------------------------------------

def canonical_json(value):
    return json.dumps(value, sort_keys=True, indent=1, ensure_ascii=False) + '\n'


def file_mode(path):
    return 0o755 if os.stat(path).st_mode & 0o111 else 0o644


def entry_xattrs(path):
    """The allowed extended attributes of a path; an unknown non-macOS attribute is a problem."""
    found, problems = {}, []
    for name in xattr_names(path):
        if name in ALLOWED_XATTRS:
            found[name] = base64.b64encode(xattr_value(path, name)).decode()
        elif not name.startswith('com.apple.'):
            problems.append('Unreviewed extended attribute %s on %s' % (name, path))
    return found, problems


def write_layer(plan, prefix, output, client):
    """Write the layer folder for a clean plan; returns its digest. Refuses an existing output."""
    if plan.problems:
        raise ValueError('The capture has unresolved items:\n  ' + '\n  '.join(plan.problems))
    output = Path(output)
    if output.exists():
        raise FileExistsError(output)
    root = Path(prefix) / 'drive_c'
    entries, problems, total = [], [], 0
    stage = Path(tempfile.mkdtemp(prefix='.layer-', dir=output.parent))
    try:
        (stage / BLOB_DIRECTORY).mkdir()
        (stage / REGISTRY_DIRECTORY).mkdir()
        for path in sorted(plan.files, key=lambda item: item.encode()):
            record, source = plan.files[path], root / path
            attributes, found = entry_xattrs(source)
            problems += found
            if record['kind'] == 'dir':
                entry = {'path': path, 'kind': 'directory', 'mode': 0o755}
            else:
                digest = record['sha256']
                blob = stage / BLOB_DIRECTORY / digest
                if not blob.exists():
                    subprocess.run(['/bin/cp', '-c', str(source), str(blob)], check=True)
                    blob.chmod(0o644)
                    if sha256_file(blob) != digest:
                        raise ValueError('The installed file changed while it was copied: ' + path)
                entry = {'path': path, 'kind': 'file', 'mode': file_mode(source), 'size': record['size'],
                         'sha256': digest}
                total += record['size']
            if attributes:
                entry['xattrs'] = attributes
            entries.append(entry)
        if problems:
            raise ValueError('\n'.join(problems))
        # The cached package exists twice in the install; under its canonical name it is one blob.
        entries = rename_package(entries)
        parts = []
        for hive in HIVES:
            sections = plan.registry[hive]
            if not sections:
                continue
            data = part_text(sections).encode()
            name = '%s/%s.part' % (REGISTRY_DIRECTORY, hive)
            (stage / name).write_bytes(data)
            parts.append({'hive': hive, 'file': name, 'sha256': hashlib.sha256(data).hexdigest(),
                          'keys': len(sections)})
        manifest = {'format': FORMAT, 'client': client, 'entries': entries, 'registry': parts}
        (stage / MANIFEST_NAME).write_text(canonical_json(manifest))
        found = verify_layer(stage)
        if found:
            raise ValueError('The new layer fails its own check:\n  ' + '\n  '.join(found))
        stage.rename(output)
        return sha256_file(output / MANIFEST_NAME)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def rename_package(entries):
    """Windows Installer's cached package takes the one canonical name."""
    renamed = []
    for entry in entries:
        if re.fullmatch(r'windows/Installer/[0-9a-f]{1,8}\.msi', entry['path']):
            entry = {**entry, 'path': CANONICAL_PACKAGE}
        renamed.append(entry)
    return sorted(renamed, key=lambda item: item['path'].encode())


# --- checking a layer -----------------------------------------------------------------------------------

def safe_path(path):
    parts = path.split('/')
    return (isinstance(path, str) and 0 < len(path.encode()) <= 512 and '\\' not in path and '\0' not in path
            and not any(ord(c) < 32 for c in path) and all(part not in {'', '.', '..'} for part in parts))


# The app refuses these on the player's Mac whatever the manifest says (ClientLayerPolicy.swift). A layer
# that passes this check can never be refused there, so the two lists are kept identical and
# Tests/LauncherCoreTests/Fixtures/client-layer-paths.json is run against both.
APP_ROOTS = ('Program Files/Electronic Arts', 'Program Files/Common Files/EAInstaller', 'ProgramData/Package Cache',
             'windows/Installer')
APP_FORBIDDEN_NAMES = {'machine.ini', 'backgroundservice.ini', 'cookies', 'cookies.sqlite', 'local state', 'login data',
                       'web data', 'session.json', 'credentials.json', 'tokens.json', '.env', 'auth.json', 'state.rsm'}
APP_FORBIDDEN_SUFFIXES = ('.log', '.sqlite', '.db', '.tmp', '.bak', '.pem', '.p12', '.pfx', '.reg', '.keychain', '.lnk',
                          '.zip', '.7z', '.rar', '.sha256')
APP_CONFIGURATION = '/legacypm/eacore_app.ini'


def app_policy_problem(path):
    """Why the app would refuse a layer path on the player's Mac, or None."""
    if not safe_path(path):
        return 'unsafe path'
    lowered = path.lower()
    if not any(lowered == root.lower() or lowered.startswith(root.lower() + '/') for root in APP_ROOTS):
        return 'outside the layer roots'
    name = lowered.rsplit('/', 1)[-1]
    if name in APP_FORBIDDEN_NAMES or name.startswith('user_') or name.endswith(APP_FORBIDDEN_SUFFIXES) \
            or (name.endswith('.ini') and not lowered.endswith(APP_CONFIGURATION)):
        return 'account or machine state'
    return None


def verify_layer(layer, expected_digest=None, client=None):
    """Every way a layer folder can be wrong; an empty list means it is exactly what policy allows.

    This is the one check used when a layer is built, by the gate, by the packager before it stages a
    layer, and by the audit of the finished app.
    """
    layer = Path(layer)
    problems = []
    manifest_path = layer / MANIFEST_NAME
    if manifest_path.is_symlink() or not manifest_path.is_file():
        return ['The layer has no manifest']
    if manifest_path.stat().st_size > 8 * 1024 * 1024:
        return ['The layer manifest is too large']
    if expected_digest is not None and sha256_file(manifest_path) != expected_digest:
        return ['The layer manifest does not match its pin']
    try:
        manifest = json.loads(manifest_path.read_text())
    except ValueError as error:
        return ['The layer manifest is not JSON: %s' % error]
    if manifest.get('format') != FORMAT or set(manifest) != {'format', 'client', 'entries', 'registry'}:
        return ['The layer manifest has an unknown shape']
    if client is not None and manifest['client'] != client:
        problems.append('The layer was made from a different client than the recipe pins')
    if manifest_path.read_text() != canonical_json(manifest):
        problems.append('The layer manifest is not in canonical form')
    entries = manifest['entries']
    if not isinstance(entries, list) or not 0 < len(entries) <= MAX_ENTRIES:
        return problems + ['The layer has an invalid number of entries']
    seen, blobs, total = set(), set(), 0
    for entry in entries:
        path = entry.get('path')
        if not safe_path(path):
            problems.append('Unsafe layer path: %r' % (path,))
            continue
        if path.lower() in seen:
            problems.append('Duplicate layer path: ' + path)
        seen.add(path.lower())
        rule = classify(FILE_RULES, path) if path != CANONICAL_PACKAGE else classify(FILE_RULES, 'windows/Installer/0.msi')
        if rule is None or rule.action != 'keep':
            problems.append('The layer holds a path policy does not keep: ' + path)
        if any(pattern.search(path) for pattern in FORBIDDEN_TEXT):
            problems.append('The layer names a user, host or temporary location: ' + path)
        if path == GAME_ROOT or path.startswith(GAME_ROOT + '/'):
            problems.append('The layer writes into the game folder: ' + path)
        refusal = app_policy_problem(path)
        if refusal:
            problems.append('The app would refuse this layer path (%s): %s' % (refusal, path))
        for name in entry.get('xattrs', {}):
            if name not in ALLOWED_XATTRS:
                problems.append('Unreviewed extended attribute %s on %s' % (name, path))
        if entry.get('kind') == 'directory':
            if set(entry) - {'path', 'kind', 'mode', 'xattrs'} or entry.get('mode') != 0o755:
                problems.append('Malformed directory entry: ' + path)
        elif entry.get('kind') == 'file':
            digest, size = entry.get('sha256'), entry.get('size')
            if set(entry) - {'path', 'kind', 'mode', 'size', 'sha256', 'xattrs'} or entry.get('mode') not in {0o644, 0o755} \
                    or not isinstance(size, int) or size < 0 or not re.fullmatch('[0-9a-f]{64}', str(digest)):
                problems.append('Malformed file entry: ' + path)
                continue
            total += size
            blobs.add(digest)
            blob = layer / BLOB_DIRECTORY / digest
            if blob.is_symlink() or not blob.is_file():
                problems.append('Missing blob for ' + path)
            elif blob.stat().st_size != size or sha256_file(blob) != digest:
                problems.append('Blob does not match its digest: ' + path)
        else:
            problems.append('Unknown entry kind: ' + path)
    if total > MAX_BYTES:
        problems.append('The layer is larger than its limit')
    present = {item.name for item in (layer / BLOB_DIRECTORY).iterdir()} if (layer / BLOB_DIRECTORY).is_dir() else set()
    if present != blobs:
        problems.append('The blob folder does not match the manifest: %d extra, %d missing'
                        % (len(present - blobs), len(blobs - present)))
    declared = set()
    for part in manifest['registry']:
        hive, name = part.get('hive'), part.get('file')
        if hive not in HIVES or name != '%s/%s.part' % (REGISTRY_DIRECTORY, hive) or hive in declared:
            problems.append('Malformed registry part: %r' % (part,))
            continue
        declared.add(hive)
        target = layer / name
        if target.is_symlink() or not target.is_file() or target.stat().st_size > MAX_PART_BYTES:
            problems.append('Missing or oversized registry part: ' + name)
            continue
        data = target.read_bytes()
        if hashlib.sha256(data).hexdigest() != part.get('sha256'):
            problems.append('Registry part does not match its digest: ' + name)
        text = data.decode('utf-8', errors='surrogateescape')
        parsed = Hive.parse(text)
        if any(line.strip() for line in parsed.header) or len(parsed.keys) != part.get('keys'):
            problems.append('Registry part is not plain key sections: ' + name)
        if text != part_text({key: section['body'] for key, section in parsed.keys.items()}):
            problems.append('Registry part is not in canonical form: ' + name)
        for key, section in parsed.keys.items():
            plain = undouble(key)
            rule = classify(KEY_RULES[hive], plain)
            if rule is None or rule.action != 'keep':
                problems.append('The layer holds a registry key policy does not keep: %s:%s' % (hive, plain))
            problems += body_problems(plain, section['body'])
        for pattern in FORBIDDEN_TEXT:
            found = pattern.search(text)
            if found:
                problems.append('Registry part %s matches a forbidden pattern %r' % (name, found.group(0)))
    for name in layer.iterdir():
        if name.name not in {MANIFEST_NAME, BLOB_DIRECTORY, REGISTRY_DIRECTORY}:
            problems.append('Unexpected item in the layer: ' + name.name)
    return problems


def load_manifest(layer):
    return json.loads((Path(layer) / MANIFEST_NAME).read_text())


# --- applying a layer (the build-time oracle for the app's own implementation) ------------------------------

def apply_layer(layer, prefix):
    """Apply a verified layer to a stopped prefix, the way the app does at first launch.

    The app's own code is Swift (`ClientLayer.swift`); this is the independent reference the capture
    tool and the gate compare it with. Files are copied with every attribute except the allowed Wine
    ones left behind, and the registry parts are appended to the stopped prefix's hives.
    """
    layer, root = Path(layer), Path(prefix) / 'drive_c'
    problems = verify_layer(layer)
    if problems:
        raise ValueError('The layer is invalid:\n  ' + '\n  '.join(problems))
    manifest = load_manifest(layer)
    for entry in manifest['entries']:
        target = root / entry['path']
        if entry['kind'] == 'directory':
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                raise FileExistsError(target)
            shutil.copyfile(layer / BLOB_DIRECTORY / entry['sha256'], target)
        os.chmod(target, entry['mode'])
        for name, value in entry.get('xattrs', {}).items():
            subprocess.run(['/usr/bin/xattr', '-wx', name, base64.b64decode(value).hex(), str(target)], check=True)
    for part in manifest['registry']:
        hive = Path(prefix) / part['hive']
        text = hive.read_bytes().decode('utf-8', errors='surrogateescape')
        merged = merge_hive(text, (layer / part['file']).read_bytes().decode('utf-8', errors='surrogateescape'))
        hive.write_bytes(merged.encode('utf-8', errors='surrogateescape'))


# --- documentation of the policy ------------------------------------------------------------------------

def describe():
    """The policy as a Markdown table, which docs/NFS2015.md must carry rule by rule."""
    def cell(text):
        return text.replace(GUID, '{GUID}').replace('|', '\\|')

    lines = ['| Rule | Decision | Applies to | Why |', '|---|---|---|---|']
    for rule in FILE_RULES:
        lines.append('| %s | %s | `%s` | %s |' % (rule.ident, rule.action, cell(rule.pattern.pattern), rule.reason))
    for hive, rules in KEY_RULES.items():
        for rule in rules:
            lines.append('| %s | %s | `%s` in %s | %s |' % (rule.ident, rule.action, cell(rule.pattern.pattern), hive,
                                                            rule.reason))
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest='command', required=True)
    verify = commands.add_parser('verify', help='check a layer folder against policy and its own digests')
    verify.add_argument('layer', type=Path)
    verify.add_argument('--digest', help='the expected SHA-256 of client-layer.json')
    commands.add_parser('describe', help='print the policy table')
    options = parser.parse_args()
    if options.command == 'describe':
        print(describe())
        return 0
    problems = verify_layer(options.layer, options.digest)
    for problem in problems:
        print('PROBLEM', problem)
    if not problems:
        print('layer ok:', sha256_file(options.layer / MANIFEST_NAME))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
