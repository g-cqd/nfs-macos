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
SHA256 = re.compile('[0-9a-f]{64}')
CAPABILITIES = {'trapFlagEmulation', 'd3dmetalDXGI', 'dxmtDXGI', 'x87Sidecar'}
RENDERER_APIS = {'d3d8', 'd3d9', 'd3d10core', 'd3d11', 'dxgi'}
# A backend measured to break a game, with the reason, so no recipe can select it for that
# game's own executable. A rule naming another program, such as the store client that starts
# the game, is a separate process judged on its own evidence.
DENIED_BACKENDS = {
    'nfs2015': {
        'executable': 'NFS16.exe',
        'backends': {
            'gptk': 'D3DMetal does not implement the D3D11 timestamp queries this engine uses',
        },
    },
}
# The executable whose pinned digest proves which game build a bundled edition contains.
GAME_EXECUTABLES = {'nfs2015': 'NFS16.exe'}
GUEST_PATH = re.compile(r'[^/\\\x00]+(?:/[^/\\\x00]+)*')
WINDOWS_PATH = re.compile(r'[A-Za-z]:(?:\\[A-Za-z0-9 ._()-]+)+\\?')


def _simple_name(value):
    return (isinstance(value, str) and 0 < len(value) <= 64 and '/' not in value
            and '\\' not in value and all(ord(c) >= 32 for c in value))


def validate_import_rules(rules):
    """Mirror of the native ImportRules validation; the Swift tests load this same JSON."""
    if not isinstance(rules, dict):
        raise ValueError('Import rules must be an object')
    safe_relative(rules.get('executable'))
    if rules.get('machine') != 'i386':
        raise ValueError('Only 32-bit executables are supported')
    required, directories = rules.get('required'), rules.get('directories')
    if not isinstance(required, list) or not 1 <= len(required) <= 64:
        raise ValueError('Import rules need 1-64 required files')
    if not isinstance(directories, list) or not 1 <= len(directories) <= 16:
        raise ValueError('Import rules need 1-16 directories')
    roots = []
    for item in directories:
        roots.append(safe_relative(item.get('path')).lower())
        if not isinstance(item.get('minimumBytes'), int) or item['minimumBytes'] < 0:
            raise ValueError('Invalid directory minimum')
        for key in ['excludedNames', 'excludedDirectories']:
            if not isinstance(item.get(key), list) or not all(_simple_name(v) for v in item[key]):
                raise ValueError('Invalid directory exclusion: ' + key)
        suffixes = item.get('excludedSuffixes')
        if not isinstance(suffixes, list) or any(
                not isinstance(v, str) or not re.fullmatch(r'\.[a-z0-9]+', v) for v in suffixes):
            raise ValueError('Excluded suffixes must be lowercase extensions')
    if len(set(roots)) != len(roots):
        raise ValueError('Duplicate import directory')
    names = []
    for item in required:
        path = safe_relative(item.get('path'))
        names.append(path.lower())
        if not isinstance(item.get('minimumSize'), int) or not 0 <= item['minimumSize'] <= 4_000_000_000:
            raise ValueError('Invalid required file size')
        if not any(path.lower().startswith(root + '/') for root in roots):
            raise ValueError('Required file is outside every copied directory: ' + path)
    if rules['executable'].lower() not in names:
        raise ValueError('The executable must be a required file')
    for item in rules.get('pairings', []):
        directory = safe_relative(item.get('directory')).lower()
        if not any(directory == root or directory.startswith(root + '/') for root in roots):
            raise ValueError('Pairing directory is outside every copied directory: ' + directory)
        for key in ['primarySuffix', 'companionSuffix']:
            if not re.fullmatch(r'\.[a-z0-9]+', str(item.get(key))):
                raise ValueError('Invalid pairing suffix')
    for item in rules.get('markers', []):
        if not _simple_name(item.get('name')) or not item.get('patterns') \
                or not all(isinstance(p, str) and p == p.lower() and '/' not in p for p in item['patterns']):
            raise ValueError('Invalid marker')
    for item in rules.get('knownBuilds', []):
        if not _simple_name(item.get('name')) or not SHA256.fullmatch(str(item.get('executableSHA256'))):
            raise ValueError('Invalid known build')
    for key in ['maximumFiles', 'maximumBytes']:
        if not isinstance(rules.get(key), int) or rules[key] < 1:
            raise ValueError('Invalid import limit: ' + key)
    return rules


def validate_store_client(client):
    """Mirror of the native StoreClientPlan validation; the Swift tests pin the same shape."""
    if not isinstance(client, dict):
        raise ValueError('The store client must be an object')
    for key in ['installRoot', 'clientExecutable', 'launcherExecutable', 'gameRoot', 'readinessLog']:
        safe_relative(client.get(key))
    marker = client.get('startMarker')
    if not isinstance(marker, str) or not 1 <= len(marker) <= 128 or '\n' in marker:
        raise ValueError('The store client needs a start marker')
    events = client.get('readyEvents')
    if not isinstance(events, list) or not 1 <= len(events) <= 8 or not all(
            isinstance(e, str) and re.fullmatch(r'[a-z0-9._]{1,64}', e) for e in events):
        raise ValueError('The store client needs plain ready event names')
    for key in ['signInEvidence']:
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
        elif item.get('kind') == 'windowsPath':
            # A guest path with single backslashes; the importer doubles them, as a .reg file needs.
            if not isinstance(value, str) or len(value) > 256 or not WINDOWS_PATH.fullmatch(value) \
                    or any(part in {'.', '..'} for part in value[3:].split('\\')):
                raise ValueError('Unusable registry path value')
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
    denial = DENIED_BACKENDS.get(recipe['gameID'], {})
    executable = denial.get('executable', '')
    denied = denial.get('backends', {})
    for item in renderers:
        if not isinstance(item, dict) or item.get('api') not in RENDERER_APIS:
            raise ValueError('Unknown graphics API in a renderer rule')
        backend = item.get('backend')
        if not isinstance(backend, str) or not re.fullmatch('[a-z0-9]{1,32}', backend):
            raise ValueError('A renderer backend must be a plain lowercase name')
        target = item.get('executable')
        if target is not None and (not isinstance(target, str)
                                   or not re.fullmatch(r'[A-Za-z0-9._-]{1,64}\.exe', target)):
            raise ValueError('A renderer rule applies to one Windows executable')
        serves_game = target is None or target.lower() == executable.lower()
        if serves_game and backend in denied:
            raise ValueError(recipe['gameID'] + ' cannot use the ' + backend + ' renderer: '
                             + denied[backend])
        reason = item.get('reason', '')
        if not isinstance(reason, str) or len(reason) > 200 or ';' in reason:
            raise ValueError('Unusable renderer reason')
    return renderers


def validate_runtime_source(source):
    """The modified runtime's corresponding source, which the LGPL requires us to ship."""
    if not isinstance(source, dict):
        raise ValueError('The runtime source declaration must be an object')
    for key in ['source', 'path', 'archive']:
        safe_relative(source.get(key))
    if not isinstance(source.get('input'), str):
        raise ValueError('The runtime source needs a declared input')
    if not re.fullmatch('[0-9a-f]{7,40}', str(source.get('baseRevision'))):
        raise ValueError('The runtime source needs its exact upstream base revision')
    if not str(source.get('repository', '')).startswith('https://'):
        raise ValueError('The runtime source needs an upstream repository URL')
    if not isinstance(source.get('patchCount'), int) or not 0 <= source['patchCount'] <= 256:
        raise ValueError('Invalid runtime patch count')
    if not source.get('archive').endswith('.tar.gz'):
        raise ValueError('The runtime source archive must be a tar.gz')
    return source


def validate_managed_runtime(declared):
    """Mirror of the native ManagedRuntime validation, plus where it comes from.

    EA's installer runs a managed custom action, so the bundled prefix needs a .NET runtime; this is
    Wine's own free one, pinned by digest and installed by the app before the installer runs.
    """
    if not isinstance(declared, dict):
        raise ValueError('The managed runtime must be an object')
    if not isinstance(declared.get('input'), str):
        raise ValueError('The managed runtime needs a declared input')
    safe_relative(declared.get('source'))
    path = safe_relative(declared.get('path'))
    if not path.lower().endswith('.msi') or '/' not in path:
        raise ValueError('The managed runtime installer must be an .msi inside a resource folder')
    if not SHA256.fullmatch(str(declared.get('sha256'))):
        raise ValueError('The managed runtime needs its SHA-256 pin')
    if not re.fullmatch(r'[0-9]{1,6}(?:\.[0-9]{1,6}){0,3}', str(declared.get('version'))):
        raise ValueError('The managed runtime needs its upstream version')
    for key in ['url', 'sourceURL']:
        if not str(declared.get(key, '')).startswith('https://'):
            raise ValueError('The managed runtime needs an https ' + key)
    return declared


def validate_third_party_licenses(items):
    """The licence texts a recipe must ship beside the third-party binaries it carries unchanged.

    Each entry pins one verbatim text kept in Packaging/Licenses by its SHA-256 and names the upstream
    tag, the commit the tag points to and the blob it was read from, so the file can be checked
    against the upstream project without trusting this tree.
    """
    keys = {'component', 'version', 'licence', 'path', 'source', 'sha256', 'url', 'tagCommit', 'blobSHA1'}
    if not isinstance(items, list) or not 0 < len(items) <= 16:
        raise ValueError('Third-party licences must be a bounded, non-empty list')
    components, paths = set(), set()
    for item in items:
        if not isinstance(item, dict) or set(item) != keys:
            raise ValueError('A third-party licence declares exactly ' + ', '.join(sorted(keys)))
        for key in ['component', 'version', 'licence']:
            if not _simple_name(item[key]) or not item[key].isprintable():
                raise ValueError('A third-party licence needs a plain ' + key)
        path = safe_relative(item['path'])
        if not re.fullmatch(r'Licenses/[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.txt', path):
            raise ValueError('A third-party licence is shipped as Licenses/<name>.txt: ' + path)
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.txt', str(item['source'])):
            raise ValueError('A third-party licence text is a plain file name under Packaging/Licenses')
        if not SHA256.fullmatch(str(item['sha256'])):
            raise ValueError('A third-party licence needs its SHA-256 pin')
        for key in ['tagCommit', 'blobSHA1']:
            if not re.fullmatch('[0-9a-f]{40}', str(item[key])):
                raise ValueError('A third-party licence needs its ' + key)
        if not str(item['url']).startswith('https://'):
            raise ValueError('A third-party licence needs an https url')
        if item['component'].casefold() in components or path.casefold() in paths:
            raise ValueError('Duplicate third-party licence: ' + item['component'])
        components.add(item['component'].casefold())
        paths.add(path.casefold())
    return items


def validate_client_layer(declared):
    """The pre-installed EA client a bundled app carries: a build input pinned by the digest of its manifest.

    The layer folder is made by tools/capture-client-layer.py; Packaging/client_layer.py is the one
    check of its contents. This only validates what the recipe says about it.
    """
    if not isinstance(declared, dict) or set(declared) != {'input', 'path', 'layerSHA256', 'client'}:
        raise ValueError('The client layer must declare exactly its input, path, digest and client')
    if not isinstance(declared['input'], str):
        raise ValueError('The client layer needs a declared input')
    path = safe_relative(declared['path'])
    if '/' in path or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,63}', path) \
            or path.casefold() in {'game', 'defaults', 'addons', 'licenses', 'sources'}:
        raise ValueError('The client layer needs its own plain resource folder name')
    if not SHA256.fullmatch(str(declared['layerSHA256'])):
        raise ValueError('The client layer needs its SHA-256 pin')
    client = declared['client']
    if not isinstance(client, dict) or set(client) != {'name', 'version', 'installer', 'package'}:
        raise ValueError('The client layer must describe its client, installer and package')
    if not isinstance(client['name'], str) or not 0 < len(client['name']) <= 64 \
            or any(not 32 <= ord(c) <= 126 for c in client['name']):
        raise ValueError('The client layer needs a plain client name')
    if not re.fullmatch(r'[0-9]{1,6}(?:\.[0-9]{1,6}){1,3}', str(client['version'])):
        raise ValueError('The client layer needs the client version')
    for key, suffix, extra in [('installer', '.exe', {'signer'}), ('package', '.msi', set())]:
        item = client[key]
        if not isinstance(item, dict) or set(item) != {'fileName', 'sha256', 'bytes'} | extra:
            raise ValueError('The client layer ' + key + ' record has the wrong fields')
        if not _simple_name(item['fileName']) or not item['fileName'].lower().endswith(suffix):
            raise ValueError('The client layer ' + key + ' needs a plain file name')
        if not SHA256.fullmatch(str(item['sha256'])):
            raise ValueError('The client layer ' + key + ' needs its SHA-256 pin')
        if isinstance(item['bytes'], bool) or not isinstance(item['bytes'], int) \
                or not 0 < item['bytes'] <= 2_000_000_000:
            raise ValueError('The client layer ' + key + ' needs its size')
    signer = client['installer']['signer']
    if not isinstance(signer, str) or not 0 < len(signer) <= 128 or any(ord(c) < 32 for c in signer):
        raise ValueError('The client layer needs the installer\'s signer')
    return declared


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
    if 'shaderCache' in recipe:
        if not isinstance(recipe['shaderCache'], bool):
            raise ValueError('The shaderCache flag must be Boolean')
        if recipe['shaderCache'] and 'mtld3dSource' not in recipe.get('inputs', {}):
            raise ValueError('A persistent shader cache needs the mtld3dSource input')
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
        # A pin names one original file, either listed on its own or inside a selected directory.
        selected = safe_relative(path) in recipe['originalFiles'] or any(
            path.casefold().startswith(directory) for directory in directories)
        if not selected or not re.fullmatch('[0-9a-f]{64}', checksum):
            raise ValueError('Invalid executable pin')
    if 'inventorySHA256' in recipe and not SHA256.fullmatch(str(recipe['inventorySHA256'])):
        raise ValueError('Invalid payload inventory pin')
    editions = recipe.get('editions', ['bundled', 'import'])
    if not isinstance(editions, list) or not editions or not set(editions) <= EDITIONS \
            or len(set(editions)) != len(editions):
        raise ValueError('Recipe editions must be a non-empty subset of bundled and import')
    if 'bundled' in editions and not recipe['executableHashes']:
        # Without pinned executable digests a bundled app could not prove which build it contains.
        raise ValueError('A bundled edition needs pinned executable hashes')
    if 'importRules' in recipe:
        validate_import_rules(recipe['importRules'])
        if recipe['originalFiles'] or recipe['originalDirectories'] or recipe['executableHashes']:
            raise ValueError('A recipe with import rules recognises the player installation; '
                             'it must not list original files or hashes')
        if 'bundled' in editions:
            raise ValueError('Import rules cannot produce a bundled edition')
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
    if 'thirdPartyLicenses' in recipe:
        validate_third_party_licenses(recipe['thirdPartyLicenses'])
    validate_runtime_tuning(recipe.get('runtimeTuning', {}))
    if recipe.get('referencesInstallation'):
        # The import edition of a store-client recipe ships no game bytes at all, so it carries no
        # inventory. Its bundled edition, when the recipe declares one, ships the user's verified
        # copy for a prefix the app creates itself, and then the recipe must pin every file.
        if 'import' not in editions:
            raise ValueError('A referencing recipe produces the import edition')
        if recipe['compatibility']:
            raise ValueError('A referencing recipe must not list compatibility files')
        if 'bundled' in editions:
            if not recipe['originalFiles'] and not recipe['originalDirectories']:
                raise ValueError('A bundled store-client edition must list its original files')
            if 'game' not in recipe['inputs']:
                raise ValueError('A bundled store-client edition needs a game input')
            if 'inventorySHA256' not in recipe:
                raise ValueError('A bundled store-client edition must pin its whole payload inventory')
            if not any(path.casefold() == GAME_EXECUTABLES.get(recipe['gameID'], '').casefold()
                       for path in recipe['executableHashes']):
                raise ValueError('A bundled store-client edition must pin the game executable')
            validate_prefix_settings(recipe.get('bundledPrefixSettings', []))
        else:
            if editions != ['import']:
                raise ValueError('Unsupported referencing recipe editions')
            if recipe['originalFiles'] or recipe['originalDirectories'] or recipe['executableHashes'] \
                    or 'inventorySHA256' in recipe or 'bundledPrefixSettings' in recipe:
                raise ValueError('An import-only referencing recipe must not list original files or pins')
            if 'game' in recipe['inputs']:
                raise ValueError('An import-only referencing recipe takes no game input')
        validate_store_client(recipe.get('storeClient'))
        validate_prefix_settings(recipe.get('prefixSettings', []))
        validate_renderers(recipe, recipe.get('renderers', []))
        if 'managedRuntime' in recipe:
            declared = validate_managed_runtime(recipe['managedRuntime'])
            if declared['input'] not in recipe['inputs']:
                raise ValueError('Undeclared managed runtime input')
            if 'bundled' not in editions:
                raise ValueError('Only a bundled edition installs a managed runtime into its prefix')
        if 'clientLayer' in recipe:
            declared = validate_client_layer(recipe['clientLayer'])
            if declared['input'] not in recipe['inputs']:
                raise ValueError('Undeclared client layer input')
            if 'bundled' not in editions:
                raise ValueError('Only a bundled edition installs a client layer into its prefix')
        if 'runtimeSource' in recipe:
            declared = validate_runtime_source(recipe['runtimeSource'])
            if declared['input'] not in recipe['inputs']:
                raise ValueError('Undeclared runtime source input')
        devices = recipe.get('controllerDevices', [])
        if not isinstance(devices, list) or len(devices) > 32 or not all(
                re.fullmatch('[0-9A-Fa-f]{4}/[0-9A-Fa-f]{4}', str(d)) for d in devices):
            raise ValueError('Invalid controller device')
    else:
        for key in ['storeClient', 'controllerDevices', 'prefixSettings', 'renderers',
                    'bundledPrefixSettings', 'managedRuntime', 'clientLayer']:
            if key in recipe:
                # A bundle that owns its prefix imports Defaults/settings.reg during wineboot.
                raise ValueError('Only a referencing recipe declares ' + key)
        if 'importRules' not in recipe:
            # Neither recognised by rules nor by reference, so this recipe packages game bytes.
            if editions == ['import']:
                raise ValueError('An import-only recipe needs import rules or an installation reference')
            if 'game' not in recipe['inputs']:
                raise ValueError('A recipe that packages original data needs a game input')
    return recipe


def shipped_recipe(recipe):
    """A recipe as it ships, in an app or in the source archive: its input roots are paths on the
    build Mac, so they stay behind. Everything else is kept, and the shipped copy still validates:
    resource lists name their inputs, only without saying where those inputs were."""
    return {**recipe, 'inputs': {name: 'build input, not shipped' for name in recipe['inputs']}}


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
