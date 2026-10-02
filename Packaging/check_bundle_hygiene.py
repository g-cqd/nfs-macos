"""A bundled store-client edition packages exactly its pinned files and carries no account state.

Every fixture here is synthetic: no real game file, account file or token exists in this tree.
"""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory

from assemble import stage_client_layer, stage_game, stage_managed_runtime
import tarfile
from bundle_hygiene import (audit_app_tree, audit_build_paths, audit_client_layer, audit_game_payload,
                            audit_managed_runtime, audit_runtime_pins, client_layer_notice, client_layer_provenance,
                            client_layer_reference, problems_in)
import client_layer
from payload import inventory, inventory_digest
from recipes import load_recipe, validate_recipe

MACHO = bytes.fromhex('cffaedfe') + b'\0' * 28
PROJECT = Path(__file__).resolve().parents[1]
LAYER_FIXTURE = PROJECT / 'Tests/LauncherCoreTests/Fixtures/client-layer'


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


def tree_equal(left, right):
    """Whether two folders hold the same relative paths with the same bytes."""
    names = lambda root: {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob('*') if p.is_file()}
    return names(left) == names(right)


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

# 5. The managed runtime installer is pinned, staged unchanged, and nothing else rides beside it.
with TemporaryDirectory() as temporary:
    base = Path(temporary)
    source = base / 'source'
    game_tree(source)
    addons = base / 'addons'
    write(addons, 'mono.msi', b'synthetic windows installer package')
    recipe = synthetic_recipe(source)
    recipe['inputs']['wineMono'] = str(addons)
    recipe['managedRuntime'] = {
        'input': 'wineMono', 'source': 'mono.msi', 'path': 'Addons/mono.msi', 'version': '10.4.1',
        'sha256': sha(b'synthetic windows installer package'),
        'url': 'https://example.invalid/mono.msi', 'sourceURL': 'https://example.invalid/mono.tar.xz'}
    recipe = validate_recipe(recipe)
    inputs = {'game': source, 'wineMono': addons}

    def make_app(name, include_game=True):
        app = base / (name + '.app')
        resources = app / 'Contents/Resources'
        resources.mkdir(parents=True)
        manifest = stage_game(resources, recipe, inputs, include_game)
        if include_game:
            stage_managed_runtime(resources, recipe, inputs)
        return app, manifest

    app, manifest = make_app('managed')
    assert manifest['managedRuntime'] == {'file': 'Addons/mono.msi', 'version': '10.4.1',
                                          'sha256': sha(b'synthetic windows installer package')}
    assert audit_managed_runtime(app, manifest, recipe) == []
    assert (app / 'Contents/Resources/Licenses/wine-mono.txt').is_file()

    def managed_problems(name, mutator, edit=None):
        copy, copy_manifest = make_app(name)
        mutator(copy)
        if edit:
            edit(copy_manifest)
        return audit_managed_runtime(copy, copy_manifest, recipe)

    assert any('differs from its pin' in p for p in managed_problems(
        'altered', lambda a: write(a, 'Contents/Resources/Addons/mono.msi', b'evil installer')))
    assert any('missing' in p for p in managed_problems(
        'gone', lambda a: (a / 'Contents/Resources/Addons/mono.msi').unlink()))
    assert any('Unexpected file beside' in p for p in managed_problems(
        'extra', lambda a: write(a, 'Contents/Resources/Addons/payload.exe', b'MZ')))
    assert any('missing' in p for p in managed_problems(
        'linked', lambda a: ((a / 'Contents/Resources/Addons/mono.msi').unlink(),
                             (a / 'Contents/Resources/Addons/mono.msi').symlink_to(addons / 'mono.msi'))))
    assert any('does not declare the pinned' in p for p in managed_problems(
        'manifest', lambda a: None, lambda m: m.update(managedRuntime={'file': 'Addons/mono.msi',
                                                                       'sha256': '0' * 64, 'version': '10.4.1'})))
    assert any('does not declare the pinned' in p for p in managed_problems(
        'undeclared', lambda a: None, lambda m: m.pop('managedRuntime')))
    assert any('no notice' in p for p in managed_problems(
        'notice', lambda a: (a / 'Contents/Resources/Licenses/wine-mono.txt').unlink()))
    # An app that is not the bundled edition carries none, and says so.
    plain, plain_manifest = make_app('import', include_game=False)
    assert audit_managed_runtime(plain, plain_manifest, recipe) == []
    write(plain, 'Contents/Resources/Addons/mono.msi', b'x')
    assert any('Addons folder' in p for p in audit_managed_runtime(plain, plain_manifest, recipe))
    # The staging refuses a changed or linked installer before copying anything.
    write(addons, 'mono.msi', b'a different installer')
    expect_refused(lambda: stage_managed_runtime(base / 'refused', recipe, inputs), 'does not match its pin')
    assert not (base / 'refused').exists()

# 5b. The pre-installed EA client layer is pinned, staged unchanged, and nothing else rides beside it.
with TemporaryDirectory() as temporary:
    base = Path(temporary)
    source = base / 'source'
    game_tree(source)
    # A small synthetic layer: the checked-in fixture when it exists, else one captured from a synthetic install.
    layer_source = base / 'layer'
    if LAYER_FIXTURE.is_dir():
        shutil.copytree(LAYER_FIXTURE, layer_source)
    else:
        import check_client_layer
        layer_source = check_client_layer.capture(base, 'layer')[1]
    layer_manifest = client_layer.load_manifest(layer_source)
    recipe = synthetic_recipe(source)
    recipe['clientLayer'] = {'input': 'clientLayer', 'path': 'ClientLayer', 'client': layer_manifest['client'],
                             'layerSHA256': client_layer.sha256_file(layer_source / client_layer.MANIFEST_NAME)}
    recipe = validate_recipe(recipe)
    declared = recipe['clientLayer']
    inputs = {'game': source, 'clientLayer': layer_source}
    assert client_layer.verify_layer(layer_source, declared['layerSHA256'], declared['client']) == []

    def make_app(name, include_game=True, with_recipe=recipe):
        app = base / (name + '.app')
        resources = app / 'Contents/Resources'
        resources.mkdir(parents=True)
        manifest = stage_game(resources, with_recipe, inputs, include_game)
        provenance = {}
        if include_game:
            provenance['clientLayer'] = stage_client_layer(resources, with_recipe, inputs)
        (resources / 'runtime-provenance.json').write_text(json.dumps(
            {key: value for key, value in provenance.items() if value}))
        return app, manifest

    app, manifest = make_app('layered')
    assert manifest['clientLayer'] == {'path': 'ClientLayer', 'manifestSHA256': declared['layerSHA256'],
                                       'version': declared['client']['version']} == client_layer_reference(declared)
    plain = {key: value for key, value in recipe.items() if key != 'clientLayer'}
    with TemporaryDirectory() as other:
        assert 'clientLayer' not in stage_game(Path(other), plain, {'game': source}, True)
    with TemporaryDirectory() as other:
        assert stage_game(Path(other), plain, {'game': source}, True)['version'] != manifest['version'], \
            'The version must change when the app carries a client layer'
    with TemporaryDirectory() as other:
        assert 'clientLayer' not in stage_game(Path(other), recipe, {}, False), 'An import app never carries the client'
    resources = app / 'Contents/Resources'
    assert audit_client_layer(app, manifest, recipe) == []
    assert (resources / 'Licenses/ea-client.txt').read_text() == client_layer_notice(declared)
    notice = (resources / 'Licenses/ea-client.txt').read_text()
    for needle in [declared['client']['installer']['sha256'], declared['client']['package']['sha256'],
                   declared['client']['installer']['signer'], 'not be redistributed', 'No EA account']:
        assert needle in notice, 'The notice does not say: ' + needle
    assert json.loads((resources / 'runtime-provenance.json').read_text())['clientLayer'] == \
        client_layer_provenance(declared)
    assert tree_equal(layer_source, resources / 'ClientLayer'), 'The layer in the app is not the verified input'
    assert audit_app_tree(app) == [], 'The layer holds a name the app tree gate refuses'
    assert audit_build_paths(app, '/Users/builder') == [], 'The layer names a build Mac'

    def layer_problems(name, mutator, edit=None, pinned=recipe):
        copy, copy_manifest = make_app(name)
        mutator(copy)
        if edit:
            edit(copy_manifest)
        return audit_client_layer(copy, copy_manifest, pinned)

    def entry_file(app_path):
        return next(path for path in (app_path / 'Contents/Resources/ClientLayer/blobs').iterdir())

    # (1) a layer the app declares is missing, (2) one byte of a blob changed, (3) something rides beside it
    assert any('missing' in p for p in layer_problems(
        'gone', lambda a: shutil.rmtree(a / 'Contents/Resources/ClientLayer')))
    assert any('missing' in p for p in layer_problems(
        'linked', lambda a: (shutil.rmtree(a / 'Contents/Resources/ClientLayer'),
                             (a / 'Contents/Resources/ClientLayer').symlink_to(layer_source))))

    def flip(a):
        blob = entry_file(a)
        data = bytearray(blob.read_bytes())
        data[0] ^= 1
        blob.write_bytes(bytes(data))

    assert any('Blob does not match' in p for p in layer_problems('flipped', flip))
    assert any('Unexpected item' in p for p in layer_problems(
        'beside', lambda a: write(a, 'Contents/Resources/ClientLayer/EADesktop.exe', b'MZ')))
    assert any('blob folder does not match' in p for p in layer_problems(
        'inside', lambda a: write(a, 'Contents/Resources/ClientLayer/blobs/' + 'c' * 64, b'MZ')))
    assert any('Unexpected item' in p for p in layer_problems(
        'state-file', lambda a: write(a, 'Contents/Resources/ClientLayer/machine.ini', b'[machine]')))

    # (4) a state file listed in the layer's manifest: refused by the pin, and by policy even when re-pinned.
    def add_state(a):
        folder = a / 'Contents/Resources/ClientLayer'
        listing = client_layer.load_manifest(folder)
        blob = entry_file(a).name
        listing['entries'].append({'path': 'ProgramData/EA Desktop/machine.ini', 'kind': 'file', 'mode': 0o644,
                                   'size': (folder / 'blobs' / blob).stat().st_size, 'sha256': blob})
        listing['entries'].sort(key=lambda entry: entry['path'].encode())
        (folder / client_layer.MANIFEST_NAME).write_text(client_layer.canonical_json(listing))

    assert any('does not match its pin' in p for p in layer_problems('state', add_state))
    repinned = deepcopy(recipe)
    state_app, state_manifest = make_app('state-repinned')
    add_state(state_app)
    repinned['clientLayer']['layerSHA256'] = client_layer.sha256_file(
        state_app / 'Contents/Resources/ClientLayer' / client_layer.MANIFEST_NAME)
    state_manifest['clientLayer'] = client_layer_reference(repinned['clientLayer'])
    (state_app / 'Contents/Resources/runtime-provenance.json').write_text(json.dumps(
        {'clientLayer': client_layer_provenance(repinned['clientLayer'])}))
    (state_app / 'Contents/Resources/Licenses/ea-client.txt').write_text(client_layer_notice(repinned['clientLayer']))
    assert any('policy does not keep' in p and 'machine.ini' in p
               for p in audit_client_layer(state_app, state_manifest, repinned)), 'A re-pinned state file passed'

    # (5) a pin that differs from the recipe: the digest, the client facts, and the manifest's own reference
    wrong = deepcopy(recipe)
    wrong['clientLayer']['layerSHA256'] = '0' * 64
    assert any('does not match its pin' in p for p in audit_client_layer(app, manifest, wrong))
    wrong = deepcopy(recipe)
    wrong['clientLayer']['client']['package']['sha256'] = '0' * 64
    assert any('different client' in p for p in audit_client_layer(app, manifest, wrong))
    assert any('does not declare the pinned' in p for p in layer_problems(
        'reference', lambda a: None, lambda m: m['clientLayer'].update(manifestSHA256='0' * 64)))
    assert any('does not declare the pinned' in p for p in layer_problems(
        'undeclared', lambda a: None, lambda m: m.pop('clientLayer')))

    # (6) a layer folder in an app whose recipe has none, or in an app that is not the bundled edition
    for name, mutator in [('folder', lambda a: shutil.copytree(layer_source, a / 'Contents/Resources/ClientLayer')),
                          ('notice', lambda a: write(a, 'Contents/Resources/Licenses/ea-client.txt', b'EA')),
                          ('provenance', lambda a: (a / 'Contents/Resources/runtime-provenance.json').write_text(
                              json.dumps({'clientLayer': client_layer_provenance(declared)})))]:
        bare, bare_manifest = make_app('bare-' + name, with_recipe=plain)
        assert 'clientLayer' not in bare_manifest and audit_client_layer(bare, bare_manifest, plain) == []
        mutator(bare)
        assert audit_client_layer(bare, bare_manifest, plain), 'Not flagged in an app without the recipe key: ' + name
    imported, imported_manifest = make_app('imported', include_game=False)
    assert audit_client_layer(imported, imported_manifest, recipe) == []
    shutil.copytree(layer_source, imported / 'Contents/Resources/ClientLayer')
    assert any('without a client layer carries' in p for p in audit_client_layer(imported, imported_manifest, recipe))
    smuggled, smuggled_manifest = make_app('smuggled', include_game=False)
    smuggled_manifest['clientLayer'] = client_layer_reference(declared)
    assert any('not built to carry' in p for p in audit_client_layer(smuggled, smuggled_manifest, recipe))

    # (7) the notice and the provenance record are part of the contract
    assert any('no notice' in p for p in layer_problems(
        'no-notice', lambda a: (a / 'Contents/Resources/Licenses/ea-client.txt').unlink()))
    assert any('notice is not' in p for p in layer_problems(
        'edited-notice', lambda a: write(a, 'Contents/Resources/Licenses/ea-client.txt', b'EA client')))
    assert any('provenance does not record' in p for p in layer_problems(
        'no-provenance', lambda a: (a / 'Contents/Resources/runtime-provenance.json').write_text('{}')))
    assert any('provenance does not record' in p for p in layer_problems(
        'wrong-provenance', lambda a: (a / 'Contents/Resources/runtime-provenance.json').write_text(json.dumps(
            {'clientLayer': {**client_layer_provenance(declared), 'installerSigner': 'Someone Else'}}))))

    # Staging refuses a layer that is not the pinned one before it copies anything.
    stale = base / 'stale-layer'
    shutil.copytree(layer_source, stale)
    blob = next((stale / 'blobs').iterdir())
    blob.write_bytes(blob.read_bytes() + b'!')
    refused = base / 'refused'
    refused.mkdir()
    expect_refused(lambda: stage_client_layer(refused, recipe, {'clientLayer': stale}), 'does not match its pin or its policy')
    assert not any(refused.iterdir()), 'Something was staged before the refusal'
    (stale / client_layer.MANIFEST_NAME).write_text('{}')
    expect_refused(lambda: stage_client_layer(refused, recipe, {'clientLayer': stale}), 'does not match its pin or its policy')
    assert stage_client_layer(refused, plain, inputs) is None and not any(refused.iterdir())

# 6. The files this project writes must not name the Mac that built them.
with TemporaryDirectory() as temporary:
    base = Path(temporary)
    home = '/Users/builder'
    app = base / 'portable.app'
    write(app, 'Contents/Info.plist', b'<plist>clean</plist>')
    write(app, 'Contents/Resources/Game/NFS16.exe', home.encode())  # the publisher's payload, pinned by digest
    write(app, 'Contents/SharedSupport/Wine/bin/wine', home.encode() + b'/src/wine.c')  # third-party build paths
    assert audit_build_paths(app, home) == []
    write(app, 'Contents/Resources/runtime-provenance.json', b'{"path": "' + home.encode() + b'/Games"}')
    assert audit_build_paths(app, home) == ['Build Mac path in Contents/Resources/runtime-provenance.json']
    (app / 'Contents/Resources/runtime-provenance.json').unlink()
    write(app, 'Contents/MacOS/Starter', (home + '/macos-app/Sources/Starter.swift').encode('utf-16-le'))
    assert audit_build_paths(app, home) == ['Build Mac path in Contents/MacOS/Starter']
    (app / 'Contents/MacOS/Starter').unlink()
    inner = base / 'note.txt'
    inner.write_text('built in ' + home + '/Games')
    (app / 'Contents/Resources/Sources').mkdir(parents=True)
    with tarfile.open(app / 'Contents/Resources/Sources/source.tar.gz', 'w:gz') as archive:
        archive.add(inner, arcname='docs/note.txt')
    assert audit_build_paths(app, home) == [
        'Build Mac path in Contents/Resources/Sources/source.tar.gz (docs/note.txt)']

print('Bundle hygiene and pinned payload regressions passed')
