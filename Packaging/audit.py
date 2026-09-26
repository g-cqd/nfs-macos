#!/usr/bin/env python3
"""Verify the final, relocated artifact without launching a game session."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from game_data import bundled_entries

app = Path(sys.argv[1]).resolve()
assert app.is_dir() and app.suffix == ".app"
pins = json.loads((app / "Contents/Resources/runtime-files.json").read_text())
for relative, expected in pins.items():
    assert hashlib.sha256((app / relative).read_bytes()).hexdigest() == expected, relative
assert not any(p.name in {"Gigi", "user.reg", "system.reg"} for p in app.rglob("*"))
report = dict(externalDependencies=[], externalLinks=[], developmentRpaths=[], machoCount=0,
              verifiedRuntimeHashes=len(pins))
magic_values = {bytes.fromhex(h) for h in ["cffaedfe", "cefaedfe", "cafebabe", "bebafeca"]}
for path in app.rglob("*"):
    if path.is_symlink():
        if not path.exists() or not str(path.resolve()).startswith(str(app) + "/"):
            report["externalLinks"].append(str(path.relative_to(app)))
        continue
    if not path.is_file(): continue
    with path.open("rb") as stream: magic = stream.read(4)
    if magic not in magic_values: continue
    report["machoCount"] += 1
    lines = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True).splitlines()[1:]
    for line in lines:
        dependency = line.strip().split(" (")[0]
        if dependency.startswith("/") and not dependency.startswith(("/System/", "/usr/lib/")):
            report["externalDependencies"].append(dependency)
    lines = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True).splitlines()
    for index, line in enumerate(lines):
        if "LC_RPATH" in line and any(value in lines[index + 2] for value in ["/Users/", "/Applications/", "/opt/"]):
            report["developmentRpaths"].append(lines[index + 2].strip())
assert not any(report[key] for key in ["externalDependencies", "externalLinks", "developmentRpaths"]), report
manifest = json.loads((app / "Contents/Resources/game-manifest.json").read_text())
entries = bundled_entries(manifest)
for entry in entries:
    path = app / "Contents/Resources/Game" / entry["path"]
    assert path.stat().st_size == entry["size"], entry["path"]
    with path.open("rb") as stream: checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    assert checksum == entry["sha256"], entry["path"]
report["verifiedGameFiles"] = len(entries)
report["gameDataIncluded"] = manifest.get("gameDataIncluded", True)
report["importInventoryFiles"] = len(manifest["gameFiles"])
report["gameVersion"] = manifest["version"]
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(json.dumps(report, indent=2))
