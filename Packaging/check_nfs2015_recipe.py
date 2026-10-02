"""The Need for Speed (2015) recipe: an import edition that packages no game bytes, and a bundled edition pinned file by file."""
from copy import deepcopy
import json
from pathlib import Path
import re
from tempfile import TemporaryDirectory

from assemble import stage_client_layer, stage_game, verify_client_layer
import client_layer
from recipes import load_recipe, resolve_inputs, supports_edition, validate_recipe
from runtime_inputs import PINS, verify_inputs, verify_runtime_provides

PROJECT = Path(__file__).resolve().parents[1]
recipe = load_recipe('nfs2015')
assert recipe['gameID'] == 'nfs2015'
assert recipe['referencesInstallation'] is True
assert recipe['editions'] == ['import', 'bundled']
assert supports_edition(recipe, 'bundled') and supports_edition(recipe, 'import')
assert recipe['compatibility'] == []
# The bundled edition lists the installation's files explicitly and pins the executables and key
# libraries, and the whole payload inventory, so the packager refuses any other build of the game.
assert set(recipe['originalDirectories']) == {'Core', 'Data', 'Support', 'Update', '__Installer'}
assert all(suffixes == [] for suffixes in recipe['originalDirectories'].values())
assert 'NFS16.exe' in recipe['originalFiles'] and 'NFS16_trial.exe' in recipe['originalFiles']
for name in ['NFS16.exe', 'NFS16_trial.exe', 'Core/Activation64.dll', 'Core/ActivationUI.exe',
             'Core/Activation.dll', '__Installer/Touchup.exe', '__Installer/installerdata.xml']:
    assert name in recipe['executableHashes'], 'Not pinned: ' + name
assert re.fullmatch('[0-9a-f]{64}', recipe['inventorySHA256'])
assert 'game' in recipe['inputs'], 'The bundled edition needs the verified installation as an input'
# The payload comes from a standalone copy of exactly the pinned files, never from a working
# prefix: a prefix is the player's own state, and a rebuild must not depend on it surviving.
game_input = recipe['inputs']['game'].casefold()
assert not any(marker in game_input for marker in ['drive_c', 'prefix', 'debug', 'program files']), \
    'The game input must be a standalone payload copy, not a Windows prefix: ' + recipe['inputs']['game']
for item in recipe['originalFiles'] + list(recipe['originalDirectories']):
    # Generated or personal files that sit beside the game in a used installation are never listed.
    assert not any(marker in item.casefold() for marker in
                   ['dxvk', 'cache', 'log', '.ini', 'profile', 'cookie', 'token']), item
registration = {item['name']: item for item in recipe['bundledPrefixSettings']}
assert registration['Install Dir']['value'] == 'C:\\Program Files\\EA Games\\Need for Speed\\'
assert registration['Install Dir']['kind'] == 'windowsPath' and registration['Install Dir']['hive'] == 'HKEY_LOCAL_MACHINE'
assert registration['Install Dir']['value'] == 'C:\\' + recipe['storeClient']['gameRoot'].replace('/', '\\') + '\\', \
    'The registered install folder is where the app seeds the game'
assert not any(item['name'] == 'Install Dir' for item in recipe['prefixSettings']), \
    'The registration belongs to the bundled edition only; the import edition never writes it'

# The verified launch sequence, as configuration rather than code.
client = recipe['storeClient']
# Readiness is the client's own start line and sign-in events, measured in the logs of its runs:
# after the start line a signed-in client prints the telemetry events `login` and `client.boot.ready`.
# File times and child process counts were tried and cannot work (Wine reparents every child to
# launchd, and a reused URL reports a cached time), and the `authenticated` flag flips within a run.
assert client['readinessLog'] == 'ProgramData/EA Desktop/Logs/EADesktop.log', client['readinessLog']
assert client['startMarker'] == '[STARTUP]'
assert client['readyEvents'] == ['login', 'client.boot.ready'], client['readyEvents']
assert 'readinessEvidence' not in client and 'readinessChildren' not in client
assert client['clientArguments'] == ['--in-process-gpu'], 'The EA interface renders blank without it'
assert client['clientExecutable'].endswith('EADesktop.exe'), 'The client is started directly'
assert client['launcherExecutable'].endswith('EALauncher.exe')
assert client['launchURL'] == 'origin2://game/launch/?offerIds={offer}'
assert client['offerID'] == '1024486'
assert client['installRoot'] == 'Program Files/Electronic Arts/EA Desktop'
assert client['gameRoot'] == 'Program Files/EA Games/Need for Speed'
assert recipe['runtimeTuning'] == {
    'WINE_TF_EMULATION': '1', 'WINE_TF_MAX_STEPS': '0', 'WINE_TF_MAX_NS': '0'}

# A 64-bit Direct3D 11 title is served by a Vulkan-backed DXGI stack, never by mtld3d, and
# never by D3DMetal: that combination clears Denuvo and then faults on a timestamp query.
assert 'renderer' not in recipe['inputs'] and 'mtld3dSource' not in recipe['inputs']
assert 'lib/wine/d3d9/mtld3d' not in recipe['runtimeRetention']
assert 'dxmtDXGI' in recipe['requiredRuntimeCapabilities']
assert recipe['renderers'], 'A referencing D3D11 recipe must say which backend serves it'
rules = {r.get('executable'): r for r in recipe['renderers']}
assert rules['NFS16.exe']['backend'] == 'dxmt', 'The game is served by the measured backend'
assert rules['EADesktop.exe']['backend'] == 'dxmt', 'The client is served by it too, measured'
# EA's CEF helper processes import dxgi.dll through libcef.dll. Without a rule they resolve to a
# backend this runtime does not ship, fail to load, and the EA window never comes up.
assert rules['EACefSubProcess.exe']['backend'] == 'dxmt', 'The EA browser helpers need a dxgi backend too'
for rule in recipe['renderers']:
    assert rule['api'] == 'dxgi' and rule['reason'], rule
assert None not in rules, 'No catch-all may silently serve the game a denied backend'
# Nothing selects D3DMetal, so no Apple-signed artifact is retained and none may be exempted.
assert recipe['runtimeRetention'] == ['lib/wine/dxgi/dxmt'], recipe['runtimeRetention']
assert 'vendorRuntimePaths' not in recipe, 'No vendor artifact is retained by this recipe'
assert not any(r['backend'] == 'gptk' for r in recipe['renderers'])
assert 'd3dmetalDXGI' not in recipe['requiredRuntimeCapabilities']

# EA's installer runs a managed custom action, so the bundled prefix needs a pinned .NET runtime.
managed = recipe['managedRuntime']
assert managed['input'] in recipe['inputs'] and re.fullmatch('[0-9a-f]{64}', managed['sha256'])
assert managed['path'].startswith('Addons/') and managed['path'].endswith('.msi')
assert managed['url'].startswith('https://dl.winehq.org/') and managed['sourceURL'].startswith('https://dl.winehq.org/')
assert managed['version'] in managed['source'] and managed['version'] in managed['url']

# The pre-installed EA client is a build input pinned by the digest of its manifest, and by the client facts.
layer = recipe['clientLayer']
assert layer['input'] == 'clientLayer' and layer['path'] == 'ClientLayer'
assert recipe['inputs']['clientLayer'] == '{tools}/inputs/client-layer'
assert layer['layerSHA256'] == '9ed3bf73529b899f2b934743ef86c51d34013dfc5fb092678b0d465a79547f86'
assert layer['client'] == {
    'name': 'EA app', 'version': '13.796.0.6309',
    'installer': {'fileName': 'EAappInstaller.exe', 'bytes': 2141240, 'signer': 'Electronic Arts, Inc.',
                  'sha256': 'dcbda653c9776320b283157be70def64db73c2b01bf45d5fa78f35d7e4e29320'},
    'package': {'fileName': 'EAapp-13.796.0.6309-15736974.msi', 'bytes': 246083584,
                'sha256': 'cb773af8c1400d0139824dc2148c0ceef978ba95654812f8a7eeec46c34dcdc8'}}
assert layer['client']['version'] in layer['client']['package']['fileName']
real_layer = resolve_inputs(recipe)['clientLayer']
if real_layer.is_dir():
    assert verify_client_layer(recipe, {'clientLayer': real_layer}) == layer
    assert client_layer.verify_layer(real_layer, layer['layerSHA256'], layer['client']) == []
    print('PASS the real client layer matches its pins and policy')
else:
    print('SKIP the real client layer is not on this machine: ' + str(real_layer))

# The runtime must actually carry what the recipe selects; a claim alone is not enough.
verify_runtime_provides(recipe, resolve_inputs(recipe)['runtime'])
for backend in ['dxvk', 'nonexistent']:
    altered = deepcopy(recipe)
    altered['renderers'] = [{'api': 'dxgi', 'backend': backend, 'reason': 'x',
                             'executable': 'NFS16.exe'}]
    try:
        verify_runtime_provides(altered, resolve_inputs(altered)['runtime'])
    except ValueError as error:
        assert 'has no dxgi backend named' in str(error), error
    else:
        raise AssertionError('A backend absent from the runtime was accepted: ' + backend)

# Selecting D3DMetal for the game itself must be impossible, named or by a catch-all, while
# the rule naming the store client keeps it.
for rule in [{'api': 'dxgi', 'backend': 'gptk', 'reason': 'x'},
             {'api': 'dxgi', 'backend': 'gptk', 'reason': 'x', 'executable': 'NFS16.exe'},
             {'api': 'dxgi', 'backend': 'gptk', 'reason': 'x', 'executable': 'nfs16.exe'}]:
    altered = deepcopy(recipe)
    altered['renderers'] = [rule]
    try:
        validate_recipe(altered)
    except ValueError as error:
        assert 'timestamp' in str(error), error
    else:
        raise AssertionError('A denied renderer backend was accepted: ' + str(rule))

# The prefix settings the game needs, which are Wine's and so cannot live in the game's file.
retina = [s for s in recipe['prefixSettings'] if s['name'] == 'RetinaMode']
assert len(retina) == 1, 'The recipe must record RetinaMode in the adopted prefix'
assert retina[0]['hive'] == 'HKEY_CURRENT_USER'
assert retina[0]['path'] == 'Software\\Wine\\Mac Driver'
assert retina[0]['kind'] == 'string' and retina[0]['value'] in {'Y', 'y'}
assert retina[0]['reason'], 'A prefix setting must say why it is needed'

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
    lambda r: r.update(editions=['bundled']),
    lambda r: r.update(editions=['import', 'bundled', 'import']),
    lambda r: r['originalFiles'].append('NFS16.exe'),
    lambda r: r['originalFiles'].append('Core/duplicate.dll'),
    lambda r: r['originalDirectories'].update({'Core/codecs': []}),
    lambda r: r['originalDirectories'].update({'Data': ['.CAS']}),
    lambda r: r['originalDirectories'].update({'../outside': []}),
    lambda r: r['executableHashes'].pop('NFS16.exe'),
    lambda r: r['executableHashes'].update({'NFS16.exe': 'not-a-digest'}),
    lambda r: r['executableHashes'].update({'Other/elsewhere.exe': '0' * 64}),
    lambda r: r['executableHashes'].update({'../NFS16.exe': '0' * 64}),
    lambda r: r.pop('inventorySHA256'),
    lambda r: r.update(inventorySHA256='abc'),
    lambda r: r['inputs'].pop('game'),
    lambda r: r['bundledPrefixSettings'][0].update(hive='HKEY_CLASSES_ROOT'),
    lambda r: r['bundledPrefixSettings'][0].update(value='C:\\..\\Windows\\'),
    lambda r: r['bundledPrefixSettings'][0].update(value='C:\\Games\\a"b'),
    lambda r: r['bundledPrefixSettings'][0].update(value='\\\\server\\share'),
    lambda r: r['bundledPrefixSettings'][0].update(path='Software\\\\EA'),
    lambda r: r['bundledPrefixSettings'][1].update(value='en_US"\n[HKEY_LOCAL_MACHINE\\X]'),
    lambda r: r.update(bundledPrefixSettings='nothing'),
    lambda r: r['storeClient'].update(launchURL='https://example.invalid/{offer}'),
    lambda r: r['storeClient'].update(clientArguments=['--in-process-gpu; id']),
    lambda r: r['storeClient'].update(offerID='not-a-number'),
    lambda r: r['storeClient'].update(installRoot='../outside'),
    lambda r: r['storeClient'].update(readinessSeconds=0),
    lambda r: r['storeClient'].pop('readinessLog'),
    lambda r: r['storeClient'].pop('startMarker'),
    lambda r: r['storeClient'].update(startMarker='[STARTUP]\n[x]'),
    lambda r: r['storeClient'].pop('readyEvents'),
    lambda r: r['storeClient'].update(readyEvents=[]),
    lambda r: r['storeClient'].update(readyEvents=['login; id']),
    lambda r: r['storeClient'].update(readinessLog='../outside.log'),
    lambda r: r.update(runtimeTuning={'DYLD_INSERT_LIBRARIES': '/tmp/x'}),
    lambda r: r.update(runtimeTuning={'WINE_TF_EMULATION': 'yes'}),
    lambda r: r.update(controllerDevices=['054C']),
    lambda r: r['prefixSettings'][0].update(value='Y"\n[HKEY_LOCAL_MACHINE\\X]'),
    lambda r: r['prefixSettings'][0].update(hive='HKEY_CLASSES_ROOT'),
    lambda r: r['prefixSettings'][0].update(kind='binary'),
    lambda r: r['prefixSettings'][0].update(path='Software\\\\Wine'),
    lambda r: r.update(renderers=[]),
    lambda r: r['renderers'][0].update(api='vulkan'),
    lambda r: r['renderers'][0].update(backend='DXMT'),
    lambda r: r['renderers'][0].update(executable='../escape.exe'),
    lambda r: r['renderers'][0].update(reason='a;exe=*;dxgi=gptk'),
    lambda r: r['managedRuntime'].update(sha256='abc'),
    lambda r: r['managedRuntime'].update(sha256='A' * 64),
    lambda r: r['managedRuntime'].update(path='../Addons/mono.msi'),
    lambda r: r['managedRuntime'].update(path='mono.msi'),
    lambda r: r['managedRuntime'].update(path='Addons/mono.exe'),
    lambda r: r['managedRuntime'].update(source='/etc/passwd'),
    lambda r: r['managedRuntime'].update(version='10.4.1; id'),
    lambda r: r['managedRuntime'].update(url='http://dl.winehq.org/mono.msi'),
    lambda r: r['managedRuntime'].update(input='undeclared'),
    lambda r: r['managedRuntime'].pop('sourceURL'),
    lambda r: r['clientLayer'].update(layerSHA256='abc'),
    lambda r: r['clientLayer'].update(layerSHA256='A' * 64),
    lambda r: r['clientLayer'].update(path='../ClientLayer'),
    lambda r: r['clientLayer'].update(path='Game'),
    lambda r: r['clientLayer'].update(path='Layer/Deep'),
    lambda r: r['clientLayer'].update(input='undeclared'),
    lambda r: r['clientLayer'].update(extra=True),
    lambda r: r['clientLayer'].pop('client'),
    lambda r: r['clientLayer']['client'].update(version='13.796; id'),
    lambda r: r['clientLayer']['client'].pop('package'),
    lambda r: r['clientLayer']['client']['installer'].update(sha256='abc'),
    lambda r: r['clientLayer']['client']['installer'].update(fileName='../EAappInstaller.exe'),
    lambda r: r['clientLayer']['client']['installer'].update(fileName='installer.msi'),
    lambda r: r['clientLayer']['client']['installer'].pop('signer'),
    lambda r: r['clientLayer']['client']['installer'].update(bytes=0),
    lambda r: r['clientLayer']['client']['installer'].update(bytes=True),
    lambda r: r['clientLayer']['client']['package'].update(signer='EA'),
    lambda r: r['clientLayer']['client']['package'].update(fileName='package.exe'),
    lambda r: r.update(clientLayer='layer'),
    lambda r: r.update(managedRuntime='mono'),
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

# An import-only recipe is valid without a managed runtime and refused with one: only the bundled
# edition owns a prefix to install it into.
importing = deepcopy(recipe)
importing.update(editions=['import'], originalFiles=[], originalDirectories={}, executableHashes={})
for key in ['inventorySHA256', 'managedRuntime', 'bundledPrefixSettings', 'clientLayer']:
    importing.pop(key)
importing['inputs'].pop('game')
validate_recipe(deepcopy(importing))
importing['managedRuntime'] = recipe['managedRuntime']
try:
    validate_recipe(importing)
except ValueError as error:
    assert 'Only a bundled edition' in str(error), error
else:
    raise AssertionError('An import-only recipe was allowed to install a managed runtime')
importing.pop('managedRuntime')
importing['clientLayer'] = recipe['clientLayer']
try:
    validate_recipe(importing)
except ValueError as error:
    assert 'Only a bundled edition' in str(error), error
else:
    raise AssertionError('An import-only recipe was allowed to install a client layer')

# A recipe that packages original data may not claim a store client.
nfsmw = load_recipe('nfsmw')
altered = deepcopy(nfsmw)
altered['prefixSettings'] = recipe['prefixSettings']
try:
    validate_recipe(altered)
except ValueError:
    pass
else:
    raise AssertionError('A copying recipe was allowed to declare prefix settings')
altered = deepcopy(nfsmw)
altered['clientLayer'] = recipe['clientLayer']
try:
    validate_recipe(altered)
except ValueError as error:
    assert 'Only a referencing recipe' in str(error), error
else:
    raise AssertionError('A copying recipe was allowed to declare a client layer')
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
    assert manifest['prefixSettings'] == recipe['prefixSettings']
    assert manifest['renderers'] == recipe['renderers']
    assert 'managedRuntime' not in manifest, 'An import app runs in the player prefix and never installs it'
    assert 'clientLayer' not in manifest, 'An import app runs in the player prefix and never carries the client'
    # No layer is staged for an import app, and staging without a declaration stages nothing.
    assert stage_client_layer(resources, {k: v for k, v in recipe.items() if k != 'clientLayer'}, {}) is None
    assert not (resources / 'ClientLayer').exists() and not (resources / 'Licenses').exists()
    assert len(manifest['version']) == 24
    assert not any((resources / 'Game').rglob('*')), 'No game file may be staged'
    first = manifest['version']
    sensitive = deepcopy(recipe)
    sensitive['storeClient']['offerID'] = '1'
    with TemporaryDirectory() as other:
        assert stage_game(Path(other), sensitive, {}, False)['version'] != first, \
            'The version must change when the launch contract changes'
    # The bundled edition refuses to stage without the verified installation behind its pins.
    empty = Path(temporary) / 'empty'
    empty.mkdir()
    staged = Path(temporary) / 'bundled'
    staged.mkdir()
    try:
        stage_game(staged, recipe, {'game': empty}, True)
    except ValueError as error:
        assert 'pinned artifact' in str(error), error
    else:
        raise AssertionError('A bundled edition was staged without the pinned game files')
    assert not any((staged / 'Game').rglob('*')), 'No game file may be staged before the pins match'

# Nothing in this tree may contain a Need for Speed (2015) game file.
for name in ['NFS16.exe', 'NFS16_trial.exe', 'EADesktop.exe', 'EALauncher.exe']:
    assert not list(PROJECT.rglob(name)), 'Game or client binaries must stay outside this tree'
print('Need for Speed (2015) recipe regressions passed')
