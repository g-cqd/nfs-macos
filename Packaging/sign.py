#!/usr/bin/env python3
"""Remove development search paths and sign only the assembled application."""
import hashlib
import json
from pathlib import Path
import stat
import subprocess
import argparse

PROJECT = Path(__file__).resolve().parent.parent
APP = PROJECT / "Build/Need for Speed Most Wanted.app"
MAGIC = {bytes.fromhex(h) for h in ["cffaedfe", "cefaedfe", "cafebabe", "bebafeca"]}


def main():
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
    for path in code:
        if path.parent == APP / "Contents/MacOS": continue
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(path)], check=True)
    pins = {}
    for path in code:
        if path.parent == APP / "Contents/MacOS": continue
        with path.open("rb") as stream: pins[str(path.relative_to(APP))] = hashlib.file_digest(stream, "sha256").hexdigest()
    (APP / "Contents/Resources/runtime-files.json").write_text(json.dumps(pins, indent=2) + "\n")
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(APP)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(APP)], check=True)
    (PROJECT / "Evidence/signing.json").write_text(json.dumps(dict(
        signature="ad-hoc", notarized=False, nestedCodeCount=len(code), removedSearchPaths=changes), indent=2) + "\n")
    print("Verified ad-hoc signatures for the app and", len(code), "nested code files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path, default=APP)
    APP = parser.parse_args().app.resolve()
    if APP.suffix != ".app" or not APP.is_dir(): parser.error("Choose an existing .app")
    main()
