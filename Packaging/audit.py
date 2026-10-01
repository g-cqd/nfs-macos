#!/usr/bin/env python3
"""Verify the final, relocated artifact without launching a game session."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import struct
from game_data import bundled_entries
from recipes import validate_recipe

app = Path(sys.argv[1]).resolve()
assert app.is_dir() and app.suffix == ".app"
probe = app/'Contents/Helpers/Rosetta Request.app/Contents/MacOS/RosettaRequest'
with probe.open('rb') as stream:
    magic, cpu = struct.unpack('<II', stream.read(8))
assert magic == 0xfeedfacf and cpu == 0x01000007, 'Rosetta request helper must be Intel-only'
pins = json.loads((app / "Contents/Resources/runtime-files.json").read_text())
for relative, expected in pins.items():
    assert hashlib.sha256((app / relative).read_bytes()).hexdigest() == expected, relative
assert not any(p.name in {"Gigi", "user.reg", "system.reg"} for p in app.rglob("*"))
# A shader cache embeds the game's own shader bytecode; it is generated on the player's Mac and never shipped.
assert not any(p.name.startswith('mtld3d_shaders') for p in app.rglob('*')), 'A shader cache was packaged'
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
recipe_path = app / 'Contents/Resources/bundle-recipe.json'
if recipe_path.exists():
    recipe = validate_recipe(json.loads(recipe_path.read_text()))
    assert manifest.get('gameID', 'nfsmw') == recipe['gameID']
    for item in recipe['defaults']:
        assert (app / 'Contents/Resources/Defaults' / item['path']).is_file(), item['path']
    key_file = app / 'Contents/Resources/renderer-cache-key.json'
    assert key_file.is_file() == bool(recipe.get('shaderCache')), 'Cache key must exist exactly when the recipe opts in'
    for name in [recipe['launcher'], recipe['session']]:
        assert any((app / 'Contents' / folder / name).is_file() for folder in ['MacOS', 'Helpers'])
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
report['gameID'] = manifest.get('gameID', 'nfsmw')
expected_game_paths = {entry['path'] for entry in entries}
actual_game_paths = {path.relative_to(app / 'Contents/Resources/Game').as_posix()
                     for path in (app / 'Contents/Resources/Game').rglob('*') if path.is_file()}
assert actual_game_paths == expected_game_paths, 'Unexpected or missing game payload files'
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(json.dumps(report, indent=2))
