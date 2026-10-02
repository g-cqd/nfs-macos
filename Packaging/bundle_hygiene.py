"""Refuse account state, credentials, archives and unlisted files inside a packaged game payload.

A store-client game stays activated by the player's own account, so a bundled edition must carry
the game's files and nothing that belongs to a person or a machine. These checks run twice: on
the source files before anything is staged, and on the finished app by the audit.
"""
import hashlib
import json
from pathlib import Path, PurePosixPath

from optimize_runtime import pe_runtime_signature
from payload import inventory_digest

# Names that only ever hold session, account or machine state, wherever they sit.
FORBIDDEN_NAMES = {'machine.ini', 'user.reg', 'system.reg', 'userdef.reg', 'cookies', 'cookies.sqlite',
                   'local state', 'login data', 'web data', 'session.json', 'credentials.json',
                   'tokens.json', '.env', 'auth.json'}
# Generated, personal or container files; the game list is explicit, so none of these is legitimate.
FORBIDDEN_SUFFIXES = {'.zip', '.7z', '.rar', '.sha256', '.log', '.dxvk-cache', '.sqlite', '.db',
                      '.reg', '.tmp', '.bak', '.pem', '.p12', '.pfx', '.keychain'}
# Folders a store client or a user profile creates; a game payload has none of them.
FORBIDDEN_DIRECTORIES = {'electronic arts', 'ea desktop', 'origin', 'appdata', 'programdata', 'users',
                         'documents', 'saves', 'savegames', 'logs', 'cache', 'crashdumps'}
# Archive signatures, checked on the first bytes so a renamed archive is still found.
ARCHIVE_MAGIC = (b'PK\x03\x04', b'PK\x05\x06', b'7z\xbc\xaf\x27\x1c', b'Rar!\x1a\x07')
# Machine-readable credential markers. Executables legitimately mention an auth flow in their
# strings, so only non-executable files up to SCAN_LIMIT bytes are searched for these.
CREDENTIAL_MARKERS = (b'access_token', b'refresh_token', b'id_token', b'authcode=', b'"authcode"',
                      b'auth_code', b'set-cookie', b'bearer ', b'x-origin-', b'x-ea-', b'sid=',
                      b'machine_hash', b'machinehash')
HOME_MARKERS = (b'/users/', b'c:\\users\\')
SCAN_LIMIT = 4 * 1024 * 1024
EXECUTABLE_MAGIC = (b'MZ', b'\x7fELF', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe')


def problems_in(root, relative_paths):
    """Return one message for each credential, archive or personal-state hazard in the listed files."""
    problems = []
    root = Path(root)
    for relative in relative_paths:
        pure = PurePosixPath(relative)
        name = pure.name.casefold()
        if name in FORBIDDEN_NAMES or pure.suffix.casefold() in FORBIDDEN_SUFFIXES \
                or name.startswith(('machine.ini', 'profileoptions')):
            problems.append('Forbidden file: ' + relative)
        for part in pure.parts[:-1]:
            if part.casefold() in FORBIDDEN_DIRECTORIES:
                problems.append('Forbidden folder ' + part + ' in ' + relative)
        path = root / relative
        if not path.is_file() or path.is_symlink():
            problems.append('Missing or linked file: ' + relative)
            continue
        with path.open('rb') as stream:
            head = stream.read(SCAN_LIMIT + 1)
        if head.startswith(ARCHIVE_MAGIC):
            problems.append('Archive inside the payload: ' + relative)
        if len(head) > SCAN_LIMIT or head.startswith(EXECUTABLE_MAGIC):
            continue
        lowered = head.lower()
        for marker in CREDENTIAL_MARKERS + HOME_MARKERS:
            if marker in lowered:
                problems.append('Credential or personal marker ' + repr(marker.decode()) + ' in ' + relative)
    return problems


def audit_game_payload(app, manifest, recipe):
    """Check the finished app's game folder against the recipe's pins; returns the list of problems."""
    game = Path(app) / 'Contents/Resources/Game'
    entries = manifest['gameFiles']
    listed = {entry['path'] for entry in entries}
    present = {path.relative_to(game).as_posix() for path in game.rglob('*') if path.is_file()}
    problems = []
    for name in sorted(present - listed):
        problems.append('File outside the pinned game list: ' + name)
    for name in sorted(listed - present):
        problems.append('Pinned game file is missing: ' + name)
    problems += problems_in(game, sorted(present))
    for path, expected in recipe.get('executableHashes', {}).items():
        target = game / path
        if not target.is_file():
            problems.append('Pinned executable is missing: ' + path)
            continue
        with target.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != expected:
                problems.append('Pinned executable digest mismatch: ' + path)
    pin = recipe.get('inventorySHA256')
    if pin is not None and inventory_digest(entries) != pin:
        problems.append('The payload inventory does not match its pinned digest')
    return problems


def audit_app_tree(app):
    """Hazards that apply to every file of every app, game payload or not."""
    problems = []
    for path in Path(app).rglob('*'):
        if path.is_file() and not path.is_symlink() and path.suffix.casefold() in {'.zip', '.7z', '.rar', '.sha256'}:
            problems.append('Archive or checksum file inside the app: ' + path.relative_to(app).as_posix())
    return problems


def audit_managed_runtime(app, manifest, recipe):
    """A bundled app carries exactly the pinned managed runtime installer; any other app carries none.

    The app installs this file into its own Windows folder and runs it, so it is held to its pin
    here as well as at run time, and nothing else may sit beside it.
    """
    app = Path(app)
    resources = app / 'Contents/Resources'
    declared = recipe.get('managedRuntime')
    bundled = manifest.get('gameDataIncluded', True) and bool(manifest.get('storeClient'))
    problems = []
    if declared is None or not bundled:
        if manifest.get('managedRuntime') is not None:
            problems.append('The manifest declares a managed runtime this app is not built to install')
        if (resources / 'Addons').exists():
            problems.append('An app without a managed runtime carries an Addons folder')
        return problems
    expected = {'file': declared['path'], 'sha256': declared['sha256'], 'version': declared['version']}
    if manifest.get('managedRuntime') != expected:
        problems.append('The manifest does not declare the pinned managed runtime')
    target = resources / declared['path']
    if target.is_symlink() or not target.is_file():
        problems.append('The pinned managed runtime installer is missing: ' + declared['path'])
    elif hashlib.sha256(target.read_bytes()).hexdigest() != declared['sha256']:
        problems.append('The managed runtime installer differs from its pin')
    folder = target.parent
    if folder.is_dir():
        for path in sorted(folder.rglob('*')):
            if path != target:
                problems.append('Unexpected file beside the managed runtime: ' + path.relative_to(app).as_posix())
    if not (resources / 'Licenses/wine-mono.txt').is_file():
        problems.append('The managed runtime has no notice')
    return problems


def same_runtime_image(staged, pinned):
    """Whether two Windows modules hold the same runtime bytes; a file that is no module never matches."""
    try:
        return pe_runtime_signature(staged) == pe_runtime_signature(pinned)
    except ValueError:
        return False


def audit_runtime_pins(app, pins, recipe, runtime=None):
    """The staged runtime must be the pinned one.

    Three facts are checked. The app records the pinned inputs it was built from. The input runtime,
    when the caller names it, still has the pinned digests. And every staged file is that input:
    a Windows module must keep the same runtime bytes (release stripping only removes debug
    sections), and a Mach-O file, which signing rewrites, must equal the digest the signing step
    recorded for the finished app.
    """
    app = Path(app)
    profile = pins['runtimeProfiles'][recipe['runtimeProfile']]
    provenance = json.loads((app / 'Contents/Resources/runtime-provenance.json').read_text())
    recorded = json.loads((app / 'Contents/Resources/runtime-files.json').read_text())
    problems = []
    if provenance.get('runtimeProfile') != recipe['runtimeProfile']:
        problems.append('The app was built from a different runtime profile')
    if provenance.get('inputRuntimeHashes') != profile['files']:
        problems.append('The recorded runtime inputs are not the pinned runtime')
    if provenance.get('inputSidecarSHA256') != pins['sidecarSHA256']:
        problems.append('The recorded x87 sidecar is not the pinned one')
    macho = {bytes.fromhex(h) for h in ['cffaedfe', 'cefaedfe', 'cafebabe', 'bebafeca']}
    for relative, expected in profile['files'].items():
        path = app / 'Contents/SharedSupport/Wine' / relative
        if not path.is_file():
            problems.append('Pinned runtime file is missing: ' + relative)
            continue
        data = path.read_bytes()
        if data[:4] in macho:
            if recorded.get('Contents/SharedSupport/Wine/' + relative) != hashlib.sha256(data).hexdigest():
                problems.append('Runtime file differs from its signed record: ' + relative)
            continue
        if runtime is None:
            continue
        source = Path(runtime) / relative
        if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            problems.append('The input runtime no longer matches its pin: ' + relative)
        elif data != source.read_bytes() and not same_runtime_image(data, source.read_bytes()):
            problems.append('Runtime file differs from its pinned input: ' + relative)
    return problems
