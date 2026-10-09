"""Recipe rules for a 64-bit game started through helper processes, such as Battlefield 4.

The schema accepts an x86_64 import executable, a list of store offer ids, a launch chain with the
process the lease follows, and the loopback ports to check; every other rule stays as strict as it
was, and the shipped recipes validate exactly as before.
"""
from copy import deepcopy
from recipes import (DENIED_BACKENDS, GAME_EXECUTABLES, denied_backends, game_executable,
                     load_recipe, validate_import_rules, validate_recipe, validate_store_client)


def synthetic():
    """A minimal referencing, import-only recipe for a made-up 64-bit game."""
    return {
        'schemaVersion': 1, 'gameID': 'sample64', 'launcher': 'Sample64Launcher',
        'session': 'Sample64Session', 'displayName': 'Sample 64', 'bundleIdentifier': 'local.sample64.mac',
        'bundleVersion': '1', 'minimumMacOS': '15.0', 'category': 'public.app-category.action-games',
        'runtimeProfile': 'sample64-profile', 'editions': ['import'], 'referencesInstallation': True,
        'inputs': {'packaging': '{project}/Packaging'}, 'compatibility': [], 'defaults': [],
        'originalFiles': [], 'originalDirectories': {}, 'executableHashes': {},
        'storeClient': {
            'name': 'EA app', 'installRoot': 'Program Files/Electronic Arts/EA Desktop',
            'clientExecutable': 'EA Desktop/EADesktop.exe', 'clientArguments': ['--in-process-gpu'],
            'launcherExecutable': 'EA Desktop/EALauncher.exe',
            'launchURL': 'origin2://game/launch/?offerIds={offer}',
            'offerID': ['1000001', '1000002', '1000003'],
            'signInEvidence': ['AppData/Local/Electronic Arts/EA Desktop'],
            'readinessLog': 'ProgramData/EA Desktop/Logs/EADesktop.log', 'startMarker': '[STARTUP]',
            'readyEvents': ['login', 'client.boot.ready'], 'readinessSeconds': 180,
            'gameRoot': 'Program Files/EA Games/Sample 64',
            'launchChain': ['Launcher64.exe', 'WebHelper.exe', 'Game64.exe'],
            'leaseTarget': 'Game64.exe', 'expectedPorts': [3215, 3216],
        },
        'renderers': [{'api': 'dxgi', 'backend': 'dxmt', 'executable': 'Game64.exe', 'reason': 'sample'}],
        'importRules': {
            'executable': 'Game/Game64.exe', 'machine': 'x86_64',
            'required': [{'path': 'Game/Game64.exe', 'minimumSize': 1}],
            'directories': [{'path': 'Game', 'minimumBytes': 0, 'excludedNames': [],
                             'excludedDirectories': [], 'excludedSuffixes': []}],
            'maximumFiles': 100, 'maximumBytes': 1000000,
        },
    }


def must_reject(recipe, why):
    try: validate_recipe(recipe)
    except ValueError: return
    raise AssertionError('Accepted invalid recipe: ' + why)


good = synthetic()
validate_recipe(good)
assert validate_import_rules(good['importRules'])['machine'] == 'x86_64'

# Machine types: i386 stays valid, x86_64 is new, anything else, or nothing, is not.
for machine in ['i386', 'x86_64']:
    rules = deepcopy(good['importRules']); rules['machine'] = machine
    validate_import_rules(rules)
for bad in ['arm64', 'X86_64', 'amd64', 'x64', '', None, 64, ['x86_64'], {'x86_64': 1}]:
    rules = deepcopy(good['importRules']); rules['machine'] = bad
    try: validate_import_rules(rules)
    except ValueError: pass
    else: raise AssertionError('Accepted machine ' + repr(bad))
rules = deepcopy(good['importRules']); del rules['machine']
try: validate_import_rules(rules)
except ValueError: pass
else: raise AssertionError('A missing machine must still be rejected')

# Offer ids: one id (the form every shipped recipe uses) or a bounded list of distinct ids.
client = deepcopy(good['storeClient'])
for offer in ['1', '1' * 20, ['1'], ['1' * 20], [str(1000 + n) for n in range(32)]]:
    client['offerID'] = offer; validate_store_client(client)
client['offerID'] = [str(100 + n) for n in range(32)]
client['launchURL'] = 'origin2://game/launch/?offerIds={offer}'
validate_store_client(client)
mutations = {
    'empty list': lambda c: c.update(offerID=[]),
    'empty string': lambda c: c.update(offerID=''),
    'letters': lambda c: c.update(offerID='abc'),
    'twenty-one digits': lambda c: c.update(offerID='1' * 21),
    'twenty-one digits in a list': lambda c: c.update(offerID=['1', '1' * 21]),
    'zero-length id in a list': lambda c: c.update(offerID=['1', '']),
    'integer id': lambda c: c.update(offerID=5),
    'integer in a list': lambda c: c.update(offerID=[1]),
    'none in a list': lambda c: c.update(offerID=['1', None]),
    'nested list': lambda c: c.update(offerID=[['1']]),
    'object': lambda c: c.update(offerID={'1': '2'}),
    'thirty-three ids': lambda c: c.update(offerID=[str(100 + n) for n in range(33)]),
    'duplicate ids': lambda c: c.update(offerID=['5', '5']),
    'signed id': lambda c: c.update(offerID=['-5']),
    'id with a comma': lambda c: c.update(offerID=['1,2']),
    'expanded request too long': lambda c: c.update(
        offerID=[str(10 ** 19 + n) for n in range(32)]),
    'offer slot missing': lambda c: c.update(launchURL='origin2://game/launch/?offerIds=1'),
    'launch chain empty': lambda c: c.update(launchChain=[]),
    'launch chain not a list': lambda c: c.update(launchChain='Game64.exe'),
    'launch chain of nine': lambda c: c.update(launchChain=['A%d.exe' % n for n in range(9)]),
    'launch chain traversal': lambda c: c.update(launchChain=['../Game64.exe']),
    'launch chain path': lambda c: c.update(launchChain=['bin/Game64.exe']),
    'launch chain backslash': lambda c: c.update(launchChain=['bin\\Game64.exe']),
    'launch chain not an exe': lambda c: c.update(launchChain=['Game64.dll']),
    'launch chain empty name': lambda c: c.update(launchChain=['']),
    'launch chain control character': lambda c: c.update(launchChain=['Game\n64.exe']),
    'launch chain overlong name': lambda c: c.update(launchChain=['a' * 70 + '.exe']),
    'launch chain duplicate by case': lambda c: c.update(launchChain=['Game64.exe', 'GAME64.EXE']),
    'launch chain integer': lambda c: c.update(launchChain=[64]),
    'lease target without chain': lambda c: (c.pop('launchChain'), c.update(leaseTarget='Game64.exe')),
    'lease target outside chain': lambda c: c.update(leaseTarget='Other.exe'),
    'lease target traversal': lambda c: c.update(leaseTarget='../Game64.exe'),
    'lease target not text': lambda c: c.update(leaseTarget=5),
    'ports empty': lambda c: c.update(expectedPorts=[]),
    'ports not a list': lambda c: c.update(expectedPorts=3215),
    'ports of nine': lambda c: c.update(expectedPorts=list(range(3000, 3009))),
    'privileged port': lambda c: c.update(expectedPorts=[80]),
    'port zero': lambda c: c.update(expectedPorts=[0]),
    'port above range': lambda c: c.update(expectedPorts=[65536]),
    'negative port': lambda c: c.update(expectedPorts=[-3215]),
    'boolean port': lambda c: c.update(expectedPorts=[True]),
    'text port': lambda c: c.update(expectedPorts=['3215']),
    'float port': lambda c: c.update(expectedPorts=[3215.0]),
    'duplicate port': lambda c: c.update(expectedPorts=[3215, 3215]),
}
for name, change in mutations.items():
    altered = deepcopy(good)
    change(altered['storeClient'])
    must_reject(altered, name)
# The three launch-chain fields are optional: the shape every shipped recipe has still validates.
plain = deepcopy(good)
for key in ['launchChain', 'leaseTarget', 'expectedPorts']:
    del plain['storeClient'][key]
plain['storeClient']['offerID'] = '1024486'
validate_recipe(plain)
# Case differences between the chain and its lease target are the same process.
cased = deepcopy(good); cased['storeClient']['leaseTarget'] = 'GAME64.EXE'
validate_recipe(cased)

# The game executable and the per-game denials: built in for nfs2015, declared by a recipe for a new game.
assert game_executable(good) == '' and game_executable(load_recipe('nfs2015')) == GAME_EXECUTABLES['nfs2015']
declared = deepcopy(good); declared['gameExecutable'] = 'Game/Game64.exe'
validate_recipe(declared); assert game_executable(declared) == 'Game/Game64.exe'
for bad in ['../Game64.exe', '/Game64.exe', 'Game64.dll', '', 5, 'a\\b.exe', 'x' * 130 + '.exe', 'a//b.exe']:
    altered = deepcopy(good); altered['gameExecutable'] = bad
    must_reject(altered, 'game executable ' + repr(bad))
nfs = load_recipe('nfs2015')
renamed = deepcopy(nfs); renamed['gameExecutable'] = 'Other.exe'
must_reject(renamed, 'a known game cannot rename its executable')
same = deepcopy(nfs); same['gameExecutable'] = 'nfs16.EXE'
validate_recipe(same)

refusal = {'executable': 'Game64.exe', 'backends': {'gptk': 'measured to fault in this game'}}
own = deepcopy(good); own['deniedBackends'] = deepcopy(refusal)
validate_recipe(own)
assert denied_backends(own) == ('Game64.exe', {'gptk': 'measured to fault in this game'})
chosen = deepcopy(own); chosen['renderers'][0]['backend'] = 'gptk'
must_reject(chosen, 'a recipe-declared denial applies to its own executable')
elsewhere = deepcopy(chosen); elsewhere['renderers'][0]['executable'] = 'EADesktop.exe'
validate_recipe(elsewhere)
for name, bad in {
    'extra key': dict(refusal, note='x'), 'missing executable': {'backends': refusal['backends']},
    'executable with a path': dict(refusal, executable='bin/Game64.exe'),
    'executable not an exe': dict(refusal, executable='Game64'),
    'empty backends': dict(refusal, backends={}),
    'nine backends': dict(refusal, backends={'b%d' % n: 'r' for n in range(9)}),
    'uppercase backend': dict(refusal, backends={'GPTK': 'r'}),
    'empty reason': dict(refusal, backends={'gptk': ''}),
    'reason with a semicolon': dict(refusal, backends={'gptk': 'a;exe=*;dxgi=gptk'}),
    'overlong reason': dict(refusal, backends={'gptk': 'r' * 201}),
    'not an object': ['gptk'],
}.items():
    altered = deepcopy(good); altered['deniedBackends'] = bad
    must_reject(altered, 'denied backends: ' + name)

# nfs2015's built-in denial cannot be removed, reworded, or moved to another executable; it can be added to.
builtin = DENIED_BACKENDS['nfs2015']
extended = deepcopy(nfs)
extended['deniedBackends'] = {'executable': builtin['executable'], 'backends': {'extra': 'measured'}}
validate_recipe(extended)
executable, denied = denied_backends(extended)
assert executable == builtin['executable'] and denied == {**builtin['backends'], 'extra': 'measured'}
assert denied_backends(nfs) == (builtin['executable'], builtin['backends'])
for name, bad in {
    'reworded': {'executable': builtin['executable'], 'backends': {'gptk': 'D3DMetal is fine'}},
    'moved to another executable': {'executable': 'Other.exe', 'backends': {'extra': 'measured'}},
}.items():
    altered = deepcopy(nfs); altered['deniedBackends'] = bad
    must_reject(altered, 'built-in denial ' + name)
unchanged = deepcopy(nfs)
unchanged['renderers'][0]['backend'] = 'gptk'
must_reject(unchanged, 'the built-in nfs2015 denial still applies')
unchanged = deepcopy(nfs)
unchanged['deniedBackends'] = {'executable': 'NFS16.exe', 'backends': {'extra': 'measured'}}
unchanged['renderers'][0]['backend'] = 'gptk'
must_reject(unchanged, 'declaring another denial does not lift the built-in one')

# Only a referencing recipe declares these keys, as with the other store-client fields.
for key, value in [('gameExecutable', 'Game.exe'), ('deniedBackends', deepcopy(refusal))]:
    altered = load_recipe('cod4'); altered[key] = value
    must_reject(altered, 'non-referencing recipe declaring ' + key)

# Nothing about the shipped recipes changes: none uses a new key, and each still validates.
for name in ['nfsmw', 'cod4', 'nfs2015', 'farcry2', 'farcry2-bundled']:
    recipe = load_recipe(name)
    assert 'gameExecutable' not in recipe and 'deniedBackends' not in recipe
    client = recipe.get('storeClient')
    if client:
        assert isinstance(client['offerID'], str)
        assert not {'launchChain', 'leaseTarget', 'expectedPorts'} & set(client)
    rules = recipe.get('importRules')
    if rules:
        assert rules['machine'] == 'i386'
print('64-bit recipe schema regressions passed')
