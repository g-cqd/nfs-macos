"""The persistent shader cache key tracks mtld3d's emitter inputs, is written only for opted-in recipes
and never lets a game-derived cache into an app."""
from copy import deepcopy
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from recipes import load_recipe, validate_recipe
from shader_cache_key import (KEY_FILE, cache_key, cache_versions, emitter_digest, emitter_sources,
                              stage_cache_key)

PROJECT = Path(__file__).resolve().parents[1]
FIXTURE = PROJECT / 'Packaging/fixtures/renderer-cache-key.json'
REVISION = '0123456789abcdef0123456789abcdef01234567'
CACHE_SOURCE = 'pub const SHADER_CACHE_SCHEMA_VERSION: u32 = 79;\npub const CACHE_FORMAT_VERSION: u32 = 20;\n'


def write(root, files):
    for name, data in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode())


def synthetic(root, **changes):
    """A miniature mtld3d checkout: invented emitter sources, with files that must not count."""
    core = 'windows/core/'
    files = {
        core + 'src/dxso/emit.rs': 'fn emit() {}\n',
        core + 'src/dxso/sub/parse.rs': 'fn parse() {}\n',
        core + 'src/dxso/tests.rs': 'fn ignored() {}\n',
        core + 'src/dxso/emit_tests.rs': 'fn ignored() {}\n',
        core + 'src/dxso/notes.txt': 'not Rust\n',
        core + 'src/dxso/sub/parse_tests/case.rs': 'fn ignored() {}\n',
        core + 'src/dxso.rs': 'mod emit;\n',
        core + 'src/vs_draw.rs': 'fn vs() {}\n',
        core + 'src/ps_draw.rs': 'fn ps() {}\n',
        core + 'src/shader_cache.rs': CACHE_SOURCE,
        core + 'src/unrelated.rs': 'fn other() {}\n',
        'unix/shared/src/mtl.rs': 'fn mtl() {}\n',
    }
    files.update(changes)
    write(root, files)
    return root


def digest_of(**changes):
    with TemporaryDirectory() as temporary:
        root = synthetic(Path(temporary), **changes)
        return emitter_digest(root / 'windows/core')


def rejects(action, text):
    try: action()
    except ValueError: return
    raise AssertionError('Accepted: ' + text)


with TemporaryDirectory() as temporary:
    root = synthetic(Path(temporary))
    core = root / 'windows/core'
    # The set and order mirror build.rs: component-wise ordering puts src/dxso/... before src/dxso.rs, and
    # the parent-directory file sorts first.
    assert emitter_sources(core) == [
        '../../unix/shared/src/mtl.rs', 'src/dxso/emit.rs', 'src/dxso/sub/parse.rs', 'src/dxso.rs',
        'src/ps_draw.rs', 'src/vs_draw.rs']
    assert cache_versions(core) == {'shaderSchemaVersion': 79, 'cacheFormatVersion': 20}
    key = cache_key(root, REVISION)
    assert key == {'schemaVersion': 1, 'mtld3dRevision': REVISION, 'shaderSchemaVersion': 79,
                   'cacheFormatVersion': 20, 'emitterDigest': key['emitterDigest'], 'emitterFileCount': 6}
    # The Swift tests decode this same file; keep it identical to what the packager writes.
    assert FIXTURE.read_text() == json.dumps(key, indent=2, sort_keys=True) + '\n', \
        'Regenerate Packaging/fixtures/renderer-cache-key.json from the synthetic tree'

base, count = digest_of()
assert count == 6 and len(base) == 64
assert digest_of() == (base, 6), 'the digest must be deterministic'
# Anything the emitter reads changes it; anything it does not read leaves it alone.
for name in ['src/dxso/emit.rs', 'src/dxso/sub/parse.rs', 'src/dxso.rs', 'src/vs_draw.rs', 'src/ps_draw.rs']:
    assert digest_of(**{'windows/core/' + name: 'fn changed() {}\n'})[0] != base, name
assert digest_of(**{'unix/shared/src/mtl.rs': 'fn changed() {}\n'})[0] != base
assert digest_of(**{'windows/core/src/dxso/added.rs': 'fn added() {}\n'})[0] != base
for name in ['src/dxso/tests.rs', 'src/dxso/emit_tests.rs', 'src/dxso/notes.txt', 'src/unrelated.rs',
             'src/shader_cache.rs', 'src/dxso/sub/parse_tests/case.rs']:
    other = {'windows/core/' + name: 'changed\n'}
    if name == 'src/shader_cache.rs':
        other = {'windows/core/' + name: CACHE_SOURCE + '// comment\n'}
    assert digest_of(**other)[0] == base, 'must not depend on ' + name
assert digest_of(**{'windows/core/src/dxso/added_tests.rs': 'x'})[0] == base
# Names and contents are length prefixed, so bytes cannot move between them unnoticed.
assert digest_of(**{'windows/core/src/dxso/emit.rs': 'fn emit() {}\n', 'windows/core/src/dxso/a.rs': 'b'})[0] != \
    digest_of(**{'windows/core/src/dxso/emit.rs': 'fn emit() {}\n', 'windows/core/src/dxso/ab.rs': ''})[0]

# A damaged checkout is refused, never hashed partially.
with TemporaryDirectory() as temporary:
    root = synthetic(Path(temporary))
    core = root / 'windows/core'
    (core / 'src/vs_draw.rs').unlink()
    rejects(lambda: emitter_digest(core), 'a missing emitter source')
with TemporaryDirectory() as temporary:
    root = synthetic(Path(temporary))
    core = root / 'windows/core'
    (core / 'src/ps_draw.rs').unlink()
    (core / 'src/ps_draw.rs').symlink_to('vs_draw.rs')
    rejects(lambda: emitter_digest(core), 'a linked emitter source')
with TemporaryDirectory() as temporary:
    root = synthetic(Path(temporary))
    (root / 'windows/core/src/dxso/linked.rs').symlink_to('emit.rs')
    rejects(lambda: emitter_digest(root / 'windows/core'), 'a linked file inside the emitter directory')
for text in ['', 'pub const SHADER_CACHE_SCHEMA_VERSION: u32 = 79;\n',
             CACHE_SOURCE + 'pub const CACHE_FORMAT_VERSION: u32 = 21;\n',
             CACHE_SOURCE.replace('79', 'x')]:
    with TemporaryDirectory() as temporary:
        root = synthetic(Path(temporary), **{'windows/core/src/shader_cache.rs': text})
        rejects(lambda: cache_versions(root / 'windows/core'), 'cache constants: ' + repr(text))
for revision in ['', 'abc', REVISION.upper(), REVISION[:-1], REVISION + '0', None, 123]:
    with TemporaryDirectory() as temporary:
        root = synthetic(Path(temporary))
        rejects(lambda: cache_key(root, revision), 'revision ' + repr(revision))

# Only a recipe that opts in gets a key file, and it cannot opt in without the source to derive it from.
farcry2 = load_recipe('farcry2')
assert farcry2['shaderCache'] is True
for name in ['nfsmw', 'cod4']:
    assert 'shaderCache' not in load_recipe(name)
with TemporaryDirectory() as temporary:
    root = synthetic(Path(temporary) / 'mtld3d')
    resources = Path(temporary) / 'resources'
    resources.mkdir()
    assert stage_cache_key(resources, {}, {'mtld3dSource': root}, REVISION) is None
    assert stage_cache_key(resources, {'shaderCache': False}, {'mtld3dSource': root}, REVISION) is None
    assert not (resources / KEY_FILE).exists()
    staged = stage_cache_key(resources, farcry2, {'mtld3dSource': root}, REVISION)
    assert json.loads((resources / KEY_FILE).read_text()) == staged == cache_key(root, REVISION)
for change in [lambda r: r.update(shaderCache='true'), lambda r: r.update(shaderCache=1),
               lambda r: r['inputs'].pop('mtld3dSource')]:
    altered = deepcopy(farcry2)
    change(altered)
    rejects(lambda: validate_recipe(altered), 'an invalid shaderCache declaration')
altered = deepcopy(farcry2)
altered['shaderCache'] = False
altered['inputs'].pop('mtld3dSource')
validate_recipe(altered)

# Privacy: nothing the cache could hold may be committed or packaged with the project.
skipped = {'.build', '.git', 'Build', 'Evidence', '__pycache__'}
offenders = [str(path.relative_to(PROJECT)) for path in PROJECT.rglob('*')
             if path.is_file() and not any(part in skipped for part in path.relative_to(PROJECT).parts)
             and (path.name.startswith('mtld3d_shaders') or path.suffix == '.fc2shadercache')]
assert not offenders, offenders
print('Shader cache key regressions passed')
