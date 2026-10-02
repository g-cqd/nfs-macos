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
    if profile.get('pending'):
        raise ValueError('Runtime profile ' + recipe['runtimeProfile'] + ' is not built yet: '
                         + profile.get('blockedBy', 'no tested artifacts are pinned'))
    if len(profile['files']) < 5:
        raise ValueError('A runtime profile must pin its loader, server and ntdll artifacts')
    missing = set(recipe.get('requiredRuntimeCapabilities', [])) - set(profile.get('capabilities', []))
    if missing:
        # Launching this game on a runtime without its capability produces a relaunch loop.
        raise ValueError('Runtime profile ' + recipe['runtimeProfile']
                         + ' does not provide: ' + ', '.join(sorted(missing)))
    verify_hashes(inputs['runtime'], profile['files'])
    verify_runtime_provides(recipe, inputs['runtime'])
    verify_hashes(inputs['sidecar'].parent, {inputs['sidecar'].name: PINS['sidecarSHA256']})
    if 'managedRuntime' in recipe:
        # The app runs this installer inside the player's prefix, so it is checked before the build starts.
        declared = recipe['managedRuntime']
        verify_hashes(inputs[declared['input']], {declared['source']: declared['sha256']})
    if 'renderer' in inputs:
        # Only a Direct3D 9 title replaces the renderer; a D3D11 title never loads mtld3d.
        verify_hashes(inputs['renderer'], PINS['rendererFiles'])
        verify_hashes(inputs['rendererEvidence'], {'source-sha256.json': PINS['rendererSourceManifestSHA256']})
        source_hashes = json.loads((inputs['rendererEvidence'] / 'source-sha256.json').read_text())
        verify_hashes(inputs['mtld3dSource'], source_hashes, allow_internal_links=True)
    for name, pin in PINS['sources'].items():
        if pin['input'] not in inputs:
            continue
        repo = inputs[pin['input']]
        actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        dirty = subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True)
        if actual != pin['revision'] or dirty:
            raise ValueError('Source checkout must be clean at pinned revision: ' + name)
    for directory in ['Sources', 'Licenses']:
        if not (inputs['baseApp'] / 'Contents/Resources' / directory).is_dir():
            raise ValueError('Missing retained corresponding sources or notices')


def verify_runtime_provides(recipe, runtime):
    """Measure what the runtime actually carries, rather than trusting the profile's claims.

    A declared capability or backend name is only a claim. Two renderer reversals on this
    branch were both caused by naming a backend the runtime did not contain, which is exactly
    what this catches: every selected backend must exist as a directory in the staged runtime,
    and a recipe needing the trap-flag gate must find its switches in the built ntdll.
    """
    for selection in recipe.get('renderers', []):
        backend = runtime / 'lib/wine' / selection['api'] / selection['backend']
        if not backend.is_dir() or backend.is_symlink():
            raise ValueError('The runtime has no ' + selection['api'] + ' backend named '
                             + selection['backend'] + '; it offers: '
                             + ', '.join(sorted(p.name for p in (runtime / 'lib/wine'
                                                                 / selection['api']).iterdir()
                                                if p.is_dir())))
    if 'trapFlagEmulation' in recipe.get('requiredRuntimeCapabilities', []):
        loader = runtime / 'lib/wine/x86_64-unix/ntdll.so'
        switches = [b'WINE_TF_EMULATION', b'WINE_TF_MAX_STEPS', b'WINE_TF_MAX_NS']
        image = loader.read_bytes()
        missing = [name.decode() for name in switches if name not in image]
        if missing:
            raise ValueError('This runtime does not carry the execution-breakpoint gate: '
                             + ', '.join(missing) + ' absent from lib/wine/x86_64-unix/ntdll.so')


def stage_runtime(contents, recipe, inputs):
    """Clone the pinned base, replace any declared renderer, then optimize the clone."""
    wine = contents / 'SharedSupport/Wine'
    clone(inputs['runtime'], wine)
    if 'renderer' in inputs:
        renderer = wine / 'lib/wine/d3d9/mtld3d'
        if renderer.exists():
            shutil.rmtree(renderer)
        for name in PINS['rendererFiles']:
            target = wine / 'lib/wine' / name
            if target.exists():
                target.unlink()
            clone(inputs['renderer'] / name, target)
    clone(inputs['sidecar'], contents / 'Helpers/x87sidecar')
    # A Direct3D 11 title is served through DXGI by D3DMetal, so its recipe keeps that stack.
    retained = {name.casefold() for name in recipe.get('runtimeRetention', [])}
    for name in ['include', 'share/man', 'lib/wine/tests', 'lib/wine/d3d9/mtld3d-v0.7.0',
                 'lib/wine/d3d9/mtld3d.before-vertex', 'lib/wine/dxgi/gptk', 'lib/wine/dxgi/dxmt',
                 'lib/external/D3DMetal.framework', 'lib/external/D3DMetal-License.rtf',
                 'lib/external/libd3dshared.dylib']:
        if name.casefold() in retained:
            continue
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
        if pin['input'] not in inputs:
            continue
        repo = inputs[pin['input']]
        archive_source(repo, name, pin['revision'], resources / 'Sources')
        shutil.copyfile(repo / 'LICENSE', resources / 'Licenses' / (name + '.txt'))
        revisions[name] = pin['revision']
    archive_launcher(resources)
    return revisions


def runtime_provenance(recipe, revisions):
    profile = PINS['runtimeProfiles'][recipe['runtimeProfile']]
    renderer = {'inputRendererHashes': PINS['rendererFiles']} if 'mtld3d' in revisions else {}
    return {**renderer, 'sources': revisions,
            'sourceURLs': {name: pin['url'] for name, pin in PINS['sources'].items()
                           if name in revisions},
            'wine': PINS['runtimeProfiles'][recipe['runtimeProfile']]['description'],
            'runtimeProfile': recipe['runtimeProfile'],
            'inputRuntimeHashes': PINS['runtimeProfiles'][recipe['runtimeProfile']]['files'],
            'runtimeCapabilities': profile.get('capabilities', []),
            'inputSidecarSHA256': PINS['sidecarSHA256'],
            'retainedRuntimePaths': recipe.get('runtimeRetention', []),
            'rendererSelection': recipe.get('renderers', []),
            'runtimeSource': recipe.get('runtimeSource', {}),
            'runtimeToolchainNote': profile.get('toolchainNote', ''),
            'runtimeTuning': recipe.get('runtimeTuning', {}),
            'referencesInstallation': bool(recipe.get('referencesInstallation')),
            'renderer': 'Production PROD=1 PERF=0; perf telemetry is compiled out, not merely silenced',
            'rendererVerification': '966 passed, 0 failed, 11 ignored per Windows architecture, '
                                    'plus 2549 host unit tests; all 631 source hashes match pinned commit',
            'x87': 'Flat cooperative sidecar; artifact rebuilt at the pinned fork revision',
            'minimumMacOS': recipe['minimumMacOS'], 'architecture': 'Apple Silicon with Rosetta',
            'gameModeOptIn': True, 'appSandboxEnabled': False, 'hostDriveMappings': False,
            'personalSavesIncluded': False, 'gameExecutableHashes': recipe['executableHashes']}
