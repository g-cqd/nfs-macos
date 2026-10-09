#!/usr/bin/env python3
"""Gate for the prepared-prefix recipe shape (Battlefield 3) and the old recipes' byte identity.

The bf3 recipe validates; each rule of validate_prepared_prefix refuses its mutation; the
manifest writer refuses a template that disagrees with the pins; and every older recipe ships
exactly the bytes it shipped before the shape existed.
"""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from recipes import load_recipe, shipped_recipe, validate_recipe  # noqa: E402
import prepared_prefix  # noqa: E402

# Shipped-form SHA-256 (bundle-recipe.json bytes as assemble.py writes them) of the recipes that
# existed before the prepared-prefix shape, taken at e7e7a1b.
SHIPPED = {
    'cod4': 'ff3d6167b643d999caf8b58aa4ad2943b2742ed36e24016cb7d6bcc0a193dfa0',
    'farcry2': '66bff346cc68870b687b86cb9ecea5b92b5c2de293137e9e677e39793c283cbb',
    'farcry2-bundled': '55039eb91b0e17e52a56dd104f102e7a26d365b3276db8d412c722b04abc973f',
    'nfs2015': '23678c96d7a5a6fdd530250a0f9b97ddec4952960afbc849e681d3ebfe072cba',
    'nfsmw': '58342c6b3f26940b27cd5476ff0b45e5ae16e8d8cf7bfc7f75b1d475463ae211',
}

failures = []


def check(name, condition):
    if not condition:
        failures.append(name)


def refuses(name, mutate):
    recipe = copy.deepcopy(load_recipe('bf3'))
    mutate(recipe)
    try:
        validate_recipe(recipe)
    except (ValueError, KeyError, TypeError):
        return
    failures.append('accepted: ' + name)


for name, digest in SHIPPED.items():
    shipped = (json.dumps(shipped_recipe(load_recipe(name)), indent=2) + '\n').encode()
    check('byte identity of ' + name, hashlib.sha256(shipped).hexdigest() == digest)

bf3 = load_recipe('bf3')
check('bf3 shipped form validates', validate_recipe(shipped_recipe(bf3)) is not None)

refuses('an import edition', lambda r: r.update(editions=['bundled', 'import']))
refuses('a managed runtime', lambda r: r.update(managedRuntime={}))
refuses('a client layer', lambda r: r.update(clientLayer={}))
refuses('an undeclared seed input', lambda r: r['prefixSeed'].update(input='other'))
refuses('an extra seed key', lambda r: r['prefixSeed'].update(extra=1))
refuses('a seed path with a separator', lambda r: r['prefixSeed'].update(path='Game/x'))
refuses('an unsafe profile path', lambda r: r['prefixSeed'].update(settingsProfile='../p'))
refuses('a background program path', lambda r: r['prefixSeed'].update(backgroundPrograms=['a/b.exe']))
refuses('no inventory pin', lambda r: r.pop('inventorySHA256'))
refuses('no launch chain', lambda r: r['storeClient'].pop('launchChain'))
refuses('no expected ports', lambda r: r['storeClient'].pop('expectedPorts'))
refuses('a lease target that is not the game', lambda r: r['storeClient'].update(leaseTarget='BF3WebHelper.exe'))
refuses('an unpinned game executable', lambda r: r['executableHashes'].pop('bf3.exe'))
refuses('a plain HTTP page', lambda r: r['storeBrowser']['pages'][0].update(url='http://battlelog.battlefield.com/'))
refuses('a duplicate page', lambda r: r['storeBrowser']['pages'].append(dict(r['storeBrowser']['pages'][0])))
refuses('a quoted identity', lambda r: r['storeBrowser'].update(userAgent='Mozilla "5.0" Windows NT 10.0'))
refuses('a duplicate browser', lambda r: r['storeBrowser']['browsers'].append('com.google.Chrome'))
refuses('a profile outside the folder', lambda r: r['storeBrowser'].update(profileFolder='../P'))
refuses('a remote service', lambda r: r['storeBrowser']['service'].update(url='http://example.com:3215/ping'))
refuses('a service on an undeclared port', lambda r: r['storeBrowser']['service'].update(url='http://127.0.0.1:4219/'))
refuses('a plain HTTP origin', lambda r: r['storeBrowser']['service'].update(origin='http://battlelog.battlefield.com'))
refuses('a game check on another port', lambda r: r['storeBrowser']['service'].update(gameURL='http://127.0.0.1:4215/game/status'))
refuses('a game check without its reply', lambda r: r['storeBrowser']['service'].pop('gameReply'))
refuses('an unbounded wait', lambda r: r['storeBrowser']['service'].update(seconds=601))
refuses('no registry records', lambda r: r.update(prefixRegistry=[]))
refuses('an unknown hive', lambda r: r['prefixRegistry'][0].update(hive='userdef.reg'))
refuses('a registry record without reason', lambda r: r['prefixRegistry'][0].update(reason=''))
refuses('an unpinned shim', lambda r: r['gameShims'][0].update(sha256='x'))
refuses('a shim outside the game', lambda r: r['gameShims'][0].update(path='../d3d11.dll'))
refuses('a duplicate preset', lambda r: r['presets'].append(copy.deepcopy(r['presets'][0])))
refuses('a preset key with a space', lambda r: r['presets'][0]['values'].append({'key': 'A B', 'value': '1'}))
refuses('an unknown placeholder', lambda r: r['presets'][0]['values'].append({'key': 'K', 'value': '{home}'}))
refuses('a denied renderer', lambda r: r.update(deniedBackends={'executable': 'bf3.exe', 'backends': {'dxmt': 'x'}}))
refuses('presets on a non-prefix recipe', lambda r: (r.pop('prefixSeed'), r.update(editions=['bundled'])))

# The manifest writer: a template that matches the pins is described, one that does not is refused.
with tempfile.TemporaryDirectory() as folder:
    root = Path(folder) / 'Game'
    game = root / 'drive_c' / bf3['storeClient']['gameRoot']
    game.mkdir(parents=True)
    (root / 'system.reg').write_text('WINE REGISTRY Version 2\n')
    (root / 'drive_c/users/crossover/Desktop').mkdir(parents=True)
    (game / 'bf3.exe').write_bytes(b'MZ')
    scanned = prepared_prefix.scan(root)
    check('scan lists files', [f['path'] for f in scanned['files']] == [
        'drive_c/Program Files/EA Games/Battlefield 3/bf3.exe', 'system.reg'])
    check('scan lists empty folders', scanned['emptyDirectories'] == ['drive_c/users/crossover/Desktop'])
    try:
        prepared_prefix.manifest(bf3, scanned)
        failures.append('accepted: a template that disagrees with the pins')
    except ValueError:
        pass
    (root / '.DS_Store').write_bytes(b'')
    try:
        prepared_prefix.scan(root)
        failures.append('accepted: Finder detritus in a template')
    except ValueError:
        pass

if failures:
    print('\n'.join(failures))
    raise SystemExit(1)
print('Prepared-prefix recipe gate passed: 5 shipped recipes byte-identical, 34 refusals, manifest writer checks')
