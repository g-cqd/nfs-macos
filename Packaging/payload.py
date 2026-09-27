"""Select recipe-declared original assets without following links or exceeding payload limits."""
import hashlib


def inventory(root, files, directories):
    """Return a stable original-asset inventory; reject incomplete or linked inputs."""
    files = set(files)
    selected = []
    for name in sorted(files):
        path = root / name
        if not path.is_file() or path.is_symlink():
            raise ValueError('Missing or linked original asset: ' + name)
        selected.append(path)
    for name, suffixes in directories.items():
        directory = root / name
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError('Missing or linked game directory: ' + name)
        for path in sorted(directory.rglob('*')):
            if path.is_symlink():
                raise ValueError('Game symlinks are not supported')
            if path.is_file() and path.name != '.DS_Store' and (not suffixes or path.suffix.lower() in suffixes):
                selected.append(path)
    entries = []
    total = 0
    seen = set()
    for path in sorted(selected):
        relative = path.relative_to(root).as_posix()
        if relative.casefold() in seen:
            raise ValueError('Duplicate game asset: ' + relative)
        seen.add(relative.casefold())
        size = path.stat().st_size
        total += size
        if size > 8 * 1024**3 or total > 20 * 1024**3 or len(entries) >= 20000:
            raise ValueError('Game payload exceeds packaging limits')
        with path.open('rb') as stream:
            checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
        entries.append({'path': relative, 'size': size, 'sha256': checksum})
    return entries
