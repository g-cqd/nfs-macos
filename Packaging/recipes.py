"""Load declarative bundle recipes with safe, unique resource destinations."""
import json
from pathlib import Path, PurePosixPath
import re

RECIPE_DIRECTORY = Path(__file__).with_name('Recipes')


def safe_relative(value):
    if not isinstance(value, str) or not value or '\\' in value or '\0' in value:
        raise ValueError('Invalid resource path')
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {'', '.', '..'} for part in value.split('/')):
        raise ValueError('Resource path must be relative without traversal')
    return value


def validate_recipe(recipe):
    if recipe.get('schemaVersion') != 1:
        raise ValueError('Unsupported bundle recipe version')
    for key in ['gameID', 'launcher', 'session']:
        if not isinstance(recipe.get(key), str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]*', recipe[key]):
            raise ValueError('Invalid recipe identifier: ' + key)
    for key in ['displayName', 'bundleIdentifier', 'bundleVersion', 'minimumMacOS', 'category', 'runtimeProfile']:
        if not isinstance(recipe.get(key), str) or not recipe[key]:
            raise ValueError('Missing recipe field: ' + key)
    if '/' in recipe['displayName'] or '\\' in recipe['displayName'] or '\0' in recipe['displayName']:
        raise ValueError('App display name must not contain path separators')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', recipe['bundleIdentifier']):
        raise ValueError('Invalid bundle identifier')
    for key in ['supportsSP', 'supportsMP']:
        if key in recipe and not isinstance(recipe[key], bool):
            raise ValueError('Launch support flags must be Boolean')
    if not isinstance(recipe.get('inputs'), dict) or not recipe['inputs']:
        raise ValueError('Recipe needs input roots')
    for key, value in recipe['inputs'].items():
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', key) or not isinstance(value, str):
            raise ValueError('Invalid recipe input')
    for group in ['compatibility', 'defaults']:
        if not isinstance(recipe.get(group), list):
            raise ValueError('Recipe resource groups must be lists')
        seen = set()
        for item in recipe.get(group, []):
            destination = safe_relative(item['path'])
            source = safe_relative(item['source'])
            if destination.casefold() in seen:
                raise ValueError('Duplicate resource destination: ' + destination)
            seen.add(destination.casefold())
            if item['input'] not in recipe['inputs']:
                raise ValueError('Undeclared resource input: ' + source)
            if 'sha256' in item and not re.fullmatch('[0-9a-f]{64}', item['sha256']):
                raise ValueError('Invalid resource checksum')
    if not isinstance(recipe.get('originalFiles'), list) or not isinstance(recipe.get('originalDirectories'), dict):
        raise ValueError('Recipe needs explicit original file and directory lists')
    for suffixes in recipe['originalDirectories'].values():
        if not isinstance(suffixes, list) or any(not isinstance(s, str) or not re.fullmatch(r'\.[a-z0-9]+', s) for s in suffixes):
            raise ValueError('Directory suffix filters must be lowercase extensions')
    for name in recipe['originalFiles'] + list(recipe['originalDirectories']):
        safe_relative(name)
    originals = [name.casefold() for name in recipe['originalFiles']]
    if len(originals) != len(set(originals)):
        raise ValueError('Duplicate original file')
    directories = [name.casefold().rstrip('/') + '/' for name in recipe['originalDirectories']]
    for index, directory in enumerate(directories):
        if any(directory.startswith(other) or other.startswith(directory) for other in directories[:index]):
            raise ValueError('Original directory selections overlap')
    if any(name.startswith(directory) for name in originals for directory in directories):
        raise ValueError('Original file duplicates a selected directory')
    for item in recipe['compatibility']:
        if item['path'].casefold() in originals:
            raise ValueError('Original and compatibility destinations overlap')
    for path, checksum in recipe['executableHashes'].items():
        if safe_relative(path) not in recipe['originalFiles'] or not re.fullmatch('[0-9a-f]{64}', checksum):
            raise ValueError('Invalid executable pin')
    return recipe


def load_recipe(name='nfsmw', path=None):
    if path is None and not re.fullmatch('[a-z][a-z0-9_-]*', name):
        raise ValueError('Invalid recipe name')
    return validate_recipe(json.loads((Path(path) if path else RECIPE_DIRECTORY / (name + '.json')).read_text()))


def resolve_inputs(recipe, overrides=()):
    project = Path(__file__).resolve().parents[1]
    variables = {'project': str(project), 'tools': str(project.parent),
                 'games': str(project.parent.parent), 'home': str(Path.home())}
    inputs = {name: Path(value.format_map(variables)).expanduser().resolve()
              for name, value in recipe['inputs'].items()}
    for override in overrides:
        name, separator, value = override.partition('=')
        if not separator or name not in inputs or not value:
            raise ValueError('Input override must be a declared NAME=PATH')
        inputs[name] = Path(value).expanduser().resolve()
    return inputs
