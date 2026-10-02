"""Shared assembly retains compatibility files in import mode and never changes its input."""
import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory
import json
from assemble import embedded_recipe, stage_game, stage_resources
from recipes import load_recipe, validate_recipe
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
    shipped = embedded_recipe(recipe)
    assert set(shipped['inputs']) == set(recipe['inputs']) and validate_recipe(json.loads(json.dumps(shipped)))
    text = json.dumps(shipped)
    for leak in ['/Users', '{home}', '{games}', '{tools}', '{project}', 'Mobile Documents',
                 'NFS2015-debug', 'drive_c']:
        assert leak not in text, name + ' ships a build location: ' + leak
    assert recipe['inputs'] != shipped['inputs'], 'The build recipe itself must keep its inputs'
print('Shared bundled/import assembly regressions passed')
