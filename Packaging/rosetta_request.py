"""Build an Intel-only app that lets Launch Services request Apple's Rosetta installer."""
from pathlib import Path
import plistlib
import subprocess


def build_rosetta_request(app, bundle_identifier='local.nfsmw.mac'):
    contents = app/'Contents/Helpers/Rosetta Request.app/Contents'
    binary = contents/'MacOS/RosettaRequest'
    binary.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['xcrun', 'clang', '-target', 'x86_64-apple-macos15.0', '-fobjc-arc',
                    '-Os', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    '-framework', 'AppKit', str(Path(__file__).with_name('RosettaRequest.m')),
                    '-o', str(binary)], check=True)
    info = {'CFBundleExecutable': 'RosettaRequest', 'CFBundleIdentifier': bundle_identifier + '.rosetta-request',
            'CFBundleName': 'Rosetta Setup', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
            'LSMinimumSystemVersion': '15.0', 'LSUIElement': True,
            'LSArchitecturePriority': ['x86_64']}
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
