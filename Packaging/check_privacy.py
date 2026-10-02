"""Every app declares the privacy usage Wine can trigger, and the audit refuses one that does not.

Regression for the Need for Speed (2015) session killed with SIGABRT inside TCC: the game's capture
device made Wine's CoreAudio driver ask macOS for the microphone, and the starter had no
NSMicrophoneUsageDescription, so macOS terminated the process instead of prompting.
"""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
from tempfile import TemporaryDirectory
from assemble import stage_metadata
from privacy import (DEVICE_ENTITLEMENTS, USAGE_DESCRIPTIONS, WINE_LOADERS, audit_privacy,
                     carries_device_entitlements, entitlement_problems, info_plist_problems)
from signing_policy import signing_entitlements

assert 'NSMicrophoneUsageDescription' in USAGE_DESCRIPTIONS
assert set(USAGE_DESCRIPTIONS) >= {
    'NSMicrophoneUsageDescription', 'NSCameraUsageDescription', 'NSBluetoothAlwaysUsageDescription',
    'NSBluetoothPeripheralUsageDescription', 'NSLocalNetworkUsageDescription'}
assert set(DEVICE_ENTITLEMENTS) >= {
    'com.apple.security.device.audio-input', 'com.apple.security.device.camera',
    'com.apple.security.device.bluetooth'}
assert all(len(text) > 40 for text in USAGE_DESCRIPTIONS.values()), 'A usage description must explain itself'

# 1. The Info.plist template of every recipe carries every description.
recipes = sorted((Path(__file__).parent / 'Recipes').glob('*.json'))
assert len(recipes) >= 5, recipes
with TemporaryDirectory() as temporary:
    for recipe_path in recipes:
        recipe = json.loads(recipe_path.read_text())
        contents = Path(temporary) / recipe_path.stem / 'Contents'
        (contents / 'Resources').mkdir(parents=True)
        stage_metadata(contents, recipe, {}, False)
        info = plistlib.loads((contents / 'Info.plist').read_bytes())
        assert info_plist_problems(info) == [], (recipe_path.name, info_plist_problems(info))
        assert info['CFBundleExecutable'] == recipe['launcher']

# 2. A plist that lacks, blanks or mistypes any description is reported, one problem per key.
complete = dict(USAGE_DESCRIPTIONS)
assert info_plist_problems(complete) == []
for key in USAGE_DESCRIPTIONS:
    for broken in [None, '', '   ', 7]:
        mutated = dict(complete)
        if broken is None: del mutated[key]
        else: mutated[key] = broken
        problems = info_plist_problems(mutated)
        assert problems == ['Info.plist lacks a usage description: ' + key], (key, broken, problems)

# 3. Which programs carry the device entitlements, and what is reported when one does not.
for path in ['Contents/MacOS/NFS2015Launcher', 'Contents/MacOS/CoD4Launcher',
             'Contents/Helpers/NFS2015Session', 'Contents/Helpers/FarCry2Session', *WINE_LOADERS]:
    assert carries_device_entitlements(path), path
    assert entitlement_problems(path, dict(DEVICE_ENTITLEMENTS)) == []
    for key in DEVICE_ENTITLEMENTS:
        reduced = {name: value for name, value in DEVICE_ENTITLEMENTS.items() if name != key}
        assert entitlement_problems(path, reduced) == [path + ' lacks the entitlement ' + key]
        assert entitlement_problems(path, {**DEVICE_ENTITLEMENTS, key: False})
for path in ['Contents/Helpers/x87sidecar', 'Contents/SharedSupport/Wine/bin/wineserver',
             'Contents/Helpers/Rosetta Request.app', 'Contents/Resources/Game/NFS16.exe']:
    assert not carries_device_entitlements(path), path
    assert entitlement_problems(path, {}) == []

# 4. A real signature round trip: what the signer embeds is what the audit reads back.
with TemporaryDirectory() as temporary:
    app = Path(temporary) / 'Fixture.app'
    programs = {'Contents/MacOS/Fixture': True, 'Contents/Helpers/FixtureSession': True,
                'Contents/SharedSupport/Wine/lib/wine/x86_64-unix/wine': True,
                'Contents/Helpers/x87sidecar': False}
    (app / 'Contents').mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(
        {'CFBundleExecutable': 'Fixture', 'CFBundleIdentifier': 'local.fixture', **USAGE_DESCRIPTIONS}))

    def sign(relative, identity='-'):
        path = app / relative
        entitlements = signing_entitlements(relative, identity)
        command = ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none']
        if entitlements:
            entitlement_file = Path(temporary) / 'entitlements.plist'
            entitlement_file.write_bytes(plistlib.dumps(entitlements))
            command += ['--entitlements', str(entitlement_file)]
        subprocess.run(command + [str(path)], check=True, capture_output=True)

    for relative in programs:
        (app / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy('/usr/bin/true', app / relative)
        (app / relative).chmod(0o755)
        sign(relative)
    assert audit_privacy(app) == [], audit_privacy(app)
    # An ad-hoc signature through the project's policy still carries every device entitlement.
    # A launcher signed without them is reported, and so is a missing usage description.
    command = ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none']
    for relative in ['Contents/MacOS/Fixture', 'Contents/Helpers/FixtureSession',
                     'Contents/SharedSupport/Wine/lib/wine/x86_64-unix/wine']:
        subprocess.run(command + [str(app / relative)], check=True, capture_output=True)
        problems = audit_privacy(app)
        assert len(problems) == len(DEVICE_ENTITLEMENTS), (relative, problems)
        assert all(problem.startswith(relative + ' lacks') for problem in problems), problems
        sign(relative)
        assert audit_privacy(app) == []
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    del info['NSMicrophoneUsageDescription']
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    assert audit_privacy(app) == ['Info.plist lacks a usage description: NSMicrophoneUsageDescription']
    (app / 'Contents/SharedSupport/Wine/lib/wine/x86_64-unix/wine').unlink()
    assert any('no Wine loader' in problem for problem in audit_privacy(app))
print('Privacy declaration regressions passed')
