"""Privacy declarations every app carries, and the gate that proves it still does.

Wine reaches macOS services that guard personal data: the CoreAudio driver asks for the
microphone the first time a Windows program opens a capture device. macOS reads the usage
description from the *responsible* app, the starter the player opened, not from the Wine process
that asks. An app without the description is killed with SIGABRT (`__TCC_CRASHING_DUE_TO_PRIVACY_
VIOLATION__`) at that moment instead of showing the usual permission prompt. A bundled Need for
Speed (2015) session died this way while the game was starting.

Declaring a usage description grants nothing: macOS still asks the player the first time a
program uses the service, and the player can refuse.
"""
import plistlib
import subprocess

# Honest wording: each string says who asks and when. Only the microphone has been observed to be
# requested; the others are the services Wine's drivers or a Windows program can reach and are
# declared so that a request produces macOS's prompt, never a crash.
USAGE_DESCRIPTIONS = {
    'NSMicrophoneUsageDescription':
        'A Windows game or the EA app can open a microphone for voice chat. This app asks macOS '
        'for it only when such a program does, and never records on its own.',
    'NSCameraUsageDescription':
        'A Windows program can ask to use a camera. This app asks macOS for it only when such a '
        'program does, and never uses a camera on its own.',
    'NSBluetoothAlwaysUsageDescription':
        'A Windows program can look for Bluetooth controllers or headsets. This app asks macOS '
        'for Bluetooth only when such a program does.',
    'NSBluetoothPeripheralUsageDescription':
        'A Windows program can look for Bluetooth controllers or headsets. This app asks macOS '
        'for Bluetooth only when such a program does.',
    'NSLocalNetworkUsageDescription':
        'A Windows game can look for other players and game servers on your local network. This '
        'app asks macOS for local network access only when such a program does.',
    'NSAudioCaptureUsageDescription':
        'A Windows program can ask to record the sound other apps play. This app asks macOS for '
        'it only when such a program does.',
}

# Hardened-runtime entitlements that let the process macOS checks ask for those devices.
DEVICE_ENTITLEMENTS = {
    'com.apple.security.device.audio-input': True,
    'com.apple.security.device.camera': True,
    'com.apple.security.device.bluetooth': True,
}

WINE_LOADERS = ('Contents/SharedSupport/Wine/bin/wine',
                'Contents/SharedSupport/Wine/lib/wine/x86_64-unix/wine')


def carries_device_entitlements(relative_path):
    """The programs that ask macOS for a device, or start the one that does.

    The Windows loaders make the request; the starter is the responsible app that macOS
    attributes it to; the session helper is the program that starts Wine on the starter's behalf.
    """
    parts = relative_path.split('/')
    if relative_path in WINE_LOADERS:
        return True
    if len(parts) == 3 and parts[:2] == ['Contents', 'MacOS']:
        return True
    return len(parts) == 3 and parts[:2] == ['Contents', 'Helpers'] and parts[2].endswith('Session')


def info_plist_problems(info):
    """Missing or empty usage descriptions in an Info.plist dictionary."""
    problems = []
    for key in USAGE_DESCRIPTIONS:
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            problems.append('Info.plist lacks a usage description: ' + key)
    return problems


def entitlement_problems(relative_path, entitlements):
    """Device entitlements a program that needs them does not carry."""
    if not carries_device_entitlements(relative_path):
        return []
    return [relative_path + ' lacks the entitlement ' + key
            for key, value in DEVICE_ENTITLEMENTS.items() if entitlements.get(key) is not value]


def read_entitlements(path):
    """The entitlements a signed program carries, read back from its signature."""
    result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(path)],
                            capture_output=True)
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def audit_privacy(app):
    """Problems with an assembled and signed app; empty when the app declares what it must."""
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    problems = info_plist_problems(info)
    helpers = sorted(path for path in (app / 'Contents/Helpers').glob('*Session') if path.is_file())
    launchers = [app / 'Contents/MacOS' / info.get('CFBundleExecutable', '')]
    candidates = launchers + helpers + [app / name for name in WINE_LOADERS]
    for path in candidates:
        relative = path.relative_to(app).as_posix()
        if not path.is_file():
            if relative in WINE_LOADERS: continue
            problems.append('Missing program: ' + relative)
            continue
        problems += entitlement_problems(relative, read_entitlements(path))
    if not any((app / name).is_file() for name in WINE_LOADERS):
        problems.append('The app holds no Wine loader to carry the device entitlements')
    return problems
