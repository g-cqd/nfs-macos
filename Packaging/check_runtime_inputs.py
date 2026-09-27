"""Packaging rejects unpinned artifacts and records exact source revisions."""
from pathlib import Path
from tempfile import TemporaryDirectory
import hashlib
from runtime_inputs import verify_hashes


with TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / 'module').write_bytes(b'known artifact')
    pins = {'module': hashlib.sha256(b'known artifact').hexdigest()}
    verify_hashes(root, pins)
    (root / 'module').write_bytes(b'other artifact')
    try: verify_hashes(root, pins)
    except ValueError: pass
    else: raise AssertionError('Changed runtime artifact was accepted')
    (root / 'module').unlink()
    try: verify_hashes(root, pins)
    except ValueError: pass
    else: raise AssertionError('Missing runtime artifact was accepted')
    (root / 'module').symlink_to('/dev/null')
    try: verify_hashes(root, pins)
    except ValueError: pass
    else: raise AssertionError('External runtime artifact link was accepted')
    (root / 'module').unlink()
    (root / 'target').write_bytes(b'known artifact')
    (root / 'module').symlink_to('target')
    verify_hashes(root, pins, allow_internal_links=True)
print('Pinned runtime input regressions passed')
