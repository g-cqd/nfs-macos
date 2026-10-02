"""Archive audited apps with ZIP64 support and Unix file/link metadata."""
import argparse
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import zipfile


def create_archive(app: Path, archive: Path) -> None:
    """Publish a CRC-verified archive without replacing an existing output.

    Input must be an immutable, audited app with no external symlinks or special
    files. File contents (including signatures and stapled tickets), permissions,
    and internal symlinks are retained. Finder metadata and ACLs are not copied;
    the signing stage already clears source extended attributes.
    """
    if app.is_symlink() or not app.is_dir() or app.suffix != '.app':
        raise ValueError('Input must be an app directory')
    if os.path.lexists(archive):
        raise FileExistsError(archive)
    app = app.resolve()
    if archive.parent.resolve().is_relative_to(app):
        raise ValueError('Archive output must be outside the input app')
    descriptor, pending_name = tempfile.mkstemp(prefix='.app-archive-', dir=archive.parent)
    pending = Path(pending_name)
    try:
        with os.fdopen(descriptor, 'w+b') as stream:
            with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED,
                                 compresslevel=6, allowZip64=True) as zipped:
                for path in [app, *sorted(app.rglob('*'))]:
                    name = path.relative_to(app.parent).as_posix()
                    mode = path.lstat().st_mode
                    if stat.S_ISLNK(mode):
                        target = path.readlink()
                        if target.is_absolute() or not path.resolve().is_relative_to(app):
                            raise ValueError('App contains an external symlink: ' + name)
                        info = zipfile.ZipInfo(name)
                        info.create_system = 3
                        info.external_attr = mode << 16
                        zipped.writestr(info, os.fsencode(target))
                    elif stat.S_ISREG(mode) or stat.S_ISDIR(mode):
                        zipped.write(path, name)
                    else:
                        raise ValueError('App contains a special file: ' + name)
        with zipfile.ZipFile(pending) as zipped:
            corrupt = zipped.testzip()
            if corrupt:
                raise ValueError('Archive verification failed: ' + corrupt)
        # A same-directory hard link publishes atomically and refuses a raced output.
        os.link(pending, archive)
    finally:
        pending.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('archive', type=Path)
    options = parser.parse_args()
    create_archive(options.app, options.archive)
    with options.archive.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    options.archive.with_suffix('.zip.sha256').write_text(checksum + '  ' + options.archive.name + '\n')
    print('Archive:', options.archive)
    print('SHA-256:', checksum)


if __name__ == '__main__':
    main()
