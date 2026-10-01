"""The Need for Speed (2015) recipe references a player's install and packages no game bytes."""
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

from assemble import stage_game
from recipes import load_recipe, resolve_inputs, supports_edition, validate_recipe
from runtime_inputs import PINS, verify_inputs

PROJECT = Path(__file__).resolve().parents[1]
recipe = load_recipe('nfs2015')
assert recipe['gameID'] == 'nfs2015'
assert recipe['referencesInstallation'] is True
assert recipe['editions'] == ['import']
assert not supports_edition(recipe, 'bundled')
assert recipe['originalFiles'] == [] and recipe['originalDirectories'] == {}
assert recipe['executableHashes'] == {} and recipe['compatibility'] == []
assert 'game' not in recipe['inputs'], 'A referencing recipe must take no game input'

# The verified launch sequence, as configuration rather than code.
client = recipe['storeClient']
assert client['clientArguments'] == ['--in-process-gpu'], 'The EA interface renders blank without it'
assert client['clientExecutable'].endswith('EADesktop.exe'), 'The client is started directly'
assert client['launcherExecutable'].endswith('EALauncher.exe')
assert client['launchURL'] == 'origin2://game/launch/?offerIds={offer}'
assert client['offerID'] == '1024486'
assert client['installRoot'] == 'Program Files/Electronic Arts/EA Desktop'
assert client['gameRoot'] == 'Program Files/EA Games/Need for Speed'
assert recipe['runtimeTuning'] == {
    'WINE_TF_EMULATION': '1', 'WINE_TF_MAX_STEPS': '0', 'WINE_TF_MAX_NS': '0'}

# A 64-bit Direct3D 11 title keeps the D3DMetal DXGI stack and never loads the D3D9 renderer.
assert 'lib/wine/dxgi/gptk' in recipe['runtimeRetention']
assert 'lib/external/D3DMetal.framework' in recipe['runtimeRetention']
assert 'lib/external/libd3dshared.dylib' in recipe['runtimeRetention']
assert 'renderer' not in recipe['inputs'] and 'mtld3dSource' not in recipe['inputs']
assert 'lib/wine/d3d9/mtld3d' not in recipe['runtimeRetention']

# The runtime capability gate must refuse a runtime without execution-breakpoint delivery.
assert 'trapFlagEmulation' in recipe['requiredRuntimeCapabilities']
for name, profile in PINS['runtimeProfiles'].items():
    if 'trapFlagEmulation' not in profile.get('capabilities', []):
        altered = deepcopy(recipe)
        altered['runtimeProfile'] = name
        try:
            verify_inputs(altered, resolve_inputs(altered))
        except ValueError as error:
            assert 'does not provide' in str(error) or 'not built yet' in str(error), error
        else:
            raise AssertionError('A runtime without the capability was accepted: ' + name)

for change in [
    lambda r: r.update(editions=['bundled', 'import']),
    lambda r: r['originalFiles'].append('NFS16.exe'),
    lambda r: r['inputs'].update(game='{games}/NFSMW'),
    lambda r: r['storeClient'].update(launchURL='https://example.invalid/{offer}'),
    lambda r: r['storeClient'].update(clientArguments=['--in-process-gpu; id']),
    lambda r: r['storeClient'].update(offerID='not-a-number'),
    lambda r: r['storeClient'].update(installRoot='../outside'),
    lambda r: r['storeClient'].update(readinessSeconds=0),
    lambda r: r['storeClient'].pop('readinessEvidence'),
    lambda r: r.update(runtimeTuning={'DYLD_INSERT_LIBRARIES': '/tmp/x'}),
    lambda r: r.update(runtimeTuning={'WINE_TF_EMULATION': 'yes'}),
    lambda r: r.update(controllerDevices=['054C']),
    lambda r: r.update(requiredRuntimeCapabilities=['teleportation']),
    lambda r: r['runtimeRetention'].append('../escape'),
    lambda r: r.update(compatibility=[{'path': 'a', 'input': 'packaging', 'source': 'b'}]),
]:
    altered = deepcopy(recipe)
    change(altered)
    try:
        validate_recipe(altered)
    except (ValueError, KeyError):
        pass
    else:
        raise AssertionError('Invalid Need for Speed recipe was accepted')

# A recipe that packages original data may not claim a store client.
nfsmw = load_recipe('nfsmw')
altered = deepcopy(nfsmw)
altered['storeClient'] = client
try:
    validate_recipe(altered)
except ValueError:
    pass
else:
    raise AssertionError('A copying recipe was allowed to declare a store client')

# Staging produces a manifest that carries the contract and not one byte of game data.
with TemporaryDirectory() as temporary:
    resources = Path(temporary)
    manifest = stage_game(resources, recipe, {}, False)
    assert manifest['gameFiles'] == [] and manifest['gameDataIncluded'] is False
    assert manifest['referencesInstallation'] is True
    assert manifest['storeClient'] == client
    assert manifest['runtimeTuning'] == recipe['runtimeTuning']
    assert manifest['controllerDevices'] == recipe['controllerDevices']
    assert len(manifest['version']) == 24
    assert not any((resources / 'Game').rglob('*')), 'No game file may be staged'
    first = manifest['version']
    sensitive = deepcopy(recipe)
    sensitive['storeClient']['offerID'] = '1'
    with TemporaryDirectory() as other:
        assert stage_game(Path(other), sensitive, {}, False)['version'] != first, \
            'The version must change when the launch contract changes'
    try:
        stage_game(Path(temporary + '/bundled'), recipe, {}, True)
    except ValueError:
        pass
    else:
        raise AssertionError('A bundled edition was staged for an import-only recipe')

# build.py refuses the bundled edition before it stages anything.
result = subprocess.run(
    [sys.executable, 'Packaging/build.py', '--game', 'nfs2015', '--game-data', 'bundled',
     '--output', str(PROJECT / 'Build/unused.app')],
    cwd=PROJECT, capture_output=True, text=True)
assert result.returncode != 0 and 'supports only' in result.stderr, result.stderr
assert not (PROJECT / 'Build/unused.app').exists()

# Nothing in this tree may contain a Need for Speed (2015) game file.
for name in ['NFS16.exe', 'NFS16_trial.exe', 'EADesktop.exe', 'EALauncher.exe']:
    assert not list(PROJECT.rglob(name)), 'Game or client binaries must stay outside this tree'
print('Need for Speed (2015) recipe regressions passed')
