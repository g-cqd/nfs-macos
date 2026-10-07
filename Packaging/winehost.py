"""The native arm64 route's nested helper app, Contents/Helpers/winehost.app.

A recipe opts in with a `winehost` block; a recipe without one is assembled exactly as before.
The helper is an arm64 Mach-O the recipe supplies, plus the provisioning profile that carries
com.apple.developer.cross-architecture-support. Neither is committed to this repository: the
recipe names an input, and the caller supplies the path (--input NAME=PATH).

    "winehost": {
      "binary": {"input": "winehostBuild", "source": "winehost"},
      "provisioningProfile": {"input": "winehostProfile"},
      "profile": "arm64-wow64",
      "fourKilobytePages": true
    }

`binary.input` is a directory holding the executable at `source`; `provisioningProfile.input`
is the profile file itself. `profile` (optional) makes the app launch Wine through posix_spawn
by writing Contents/Resources/runtime-profile.json; without it the helper is only staged and
every launch is unchanged.
"""
import json
from pathlib import Path
import plistlib
import re
import stat

from signing_policy import WINEHOST_BUNDLE_IDENTIFIER

APP_RELATIVE = 'Contents/Helpers/winehost.app'
EXECUTABLE_NAME = 'winehost'
EXECUTABLE_RELATIVE = APP_RELATIVE + '/Contents/MacOS/' + EXECUTABLE_NAME
PROFILE_RELATIVE = APP_RELATIVE + '/Contents/embedded.provisionprofile'
PROFILE_NAME = 'arm64-wow64'
KEYS = {'binary', 'provisioningProfile', 'profile', 'fourKilobytePages', 'minimumMacOS'}
MACH_O_ARM64 = (0xfeedfacf, 0x0100000c)
MAX_PROFILE_BYTES = 64 * 1024


def _relative(value):
    # Same rule as Recipes: a plain relative path with no traversal.
    from recipes import safe_relative
    return safe_relative(value)


def validate_winehost(block, inputs):
    """Reject a malformed winehost block; `inputs` is the recipe's declared input roots."""
    if not isinstance(block, dict):
        raise ValueError('The winehost declaration must be an object')
    unknown = set(block) - KEYS
    if unknown:
        raise ValueError('Unknown winehost key: ' + ', '.join(sorted(unknown)))
    binary = block.get('binary')
    if not isinstance(binary, dict) or set(binary) != {'input', 'source'}:
        raise ValueError('winehost.binary needs exactly an input and a source')
    _relative(binary['source'])
    profile = block.get('provisioningProfile')
    if not isinstance(profile, dict) or set(profile) != {'input'}:
        raise ValueError('winehost.provisioningProfile needs exactly an input')
    for name in (binary['input'], profile['input']):
        if name not in inputs:
            raise ValueError('Undeclared winehost input: ' + str(name))
    if binary['input'] == profile['input']:
        # The binary is a directory root and the profile a file; one input cannot be both.
        raise ValueError('winehost.binary and winehost.provisioningProfile need separate inputs')
    if 'profile' in block and block['profile'] != PROFILE_NAME:
        raise ValueError('The only winehost launch profile is ' + PROFILE_NAME)
    if 'fourKilobytePages' in block:
        if not isinstance(block['fourKilobytePages'], bool):
            raise ValueError('winehost.fourKilobytePages must be Boolean')
        if 'profile' not in block:
            raise ValueError('winehost.fourKilobytePages needs a winehost.profile')
    if 'minimumMacOS' in block and not re.fullmatch(r'\d{2}\.\d+(?:\.\d+)?', str(block['minimumMacOS'])):
        raise ValueError('Invalid winehost minimum macOS version')
    return block


def macho_header(path):
    with Path(path).open('rb') as stream:
        head = stream.read(8)
    if len(head) < 8:
        raise ValueError('Not a Mach-O file: ' + str(path))
    return int.from_bytes(head[:4], 'little'), int.from_bytes(head[4:], 'little')


def require_arm64_macho(path):
    """A thin 64-bit arm64 Mach-O; a fat file or an Intel binary cannot be the host."""
    if macho_header(path) != MACH_O_ARM64:
        raise ValueError('The winehost executable must be a thin arm64 Mach-O: ' + Path(path).name)


def _plain_file(path, root=None):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('Missing or linked winehost input: ' + path.name)
    return path


def info_plist(block):
    return {'CFBundleExecutable': EXECUTABLE_NAME, 'CFBundleIdentifier': WINEHOST_BUNDLE_IDENTIFIER,
            'CFBundleName': 'Wine Host', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
            'LSMinimumSystemVersion': block.get('minimumMacOS', '26.0'), 'LSUIElement': True,
            'LSArchitecturePriority': ['arm64']}


def stage_winehost(contents, recipe, inputs):
    """Assemble Contents/Helpers/winehost.app; returns the relative paths it created."""
    from runtime_inputs import clone
    block = recipe.get('winehost')
    if block is None:
        return []
    binary = _plain_file(inputs[block['binary']['input']] / block['binary']['source'])
    if not binary.resolve().is_relative_to(inputs[block['binary']['input']].resolve()):
        raise ValueError('The winehost executable lies outside its input')
    require_arm64_macho(binary)
    profile = _plain_file(inputs[block['provisioningProfile']['input']])
    size = profile.stat().st_size
    if not 0 < size <= MAX_PROFILE_BYTES:
        raise ValueError('The provisioning profile has an implausible size')
    app = Path(contents) / 'Helpers/winehost.app/Contents'
    clone(binary, app / 'MacOS' / EXECUTABLE_NAME)
    (app / 'MacOS' / EXECUTABLE_NAME).chmod(0o755)
    clone(profile, app / 'embedded.provisionprofile')
    (app / 'embedded.provisionprofile').chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
    (app / 'Info.plist').write_bytes(plistlib.dumps(info_plist(block)))
    created = [EXECUTABLE_RELATIVE, PROFILE_RELATIVE, APP_RELATIVE + '/Contents/Info.plist']
    if 'profile' in block:
        marker = {'profile': block['profile'], 'fourKilobytePages': block.get('fourKilobytePages', True)}
        (Path(contents) / 'Resources/runtime-profile.json').write_text(json.dumps(marker, indent=2) + '\n')
        created.append('Contents/Resources/runtime-profile.json')
    return created
