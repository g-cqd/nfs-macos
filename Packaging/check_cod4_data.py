"""CoD4 payload selection excludes player state and keeps the import inventory."""
from pathlib import Path
from tempfile import TemporaryDirectory
from cod4_data import inventory, is_original
from game_data import bundled_entries


with TemporaryDirectory() as temporary:
    root = Path(temporary)
    included = ['iw3sp.exe', 'iw3mp.exe', 'binkw32.dll', 'mss32.dll', 'localization.txt',
                'main/iw_00.iwd', 'main/video/intro.bik', 'zone/english/common.ff',
                'miles/mssmp3.asi']
    excluded = ['players/profiles/Gigi/config.cfg', 'players/profiles/Gigi/save/autosave.svg',
                'main/console.log', 'main/hunkusage.dat', 'mtld3d_shaders.bin',
                'Mods/custom/mod.ff', 'codkey', 'mtld3d.conf']
    for name in included + excluded:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'fixture')
    entries = inventory(root)
    assert {item['path'] for item in entries} == set(included)
    assert all(item['size'] == 7 and len(item['sha256']) == 64 for item in entries)
    compatibility = {'path': 'mtld3d.conf', 'size': 2, 'sha256': 'f' * 64}
    manifest = {'gameID': 'cod4', 'gameFiles': entries + [compatibility], 'gameDataIncluded': False}
    assert bundled_entries(manifest) == [compatibility]
    manifest['gameDataIncluded'] = True
    assert bundled_entries(manifest) == entries + [compatibility]
    assert is_original('main/iw_00.iwd') and not is_original('mtld3d.conf')
    (root / 'main/escape.iwd').symlink_to(root / 'iw3sp.exe')
    try: inventory(root)
    except ValueError: pass
    else: raise AssertionError('Game symlink was accepted')
    (root / 'main/escape.iwd').unlink()
    (root / 'iw3mp.exe').unlink()
    try: inventory(root)
    except ValueError: pass
    else: raise AssertionError('Incomplete multiplayer installation was accepted')
print('CoD4 payload/privacy/import regressions passed')

defaults = Path(__file__).with_name('CoD4Defaults') / 'config.cfg'
text = defaults.read_text()
assert 'seta r_mode ' not in text, 'Initial resolution must come from the selected display'
assert 'seta r_vsync "0"' in text and 'seta com_maxfps "0"' in text
assert not any(word in text.lower() for word in ['codkey', 'guid', 'password', 'gigi'])
print('CoD4 clean first-run defaults regression passed')
