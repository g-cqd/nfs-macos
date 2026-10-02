"""Identify the persistent shader cache a pinned mtld3d build reads and writes.

mtld3d keeps `mtld3d_shaders.bin` with a header (container format and shader schema, both integers in
`windows/core/src/shader_cache.rs`) and, in every record, a fingerprint of its MSL emitter. The
fingerprint is an xxh3 hash that mtld3d's `build.rs` computes over a fixed set of sources. This module
does not reproduce xxh3; it hashes the same set of files, with the same delimiting, using SHA-256. The
digest therefore changes exactly when mtld3d's own fingerprint input changes, and the app can compare
caches without reading a Rust binary. The pinned revision is part of the key too, so a different pin
never loads another pin's cache even if the emitter sources happen to match.
"""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

KEY_FILE = 'renderer-cache-key.json'
KEY_SCHEMA = 1

# Mirrors windows/core/build.rs `emitter_fingerprint`; paths are relative to windows/core.
EMITTER_DIRECTORY = 'src/dxso'
EMITTER_FILES = ('src/dxso.rs', 'src/vs_draw.rs', 'src/ps_draw.rs', '../../unix/shared/src/mtl.rs')
CORE = 'windows/core'
CACHE_SOURCE = 'src/shader_cache.rs'
REVISION = re.compile('[0-9a-f]{40}')


def _collect(root, relative, found):
    """Walks a directory as build.rs does: `tests` and `*_tests` entries are skipped, `.rs` files kept."""
    for entry in root.joinpath(relative).iterdir():
        stem = entry.name.rsplit('.', 1)[0] if '.' in entry.name else entry.name
        if stem == 'tests' or stem.endswith('_tests'):
            continue
        child = f'{relative}/{entry.name}'
        if entry.is_symlink():
            raise ValueError('Emitter source must not be a link: ' + child)
        if entry.is_dir():
            _collect(root, child, found)
        elif entry.suffix == '.rs':
            found.append(child)


def emitter_sources(core):
    """The files whose bytes define the emitter, in the order mtld3d hashes them.

    Rust orders paths component by component, so `src/dxso/a.rs` precedes `src/dxso.rs`.
    """
    core = Path(core)
    found = []
    _collect(core, EMITTER_DIRECTORY, found)
    found.extend(EMITTER_FILES)
    found.sort(key=lambda value: PurePosixPath(value).parts)
    for relative in found:
        path = core / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError('Missing emitter source: ' + relative)
    return found


def emitter_digest(core):
    """SHA-256 over each path and file, both length-prefixed (u64 little endian), plus the file count."""
    core = Path(core)
    sources = emitter_sources(core)
    digest = hashlib.sha256()
    for relative in sources:
        data = (core / relative).read_bytes()
        name = relative.encode()
        for part in (name, data):
            digest.update(len(part).to_bytes(8, 'little'))
            digest.update(part)
    return digest.hexdigest(), len(sources)


def cache_versions(core):
    """The container format and shader schema integers mtld3d writes into every cache header."""
    text = (Path(core) / CACHE_SOURCE).read_text()
    found = {}
    for name, key in [('SHADER_CACHE_SCHEMA_VERSION', 'shaderSchemaVersion'),
                      ('CACHE_FORMAT_VERSION', 'cacheFormatVersion')]:
        matches = re.findall(rf'^pub const {name}: u32 = (\d+);$', text, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError('Cannot read ' + name + ' from ' + CACHE_SOURCE)
        found[key] = int(matches[0])
    return found


def cache_key(mtld3d_root, revision):
    if not isinstance(revision, str) or not REVISION.fullmatch(revision):
        raise ValueError('The mtld3d revision must be a full lowercase commit hash')
    core = Path(mtld3d_root) / CORE
    digest, count = emitter_digest(core)
    return {'schemaVersion': KEY_SCHEMA, 'mtld3dRevision': revision, **cache_versions(core),
            'emitterDigest': digest, 'emitterFileCount': count}


def stage_cache_key(resources, recipe, inputs, revision):
    """Writes the key beside the manifest for a recipe that opts in; returns it, or None."""
    if not recipe.get('shaderCache'):
        return None
    key = cache_key(inputs['mtld3dSource'], revision)
    (Path(resources) / KEY_FILE).write_text(json.dumps(key, indent=2, sort_keys=True) + '\n')
    return key
