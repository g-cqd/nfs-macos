"""Shared assembly retains compatibility files in import mode and never changes its input."""
import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory
from assemble import stage_game, stage_resources
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
print('Shared bundled/import assembly regressions passed')
