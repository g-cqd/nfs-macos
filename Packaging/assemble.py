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
from bundle_hygiene import problems_in
from payload import inventory, inventory_digest
from recipes import load_recipe, resolve_inputs, supports_edition
from rosetta_request import build_rosetta_request
from runtime_inputs import (PINS, PROJECT, clone, collect_sources, digest, runtime_provenance,
                            stage_runtime, verify_hashes, verify_inputs)
from shader_cache_key import stage_cache_key


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
    rules = recipe.get('importRules')
    references = bool(recipe.get('referencesInstallation'))
    seeded = references and include_game_data
    if rules is not None or (references and not include_game_data):
        # The player's own installation is recognised on their Mac, either by the import
        # rules at import time or by reference; nothing is inventoried here either way.
        entries = []
    else:
        verify_hashes(inputs['game'], recipe['executableHashes'])
        entries = inventory(inputs['game'], recipe['originalFiles'], recipe['originalDirectories'])
        if 'inventorySHA256' in recipe and inventory_digest(entries) != recipe['inventorySHA256']:
            # A file was changed, added or removed since the verified installation was pinned.
            raise ValueError('The game files do not match the pinned payload inventory')
        if seeded:
            hazards = problems_in(inputs['game'], [entry['path'] for entry in entries])
            if hazards:
                raise ValueError('The game files carry account state or an archive: '
                                 + '; '.join(hazards[:5]))
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
    if rules is not None:
        # Recognition happens on the player's Mac, so the rules are part of the contract.
        manifest['importRules'] = rules
    if references:
        # Without an inventory, the recognition and launch contract is what the version covers.
        # A bundled edition has an inventory, but it still runs through the store client, in a
        # prefix the app creates and seeds itself, so it also records the registration the game's
        # own installer would have written there.
        settings = list(recipe.get('prefixSettings', []))
        if seeded:
            settings += recipe.get('bundledPrefixSettings', [])
        if seeded and 'managedRuntime' in recipe:
            # The app installs this into its own prefix before EA's installer, which needs a .NET runtime.
            declared = recipe['managedRuntime']
            manifest['managedRuntime'] = {'file': declared['path'], 'sha256': declared['sha256'],
                                          'version': declared['version']}
        manifest.update(referencesInstallation=not seeded, storeClient=recipe['storeClient'],
                        runtimeTuning=recipe.get('runtimeTuning', {}),
                        controllerDevices=recipe.get('controllerDevices', []),
                        prefixSettings=settings,
                        renderers=recipe.get('renderers', []))
    # The version identifies the contract, not the edition: both editions of one recipe share it.
    fingerprint = {key: value for key, value in manifest.items()
                   if key not in {'version', 'gameDataIncluded'}}
    manifest['version'] = hashlib.sha256(
        json.dumps(fingerprint, sort_keys=True).encode()).hexdigest()[:24]
    (resources / 'game-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def stage_managed_runtime(resources, recipe, inputs):
    """Ship Wine Mono beside the app's resources, verified against its pin, with its notice.

    Only the bundled edition installs it, into the prefix it owns; an import app runs in the
    player's own prefix and never carries it. The notice names the exact upstream release and
    where its complete source is published, as the component's licences require.
    """
    declared = recipe.get('managedRuntime')
    if declared is None:
        return None
    source = inputs[declared['input']] / declared['source']
    root = inputs[declared['input']]
    if source.is_symlink() or not source.is_file() or not source.resolve().is_relative_to(root.resolve()):
        raise ValueError('Missing or linked managed runtime installer: ' + declared['source'])
    if digest(source) != declared['sha256']:
        raise ValueError('The managed runtime installer does not match its pin')
    clone(source, resources / declared['path'])
    notice = ('Wine Mono ' + declared['version'] + '\n\n'
              'The .NET runtime Wine ships as a free replacement for Microsoft .NET. This app installs it '
              'unchanged into its own Windows folder, because the EA app installer runs a managed '
              'custom action that cannot start without one.\n\n'
              'Installer: ' + declared['path'] + ' (SHA-256 ' + declared['sha256'] + ')\n'
              'Downloaded from: ' + declared['url'] + '\n'
              'Complete corresponding source: ' + declared['sourceURL'] + '\n'
              'Wine Mono is free software made of components under several free licences. Their texts '
              'are in the source release named above, which is the authority for them.\n')
    (resources / 'Licenses').mkdir(exist_ok=True)
    (resources / 'Licenses' / 'wine-mono.txt').write_text(notice)
    return {'version': declared['version'], 'sha256': declared['sha256'], 'url': declared['url'],
            'sourceURL': declared['sourceURL']}


def stage_runtime_source(resources, recipe, inputs):
    """Ship the modified runtime's corresponding source, as the LGPL requires.

    The patches and build description are copied verbatim, and the complete source tree is
    archived at the exact revision that was built, so the package carries the source itself
    and not only a reference to it.
    """
    declared = recipe.get('runtimeSource')
    if declared is None:
        return
    root = inputs[declared['input']] / declared['source']
    patches = sorted((root / 'patches').glob('*.patch'))
    if len(patches) != declared['patchCount']:
        raise ValueError('The runtime source ships %d patches but declares %d'
                         % (len(patches), declared['patchCount']))
    for name in ['BUILD.md', 'NOTICE.md']:
        if not (root / name).is_file():
            raise ValueError('The runtime source is missing ' + name)
    clone(root, resources / 'Sources' / declared['path'])
    tree = inputs['runtimeSourceTree']
    actual = subprocess.check_output(
        ['git', '-C', str(tree), 'rev-parse', 'HEAD'], text=True).strip()
    base = subprocess.check_output(
        ['git', '-C', str(tree), 'rev-parse', declared['baseRevision']], text=True).strip()
    if subprocess.check_output(['git', '-C', str(tree), 'status', '--porcelain'], text=True):
        raise ValueError('The runtime source tree must be clean to archive it')
    if int(subprocess.check_output(
            ['git', '-C', str(tree), 'rev-list', '--count', base + '..' + actual],
            text=True).strip()) != declared['patchCount']:
        raise ValueError('The runtime source tree is not the declared base plus its patches')
    subprocess.run(['git', '-C', str(tree), 'archive', '--format=tar.gz', actual,
                    '-o', str(resources / 'Sources' / declared['archive'])], check=True)


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
        stage_runtime_source(resources, recipe, inputs)
        managed = stage_managed_runtime(resources, recipe, inputs) if include_game_data else None
        stage_cache_key(resources, recipe, inputs, PINS['sources']['mtld3d']['revision'])
        provenance = runtime_provenance(recipe, revisions)
        if managed:
            provenance['managedRuntime'] = managed
        stage_metadata(contents, recipe, provenance, include_game_data)
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
