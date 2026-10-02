"""A bundled store-client edition packages exactly its pinned files and carries no account state.

Every fixture here is synthetic: no real game file, account file or token exists in this tree.
"""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory

from assemble import stage_game
from bundle_hygiene import (audit_app_tree, audit_game_payload, audit_runtime_pins, problems_in)
from payload import inventory, inventory_digest
from recipes import load_recipe, validate_recipe

MACHO = bytes.fromhex('cffaedfe') + b'\0' * 28


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write(root, relative, data):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def game_tree(root):
    """A synthetic installation shaped like the real one, with strings an executable may hold."""
    write(root, 'NFS16.exe', b'MZ synthetic game executable OriginRequestAuthCode')
    write(root, 'NFS16_trial.exe', b'MZ synthetic trial executable')
    write(root, 'Core/Activation64.dll', b'MZ synthetic activation library authCode access_token')
    write(root, 'Core/codecs/codec.dll', b'MZ synthetic codec')
    write(root, 'Data/cas_01.cas', bytes(range(256)) * 8)
    write(root, 'Data/Win32/layout.toc', b'synthetic table of contents')
    write(root, 'Support/mnfst.txt', b'"NFS16.exe"\r\n"Data/cas_01.cas"\r\n')


def synthetic_recipe(root):
    """The real recipe's rules, pinned to the synthetic installation."""
    recipe = deepcopy(load_recipe('nfs2015'))
    recipe['originalFiles'] = ['NFS16.exe', 'NFS16_trial.exe']
    recipe['originalDirectories'] = {'Core': [], 'Data': [], 'Support': []}
    entries = inventory(root, recipe['originalFiles'], recipe['originalDirectories'])
    by_path = {entry['path']: entry['sha256'] for entry in entries}
    recipe['executableHashes'] = {name: by_path[name] for name in
                                  ['NFS16.exe', 'NFS16_trial.exe', 'Core/Activation64.dll']}
    recipe['inventorySHA256'] = inventory_digest(entries)
    return validate_recipe(recipe)


def expect_refused(action, text):
    try:
        action()
    except ValueError as error:
        assert text in str(error), error
    else:
        raise AssertionError('Accepted: ' + text)


# 1. The scanner flags account state, archives and personal markers, and leaves a clean tree alone.
with TemporaryDirectory() as temporary:
    root = Path(temporary)
    game_tree(root)
    names = sorted(path.relative_to(root).as_posix() for path in root.rglob('*') if path.is_file())
    assert problems_in(root, names) == [], 'A clean installation, whose executables mention an auth flow, was flagged'
    hazards = {
        'machine.ini': b'[machine]\nid=1\n',
        'Data/Win32/Machine.INI': b'[machine]\n',
        'Core/settings.xml': b'<a access_token="abc"/>',
        'Core/state.json': b'{"refresh_token": "abc"}',
        'Core/login.txt': b'Set-Cookie: session=1',
        'Core/note.txt': b'saved by /Users/someone/Library',
        'Core/Library.cfg': b'authCode=0123456789abcdef',
        'Support/bundle.dat': b'PK\x03\x04 hidden archive under an innocent name',
        'Support/extra.zip': b'not even an archive',
        'NFS16.dxvk-cache': b'cache',
        'Data/session.log': b'log',
        'Core/AppData/Local/x.bin': b'folder of a user profile',
        'Core/Electronic Arts/EA Desktop/state': b'folder of the store client',
        'Data/PROFILEOPTIONS_profile': b'GstRender.ResolutionWidth 2560',
        'Core/system.reg': b'WINE REGISTRY',
    }
    for relative, data in hazards.items():
        fresh = root / 'hazard'
        shutil.rmtree(fresh, ignore_errors=True)
        game_tree(fresh)
        write(fresh, relative, data)
        assert problems_in(fresh, [relative]), 'Not flagged: ' + relative
    linked = root / 'linked'
    game_tree(linked)
    (linked / 'Core/link.dll').symlink_to(linked / 'NFS16.exe')
    assert problems_in(linked, ['Core/link.dll']), 'A linked file was accepted'
    assert problems_in(linked, ['Core/missing.dll']), 'A missing file was accepted'

# 2. Packaging refuses a game folder that does not match what was verified, in every way it can differ.
with TemporaryDirectory() as temporary:
    base = Path(temporary)
    source = base / 'source'
    game_tree(source)
    recipe = synthetic_recipe(source)
    resources = base / 'resources'
    resources.mkdir()
    manifest = stage_game(resources, recipe, {'game': source}, True)
    assert manifest['gameDataIncluded'] is True and manifest['referencesInstallation'] is False
    assert [entry['path'] for entry in manifest['gameFiles']] == sorted(
        entry['path'] for entry in manifest['gameFiles'])
    assert len(manifest['gameFiles']) == 7
    assert inventory_digest(manifest['gameFiles']) == recipe['inventorySHA256']
    assert manifest['storeClient'] == recipe['storeClient']
    assert manifest['renderers'] == recipe['renderers']
    assert manifest['controllerDevices'] == recipe['controllerDevices']
    assert manifest['runtimeTuning'] == recipe['runtimeTuning']
    # The bundled app also records the registration the game's installer writes; the import app never does.
    assert manifest['prefixSettings'] == recipe['prefixSettings'] + recipe['bundledPrefixSettings']
    assert {item['name'] for item in manifest['prefixSettings']} >= {'RetinaMode', 'Install Dir'}
    (base / 'imported').mkdir()
    imported = stage_game(base / 'imported', recipe, {}, False)
    assert imported['referencesInstallation'] is True and imported['gameFiles'] == []
    assert imported['prefixSettings'] == recipe['prefixSettings']
    assert imported['version'] != manifest['version']
    for entry in manifest['gameFiles']:
        assert (resources / 'Game' / entry['path']).read_bytes() == (source / entry['path']).read_bytes()
    assert not any(path.name == 'NFS16.dxvk-cache' for path in resources.rglob('*'))

    def stage(mutator, expected):
        copy = base / ('case-' + str(len(list(base.iterdir()))))
        shutil.copytree(source, copy)
        mutator(copy)
        target = base / ('out-' + copy.name)
        target.mkdir()
        expect_refused(lambda: stage_game(target, recipe, {'game': copy}, True), expected)
        assert not any((target / 'Game').rglob('*')), 'Files were staged before the refusal'

    stage(lambda c: write(c, 'NFS16.exe', b'MZ patched executable'), 'Pinned artifact checksum mismatch')
    stage(lambda c: write(c, 'Core/Activation64.dll', b'MZ replaced library'), 'Pinned artifact checksum mismatch')
    stage(lambda c: (c / 'NFS16_trial.exe').unlink(), 'Missing or linked pinned artifact')
    stage(lambda c: write(c, 'Data/cas_01.cas', b'changed game data'), 'do not match the pinned payload inventory')
    stage(lambda c: write(c, 'Data/extra.cas', b'an unlisted data file'), 'do not match the pinned payload inventory')
    stage(lambda c: write(c, 'Core/codecs/codec.dll', b'MZ replaced codec'), 'do not match the pinned payload inventory')
    stage(lambda c: (c / 'Data/Win32/layout.toc').unlink(), 'do not match the pinned payload inventory')
    # Account state must be refused even when someone also re-pins the inventory around it.
    hostile = base / 'hostile'
    shutil.copytree(source, hostile)
    write(hostile, 'Core/machine.ini', b'[machine]\nid=1\n')
    hostile_recipe = deepcopy(recipe)
    hostile_recipe['inventorySHA256'] = inventory_digest(
        inventory(hostile, recipe['originalFiles'], recipe['originalDirectories']))
    target = base / 'out-hostile'
    target.mkdir()
    expect_refused(lambda: stage_game(target, hostile_recipe, {'game': hostile}, True),
                   'carry account state or an archive')
    assert not any((target / 'Game').rglob('*'))
    assert (source / 'NFS16.exe').read_bytes().startswith(b'MZ synthetic'), 'The source was modified'

# 3. The finished app is audited against the same pins.
with TemporaryDirectory() as temporary:
    base = Path(temporary)
    source = base / 'source'
    game_tree(source)
    recipe = synthetic_recipe(source)

    def make_app(name):
        app = base / (name + '.app')
        resources = app / 'Contents/Resources'
        resources.mkdir(parents=True)
        manifest = stage_game(resources, recipe, {'game': source}, True)
        return app, manifest

    app, manifest = make_app('clean')
    assert audit_game_payload(app, manifest, recipe) == []
    assert audit_app_tree(app) == []

    def audited(name, mutator):
        copy, copy_manifest = make_app(name)
        mutator(copy)
        return audit_game_payload(copy, copy_manifest, recipe)

    assert any('outside the pinned game list' in p for p in audited(
        'extra', lambda a: write(a, 'Contents/Resources/Game/Data/more.cas', b'unlisted')))
    assert any('outside the pinned game list' in p for p in audited(
        'ini', lambda a: write(a, 'Contents/Resources/Game/machine.ini', b'[machine]')))
    assert any('missing' in p for p in audited(
        'gone', lambda a: (a / 'Contents/Resources/Game/Data/cas_01.cas').unlink()))
    assert any('Pinned executable digest mismatch: NFS16.exe' in p for p in audited(
        'patched', lambda a: write(a, 'Contents/Resources/Game/NFS16.exe', b'MZ patched')))
    assert any('Credential or personal marker' in p for p in audited(
        'token', lambda a: write(a, 'Contents/Resources/Game/Support/mnfst.txt', b'"access_token":"x"')))
    assert any('Archive' in p for p in audited(
        'archive', lambda a: write(a, 'Contents/Resources/Game/Data/cas_01.cas', b'PK\x03\x04' + b'\0' * 64)))
    pinned_wrong = deepcopy(recipe)
    pinned_wrong['inventorySHA256'] = '0' * 64
    assert any('pinned digest' in p for p in audit_game_payload(app, manifest, pinned_wrong))
    write(app, 'Contents/Resources/Sources/bundle.zip', b'zip')
    assert len(audit_app_tree(app)) == 1 and 'Archive or checksum file' in audit_app_tree(app)[0]
    write(app, 'Contents/Resources/Sources/x.sha256', b'abc')
    assert len(audit_app_tree(app)) == 2

# 4. The staged runtime must be the pinned one.
with TemporaryDirectory() as temporary:
    base = Path(temporary)
    recipe = deepcopy(load_recipe('nfs2015'))
    pe = b'MZ' + b'\0' * 62
    unix = MACHO + b'wine'
    profile_files = {'bin/wine': sha(unix), 'lib/wine/i386-windows/ntdll.dll': sha(pe)}
    pins = {'sidecarSHA256': 'ab' * 32,
            'runtimeProfiles': {recipe['runtimeProfile']: {'files': profile_files}}}

    def runtime_app(name, provenance=None, wine=unix, dll=pe, recorded=None):
        app = base / (name + '.app')
        write(app, 'Contents/SharedSupport/Wine/bin/wine', wine)
        write(app, 'Contents/SharedSupport/Wine/lib/wine/i386-windows/ntdll.dll', dll)
        (app / 'Contents/Resources').mkdir(parents=True, exist_ok=True)
        (app / 'Contents/Resources/runtime-provenance.json').write_text(json.dumps(provenance or {
            'runtimeProfile': recipe['runtimeProfile'], 'inputRuntimeHashes': profile_files,
            'inputSidecarSHA256': pins['sidecarSHA256']}))
        (app / 'Contents/Resources/runtime-files.json').write_text(json.dumps(
            recorded if recorded is not None else {'Contents/SharedSupport/Wine/bin/wine': sha(wine)}))
        return app

    source = base / 'runtime'
    write(source, 'bin/wine', unix)
    write(source, 'lib/wine/i386-windows/ntdll.dll', pe)
    assert audit_runtime_pins(runtime_app('ok'), pins, recipe, source) == []
    assert audit_runtime_pins(runtime_app('ok2'), pins, recipe) == []
    assert any('different runtime profile' in p for p in audit_runtime_pins(
        runtime_app('profile', {'runtimeProfile': 'other', 'inputRuntimeHashes': profile_files,
                                'inputSidecarSHA256': pins['sidecarSHA256']}), pins, recipe))
    assert any('not the pinned runtime' in p for p in audit_runtime_pins(
        runtime_app('inputs', {'runtimeProfile': recipe['runtimeProfile'],
                               'inputRuntimeHashes': {**profile_files, 'bin/wine': '0' * 64},
                               'inputSidecarSHA256': pins['sidecarSHA256']}), pins, recipe))
    assert any('x87 sidecar' in p for p in audit_runtime_pins(
        runtime_app('sidecar', {'runtimeProfile': recipe['runtimeProfile'],
                                'inputRuntimeHashes': profile_files,
                                'inputSidecarSHA256': '0' * 64}), pins, recipe))
    assert any('signed record' in p for p in audit_runtime_pins(
        runtime_app('tampered', wine=MACHO + b'evil', recorded={
            'Contents/SharedSupport/Wine/bin/wine': sha(unix)}), pins, recipe))
    assert any('differs from its pinned input' in p for p in audit_runtime_pins(
        runtime_app('pe', dll=b'MZ' + b'\1' * 62), pins, recipe, source))
    shutil.rmtree(base / 'ok.app/Contents/SharedSupport/Wine/bin')
    assert any('missing' in p for p in audit_runtime_pins(base / 'ok.app', pins, recipe))

print('Bundle hygiene and pinned payload regressions passed')
