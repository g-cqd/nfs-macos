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


EDITIONS = {'bundled', 'import'}
CAPABILITIES = {'trapFlagEmulation', 'd3dmetalDXGI', 'vulkanDXGI', 'x87Sidecar'}
RENDERER_APIS = {'d3d8', 'd3d9', 'd3d10core', 'd3d11', 'dxgi'}
# A backend measured to break a game, with the reason, so no recipe can select it for that game.
DENIED_BACKENDS = {
    'nfs2015': {'gptk': 'D3DMetal does not implement the D3D11 timestamp queries this engine uses'},
}
GUEST_PATH = re.compile(r'[^/\\\x00]+(?:/[^/\\\x00]+)*')


def validate_store_client(client):
    """Mirror of the native StoreClientPlan validation; the Swift tests pin the same shape."""
    if not isinstance(client, dict):
        raise ValueError('The store client must be an object')
    for key in ['installRoot', 'clientExecutable', 'launcherExecutable', 'gameRoot']:
        safe_relative(client.get(key))
    for key in ['signInEvidence', 'readinessEvidence']:
        paths = client.get(key)
        if not isinstance(paths, list) or not 1 <= len(paths) <= 16:
            raise ValueError('The store client needs 1-16 ' + key + ' paths')
        for path in paths:
            safe_relative(path)
    name = client.get('name')
    if not isinstance(name, str) or not 0 < len(name) <= 64 or any(ord(c) < 32 for c in name):
        raise ValueError('The store client needs a plain name')
    arguments = client.get('clientArguments')
    if not isinstance(arguments, list) or len(arguments) > 7 or not all(
            isinstance(a, str) and re.fullmatch(r'--[a-z-]{1,62}', a) for a in arguments):
        raise ValueError('The store client arguments must be plain long switches')
    url = client.get('launchURL')
    if not isinstance(url, str) or len(url) > 256 or '{offer}' not in url \
            or not url.startswith(('origin2://', 'link2ea://')) \
            or any(ord(c) < 32 or ord(c) > 126 for c in url):
        raise ValueError('The store launch request must be a bounded store URL with an offer slot')
    if not re.fullmatch(r'[0-9]{1,20}', str(client.get('offerID'))):
        raise ValueError('The store offer identifier must be a decimal number')
    if not isinstance(client.get('readinessChildren'), int) \
            or not 0 <= client['readinessChildren'] <= 64:
        raise ValueError('Invalid store client readiness child count')
    if not isinstance(client.get('readinessSeconds'), int) \
            or not 5 <= client['readinessSeconds'] <= 600:
        raise ValueError('Invalid store client readiness wait')
    return client


def validate_runtime_tuning(tuning):
    """Only the gate variables the Wine runtime reads, and only bounded decimal counts."""
    supported = {'WINE_TF_EMULATION', 'WINE_TF_MAX_STEPS', 'WINE_TF_MAX_NS'}
    if not isinstance(tuning, dict) or not set(tuning) <= supported:
        raise ValueError('Unsupported runtime switch')
    for value in tuning.values():
        if not isinstance(value, str) or not re.fullmatch(r'[0-9]{1,20}', value):
            raise ValueError('Runtime switches must be decimal counts')
    return tuning


def validate_prefix_settings(settings):
    """Mirror of the native RegistrySetting validation; nothing may inject a second key or line."""
    if not isinstance(settings, list) or len(settings) > 64:
        raise ValueError('Prefix settings must be a bounded list')
    for item in settings:
        if not isinstance(item, dict):
            raise ValueError('A prefix setting must be an object')
        if item.get('hive') not in {'HKEY_CURRENT_USER', 'HKEY_LOCAL_MACHINE'}:
            raise ValueError('Unknown registry hive')
        path, name = item.get('path'), item.get('name')
        for text, limit in [(path, 256), (name, 128)]:
            if not isinstance(text, str) or not 0 < len(text) <= limit \
                    or any(ord(c) < 32 or ord(c) > 126 or c in '"[]' for c in text):
                raise ValueError('Unusable registry location')
        if path.startswith('\\') or path.endswith('\\') or '\\\\' in path or '\\' in name:
            raise ValueError('Unusable registry key path')
        value = item.get('value')
        if item.get('kind') == 'string':
            if not isinstance(value, str) or not 0 < len(value) <= 256 \
                    or any(ord(c) < 32 or ord(c) > 126 or c in '"[]\\' for c in value):
                raise ValueError('Unusable registry string value')
        elif item.get('kind') == 'dword':
            if not re.fullmatch('[0-9a-f]{1,8}', str(value)):
                raise ValueError('A registry number must be lowercase hexadecimal')
        else:
            raise ValueError('Unknown registry value kind')
        if not isinstance(item.get('reason', ''), str) or len(item.get('reason', '')) > 200:
            raise ValueError('Overlong registry reason')
    return settings


def validate_renderers(recipe, renderers):
    """Mirror of the native RendererSelection validation, plus the per-game denial list."""
    if not isinstance(renderers, list) or not 1 <= len(renderers) <= 16:
        raise ValueError('A recipe needs between one and sixteen renderer rules')
    denied = DENIED_BACKENDS.get(recipe['gameID'], {})
    for item in renderers:
        if not isinstance(item, dict) or item.get('api') not in RENDERER_APIS:
            raise ValueError('Unknown graphics API in a renderer rule')
        backend = item.get('backend')
        if not isinstance(backend, str) or not re.fullmatch('[a-z0-9]{1,32}', backend):
            raise ValueError('A renderer backend must be a plain lowercase name')
        if backend in denied:
            raise ValueError(recipe['gameID'] + ' cannot use the ' + backend + ' renderer: '
                             + denied[backend])
        if 'vulkanDXGI' in recipe.get('requiredRuntimeCapabilities', []) and backend == 'gptk':
            raise ValueError('A recipe cannot require a Vulkan backend and select D3DMetal')
        executable = item.get('executable')
        if executable is not None and (not isinstance(executable, str)
                                       or not re.fullmatch(r'[A-Za-z0-9._-]{1,64}\.exe', executable)):
            raise ValueError('A renderer rule applies to one Windows executable')
        reason = item.get('reason', '')
        if not isinstance(reason, str) or len(reason) > 200 or ';' in reason:
            raise ValueError('Unusable renderer reason')
    return renderers


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
    editions = recipe.get('editions', ['bundled', 'import'])
    if not isinstance(editions, list) or not editions or not set(editions) <= EDITIONS \
            or len(set(editions)) != len(editions):
        raise ValueError('Recipe editions must be a non-empty subset of bundled and import')
    if 'bundled' in editions and not recipe['executableHashes']:
        # Without pinned executable digests a bundled app could not prove which build it contains.
        raise ValueError('A bundled edition needs pinned executable hashes')
    capabilities = recipe.get('requiredRuntimeCapabilities', [])
    if not isinstance(capabilities, list) or not set(capabilities) <= CAPABILITIES \
            or len(set(capabilities)) != len(capabilities):
        raise ValueError('Unknown required runtime capability')
    retention = recipe.get('runtimeRetention', [])
    if not isinstance(retention, list) or len(retention) > 32:
        raise ValueError('Runtime retention must be a bounded list')
    for name in retention:
        safe_relative(name)
    if len({name.casefold() for name in retention}) != len(retention):
        raise ValueError('Duplicate runtime retention entry')
    # Vendor artifacts keep their own signature and search paths; we neither alter nor re-sign them.
    vendor = recipe.get('vendorRuntimePaths', [])
    if not isinstance(vendor, list) or len(vendor) > 32:
        raise ValueError('Vendor runtime paths must be a bounded list')
    folded = {name.casefold() for name in retention}
    for name in vendor:
        if safe_relative(name).casefold() not in folded:
            raise ValueError('A vendor runtime path must also be retained: ' + name)
    validate_runtime_tuning(recipe.get('runtimeTuning', {}))
    if recipe.get('referencesInstallation'):
        # A referencing app ships no game bytes at all, so it can carry no inventory.
        if editions != ['import']:
            raise ValueError('A referencing recipe produces the import edition only')
        if recipe['originalFiles'] or recipe['originalDirectories'] or recipe['executableHashes'] \
                or recipe['compatibility']:
            raise ValueError('A referencing recipe must not list original or compatibility files')
        if 'game' in recipe['inputs']:
            raise ValueError('A referencing recipe takes no game input')
        validate_store_client(recipe.get('storeClient'))
        validate_prefix_settings(recipe.get('prefixSettings', []))
        validate_renderers(recipe, recipe.get('renderers', []))
        devices = recipe.get('controllerDevices', [])
        if not isinstance(devices, list) or len(devices) > 32 or not all(
                re.fullmatch('[0-9A-Fa-f]{4}/[0-9A-Fa-f]{4}', str(d)) for d in devices):
            raise ValueError('Invalid controller device')
    else:
        for key in ['storeClient', 'controllerDevices', 'prefixSettings', 'renderers']:
            if key in recipe:
                # A bundle that owns its prefix imports Defaults/settings.reg during wineboot.
                raise ValueError('Only a referencing recipe declares ' + key)
        if 'game' not in recipe['inputs']:
            raise ValueError('A recipe that packages original data needs a game input')
    return recipe


def supports_edition(recipe, edition):
    return edition in recipe.get('editions', ['bundled', 'import'])


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
