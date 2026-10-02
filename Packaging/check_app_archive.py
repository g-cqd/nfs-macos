"""ZIP64 app archives retain file bytes, executable modes, and internal links."""
from pathlib import Path
import stat
import subprocess
from tempfile import TemporaryDirectory
from unittest.mock import patch
import zipfile
from app_archive import create_archive


with TemporaryDirectory(prefix='app-archive-check-') as temporary:
    root = Path(temporary)
    app = root / 'Fixture.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    executable = app / 'Contents/MacOS/Fixture'
    executable.write_bytes(bytes(range(256)) * 8)
    executable.chmod(0o755)
    (app / 'Contents/CodeResources').write_bytes(b'stapled-ticket-fixture')
    (app / 'Contents/.hidden').write_bytes(b'hidden-resource')
    (app / 'Contents/current').symlink_to('MacOS/Fixture')
    archive = root / 'Fixture.zip'
    # Lower the standard library threshold to exercise both ZIP64 sizes and offsets.
    with patch.object(zipfile, 'ZIP64_LIMIT', 64):
        create_archive(app, archive)
    assert b'PK\x06\x06' in archive.read_bytes()
    with zipfile.ZipFile(archive) as zipped:
        assert zipped.testzip() is None
        assert zipped.read('Fixture.app/Contents/CodeResources') == b'stapled-ticket-fixture'
    extracted = root / 'extracted'
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(extracted)], check=True)
    copied = extracted / app.name
    assert (copied / 'Contents/MacOS/Fixture').read_bytes() == executable.read_bytes()
    assert stat.S_IMODE((copied / 'Contents/MacOS/Fixture').stat().st_mode) == 0o755
    assert (copied / 'Contents/current').is_symlink()
    assert (copied / 'Contents/current').readlink() == Path('MacOS/Fixture')
    assert (copied / 'Contents/.hidden').read_bytes() == b'hidden-resource'
    before = archive.read_bytes()
    try: create_archive(app, archive)
    except FileExistsError: pass
    else: raise AssertionError('Existing archive was replaced')
    assert archive.read_bytes() == before
    with patch('app_archive.tempfile.mkstemp', side_effect=AssertionError('Allocated output inside input')):
        try: create_archive(app, app / 'nested.zip')
        except ValueError: pass
        else: raise AssertionError('Output inside input was accepted')
    (app / 'Contents/escape').symlink_to('/etc/passwd')
    try: create_archive(app, root / 'rejected.zip')
    except ValueError: pass
    else: raise AssertionError('External link was accepted')
    assert not (root / 'rejected.zip').exists()
    assert not list(root.glob('.app-archive-*'))
print('ZIP64 app archive round-trip, existing-output and failure-cleanup checks passed')
