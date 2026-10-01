#!/usr/bin/env python3
"""Build, sign, audit and archive either macOS app variant with one command."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys
import zipfile
from recipes import load_recipe, supports_edition


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', default='nfsmw', help='Recipe name under Packaging/Recipes')
    parser.add_argument('--recipe', type=Path, help='Alternative validated JSON recipe')
    parser.add_argument('--input', action='append', default=[], metavar='NAME=PATH')
    parser.add_argument('--game-data', choices=['bundled', 'import'], required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--identity', default='-', help='Developer ID Application identity; default is ad-hoc')
    parser.add_argument('--no-archive', action='store_true', help='Deliver the audited app without allocating a ZIP')
    options = parser.parse_args()
    if sys.version_info < (3, 11): parser.error('Python 3.11 or newer is required')
    project = Path(__file__).resolve().parents[1]
    recipe = load_recipe(options.game, options.recipe)
    if not supports_edition(recipe, options.game_data):
        parser.error('The ' + recipe['displayName'] + ' recipe supports only: '
                     + ', '.join(recipe.get('editions', ['bundled', 'import'])))
    name = recipe['displayName'] + (' Bundled.app' if options.game_data == 'bundled' else ' Import.app')
    output = (options.output or project/'Build'/name).resolve()
    archive = output.with_suffix('.zip')
    if output.exists() or archive.exists(): parser.error('Choose a new --output path; the previous build is preserved')
    mode = '--with-game-data' if options.game_data == 'bundled' else '--without-game-data'
    assembly = [sys.executable, 'Packaging/package.py', '--game', options.game, mode, '--output', str(output)]
    if options.recipe: assembly += ['--recipe', str(options.recipe.resolve())]
    for value in options.input: assembly += ['--input', value]
    commands = [
        ['xcrun', 'swift', 'test'],
        ['xcrun', 'swift', 'build', '-c', 'release', '-Xswiftc', '-warnings-as-errors'],
        ['xcrun', 'swift-format', 'lint', '--strict', '--recursive', 'Sources', 'Tests'],
        [sys.executable, 'Packaging/check_game_data.py'],
        [sys.executable, 'Packaging/check_cod4_data.py'],
        [sys.executable, 'Packaging/check_recipes.py'],
        [sys.executable, 'Packaging/check_nfs2015_recipe.py'],
        [sys.executable, 'Packaging/check_runtime_inputs.py'],
        [sys.executable, 'Packaging/check_assembly.py'],
        [sys.executable, 'Packaging/check_runtime_optimization.py'],
        [sys.executable, 'Packaging/check_signing_policy.py'],
        [sys.executable, 'Packaging/check_widescreen_compat.py'],
        assembly,
        [sys.executable, 'Packaging/sign.py', str(output), '--identity', options.identity],
        [sys.executable, 'Packaging/audit.py', str(output)],
    ]
    for command in commands:
        subprocess.run(command, cwd=project, check=True)
    if options.no_archive:
        print('Built and audited:', output)
        return
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(output), str(archive)], check=True)
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
