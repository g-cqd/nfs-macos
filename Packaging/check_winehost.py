"""The optional winehost block validates strictly and stages a nested arm64 helper app."""
from copy import deepcopy
import json
from pathlib import Path
import plistlib
from tempfile import TemporaryDirectory

from recipes import RECIPE_DIRECTORY, load_recipe, validate_recipe
from winehost import (EXECUTABLE_RELATIVE, PROFILE_RELATIVE, require_arm64_macho, stage_winehost,
                      validate_winehost)

ARM64 = bytes.fromhex('cffaedfe0c000001') + bytes(56)
INTEL = bytes.fromhex('cffaedfe07000001') + bytes(56)
FAT = bytes.fromhex('cafebabe00000002') + bytes(56)
PROFILE = b'0\x82synthetic provisioning profile, not a real one'

block = {'binary': {'input': 'winehostBuild', 'source': 'bin/winehost'},
         'provisioningProfile': {'input': 'winehostProfile'},
         'profile': 'arm64-wow64', 'fourKilobytePages': True}


def with_winehost(name='farcry2', **changes):
    recipe = deepcopy(load_recipe(name))
    recipe['inputs'].update(winehostBuild='{project}/build', winehostProfile='{home}/profile')
    recipe['winehost'] = deepcopy(block)
    recipe['winehost'].update(changes)
    return recipe


def rejected(recipe, message):
    try: validate_recipe(recipe)
    except ValueError: return
    raise AssertionError(message)


# Existing recipes stay valid, carry no winehost block and stage nothing.
for path in sorted(RECIPE_DIRECTORY.glob('*.json')):
    existing = json.loads(path.read_text())
    assert 'winehost' not in existing, path.name
    validate_recipe(existing)
    with TemporaryDirectory() as temporary:
        assert stage_winehost(Path(temporary), existing, {}) == []
        assert not any(Path(temporary).iterdir()), 'A recipe without winehost must stage nothing'

# The valid block, with and without the optional launch profile, is accepted.
validate_recipe(with_winehost())
minimal = with_winehost()
for key in ['profile', 'fourKilobytePages']: minimal['winehost'].pop(key)
validate_recipe(minimal)

invalid = [
    lambda r: r.update(winehost='arm64'),
    lambda r: r['winehost'].update(unexpected=True),
    lambda r: r['winehost'].pop('binary'),
    lambda r: r['winehost'].pop('provisioningProfile'),
    lambda r: r['winehost']['binary'].update(source='../escape'),
    lambda r: r['winehost']['binary'].update(source='/absolute'),
    lambda r: r['winehost']['binary'].update(extra=1),
    lambda r: r['winehost']['binary'].update(input='undeclared'),
    lambda r: r['winehost']['provisioningProfile'].update(input='undeclared'),
    lambda r: r['winehost']['provisioningProfile'].update(input='winehostBuild'),
    lambda r: r['winehost'].update(profile='x86-rosetta'),
    lambda r: r['winehost'].update(fourKilobytePages='yes'),
    lambda r: (r['winehost'].pop('profile'), r['winehost'].update(fourKilobytePages=True)),
    lambda r: r['winehost'].update(minimumMacOS='latest'),
]
for change in invalid:
    altered = with_winehost()
    change(altered)
    rejected(altered, 'Invalid winehost block was accepted')

# Mach-O check: only a thin arm64 executable can be the host.
with TemporaryDirectory() as temporary:
    root = Path(temporary)
    for name, data, good in [('arm64', ARM64, True), ('intel', INTEL, False), ('fat', FAT, False),
                             ('text', b'#!/bin/sh\n', False), ('empty', b'', False)]:
        (root / name).write_bytes(data)
        try: require_arm64_macho(root / name)
        except ValueError: assert not good, name
        else: assert good, name

# Staging builds winehost.app from supplied inputs and never reads a real profile.
with TemporaryDirectory() as temporary:
    root = Path(temporary)
    build = root / 'build'
    (build / 'bin').mkdir(parents=True)
    (build / 'bin/winehost').write_bytes(ARM64)
    profile = root / 'test.provisionprofile'
    profile.write_bytes(PROFILE)
    inputs = {'winehostBuild': build, 'winehostProfile': profile}
    recipe = with_winehost()
    contents = root / 'App.app/Contents'
    (contents / 'Resources').mkdir(parents=True)
    created = stage_winehost(contents, recipe, inputs)
    app = contents.parent
    assert created == [EXECUTABLE_RELATIVE, PROFILE_RELATIVE,
                       'Contents/Helpers/winehost.app/Contents/Info.plist',
                       'Contents/Resources/runtime-profile.json']
    assert (app / EXECUTABLE_RELATIVE).read_bytes() == ARM64
    assert (app / EXECUTABLE_RELATIVE).stat().st_mode & 0o111
    assert (app / PROFILE_RELATIVE).read_bytes() == PROFILE
    assert PROFILE_RELATIVE == 'Contents/Helpers/winehost.app/Contents/embedded.provisionprofile'
    info = plistlib.loads((app / 'Contents/Helpers/winehost.app/Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'fr.gcqd.winehost'
    assert info['CFBundleExecutable'] == 'winehost' and info['CFBundlePackageType'] == 'APPL'
    assert info['LSArchitecturePriority'] == ['arm64']
    marker = json.loads((contents / 'Resources/runtime-profile.json').read_text())
    assert marker == {'profile': 'arm64-wow64', 'fourKilobytePages': True}

    # Without a launch profile the helper is staged and launches stay on the Rosetta path.
    plain = with_winehost()
    for key in ['profile', 'fourKilobytePages']: plain['winehost'].pop(key)
    other = root / 'Other.app/Contents'
    (other / 'Resources').mkdir(parents=True)
    stage_winehost(other, plain, inputs)
    assert not (other / 'Resources/runtime-profile.json').exists()
    assert (other / 'Helpers/winehost.app/Contents/embedded.provisionprofile').is_file()

    # Bad inputs fail before anything is copied.
    def stage_fails(setup, message):
        target = root / 'Failing.app/Contents'
        (target / 'Resources').mkdir(parents=True, exist_ok=True)
        setup()
        try: stage_winehost(target, recipe, inputs)
        except ValueError: pass
        else: raise AssertionError(message)
        assert not (target / 'Helpers').exists(), 'Partial winehost app left behind'
        import shutil; shutil.rmtree(target.parent)
    (build / 'bin/winehost').write_bytes(INTEL)
    stage_fails(lambda: None, 'An Intel executable was accepted as the host')
    (build / 'bin/winehost').write_bytes(ARM64)
    profile.write_bytes(b'')
    stage_fails(lambda: None, 'An empty provisioning profile was accepted')
    profile.write_bytes(PROFILE)
    profile.rename(root / 'moved')
    stage_fails(lambda: None, 'A missing provisioning profile was accepted')
    (root / 'moved').rename(profile)
    (build / 'bin/winehost').unlink()
    (build / 'bin/winehost').symlink_to('/bin/ls')
    stage_fails(lambda: None, 'A linked executable was accepted')
print('Winehost recipe and assembly regressions passed')
