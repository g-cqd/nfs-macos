"""Original PC assets omitted from a package that imports its user's installation."""
from pathlib import PurePosixPath

ORIGINAL_FOLDERS = {"cars", "credits", "frontend", "global", "languages", "memcard",
                    "movies", "nis", "sound", "subtitles", "tracks"}
ORIGINAL_FILES = {"speed.exe", "bin.dat", "server.cfg", "server.dll"}


def is_original(path):
    parts = PurePosixPath(path.lower()).parts
    return bool(parts) and (parts[0] in ORIGINAL_FOLDERS if len(parts) > 1 else parts[0] in ORIGINAL_FILES)


def omit_original_data(root, entries):
    for entry in entries:
        if is_original(entry["path"]):
            (root / entry["path"]).unlink()


def bundled_entries(manifest):
    if manifest.get("gameDataIncluded", True):
        return manifest["gameFiles"]
    return [entry for entry in manifest["gameFiles"] if not is_original(entry["path"])]
