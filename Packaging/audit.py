#!/usr/bin/env python3
"""Verify the final, relocated artifact without launching a game session."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import struct
from bundle_hygiene import (audit_app_tree, audit_build_paths, audit_client_layer, audit_game_payload, audit_managed_runtime,
                            audit_runtime_pins)
from game_data import bundled_entries
from privacy import audit_privacy
from recipes import validate_recipe
from runtime_inputs import PINS

app = Path(sys.argv[1]).resolve()
# The pinned input runtime, when the caller names it, lets the audit compare staged Windows modules with it.
pinned_runtime = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 and sys.argv[2] == '--runtime' else None
assert app.is_dir() and app.suffix == ".app"
probe = app/'Contents/Helpers/Rosetta Request.app/Contents/MacOS/RosettaRequest'
with probe.open('rb') as stream:
    magic, cpu = struct.unpack('<II', stream.read(8))
assert magic == 0xfeedfacf and cpu == 0x01000007, 'Rosetta request helper must be Intel-only'
recipe_path = app / 'Contents/Resources/bundle-recipe.json'
embedded = validate_recipe(json.loads(recipe_path.read_text())) if recipe_path.exists() else {}
# A retained vendor artifact keeps its own signature and its own search paths; it is reported,
# never rewritten, so the gate stays strict for every file this project builds or stages itself.
vendor_roots = [app / 'Contents/SharedSupport/Wine' / name
                for name in embedded.get('vendorRuntimePaths', [])]
pins = json.loads((app / "Contents/Resources/runtime-files.json").read_text())
for relative, expected in pins.items():
    assert hashlib.sha256((app / relative).read_bytes()).hexdigest() == expected, relative
assert not any(p.name in {"Gigi", "user.reg", "system.reg"} for p in app.rglob("*"))
# A shader cache embeds the game's own shader bytecode; it is generated on the player's Mac and never shipped.
assert not any(p.name.startswith('mtld3d_shaders') for p in app.rglob('*')), 'A shader cache was packaged'
report = dict(externalDependencies=[], externalLinks=[], developmentRpaths=[], vendorRpaths=[],
              vendorCode=[], machoCount=0, verifiedRuntimeHashes=len(pins))
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
    is_vendor = any(path == root or root in path.parents for root in vendor_roots)
    if is_vendor:
        report["vendorCode"].append(str(path.relative_to(app)))
    lines = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True).splitlines()[1:]
    for line in lines:
        dependency = line.strip().split(" (")[0]
        if dependency.startswith("/") and not dependency.startswith(("/System/", "/usr/lib/")):
            report["externalDependencies"].append(dependency)
    lines = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True).splitlines()
    for index, line in enumerate(lines):
        if "LC_RPATH" not in line: continue
        rpath = lines[index + 2].strip()
        if is_vendor:
            report["vendorRpaths"].append(rpath)
        elif any(value in rpath for value in ["/Users/", "/Applications/", "/opt/", "/AppleInternal/",
                                              "/Library/Caches/"]):
            report["developmentRpaths"].append(rpath)
assert not any(report[key] for key in ["externalDependencies", "externalLinks", "developmentRpaths"]), report
for relative in report["vendorCode"]:
    authority = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=2", str(app / relative)],
                               capture_output=True, text=True).stderr
    assert "Authority=" in authority, 'A retained vendor artifact must keep a real signature: ' + relative
    assert "adhoc" not in authority, 'A retained vendor artifact was re-signed: ' + relative
manifest = json.loads((app / "Contents/Resources/game-manifest.json").read_text())
if recipe_path.exists():
    recipe = embedded
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
# No archive or checksum file may ride along inside any app. A recipe's own pins then decide the
# rest: the staged runtime must be the pinned one, and a store-client bundled edition must hold
# exactly its pinned game list with no account, session or machine state in it.
hazards = audit_app_tree(app)
hazards += audit_privacy(app)
hazards += audit_build_paths(app, Path.home())
if recipe_path.exists():
    hazards += audit_runtime_pins(app, PINS, embedded, pinned_runtime)
    hazards += audit_managed_runtime(app, manifest, embedded)
    hazards += audit_client_layer(app, manifest, embedded)
    if manifest.get('gameDataIncluded', True) and manifest.get('storeClient'):
        hazards += audit_game_payload(app, manifest, embedded)
        report['pinnedExecutables'] = len(embedded.get('executableHashes', {}))
        report['pinnedInventory'] = embedded.get('inventorySHA256')
assert not hazards, hazards
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(json.dumps(report, indent=2))
