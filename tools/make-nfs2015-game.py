#!/usr/bin/env python3
"""Make the standalone copy of the pinned Need for Speed (2015) payload that the recipe's `game` input names.

    tools/make-nfs2015-game.py --source <installed game folder> --destination <new folder>

The destination is an APFS clone (copy on write, so it costs almost no disk) of exactly the files the
recipe lists and nothing beside them: the `.dxvk-cache` and anything else that a used prefix leaves next to
the game stay behind. The recipe's own pins are checked on the source before anything is copied and on the
result afterwards: every executable hash and the inventory digest. File modes and times are kept as in the
installation, because the app clones them into the player's prefix and EA's updater must be able to write
there; only the folders are made read-only. Nothing in the source is changed.
"""
import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Packaging'))
from payload import inventory, inventory_digest  # noqa: E402
from recipes import load_recipe  # noqa: E402
from runtime_inputs import verify_hashes  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    options = parser.parse_args()
    recipe = load_recipe('nfs2015')
    source, destination = options.source.resolve(), options.destination.resolve()
    if destination.exists():
        parser.error('the destination already exists; a standalone copy is never overwritten')
    entries = inventory(source, recipe['originalFiles'], recipe['originalDirectories'])
    if inventory_digest(entries) != recipe['inventorySHA256']:
        parser.error('the source does not match the recipe\'s pinned payload inventory')
    destination.mkdir(parents=True)
    for entry in entries:
        target = destination / entry['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/bin/cp', '-c', '-p', str(source / entry['path']), str(target)], check=True)
    copied = inventory(destination, recipe['originalFiles'], recipe['originalDirectories'])
    if copied != entries:
        raise SystemExit('the copy differs from the source inventory')
    verify_hashes(destination, recipe['executableHashes'])
    listed = {entry['path'] for entry in entries}
    extra = sorted(path.relative_to(destination).as_posix() for path in destination.rglob('*')
                   if path.is_file() and path.relative_to(destination).as_posix() not in listed)
    if extra:
        raise SystemExit('the copy holds files the recipe does not list: ' + ', '.join(extra[:5]))
    for folder in sorted((path for path in destination.rglob('*') if path.is_dir()), reverse=True):
        folder.chmod(0o555)
    destination.chmod(0o555)
    print('%d files, %d bytes, inventory %s' % (len(entries), sum(e['size'] for e in entries),
                                                inventory_digest(copied)))


main()
