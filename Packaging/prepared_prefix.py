#!/usr/bin/env python3
"""Describe a prepared Windows prefix that an app ships whole (recipe key `prefixSeed`).

Battlefield 3's app carries the prefix its bring-up produced: the EA app, Wine Gecko, the
ShellWindows stand-in, the protocol and Game Explorer registrations, the game-folder d3d11 proxy
and the game. This module scans that template inside an assembled app and writes the
`game-manifest.json` the native session reads (`PreparedPrefixGame` in LauncherCore): every
file by size and SHA-256, the empty folders, Wine's own extended attributes (DOS attributes and
reparse points, which signing would otherwise clear) and Wine's two drive links, which cannot be
signed inside an app and are recreated by the session.

    prepared_prefix.py scan <template> <scan.json>
    prepared_prefix.py manifest <recipe-name> <scan.json> <game-manifest.json>
    prepared_prefix.py pins <recipe.json> <scan.json>
    prepared_prefix.py finish <app> <recipe-name> <scan.json> <build-folder> <sources-app>

`finish` completes an app whose payload is already in place (the template in
Contents/Resources/<path>, the runtime in Contents/SharedSupport/Wine and the sidecar in
Contents/Helpers, moved there from the bring-up folder): the native starter and helper from a
release build folder, the Rosetta request helper, Info.plist, the shipped recipe, the game
manifest, the pinned licences, and the Wine corresponding source and notices cloned from an
app built on the same runtime. Signing is `sign.py`, as for every app.
"""
import base64
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from payload import inventory_digest
from recipes import load_recipe, validate_recipe

LIBC = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
XATTR_NOFOLLOW = 0x0001
# The only extended attributes Wine's file layer reads; the Swift side accepts no others.
WINE_ATTRIBUTES = ('user.DOSATTRIB', 'user.WINEREPARSE')
# Wine's drive links: kept out of the signed app and recreated by the session.
DRIVE_LINKS = [{'path': 'dosdevices/c:', 'target': '../drive_c'},
               {'path': 'dosdevices/z:', 'target': '/'}]
# Finder state and other detritus never belongs to a template.
DETRITUS = {'.DS_Store'}


def _attributes(path):
    """Wine's own extended attributes of one path, without following a link."""
    found = {}
    encoded = os.fsencode(path)
    for name in WINE_ATTRIBUTES:
        size = LIBC.getxattr(encoded, name.encode(), None, 0, 0, XATTR_NOFOLLOW)
        if size < 0:
            continue
        buffer = ctypes.create_string_buffer(size)
        if LIBC.getxattr(encoded, name.encode(), buffer, size, 0, XATTR_NOFOLLOW) != size:
            raise OSError('Could not read ' + name + ' of ' + str(path))
        found[name] = base64.b64encode(buffer.raw).decode()
    return found


def scan(root):
    """Every file with size and SHA-256, the empty folders and Wine's attributes, in path order.

    Refuses links and special files: the template must be plain files and folders only.
    """
    root = Path(root)
    files, empty, attributes = [], [], []
    for directory, folders, names in os.walk(root):
        folders.sort()
        here = Path(directory)
        relative_dir = here.relative_to(root).as_posix()
        for name in sorted(names + folders):
            path = here / name
            relative = path.relative_to(root).as_posix()
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                raise ValueError('The template must not hold links: ' + relative)
            if name in DETRITUS:
                raise ValueError('Remove Finder detritus first: ' + relative)
            for attribute, value in _attributes(path).items():
                attributes.append({'path': relative, 'name': attribute, 'value': value})
            if stat.S_ISREG(mode):
                digest = hashlib.sha256()
                with path.open('rb') as stream:
                    for chunk in iter(lambda: stream.read(4 << 20), b''):
                        digest.update(chunk)
                files.append({'path': relative, 'size': path.stat().st_size,
                              'sha256': digest.hexdigest()})
            elif not stat.S_ISDIR(mode):
                raise ValueError('The template must hold only files and folders: ' + relative)
        if not names and not folders and relative_dir != '.':
            empty.append(relative_dir)
    files.sort(key=lambda entry: entry['path'])
    return {'files': files, 'emptyDirectories': sorted(empty), 'attributes': attributes}


def game_inventory(recipe, scanned):
    """The game folder's entries, relative to the game folder, as the inventory pin covers them."""
    root = 'drive_c/' + recipe['storeClient']['gameRoot'] + '/'
    return [{**entry, 'path': entry['path'][len(root):]}
            for entry in scanned['files'] if entry['path'].startswith(root)]


def pins(recipe, scanned):
    """The executable digests and the game inventory digest the recipe must pin."""
    game = {entry['path']: entry for entry in game_inventory(recipe, scanned)}
    hashes = {path: game[path]['sha256'] for path in recipe['executableHashes'] if path in game}
    return hashes, inventory_digest(game.values())


def manifest(recipe, scanned):
    """The `game-manifest.json` of a prepared-prefix app; refuses a template the pins disagree with."""
    validate_recipe(recipe)
    seed = recipe['prefixSeed']
    hashes, digest = pins(recipe, scanned)
    if hashes != recipe['executableHashes'] or digest != recipe['inventorySHA256']:
        raise ValueError('The template does not match the recipe pins')
    shims = {entry['path']: entry['sha256'] for entry in game_inventory(recipe, scanned)}
    for shim in recipe['gameShims']:
        if shims.get(shim['path']) != shim['sha256']:
            raise ValueError('Game-folder file differs from its pin: ' + shim['path'])
    client = recipe['storeClient']
    content = json.dumps(scanned, sort_keys=True, separators=(',', ':')).encode()
    version = hashlib.sha256(content + json.dumps(recipe, sort_keys=True).encode()).hexdigest()[:24]
    return {
        'version': version,
        'gameID': recipe['gameID'],
        'prefix': {'path': seed['path'], 'files': scanned['files'],
                   'emptyDirectories': scanned['emptyDirectories'], 'links': DRIVE_LINKS,
                   'attributes': scanned['attributes']},
        'storeClient': {key: client[key] for key in [
            'name', 'installRoot', 'clientExecutable', 'clientArguments', 'gameRoot',
            'launchChain', 'leaseTarget']},
        'storeBrowser': recipe['storeBrowser'],
        'renderers': recipe['renderers'],
        'runtimeTuning': recipe.get('runtimeTuning', {}),
        'settingsProfile': seed['settingsProfile'],
        'presets': recipe['presets'],
        'prefixRegistry': recipe['prefixRegistry'],
        'gameShims': recipe['gameShims'],
        'backgroundPrograms': seed['backgroundPrograms'],
    }


def finish(app, recipe, scanned, build, sources_app):
    """Everything but the payload and the signature; see the module documentation."""
    import shutil
    import subprocess
    from assemble import stage_metadata, stage_third_party_licenses
    from rosetta_request import build_rosetta_request
    contents = Path(app) / 'Contents'
    resources = contents / 'Resources'
    for name, folder in [(recipe['launcher'], 'MacOS'), (recipe['session'], 'Helpers')]:
        (contents / folder).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(build) / name, contents / folder / name)
        (contents / folder / name).chmod(0o755)
    build_rosetta_request(Path(app), recipe['bundleIdentifier'])
    retained = Path(sources_app) / 'Contents/Resources'
    for folder in ['Licenses', 'Sources']:
        for item in sorted((retained / folder).iterdir()):
            target = resources / folder / item.name
            if item.name == 'launcher-source.tar.gz' or target.exists():
                continue
            # A clone on one APFS volume: the corresponding source of the same runtime build.
            subprocess.run(['/bin/cp', '-cR', str(item), str(target)], check=True)
    provenance = json.loads((retained / 'runtime-provenance.json').read_text())
    for key in ['clientLayer', 'managedRuntime', 'gameExecutableHashes', 'rendererSelection']:
        provenance.pop(key, None)
    provenance.update(
        runtimeProfile=recipe['runtimeProfile'],
        wine='wine-11.0 (CrossOver 26.3 base, athei/wine cx-26-patched 1a7b0c76 plus ten patches: '
             'the wine-0010 build of the NFS apps) with the 32- and 64-bit dsound.dll of wine-0011 '
             '(the dsound resampler change, Sources/wine-0011-dsound)',
        rendererSelection=recipe['renderers'], gameExecutableHashes=recipe['executableHashes'],
        storeClient={'name': recipe['storeClient']['name'], 'location': 'inside the prepared prefix',
                     'accountState': 'none: the player signs in'},
        preparedPrefix={'files': len(scanned['files']),
                        'bytes': sum(entry['size'] for entry in scanned['files']),
                        'reason': recipe['prefixSeed']['reason']},
        storeBrowser={'name': recipe['storeBrowser']['name'],
                      'userAgent': recipe['storeBrowser']['userAgent'],
                      'browsers': recipe['storeBrowser']['browsers']},
        gameShims=recipe['gameShims'], prefixRegistry=recipe['prefixRegistry'])
    stage_metadata(contents, recipe, provenance, True)
    stage_third_party_licenses(resources, recipe)
    (resources / 'game-manifest.json').write_text(json.dumps(manifest(recipe, scanned), indent=1) + '\n')


def main(arguments):
    if len(arguments) == 3 and arguments[0] == 'scan':
        Path(arguments[2]).write_text(json.dumps(scan(arguments[1])) + '\n')
    elif len(arguments) == 4 and arguments[0] == 'manifest':
        scanned = json.loads(Path(arguments[2]).read_text())
        Path(arguments[3]).write_text(
            json.dumps(manifest(load_recipe(arguments[1]), scanned), indent=1) + '\n')
    elif len(arguments) == 3 and arguments[0] == 'pins':
        hashes, digest = pins(json.loads(Path(arguments[1]).read_text()),
                              json.loads(Path(arguments[2]).read_text()))
        print(json.dumps({'executableHashes': hashes, 'inventorySHA256': digest}, indent=2))
    elif len(arguments) == 6 and arguments[0] == 'finish':
        finish(arguments[1], load_recipe(arguments[2]), json.loads(Path(arguments[3]).read_text()),
               arguments[4], arguments[5])
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
