"""Shared assembly retains compatibility files in import mode and never changes its input."""
import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory
import json
import subprocess
from assemble import stage_client_layer, stage_game, stage_resources, strip_debug_map
import client_layer
from recipes import load_recipe, shipped_recipe, validate_recipe
from game_data import bundled_entries


with TemporaryDirectory() as temporary:
    root = Path(temporary)
    source = root / 'input'
    source.mkdir()
    (source / 'game.exe').write_bytes(b'original')
    (source / 'mtld3d.conf').write_bytes(b'render.scale = 1\n')
    checksum = hashlib.sha256(b'original').hexdigest()
    recipe = {'gameID': 'fixture', 'originalFiles': ['game.exe'], 'originalDirectories': {},
              'executableHashes': {'game.exe': checksum}, 'supportsSP': True, 'supportsMP': False,
              'compatibility': [{'input': 'defaults', 'source': 'mtld3d.conf', 'path': 'mtld3d.conf'}]}
    manifests = []
    for included in [False, True]:
        resources = root / str(included)
        resources.mkdir()
        manifest = stage_game(resources, recipe, {'game': source, 'defaults': source}, included)
        manifests.append(manifest)
        expected = {item['path'] for item in bundled_entries(manifest)}
        assert {p.name for p in (resources / 'Game').iterdir()} == expected
        assert (resources / 'Game/mtld3d.conf').read_bytes() == b'render.scale = 1\n'
        assert (resources / 'Game/game.exe').exists() == included
    assert manifests[0]['gameFiles'] == manifests[1]['gameFiles']
    assert manifests[0]['version'] == manifests[1]['version']
    assert (source / 'game.exe').read_bytes() == b'original'
    (source / 'linked').symlink_to('/dev/null')
    try: stage_resources([{'input': 'defaults', 'source': 'linked', 'path': 'unsafe'}],
                         {'defaults': source}, root / 'output')
    except ValueError: pass
    else: raise AssertionError('Linked default resource was accepted')
# The recipe an app ships names its inputs but never where they sit on the build Mac, and still
# validates under the same rules the audit applies to it.
for name in ['nfsmw', 'cod4', 'farcry2', 'nfs2015']:
    recipe = load_recipe(name)
    shipped = shipped_recipe(recipe)
    assert set(shipped['inputs']) == set(recipe['inputs']) and validate_recipe(json.loads(json.dumps(shipped)))
    text = json.dumps(shipped)
    for leak in ['/Users', '{home}', '{games}', '{store}', '{tools}', '{project}', 'Mobile Documents',
                 'NFS2015-debug', 'drive_c']:
        assert leak not in text, name + ' ships a build location: ' + leak
    assert recipe['inputs'] != shipped['inputs'], 'The build recipe itself must keep its inputs'
# The pre-installed EA client layer is staged only for a recipe that declares it, by cloning the verified
# input, and the app records exactly what was pinned. A recipe without it stages nothing.
fixture = Path(__file__).resolve().parents[1] / 'Tests/LauncherCoreTests/Fixtures/client-layer'
if fixture.is_dir():
    with TemporaryDirectory() as temporary:
        root = Path(temporary)
        layered = load_recipe('nfs2015')
        layered['clientLayer'].update(
            layerSHA256=client_layer.sha256_file(fixture / client_layer.MANIFEST_NAME),
            client=client_layer.load_manifest(fixture)['client'])
        layered = validate_recipe(layered)
        resources = root / 'Resources'
        resources.mkdir()
        provenance = stage_client_layer(resources, layered, {'clientLayer': fixture})
        assert provenance == {'version': layered['clientLayer']['client']['version'],
                              'layerSHA256': layered['clientLayer']['layerSHA256'],
                              'installerSHA256': layered['clientLayer']['client']['installer']['sha256'],
                              'packageSHA256': layered['clientLayer']['client']['package']['sha256'],
                              'installerSigner': layered['clientLayer']['client']['installer']['signer']}
        assert client_layer.verify_layer(resources / 'ClientLayer', layered['clientLayer']['layerSHA256'],
                                         layered['clientLayer']['client']) == []
        assert (resources / 'Licenses/ea-client.txt').read_text().count('/Users') == 0
        bare = root / 'bare'
        bare.mkdir()
        assert stage_client_layer(bare, load_recipe('nfsmw'), {}) is None and not any(bare.iterdir())
    print('PASS client layer staging: cloned, recorded and noticed; nothing staged without a declaration')
else:
    print('SKIP client layer staging: the fixture is not in this tree yet')
# A binary this project builds names every object file's absolute path on the build Mac in its debug
# map. Stripping it removes those paths and leaves a working program.
with TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / 'hello.c').write_text('#include <stdio.h>\nint main(void) { puts("ready"); return 0; }\n')
    subprocess.run(['/usr/bin/cc', '-g', '-c', str(root / 'hello.c'), '-o', str(root / 'hello.o')], check=True)
    subprocess.run(['/usr/bin/cc', str(root / 'hello.o'), '-o', str(root / 'hello')], check=True)
    before = subprocess.check_output(['/usr/bin/nm', '-a', str(root / 'hello')], text=True)
    assert str(root.resolve()) in before or str(root) in before, 'The fixture binary has no debug map to strip'
    strip_debug_map(root / 'hello')
    after = subprocess.check_output(['/usr/bin/nm', '-a', str(root / 'hello')], text=True)
    assert str(root) not in after and str(root.resolve()) not in after, 'The debug map survived stripping'
    assert subprocess.check_output([str(root / 'hello')], text=True) == 'ready\n'
print('Shared bundled/import assembly regressions passed')
