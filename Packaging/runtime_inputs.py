"""Pin retained runtime artifacts and package their corresponding source and notices."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from optimize_runtime import optimize

PROJECT = Path(__file__).resolve().parents[1]
PINS = json.loads(Path(__file__).with_name('runtime-inputs.json').read_text())


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def clone(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/bin/cp', '-cR', str(source), str(target)], check=True)


def verify_hashes(root, pins, allow_internal_links=False):
    for name, expected in pins.items():
        path = root / name
        if (path.is_symlink() and not allow_internal_links) or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError('Missing or linked pinned artifact: ' + name)
        if digest(path) != expected:
            raise ValueError('Pinned artifact checksum mismatch: ' + name)


def archive_source(repo, name, revision, destination):
    actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True)
    if actual != revision or dirty:
        raise ValueError('Source checkout must be clean at pinned revision: ' + name)
    subprocess.run(['git', '-C', str(repo), 'archive', '--format=tar.gz', revision,
                    '-o', str(destination / (name + '-source.tar.gz'))], check=True)
    (destination / (name + '.patch')).write_text('')


def verify_inputs(recipe, inputs):
    profile = PINS['runtimeProfiles'].get(recipe['runtimeProfile'])
    if profile is None:
        raise ValueError('Unknown pinned runtime profile')
    verify_hashes(inputs['runtime'], profile['files'])
    verify_hashes(inputs['renderer'], PINS['rendererFiles'])
    verify_hashes(inputs['sidecar'].parent, {inputs['sidecar'].name: PINS['sidecarSHA256']})
    verify_hashes(inputs['rendererEvidence'], {'source-sha256.json': PINS['rendererSourceManifestSHA256']})
    source_hashes = json.loads((inputs['rendererEvidence'] / 'source-sha256.json').read_text())
    verify_hashes(inputs['mtld3dSource'], source_hashes, allow_internal_links=True)
    for name, pin in PINS['sources'].items():
        repo = inputs[pin['input']]
        actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        dirty = subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True)
        if actual != pin['revision'] or dirty:
            raise ValueError('Source checkout must be clean at pinned revision: ' + name)
    for directory in ['Sources', 'Licenses']:
        if not (inputs['baseApp'] / 'Contents/Resources' / directory).is_dir():
            raise ValueError('Missing retained corresponding sources or notices')


def stage_runtime(contents, recipe, inputs):
    """Clone the pinned base, replace its complete 32-bit renderer, then optimize the clone."""
    wine = contents / 'SharedSupport/Wine'
    clone(inputs['runtime'], wine)
    renderer = wine / 'lib/wine/d3d9/mtld3d'
    if renderer.exists():
        shutil.rmtree(renderer)
    for name in PINS['rendererFiles']:
        target = wine / 'lib/wine' / name
        if target.exists():
            target.unlink()
        clone(inputs['renderer'] / name, target)
    clone(inputs['sidecar'], contents / 'Helpers/x87sidecar')
    for name in ['include', 'share/man', 'lib/wine/tests', 'lib/wine/d3d9/mtld3d-v0.7.0',
                 'lib/wine/d3d9/mtld3d.before-vertex', 'lib/wine/dxgi/gptk', 'lib/wine/dxgi/dxmt',
                 'lib/external/D3DMetal.framework', 'lib/external/D3DMetal-License.rtf',
                 'lib/external/libd3dshared.dylib']:
        path = wine / name
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
    for path in (wine / 'bin').iterdir():
        if path.name not in {'wine', 'wineserver'}:
            path.unlink()
    for path in wine.rglob('*'):
        if path.is_file() and (path.suffix == '.a' or path.name == '.DS_Store'):
            path.unlink()
    return optimize(wine)


def archive_launcher(resources):
    destination = resources / 'Sources/launcher-source.tar.gz'
    subprocess.run(['/usr/bin/tar', '-czf', str(destination), '-C', str(PROJECT),
                    'Package.swift', 'Sources', 'Tests', 'Packaging', 'README.md', 'docs',
                    'tools', 'PLAN.md', 'SETTINGS-PLAN.md'], check=True)


def collect_sources(resources, inputs):
    retained = inputs['baseApp'] / 'Contents/Resources'
    clone(retained / 'Sources', resources / 'Sources')
    clone(retained / 'Licenses', resources / 'Licenses')
    previous = resources / 'Sources/NFSMW-launcher-source.tar.gz'
    if previous.exists():
        previous.unlink()
    revisions = json.loads((retained / 'runtime-provenance.json').read_text())['sources']
    for name, pin in PINS['sources'].items():
        repo = inputs[pin['input']]
        archive_source(repo, name, pin['revision'], resources / 'Sources')
        shutil.copyfile(repo / 'LICENSE', resources / 'Licenses' / (name + '.txt'))
        revisions[name] = pin['revision']
    archive_launcher(resources)
    return revisions


def runtime_provenance(recipe, revisions):
    return {'sources': revisions, 'sourceURLs': {name: pin['url'] for name, pin in PINS['sources'].items()},
            'wine': PINS['runtimeProfiles'][recipe['runtimeProfile']]['description'],
            'runtimeProfile': recipe['runtimeProfile'],
            'inputRuntimeHashes': PINS['runtimeProfiles'][recipe['runtimeProfile']]['files'],
            'inputRendererHashes': PINS['rendererFiles'], 'inputSidecarSHA256': PINS['sidecarSHA256'],
            'renderer': 'Production PROD=1 PERF=1; normal launch disables telemetry',
            'rendererVerification': '923 passed, 0 failed, 11 ignored; all 535 source hashes match pinned commit',
            'x87': 'Flat cooperative sidecar; tested CoD4 artifact matches current fork build',
            'minimumMacOS': recipe['minimumMacOS'], 'architecture': 'Apple Silicon with Rosetta',
            'gameModeOptIn': True, 'appSandboxEnabled': False, 'hostDriveMappings': False,
            'personalSavesIncluded': False, 'gameExecutableHashes': recipe['executableHashes']}
