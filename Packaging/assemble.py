"""Compose validated input, runtime, payload, defaults and metadata stages into a new app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid
from payload import inventory
from recipes import load_recipe, resolve_inputs, supports_edition
from rosetta_request import build_rosetta_request
from runtime_inputs import (PROJECT, clone, collect_sources, digest, runtime_provenance,
                            stage_runtime, verify_hashes, verify_inputs)


def stage_resources(items, inputs, destination):
    for item in items:
        source = inputs[item['input']] / item['source']
        root = inputs[item['input']]
        if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(root.resolve()):
            raise ValueError('Missing or linked resource: ' + item['path'])
        if 'sha256' in item and digest(source) != item['sha256']:
            raise ValueError('Resource checksum mismatch: ' + item['path'])
        clone(source, destination / item['path'])


def stage_game(resources, recipe, inputs, include_game_data):
    if include_game_data and not supports_edition(recipe, 'bundled'):
        raise ValueError('This recipe supports the import edition only; no game files are packaged')
    references = bool(recipe.get('referencesInstallation'))
    if references:
        # The player's own installation is recognised on their Mac; nothing is inventoried here.
        entries = []
    else:
        verify_hashes(inputs['game'], recipe['executableHashes'])
        entries = inventory(inputs['game'], recipe['originalFiles'], recipe['originalDirectories'])
    game = resources / 'Game'
    game.mkdir()
    if include_game_data:
        for entry in entries:
            clone(inputs['game'] / entry['path'], game / entry['path'])
    stage_resources(recipe['compatibility'], inputs, game)
    originals = {entry['path'].casefold() for entry in entries}
    for item in recipe['compatibility']:
        if item['path'].casefold() in originals:
            raise ValueError('Compatibility file overwrites original data')
        path = game / item['path']
        entries.append({'path': item['path'], 'size': path.stat().st_size, 'sha256': digest(path)})
    entries.sort(key=lambda entry: entry['path'])
    manifest = {'version': '', 'gameID': recipe['gameID'], 'gameFiles': entries,
                'gameDataIncluded': include_game_data,
                'compatibilityFiles': [item['path'] for item in recipe['compatibility']],
                'supportsSP': recipe.get('supportsSP', True), 'supportsMP': recipe.get('supportsMP', False)}
    if references:
        # Without an inventory, the recognition and launch contract is what the version covers.
        manifest.update(referencesInstallation=True, storeClient=recipe['storeClient'],
                        runtimeTuning=recipe.get('runtimeTuning', {}),
                        controllerDevices=recipe.get('controllerDevices', []))
    # The version identifies the contract, not the edition: both editions of one recipe share it.
    fingerprint = {key: value for key, value in manifest.items()
                   if key not in {'version', 'gameDataIncluded'}}
    manifest['version'] = hashlib.sha256(
        json.dumps(fingerprint, sort_keys=True).encode()).hexdigest()[:24]
    (resources / 'game-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def stage_metadata(contents, recipe, provenance, include_game_data):
    resources = contents / 'Resources'
    provenance.update(gameID=recipe['gameID'], gameDataIncluded=include_game_data)
    (resources / 'runtime-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    info = {'CFBundleExecutable': recipe['launcher'], 'CFBundleIdentifier': recipe['bundleIdentifier'],
            'CFBundleName': recipe['displayName'], 'CFBundleDisplayName': recipe['displayName'],
            'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0',
            'CFBundleVersion': recipe['bundleVersion'], 'LSMinimumSystemVersion': recipe['minimumMacOS'],
            'LSArchitecturePriority': ['arm64'], 'NSHighResolutionCapable': True, 'LSSupportsGameMode': True,
            'LSApplicationCategoryType': recipe['category'],
            'NSHumanReadableCopyright': 'Unofficial local macOS package. Component notices are included.'}
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    (resources / 'bundle-recipe.json').write_text(json.dumps(recipe, indent=2) + '\n')


def assemble(recipe, inputs, destination, include_game_data):
    destination = destination.resolve()
    if destination.suffix != '.app' or destination.exists():
        raise ValueError('Choose a new output .app; existing builds are preserved')
    verify_inputs(recipe, inputs)
    binary_dir = Path(subprocess.check_output(
        ['xcrun', 'swift', 'build', '-c', 'release', '--show-bin-path'], cwd=PROJECT, text=True).strip())
    for name in [recipe['launcher'], recipe['session']]:
        if not (binary_dir / name).is_file():
            raise ValueError('Build the recipe executable first: ' + name)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.bundle-', dir=destination.parent))
    token = str(uuid.uuid4())
    marker = temporary / 'owner'
    marker.write_text(token)
    app = temporary / destination.name
    try:
        contents = app / 'Contents'
        resources = contents / 'Resources'
        resources.mkdir(parents=True)
        clone(binary_dir / recipe['launcher'], contents / 'MacOS' / recipe['launcher'])
        clone(binary_dir / recipe['session'], contents / 'Helpers' / recipe['session'])
        build_rosetta_request(app, recipe['bundleIdentifier'])
        optimization = stage_runtime(contents, recipe, inputs)
        (resources / 'size-optimization.json').write_text(json.dumps(optimization, indent=2) + '\n')
        manifest = stage_game(resources, recipe, inputs, include_game_data)
        stage_resources(recipe['defaults'], inputs, resources / 'Defaults')
        revisions = collect_sources(resources, inputs)
        stage_metadata(contents, recipe, runtime_provenance(recipe, revisions), include_game_data)
        if destination.exists():
            raise FileExistsError('Output appeared during assembly; preserving it')
        app.rename(destination)
        return {'app': str(destination), 'gameFiles': len(manifest['gameFiles']),
                'gameBytes': sum(item['size'] for item in manifest['gameFiles']), 'version': manifest['version']}
    finally:
        if marker.is_file() and marker.read_text() == token:
            shutil.rmtree(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', default='nfsmw', help='Recipe name under Packaging/Recipes')
    parser.add_argument('--recipe', type=Path, help='Alternative validated JSON recipe')
    parser.add_argument('--input', action='append', default=[], metavar='NAME=PATH')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--without-game-data', action='store_true')
    modes.add_argument('--with-game-data', action='store_true')
    parser.add_argument('--output', type=Path)
    options = parser.parse_args()
    if sys.version_info < (3, 11):
        parser.error('Python 3.11 or newer is required')
    recipe = load_recipe(options.game, options.recipe)
    inputs = resolve_inputs(recipe, options.input)
    output = options.output or PROJECT / 'Build' / (recipe['displayName'] + '.app')
    print(json.dumps(assemble(recipe, inputs, output, not options.without_game_data)))


if __name__ == '__main__':
    main()
