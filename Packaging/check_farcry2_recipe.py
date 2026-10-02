"""Far Cry 2 is an import-only recipe: it recognises the player's installation and ships no game bytes."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from assemble import stage_game
from recipes import load_recipe, supports_edition, validate_import_rules, validate_recipe

PROJECT = Path(__file__).resolve().parents[1]
recipe = load_recipe('farcry2')
assert recipe['gameID'] == 'farcry2' and recipe['launcher'] == 'FarCry2Launcher'
assert recipe['session'] == 'FarCry2Session'
assert recipe['editions'] == ['import'] and supports_edition(recipe, 'import')
assert not supports_edition(recipe, 'bundled')
assert recipe['executableHashes'] == {} and recipe['originalFiles'] == [] and recipe['originalDirectories'] == {}
rules = recipe['importRules']
assert rules['executable'] == 'bin/FarCry2.exe' and rules['machine'] == 'i386'
assert rules['knownBuilds'] == [], 'no digest may be pinned before a legitimate install is hashed'
assert [item['path'] for item in recipe['compatibility']] == ['bin/mtld3d.conf'], \
    'the renderer configuration must sit next to the executable in bin'
assert recipe['supportsSP'] is True and recipe['supportsMP'] is False

# Invalid recipes are rejected; each mutation breaks exactly one rule.
mutations = {
    'bundled edition without pinned hashes': lambda r: r.update(editions=['bundled', 'import']),
    'unknown edition': lambda r: r.update(editions=['import', 'download']),
    'duplicate edition': lambda r: r.update(editions=['import', 'import']),
    'empty editions': lambda r: r.update(editions=[]),
    'original files beside rules': lambda r: r.update(originalFiles=['bin/FarCry2.exe']),
    'import-only without rules': lambda r: r.pop('importRules'),
    'executable traversal': lambda r: r['importRules'].update(executable='../FarCry2.exe'),
    'executable not required': lambda r: r['importRules'].update(executable='bin/Other.exe'),
    'wrong machine': lambda r: r['importRules'].update(machine='arm64'),
    'required outside directories': lambda r: r['importRules']['required'].append(
        {'path': 'docs/readme.txt', 'minimumSize': 1}),
    'uppercase suffix': lambda r: r['importRules']['directories'][0]['excludedSuffixes'].append('.LOG'),
    'path in exclusion': lambda r: r['importRules']['directories'][0]['excludedNames'].append('a/b'),
    'duplicate directory': lambda r: r['importRules']['directories'].append(
        dict(r['importRules']['directories'][0], path='BIN')),
    'pairing directory only resembles a root': lambda r: r['importRules']['pairings'][0].update(
        directory='Data_Win32x'),
    'bad pairing suffix': lambda r: r['importRules']['pairings'][0].update(primarySuffix='fat'),
    'marker with path': lambda r: r['importRules']['markers'][0]['patterns'].append('a/b'),
    'malformed digest': lambda r: r['importRules']['knownBuilds'].append(
        {'name': 'x', 'executableSHA256': 'abc'}),
    'negative limit': lambda r: r['importRules'].update(maximumFiles=0),
    'compatibility traversal': lambda r: r['compatibility'][0].update(path='../mtld3d.conf'),
}
for name, change in mutations.items():
    altered = deepcopy(recipe)
    change(altered)
    try: validate_recipe(altered)
    except ValueError: pass
    else: raise AssertionError('Accepted invalid recipe: ' + name)
validate_import_rules(rules)

# A recipe that pins hashes and lists its files may offer a bundled edition; the existing games do.
for name in ['nfsmw', 'cod4']:
    other = load_recipe(name)
    assert supports_edition(other, 'bundled') and supports_edition(other, 'import')
    assert 'importRules' not in other

# Import assembly: compatibility files only, the rules travel in the manifest, nothing else is copied.
with TemporaryDirectory() as temporary:
    root = Path(temporary)
    packaging = root / 'packaging'
    (packaging / 'FarCry2Defaults').mkdir(parents=True)
    config = (PROJECT / 'Packaging/FarCry2Defaults/mtld3d.conf').read_bytes()
    (packaging / 'FarCry2Defaults/mtld3d.conf').write_bytes(config)
    inputs = {'packaging': packaging}
    resources = root / 'resources'
    resources.mkdir()
    manifest = stage_game(resources, recipe, inputs, False)
    assert manifest['gameDataIncluded'] is False
    assert manifest['importRules'] == rules
    assert manifest['gameFiles'] == [{'path': 'bin/mtld3d.conf', 'size': len(config),
                                      'sha256': hashlib.sha256(config).hexdigest()}]
    assert manifest['compatibilityFiles'] == ['bin/mtld3d.conf']
    assert {p.relative_to(resources / 'Game').as_posix() for p in (resources / 'Game').rglob('*') if p.is_file()} \
        == {'bin/mtld3d.conf'}
    assert json.loads((resources / 'game-manifest.json').read_text()) == manifest
    # The recognition rules are part of the version, so a rule change is a new generation key.
    changed = deepcopy(recipe)
    changed['importRules']['directories'][1]['minimumBytes'] += 1
    again = root / 'again'
    again.mkdir()
    assert stage_game(again, changed, inputs, False)['version'] != manifest['version']
    # Bundling is refused even if a caller asks for it directly.
    refused = root / 'refused'
    refused.mkdir()
    try: stage_game(refused, recipe, inputs, True)
    except ValueError as error: assert 'import edition only' in str(error)
    else: raise AssertionError('A bundled Far Cry 2 assembly was accepted')
    assert not (refused / 'Game').exists(), 'refusal must happen before anything is staged'

# The command-line entry point refuses the bundled edition before any build step starts.
result = subprocess.run([sys.executable, str(PROJECT / 'Packaging/build.py'), '--game', 'farcry2',
                         '--game-data', 'bundled', '--output', '/nonexistent/Far Cry 2.app'],
                        capture_output=True, text=True, cwd=PROJECT)
assert result.returncode == 2 and 'supports only: import' in result.stderr, result.stderr

# Privacy gate: no game file, archive or executable may ever be tracked or packaged from this tree.
forbidden_names = {'farcry2.exe', 'dunia.dll', 'farcry2_game.dll'}
forbidden_suffixes = {'.fat', '.sbao', '.xbg'}
skipped = {'.build', '.git', 'Build', 'Evidence', '__pycache__'}
offenders = []
for path in PROJECT.rglob('*'):
    if any(part in skipped for part in path.relative_to(PROJECT).parts) or not path.is_file():
        continue
    if path.name.lower() in forbidden_names or path.suffix.lower() in forbidden_suffixes:
        offenders.append(str(path.relative_to(PROJECT)))
assert not offenders, offenders

defaults = (PROJECT / 'Packaging/FarCry2Defaults/mtld3d.conf').read_text()
assert 'shader.asyncCompile = false' in defaults and 'render.scale = 1' in defaults
assert 'present.maxFps = 0' in defaults
assert (PROJECT / 'Packaging/FarCry2Defaults/settings.reg').read_text() == \
    (PROJECT / 'Packaging/CoD4Defaults/settings.reg').read_text()
print('Far Cry 2 import-only recipe regressions passed')
