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
from signing_policy import resolve_identity, executable_entitlements

PROJECT = Path(__file__).resolve().parent.parent
APP = PROJECT / "Build/Need for Speed Most Wanted.app"
MAGIC = {bytes.fromhex(h) for h in ["cffaedfe", "cefaedfe", "cafebabe", "bebafeca"]}


def main(identity='-'):
    listing = subprocess.check_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], text=True) if identity != '-' else ''
    identity = resolve_identity(identity, listing)
    subprocess.run(["/usr/bin/tar", "-czf", str(APP / "Contents/Resources/Sources/NFSMW-launcher-source.tar.gz"),
        "-C", str(PROJECT), "Package.swift", "Sources", "Tests", "Packaging", "README.md", "docs", "tools", "PLAN.md", "SETTINGS-PLAN.md"], check=True)
    code = []
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

    subprocess.run(["/usr/bin/xattr", "-cr", str(APP)], check=True)
    def sign(path):
        command = ['/usr/bin/codesign', '--force', '--sign', identity]
        command += ['--timestamp=none'] if identity == '-' else ['--options', 'runtime', '--timestamp']
        entitlements = executable_entitlements(path.relative_to(APP).as_posix()) if path != APP else {}
        if identity != '-' and entitlements:
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
    for path in code:
        if path.parent == APP / "Contents/MacOS": continue
        with path.open("rb") as stream: pins[str(path.relative_to(APP))] = hashlib.file_digest(stream, "sha256").hexdigest()
    (APP / "Contents/Resources/runtime-files.json").write_text(json.dumps(pins, indent=2) + "\n")
    sign(APP)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(APP)], check=True)
    (PROJECT / "Evidence/signing.json").write_text(json.dumps(dict(
        signature="ad-hoc" if identity == '-' else 'Developer ID', notarized=False,
        hardenedRuntime=identity != '-', nestedCodeCount=len(code), removedSearchPaths=changes), indent=2) + "\n")
    print("Verified", 'ad-hoc' if identity == '-' else 'Developer ID', "signatures for the app and", len(code), "nested code files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path, default=APP)
    parser.add_argument('--identity', default='-', help='Developer ID Application name or SHA-1; default is ad-hoc')
    options = parser.parse_args()
    APP = options.app.resolve()
    if APP.suffix != ".app" or not APP.is_dir(): parser.error("Choose an existing .app")
    main(options.identity)
