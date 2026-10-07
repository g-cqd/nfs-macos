#!/usr/bin/env python3
"""Remove development search paths and sign only the assembled application."""
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import argparse
import plistlib
import tempfile
from signing_policy import resolve_identity, signing_entitlements, WINEHOST_APP, WINEHOST_PATHS
from runtime_inputs import archive_launcher

PROJECT = Path(__file__).resolve().parent.parent
APP = PROJECT / "Build/Need for Speed Most Wanted.app"
MAGIC = {bytes.fromhex(h) for h in ["cffaedfe", "cefaedfe", "cafebabe", "bebafeca"]}


def vendor_artifacts(app):
    """Paths the recipe retains verbatim: an Apple-signed framework must not be re-signed.

    Deleting a search path or re-signing one of these would discard the signature that proves
    where it came from, so they are preserved and only hash-pinned.
    """
    recipe = app / 'Contents/Resources/bundle-recipe.json'
    if not recipe.is_file():
        return []
    declared = json.loads(recipe.read_text()).get('vendorRuntimePaths', [])
    return [app / 'Contents/SharedSupport/Wine' / name for name in declared]


def is_vendor(path, roots):
    return any(path == root or root in path.parents for root in roots)


def main(identity='-'):
    listing = subprocess.check_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], text=True) if identity != '-' else ''
    identity = resolve_identity(identity, listing)
    archive_launcher(APP / 'Contents/Resources')
    vendor_roots = vendor_artifacts(APP)
    code = []
    vendor = []
    changes = []
    for path in sorted(APP.rglob("*")):
        if path.is_symlink():
            if not path.exists() or not str(path.resolve()).startswith(str(APP) + "/"):
                raise ValueError("Unresolved or external link: " + str(path))
            continue
        if not path.is_file(): continue
        path.chmod(stat.S_IMODE(path.stat().st_mode) | stat.S_IWUSR)
        with path.open("rb") as stream: magic = stream.read(4)
        if magic not in MAGIC: continue
        if is_vendor(path, vendor_roots):
            vendor.append(path)
            continue
        code.append(path)
        lines = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True).splitlines()
        for index, line in enumerate(lines):
            if "LC_RPATH" not in line: continue
            rpath = lines[index + 2].strip().split(" (offset")[0].removeprefix("path ")
            if rpath.startswith(("/Users/", "/Applications/")) or "/opt/" in rpath:
                subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", rpath, str(path)], check=True)
                changes.append([str(path.relative_to(APP)), rpath])
        deps = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True).splitlines()[1:]
        for line in deps:
            dependency = line.strip().split(" (compatibility")[0]
            if dependency.startswith("/") and not dependency.startswith(("/System/", "/usr/lib/")):
                raise ValueError("External library dependency: " + dependency)

    if identity != '-' and (APP / WINEHOST_APP).is_dir() and not (APP / WINEHOST_APP / 'Contents/embedded.provisionprofile').is_file():
        # The restricted entitlements below are honoured only with the profile; refuse to ship without it.
        raise ValueError('A Developer ID winehost needs Contents/embedded.provisionprofile')
    subprocess.run(["/usr/bin/xattr", "-cr", str(APP)], check=True)
    def sign(path):
        command = ['/usr/bin/codesign', '--force', '--sign', identity]
        command += ['--timestamp=none'] if identity == '-' else ['--options', 'runtime', '--timestamp']
        # The app itself is signed through its main executable, which is the responsible program
        # for the permission prompts of every program it starts.
        program = APP / 'Contents/MacOS' / plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['CFBundleExecutable'] if path == APP else path
        # A nested app is re-signed below and a re-sign discards the inner executable's
        # entitlements, so the policy covers the nested bundle path as well as its executable.
        entitlements = signing_entitlements(program.relative_to(APP).as_posix(), identity)
        if entitlements:
            with tempfile.NamedTemporaryFile(suffix='.plist') as temporary:
                temporary.write(plistlib.dumps(entitlements)); temporary.flush()
                subprocess.run(command + ['--entitlements', temporary.name, str(path)], check=True)
        else:
            subprocess.run(command + [str(path)], check=True)
    for path in code:
        if path.parent == APP / "Contents/MacOS": continue
        sign(path)
    for nested in sorted(APP.rglob('*.app'), key=lambda path: len(path.parts), reverse=True):
        if nested.is_dir(): sign(nested)
    pins = {}
    for path in code + vendor:
        if path.parent == APP / "Contents/MacOS": continue
        with path.open("rb") as stream: pins[str(path.relative_to(APP))] = hashlib.file_digest(stream, "sha256").hexdigest()
    (APP / "Contents/Resources/runtime-files.json").write_text(json.dumps(pins, indent=2) + "\n")
    sign(APP)
    winehost = [path for path in code if path.relative_to(APP).as_posix() in WINEHOST_PATHS]
    if winehost and identity == '-':
        print('Ad-hoc winehost: signed without com.apple.developer.cross-architecture-support, '
              'the application identifier and the team identifier (a restricted entitlement without '
              'its provisioning profile gets the process killed); sign with --identity for the arm64 route')
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(APP)], check=True)
    game_id = json.loads((APP / 'Contents/Resources/game-manifest.json').read_text()).get('gameID', 'nfsmw')
    (PROJECT / 'Evidence').mkdir(exist_ok=True)
    (PROJECT / 'Evidence' / ('signing-' + game_id + '.json')).write_text(json.dumps(dict(
        signature="ad-hoc" if identity == '-' else 'Developer ID', notarized=False,
        hardenedRuntime=identity != '-', nestedCodeCount=len(code), removedSearchPaths=changes,
        preservedVendorCode=[str(path.relative_to(APP)) for path in vendor],
        **({'winehost': 'ad-hoc: restricted entitlements omitted' if identity == '-' else 'Developer ID: entitlements and provisioning profile applied'} if winehost else {})), indent=2) + "\n")
    print("Verified", 'ad-hoc' if identity == '-' else 'Developer ID', "signatures for the app and",
          len(code), "nested code files;", len(vendor), "vendor files kept their own signature")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path, default=APP)
    parser.add_argument('--identity', default='-', help='Developer ID Application name or SHA-1; default is ad-hoc')
    options = parser.parse_args()
    APP = options.app.resolve()
    if APP.suffix != ".app" or not APP.is_dir(): parser.error("Choose an existing .app")
    main(options.identity)
