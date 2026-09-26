#!/usr/bin/env python3
"""Build, sign, audit and archive either macOS app variant with one command."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-data', choices=['bundled', 'import'], required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--identity', default='-', help='Developer ID Application identity; default is ad-hoc')
    options = parser.parse_args()
    if sys.version_info < (3, 11): parser.error('Python 3.11 or newer is required')
    project = Path(__file__).resolve().parents[1]
    name = 'Need for Speed Most Wanted.app' if options.game_data == 'bundled' else 'Most Wanted Import.app'
    output = (options.output or project/'Build'/name).resolve()
    archive = output.with_suffix('.zip')
    if output.exists() or archive.exists(): parser.error('Choose a new --output path; the previous build is preserved')
    mode = '--with-game-data' if options.game_data == 'bundled' else '--without-game-data'
    commands = [
        ['xcrun', 'swift', 'test'],
        ['xcrun', 'swift', 'build', '-c', 'release', '-Xswiftc', '-warnings-as-errors'],
        ['xcrun', 'swift-format', 'lint', '--strict', '--recursive', 'Sources', 'Tests'],
        [sys.executable, 'Packaging/check_game_data.py'],
        [sys.executable, 'Packaging/check_runtime_optimization.py'],
        [sys.executable, 'Packaging/check_signing_policy.py'],
        [sys.executable, 'Packaging/check_widescreen_compat.py'],
        [sys.executable, 'Packaging/package.py', mode, '--output', str(output)],
        [sys.executable, 'Packaging/sign.py', str(output), '--identity', options.identity],
        [sys.executable, 'Packaging/audit.py', str(output)],
        ['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(output), str(archive)],
    ]
    for command in commands:
        subprocess.run(command, cwd=project, check=True)
    with zipfile.ZipFile(archive) as zipped:
        corrupt = zipped.testzip()
        if corrupt: raise ValueError('Archive verification failed: ' + corrupt)
    with archive.open('rb') as stream: checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    archive.with_suffix('.zip.sha256').write_text(checksum + '  ' + archive.name + '\n')
    print('Built:', output)
    print('Archive:', archive)
    print('SHA-256:', checksum)


if __name__ == '__main__':
    main()
