"""A runtime-only package keeps fixes and its complete import inventory."""
from pathlib import Path
from tempfile import TemporaryDirectory
from game_data import omit_original_data, bundled_entries

entries = [{"path": path} for path in ["speed.exe", "CARS/BMW/GEOMETRY.BIN", "scripts/fix.asi", "dinput8.dll"]]
with TemporaryDirectory() as temporary:
    root = Path(temporary)
    for entry in entries:
        path = root / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture")
    omit_original_data(root, entries)
    assert not (root / "speed.exe").exists()
    assert not (root / "CARS/BMW/GEOMETRY.BIN").exists()
    assert (root / "scripts/fix.asi").read_bytes() == b"fixture"
    assert (root / "dinput8.dll").read_bytes() == b"fixture"
    assert [entry["path"] for entry in bundled_entries({"gameFiles": entries, "gameDataIncluded": False})] == ["scripts/fix.asi", "dinput8.dll"]
    assert bundled_entries({"gameFiles": entries}) == entries
    assert len(entries) == 4
print("Runtime-only packaging regression passed")
