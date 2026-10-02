"""Packaging rejects unpinned artifacts and records exact source revisions."""
from pathlib import Path
from tempfile import TemporaryDirectory
import hashlib
import json
from pathlib import Path as _Path
import subprocess
import tarfile
import runtime_inputs
from runtime_inputs import PINS, collect_sources, runtime_provenance, verify_hashes


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
# A source an app does not build must not inherit the retained base app's revision for it, and an app
# that installs no renderer must not claim a renderer verification: the Need for Speed (2015) app
# carried an mtld3d revision, an archive and a test claim that described the Most Wanted base app.
with TemporaryDirectory() as temporary:
    root = Path(temporary)
    base = root / 'base/Contents/Resources'
    (base / 'Sources').mkdir(parents=True)
    (base / 'Licenses').mkdir()
    for name in ['mtld3d-source.tar.gz', 'mtld3d.patch', 'x87sidecar-source.tar.gz', 'x87sidecar.patch',
                 'wine-source.tar.gz']:
        (base / 'Sources' / name).write_bytes(b'inherited')
    (base / 'Licenses/mtld3d.txt').write_text('licence')
    (base / 'runtime-provenance.json').write_text(json.dumps({'sources': {
        'mtld3d': '2513602' + '0' * 33, 'x87sidecar': 'old', 'wine': 'f064add'}}))
    repo = root / 'x87'
    repo.mkdir()
    (repo / 'LICENSE').write_text('licence')
    for command in [['init', '-q'], ['add', 'LICENSE'],
                    ['-c', 'core.hooksPath=/dev/null', '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'x']]:
        subprocess.run(['git', '-C', str(repo)] + command, check=True)
    head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    saved = (runtime_inputs.archive_launcher, PINS['sources']['x87sidecar']['revision'])
    runtime_inputs.archive_launcher = lambda resources: None
    PINS['sources']['x87sidecar']['revision'] = head
    try:
        resources = root / 'out'
        resources.mkdir()
        revisions = collect_sources(resources, {'baseApp': root / 'base', 'x87Source': repo})
    finally:
        runtime_inputs.archive_launcher, PINS['sources']['x87sidecar']['revision'] = saved
    assert 'mtld3d' not in revisions, 'A revision the app does not build was inherited'
    assert revisions['x87sidecar'] == head and revisions['wine'] == 'f064add'
    assert not (resources / 'Sources/mtld3d-source.tar.gz').exists()
    assert not (resources / 'Sources/mtld3d.patch').exists()
    assert (resources / 'Sources/x87sidecar-source.tar.gz').read_bytes() != b'inherited'
    recipe = {'runtimeProfile': 'nfs2015-tf-cx11', 'minimumMacOS': '15.0', 'executableHashes': {}}
    provenance = runtime_provenance(recipe, revisions)
    assert 'mtld3d' not in provenance['sources'] and 'mtld3d' not in provenance['sourceURLs']
    assert set(provenance['sourcesNotApplicable']) == {'mtld3d'}
    assert not {'renderer', 'rendererVerification', 'inputRendererHashes'} & set(provenance)
    renderer = runtime_provenance(recipe, {**revisions, 'mtld3d': PINS['sources']['mtld3d']['revision']})
    assert renderer['sourcesNotApplicable'] == {} and renderer['rendererVerification'] == PINS['rendererVerification']
    assert renderer['inputRendererHashes'] == PINS['rendererFiles']
# The launcher source an app carries is the tracked source only: no bytecode caches, which record the
# absolute path of each source file, and recipes whose input roots were this Mac's paths.
with TemporaryDirectory() as temporary:
    resources = Path(temporary)
    (resources / 'Sources').mkdir()
    runtime_inputs.archive_launcher(resources)
    home = str(_Path.home()).encode()
    with tarfile.open(resources / 'Sources/launcher-source.tar.gz') as archive:
        members = [member for member in archive if member.isfile()]
        names = {member.name for member in members}
        assert 'Packaging/runtime_inputs.py' in names and 'Packaging/Recipes/nfs2015.json' in names
        assert not [name for name in names if '__pycache__' in name or name.endswith(('.pyc', '.DS_Store'))
                    or '/._' in name or name.startswith('._')], 'Build leftovers or AppleDouble files were archived'
        for member in members:
            data = archive.extractfile(member).read()
            assert home not in data or not data.strip(), member.name + ' carries the build Mac home folder'
            if member.name.startswith('Packaging/Recipes/'):
                inputs = json.loads(data)['inputs']
                assert inputs and set(inputs.values()) == {'build input, not shipped'}, member.name
print('Pinned runtime input regressions passed')
