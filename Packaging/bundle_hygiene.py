"""Refuse account state, credentials, archives and unlisted files inside a packaged game payload.

A store-client game stays activated by the player's own account, so a bundled edition must carry
the game's files and nothing that belongs to a person or a machine. These checks run twice: on
the source files before anything is staged, and on the finished app by the audit.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import tarfile

import client_layer
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


CLIENT_LAYER_NOTICE = 'Licenses/ea-client.txt'


def client_layer_reference(declared):
    """What the app's game manifest records about its client layer: where it is and which digest it must have."""
    return {'path': declared['path'], 'manifestSHA256': declared['layerSHA256'],
            'version': declared['client']['version']}


def client_layer_provenance(declared):
    """The provenance record for a client layer, which names the installer and package it was made from."""
    client = declared['client']
    return {'version': client['version'], 'layerSHA256': declared['layerSHA256'],
            'installerSHA256': client['installer']['sha256'], 'packageSHA256': client['package']['sha256'],
            'installerSigner': client['installer']['signer']}


def client_layer_notice(declared):
    """The notice the app carries beside the EA client files; the audit compares it word for word."""
    client = declared['client']
    return (client['name'] + ' ' + client['version'] + '\n\n'
            'The folder ' + declared['path'] + ' holds the files and registry entries that EA\'s own installer '
            'creates for the ' + client['name'] + ', captured once at build time from EA\'s official installer '
            'and installed unchanged into this app\'s own Windows folder on first launch. They are EA\'s '
            'software, included for the player\'s personal use on their own Macs. They must not be '
            'redistributed.\n\n'
            'Installer: ' + client['installer']['fileName'] + ' (SHA-256 ' + client['installer']['sha256'] + '), '
            'signed by ' + client['installer']['signer'] + '\n'
            'Package: ' + client['package']['fileName'] + ' (SHA-256 ' + client['package']['sha256'] + ')\n'
            'Layer manifest SHA-256: ' + declared['layerSHA256'] + '\n\n'
            'No EA account, sign-in, session, token, cookie, machine identifier, activation or credential is '
            'included. The player signs in with their own EA account.\n')


def audit_client_layer(app, manifest, recipe):
    """A bundled app carries exactly the pinned EA client layer; any other app carries none of it.

    The layer is held to the same check that made it (`client_layer.verify_layer`) against the digest and
    client facts the recipe pins, and the manifest, provenance and notice must all agree with the recipe.
    """
    app = Path(app)
    resources = app / 'Contents/Resources'
    declared = recipe.get('clientLayer')
    bundled = manifest.get('gameDataIncluded', True) and bool(manifest.get('storeClient'))
    folder = resources / (declared['path'] if declared else 'ClientLayer')
    notice = resources / CLIENT_LAYER_NOTICE
    provenance_path = resources / 'runtime-provenance.json'
    recorded = json.loads(provenance_path.read_text()).get('clientLayer') if provenance_path.is_file() else None
    problems = []
    if declared is None or not bundled:
        if manifest.get('clientLayer') is not None:
            problems.append('The manifest declares a client layer this app is not built to carry')
        if os.path.lexists(folder):
            problems.append('An app without a client layer carries a ' + folder.name + ' folder')
        if os.path.lexists(notice):
            problems.append('An app without a client layer carries its notice')
        if recorded is not None:
            problems.append('The provenance records a client layer this app does not carry')
        return problems
    if manifest.get('clientLayer') != client_layer_reference(declared):
        problems.append('The manifest does not declare the pinned client layer')
    if folder.is_symlink() or not folder.is_dir():
        problems.append('The pinned client layer is missing: ' + declared['path'])
    else:
        problems += ['Client layer: ' + problem
                     for problem in client_layer.verify_layer(folder, declared['layerSHA256'], declared['client'])]
    if notice.is_symlink() or not notice.is_file():
        problems.append('The client layer has no notice')
    elif notice.read_text() != client_layer_notice(declared):
        problems.append('The client layer notice is not the one its pins produce')
    if recorded != client_layer_provenance(declared):
        problems.append('The provenance does not record the pinned client layer')
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


def audit_build_paths(app, home):
    """The files this project writes must not name the Mac that built them.

    Searched as raw bytes, and as UTF-16 for Windows text, in every file of the app except the two
    trees that are not ours: the third-party Wine runtime, whose binaries carry the paths of the
    tree they were compiled in and are pinned by digest instead, and the game payload, which is the
    publisher's. Source archives are opened and searched member by member, because compression
    hides their text from a plain search. The names it reports are the ones to fix or to list.
    """
    app = Path(app)
    needles = [str(home).encode(), str(home).encode('utf-16-le')]
    skipped = [app / 'Contents/SharedSupport/Wine', app / 'Contents/Resources/Game']
    problems = []

    def holds_home(stream):
        tail = b''
        keep = max(len(needle) for needle in needles) - 1
        while block := stream.read(8 * 1024 * 1024):
            data = tail + block
            if any(needle in data for needle in needles):
                return True
            tail = data[-keep:]
        return False

    for path in sorted(app.rglob('*')):
        if path.is_symlink() or not path.is_file() or any(root in path.parents for root in skipped):
            continue
        relative = path.relative_to(app).as_posix()
        if path.name.endswith('.tar.gz'):
            with tarfile.open(path, 'r:gz') as archive:
                for member in archive:
                    if member.isfile() and holds_home(archive.extractfile(member)):
                        problems.append('Build Mac path in ' + relative + ' (' + member.name + ')')
        elif holds_home(path.open('rb')):
            problems.append('Build Mac path in ' + relative)
    return problems
