"""Select installed CoD4 assets without player files, logs or generated caches."""
from pathlib import PurePosixPath
from payload import inventory as select_inventory

FILES = {'iw3sp.exe', 'iw3mp.exe', 'binkw32.dll', 'mss32.dll', 'localization.txt'}
DIRECTORIES = {'main': {'.iwd', '.bik'}, 'zone': {'.ff'}, 'miles': {'.asi', '.flt'}}


def is_original(path):
    parts = PurePosixPath(path.lower()).parts
    return bool(parts) and (parts[0] in DIRECTORIES if len(parts) > 1 else parts[0] in FILES)


def inventory(root):
    return select_inventory(root, FILES, DIRECTORIES)
