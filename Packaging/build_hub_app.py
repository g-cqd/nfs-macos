#!/usr/bin/env python3
"""Build the Game Hub app (GameHub.app) into the data store with one command.

The data store is --data-store, else the one in ~/Library/Application Support/GameHub/settings.json,
else the default of HubSettings. The app lands in <data store>/Apps/GameHub.app; SwiftPM keeps its
intermediates in <data store>/Build/swiftpm. The previous app is kept as GameHub.previous.app.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
SETTINGS_FILE = Path.home() / 'Library/Application Support/GameHub/settings.json'
BUNDLE_ID = 'local.gamehub.mac'
RENAME_SWAP, RENAME_EXCL = 0x2, 0x4


def default_data_store():
    """The default of HubSettings, read from its source so the path is written in one place."""
    source = (PROJECT / 'Sources/HubCore/Settings/HubSettings.swift').read_text()
    found = re.search(r'defaultDataStoreRoot\s*=\s*"(/[^"]+)"', source)
    if not found: raise SystemExit('Cannot find defaultDataStoreRoot in HubSettings.swift')
    return found.group(1)


def is_normalised(path):
    """Absolute, no ".", ".." or empty component, no trailing slash, no NUL (as the app checks)."""
    if not path.startswith('/') or '\0' in path: return False
    return path == '/' or all(part not in ('', '.', '..') for part in path[1:].split('/'))


def settings_data_store():
    """The dataStoreRoot of settings.json, validated as strictly as the app does."""
    if SETTINGS_FILE.is_symlink() or not SETTINGS_FILE.is_file():
        raise SystemExit(f'{SETTINGS_FILE} is not a regular file; refusing to read it.')
    try:
        settings = json.loads(SETTINGS_FILE.read_text())
    except ValueError as error:
        raise SystemExit(f'Cannot read {SETTINGS_FILE}: {error}')
    keys = {'schemaVersion', 'dataStoreRoot', 'runtimeApp'}
    if not isinstance(settings, dict) or set(settings) != keys:
        raise SystemExit(f'{SETTINGS_FILE} must hold exactly these keys: {", ".join(sorted(keys))}')
    root, app = settings['dataStoreRoot'], settings['runtimeApp']
    if settings['schemaVersion'] != 1 or isinstance(settings['schemaVersion'], bool):
        raise SystemExit(f'{SETTINGS_FILE}: schemaVersion must be 1')
    if not (isinstance(root, str) and is_normalised(root) and root != '/'):
        raise SystemExit(f'{SETTINGS_FILE}: dataStoreRoot must be an absolute, normalised path')
    if not (isinstance(app, str) and is_normalised(app) and app.endswith('.app')):
        raise SystemExit(f'{SETTINGS_FILE}: runtimeApp must be an absolute path to an .app bundle')
    return Path(root)


def resolve_data_store(option):
    """--data-store, else settings.json, else the default."""
    if option: return Path(option)
    if SETTINGS_FILE.exists() or SETTINGS_FILE.is_symlink(): return settings_data_store()
    return Path(default_data_store())


def require_mounted(root):
    """Refuses a data store whose drive is not connected; nothing is written before this."""
    if not is_normalised(str(root)) or str(root) == '/':
        raise SystemExit(f'The data store path must be absolute and normalised: {root}')
    parts = root.parts
    if len(parts) > 2 and parts[1] == 'Volumes':
        volume = Path('/Volumes') / parts[2]
        if not os.path.ismount(volume):
            raise SystemExit(f'The drive {volume} is not mounted; connect it and run this again.')
    if not root.is_dir():
        raise SystemExit(f'The data store folder does not exist: {root}')
    if not os.access(root, os.W_OK):
        raise SystemExit(f'The data store folder is not writable: {root}')


def minimum_system_version():
    """The macOS floor of Package.swift (.macOS(.v15) gives 15.0)."""
    manifest = (PROJECT / 'Package.swift').read_text()
    found = re.search(r'platforms:\s*\[\s*\.macOS\(\.v(\d+)(?:_(\d+))?\)', manifest)
    if not found: raise SystemExit('Cannot read the macOS platform from Package.swift')
    return f'{found.group(1)}.{found.group(2) or 0}'


def revision():
    result = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=PROJECT,
                            capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 and result.stdout.strip() else '1'


def swift_build(scratch, product):
    """Builds `product` in release and returns the path of its executable."""
    base = ['xcrun', 'swift', 'build', '-c', 'release', '--scratch-path', str(scratch)]
    subprocess.run(base + ['--product', product], cwd=PROJECT, check=True)
    shown = subprocess.run(base + ['--show-bin-path'], cwd=PROJECT, check=True,
                           capture_output=True, text=True)
    binary = Path(shown.stdout.strip().splitlines()[-1]) / product
    if not binary.is_file(): raise SystemExit(f'The build did not produce {binary}')
    return binary


def info_plist(floor):
    return {
        'CFBundleIdentifier': BUNDLE_ID,
        'CFBundleExecutable': 'GameHub',
        'CFBundleName': 'Game Hub',
        'CFBundleDisplayName': 'Game Hub',
        'CFBundlePackageType': 'APPL',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleShortVersionString': '1.0',
        'CFBundleVersion': revision(),
        'LSMinimumSystemVersion': floor,
        'LSApplicationCategoryType': 'public.app-category.utilities',
        'NSPrincipalClass': 'NSApplication',
        'NSHighResolutionCapable': True,
    }


def assemble(staging, gamehub, cli, floor):
    """Lays out Contents/{Info.plist,MacOS/GameHub,Helpers/gamehub-cli} in `staging`."""
    (staging / 'Contents/MacOS').mkdir(parents=True)
    (staging / 'Contents/Helpers').mkdir()
    with (staging / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump(info_plist(floor), stream)
    shutil.copy2(gamehub, staging / 'Contents/MacOS/GameHub')
    shutil.copy2(cli, staging / 'Contents/Helpers/gamehub-cli')


def sign(staging):
    """Ad-hoc signs the helper, then the app, and verifies the result."""
    codesign = ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none']
    subprocess.run(codesign + ['--identifier', BUNDLE_ID + '.cli',
                               str(staging / 'Contents/Helpers/gamehub-cli')], check=True)
    subprocess.run(codesign + ['--identifier', BUNDLE_ID, str(staging)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2',
                    str(staging)], check=True)


def rename_np(source, destination, flags):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renamex_np(os.fsencode(source), os.fsencode(destination), flags) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), f'{source} -> {destination}')


def install(staging, apps):
    """Puts `staging` at Apps/GameHub.app. An existing app is swapped out in one atomic step
    (renamex_np RENAME_SWAP) and kept as GameHub.previous.app, replacing an older previous."""
    app, previous = apps / 'GameHub.app', apps / 'GameHub.previous.app'
    if not app.exists():
        rename_np(staging, app, RENAME_EXCL)
        return None
    rename_np(staging, app, RENAME_SWAP)  # app is the new build; staging now holds the old one
    if previous.exists(): shutil.rmtree(previous)
    os.rename(staging, previous)
    return previous


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--data-store', metavar='PATH',
                        help='Data store folder; default: settings.json, else the HubSettings default')
    options = parser.parse_args()
    if sys.version_info < (3, 11): parser.error('Python 3.11 or newer is required')

    root = resolve_data_store(options.data_store)
    require_mounted(root)
    apps, scratch = root / 'Apps', root / 'Build/swiftpm'
    apps.mkdir(exist_ok=True)
    scratch.mkdir(parents=True, exist_ok=True)
    print('Data store:', root)

    gamehub = swift_build(scratch, 'GameHub')
    cli = swift_build(scratch, 'gamehub-cli')

    staging = apps / f'.GameHub.staging-{os.getpid()}.app'
    if staging.exists(): shutil.rmtree(staging)
    try:
        assemble(staging, gamehub, cli, minimum_system_version())
        sign(staging)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)  # nothing was installed yet
        raise
    previous = install(staging, apps)
    app = apps / 'GameHub.app'
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('Built:', app)
    if previous: print('Previous kept:', previous)


if __name__ == '__main__':
    main()
