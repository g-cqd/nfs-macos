#!/usr/bin/env python3
"""Capture the EA client layer: install EA's official installer once, offline, in a pristine prefix.

BUILD-TIME tool. Needs an app of this line that has no client layer yet (its helper makes the pristine
prefix with the app's own `--prepare`), EA's installer, and, unless a payload folder is given, the
network for one step: the installer's own `/layout`, which only downloads its MSI into a folder.

    tools/capture-client-layer.py --host-app <layerless app> --installer <EAappInstaller.exe> \\
        --work <new scratch folder> --output <new layer folder> [--payload <folder>] \\
        [--save-payload <new folder>] [--expect-installer-sha256 H] [--expect-package-sha256 H]

What it does, in order, and what it refuses:
  1. Verifies the installer is Authenticode-signed by Electronic Arts, Inc., and records its SHA-256.
  2. Makes a pristine prefix with the host app's `--prepare` (wineboot, registry settings, the game
     copy, and Wine Mono installed first), and snapshots it as the baseline.
  3. Downloads the MSI with `/layout` in a clone of that prefix (the only use of the network; the
     clone is deleted), and records the MSI's SHA-256.
  4. Runs the installer `/quiet` in the pristine prefix under a sandbox that denies every IP
     connection, so the client can never reach EA's sign-in, and ends the Windows side the moment
     the installer exits. A client process that appears is killed at once. Nothing is ever typed.
  5. Classifies every new file and registry key with Packaging/client_layer.py's policy and writes the
     layer. An unclassified or forbidden item stops the run.
  6. Gates: the cached packages equal the pinned installer and MSI byte for byte; no identifier of this
     Mac or of the captured machine state occurs in any kept byte; applying the layer to a clone of the
     baseline gives exactly the installed files and keys; the client never started.
The scratch prefix is deleted at the end, whatever happens, unless --keep is given.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Packaging'))
import authenticode  # noqa: E402
import client_layer as layer  # noqa: E402

PUBLISHER = 'Electronic Arts, Inc.'
OFFLINE_PROFILE = '(version 1)\n(allow default)\n(deny network-outbound (remote ip))\n(deny network-bind (local ip))\n'
CLIENT_PROCESS = re.compile(r'\\EADesktop\.exe')


def log(message):
    print('capture:', message, flush=True)


class Host:
    """The host app's Wine, run with the environment the app's own session helper gives it."""

    def __init__(self, app, support):
        self.app, self.support = Path(app).resolve(), Path(support).resolve()
        self.prefix = self.support / 'Data/Prefix'
        self.recipe = json.loads((self.app / 'Contents/Resources/bundle-recipe.json').read_text())
        self.manifest = json.loads((self.app / 'Contents/Resources/game-manifest.json').read_text())
        self.wine = self.app / 'Contents/SharedSupport/Wine/bin/wine'
        self.wineserver = self.app / 'Contents/SharedSupport/Wine/bin/wineserver'

    def environment(self, managed):
        """Mirrors LaunchEnvironment.make for this game; the layer does not depend on the renderer rules."""
        rules = ['v=3'] + ['name=nfs2015-%d;exe=%s;%s=%s' % (index, item['executable'], item['api'], item['backend'])
                           for index, item in enumerate(self.recipe['renderers'])]
        overrides = 'IGOProxy32.exe=d;winemenubuilder.exe=d;' + ('mshtml=' if managed else 'mscoree,mshtml=')
        home = self.support / 'RuntimeHome/Player'
        environment = {'HOME': str(home), 'USER': home.name, 'LOGNAME': home.name,
                       'TMPDIR': str(self.support / 'Temporary'), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                       'LANG': 'en_US.UTF-8', 'WINEPREFIX': str(self.prefix), 'WINEDEBUG': '-all',
                       'WINEDLLOVERRIDES': overrides, 'ROSETTA_X87_PATH': str(self.app / 'Contents/Helpers/x87sidecar'),
                       'WINEMSYNC': '1', 'WINE_COMPATDB': '\n'.join(rules), 'MTL_HUD_ENABLED': '0',
                       'RUST_LOG': 'warn,mtld3d::perf=off'}
        environment.update(self.recipe.get('runtimeTuning', {}))
        return environment

    def run(self, arguments, *, managed=True, sandbox=False, timeout=1800, watcher=None):
        command = [str(self.wine)] + arguments
        if sandbox:
            profile = self.support / 'offline.sb'
            profile.write_text(OFFLINE_PROFILE)
            command = ['/usr/bin/sandbox-exec', '-f', str(profile)] + command
        process = subprocess.Popen(command, env=self.environment(managed), cwd=self.support,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + timeout
        while process.poll() is None:
            if watcher is not None:
                watcher(process)
            if time.monotonic() > deadline:
                process.kill()
                raise TimeoutError('Wine did not finish within %d s: %s' % (timeout, arguments[:1]))
            time.sleep(0.25)
        return process.returncode

    def stop(self):
        environment = self.environment(True)
        subprocess.run([str(self.wineserver), '-k'], env=environment, cwd=self.support, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        subprocess.run([str(self.wineserver), '-w'], env=environment, cwd=self.support, timeout=120,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def has_mono(self):
        root = self.prefix / 'drive_c'
        return all((root / name).is_file() for name in [
            'windows/mono/mono-2.0/bin/libmono-2.0-x86_64.dll', 'windows/mono/mono-2.0/bin/libmono-2.0-x86.dll'])


def prepare_prefix(host, app):
    """The app's own first-run preparation, in a clean environment."""
    support = host.support
    (support.parent / 'Home').mkdir(exist_ok=True)
    (support.parent / 'Temp').mkdir(exist_ok=True)
    environment = {'HOME': str(support.parent / 'Home'), 'TMPDIR': str(support.parent / 'Temp') + '/',
                   'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'NFS2015_SUPPORT_FOLDER': str(support),
                   'USER': 'capture', 'LOGNAME': 'capture'}
    with (support.parent / 'prepare.log').open('wb') as output:
        done = subprocess.run([str(app / 'Contents/Helpers/NFS2015Session'), str(app), '--support', str(support),
                               '--prepare'], env=environment, stdout=output, stderr=subprocess.STDOUT, timeout=3600)
    if done.returncode != 0:
        raise RuntimeError('--prepare failed (%d); see %s' % (done.returncode, support.parent / 'prepare.log'))
    host.stop()


def install_mono_if_missing(host):
    """An app made before first-run installed Mono: do what the session's --install-client does first."""
    if host.has_mono():
        return
    installer = host.app / 'Contents/Resources' / host.manifest['managedRuntime']['file']
    digest = hashlib.sha256(installer.read_bytes()).hexdigest()
    if digest != host.manifest['managedRuntime']['sha256']:
        raise RuntimeError('The host app\'s Wine Mono does not match its pin')
    log('installing Wine Mono (the host app does not do it in --prepare)')
    status = host.run(['msiexec', '/i', 'Z:' + str(installer).replace('/', '\\'), '/qn'], managed=False, timeout=900)
    host.stop()
    if status != 0 or not host.has_mono():
        raise RuntimeError('Wine Mono did not install (%d)' % status)


def find_package(folder):
    packages = sorted(folder.glob('*.msi'))
    if len(packages) != 1:
        raise RuntimeError('Expected exactly one MSI in %s, found %d' % (folder, len(packages)))
    return packages[0]


def download_payload(host, installer, destination):
    """EA's own `/layout`: it downloads and verifies its MSI into a folder and installs nothing."""
    clone = host.support.parent / 'Support-layout'
    subprocess.run(['/bin/cp', '-cR', str(host.support), str(clone)], check=True)
    helper = Host(host.app, clone)
    try:
        destination.mkdir(parents=True)
        status = helper.run(['Z:' + str(installer).replace('/', '\\'), '/layout', 'Z:' + str(destination).replace('/', '\\'),
                             '/quiet'], timeout=1200)
        helper.stop()
        if status != 0:
            raise RuntimeError('The installer\'s /layout failed (%d)' % status)
    finally:
        shutil.rmtree(clone, ignore_errors=True)


def run_installer(host, payload_installer):
    """Offline, silent; the client process is killed the instant it appears and Wine is stopped at exit."""
    events = []

    def watch(process):
        listing = subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
        for line in listing.splitlines():
            if str(host.app) in line and CLIENT_PROCESS.search(line):
                subprocess.run(['/bin/kill', '-9', line.split()[0]], check=False)
                events.append('killed a client process: ' + line.split()[0])

    status = host.run(['Z:' + str(payload_installer).replace('/', '\\'), '/quiet', '/norestart'], sandbox=True,
                      timeout=1200, watcher=watch)
    host.stop()
    return status, events


def identifiers(host, baseline_dir, prefix):
    """Strings that identify this Mac or the captured machine; none may occur in a kept byte."""
    found = {str(Path.home()), str(host.support.parent), str(host.app), socket.gethostname()}
    for command in (['/usr/sbin/scutil', '--get', 'ComputerName'], ['/usr/sbin/scutil', '--get', 'LocalHostName']):
        value = subprocess.run(command, capture_output=True, text=True).stdout.strip()
        if len(value) >= 4:
            found.add(value)
    account = os.environ.get('USER', '')
    if len(account) >= 4:
        found.add(account)
    state = prefix / 'drive_c/ProgramData/EA Desktop'
    if state.is_dir():
        for path in state.rglob('*'):
            # The names of this machine's state folders are identifiers too (a hash derived from the host).
            found.update(re.findall(r'[0-9A-Fa-f]{20,}', path.name))
            if not path.is_file() or path.stat().st_size > 1_000_000:
                continue
            text = path.read_bytes().decode('latin-1')
            # Identifiers: long hex tokens and GUIDs anywhere in the machine state, and every value of a
            # configuration file (a log's prose is not an identifier).
            found.update(re.findall(r'[0-9A-Fa-f]{20,}', text))
            found.update(re.findall(r'[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}', text))
            if path.suffix == '.ini':
                found.update(value.strip() for value in re.findall(r'=(.{6,})', text) if '\n' not in value)
    for hive in ('system.reg', 'user.reg'):
        text = (baseline_dir / hive).read_text(errors='replace')
        found.update(re.findall(r'(?<![0-9A-Fa-f-])(?:[0-9A-F]{2}-){5}[0-9A-F]{2}(?![0-9A-Fa-f-])', text))
        found.update(re.findall(r'"MachineGuid"="([^"]+)"', text))
    return sorted(item for item in found if len(item) >= 6)


def spellings(needle):
    """Every way a Windows program or a registry file could write down a host string, as bytes.

    A POSIX path appears inside Wine as `Z:\\...` with single or doubled backslashes (a hive file doubles them);
    each spelling occurs as UTF-8, as UTF-16LE (Windows binaries and text), and, in a registry value of type
    binary, as a comma-separated list of the UTF-16LE bytes in hex.
    """
    texts = {needle}
    if needle.startswith('/'):
        windows = needle.replace('/', '\\')
        texts |= {windows, windows.replace('\\', '\\\\'), 'Z:' + windows, 'Z:' + windows.replace('\\', '\\\\')}
    found = {}
    for text in texts:
        found[text.encode()] = text
        found[text.encode('utf-16-le')] = text + ' (UTF-16)'
        found[','.join('%02x' % byte for byte in text.encode('utf-16-le')).encode()] = text + ' (hex list)'
    return found


def scan_bytes(data, patterns, label):
    return [(label, patterns[pattern]) for pattern in patterns if pattern in data]


def scan_for(needles, files, extra=()):
    """Search kept bytes for the needles in every spelling; `extra` is (label, bytes) pairs, such as decoded attributes.

    Returns each hit as (file, needle). Chunks overlap by the longest pattern so a hit across a boundary is found.
    """
    patterns = {}
    for needle in needles:
        patterns.update(spellings(needle))
    keep = max(len(pattern) for pattern in patterns)
    hits = []
    for path in files:
        tail = b''
        with open(path, 'rb') as stream:
            while block := stream.read(16 << 20):
                data = tail + block
                hits += scan_bytes(data, patterns, str(path))
                tail = data[-keep:]
    for label, data in extra:
        hits += scan_bytes(data, patterns, label)
    return hits


def installed_path(prefix, baseline, relative):
    """Where an entry sits in the captured prefix: the cached package has its random Windows Installer name there."""
    if relative != layer.CANONICAL_PACKAGE:
        return prefix / 'drive_c' / relative
    added = sorted(path for path in (prefix / 'drive_c/windows/Installer').glob('*.msi')
                   if path.relative_to(prefix / 'drive_c').as_posix() not in baseline['tree'])
    if len(added) != 1:
        raise RuntimeError('Expected one new cached package in windows/Installer, found %d' % len(added))
    return added[0]


def allowed_attributes(path):
    return {name: layer.xattr_value(path, name) for name in layer.xattr_names(path) if name in layer.ALLOWED_XATTRS}


def check_against_install(layer_dir, baseline_dir, prefix, scratch):
    """The layer applied to a copy of the pristine prefix gives exactly what the installer left, kept parts only."""
    problems = []
    baseline = layer.load_baseline(baseline_dir)
    manifest = layer.load_manifest(layer_dir)
    twin = scratch / 'twin'
    (twin / 'drive_c').mkdir(parents=True)
    for hive in layer.HIVES:
        shutil.copyfile(baseline_dir / hive, twin / hive)
    layer.apply_layer(layer_dir, twin)
    for entry in manifest['entries']:
        installed, copy = installed_path(prefix, baseline, entry['path']), twin / 'drive_c' / entry['path']
        if entry['kind'] == 'file':
            if layer.sha256_file(copy) != layer.sha256_file(installed):
                problems.append('Different bytes: ' + entry['path'])
        elif not copy.is_dir():
            problems.append('Missing directory: ' + entry['path'])
        if allowed_attributes(installed) != allowed_attributes(copy):
            problems.append('Different attributes: ' + entry['path'])
    for part in manifest['registry']:
        installed = layer.read_hive(prefix / part['hive'])
        merged = layer.read_hive(twin / part['hive'])
        for key, section in layer.Hive.parse((layer_dir / part['file']).read_text()).keys.items():
            if key not in merged.keys or merged.keys[key]['body'] != section['body']:
                problems.append('Registry key not reproduced: ' + key)
            expected, _ = layer.normalized_body(key, installed.keys[key]['body'])
            if expected != section['body']:
                problems.append('Registry key differs from the install: ' + key)
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--host-app', type=Path, required=True)
    parser.add_argument('--installer', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True, help='a new scratch folder, deleted at the end')
    parser.add_argument('--output', type=Path, required=True, help='a new layer folder')
    parser.add_argument('--payload', type=Path, help='a folder from an earlier /layout (installer and MSI) to use offline')
    parser.add_argument('--save-payload', type=Path, help='a new folder to keep the downloaded installer and MSI in')
    parser.add_argument('--expect-installer-sha256')
    parser.add_argument('--expect-package-sha256')
    parser.add_argument('--keep', action='store_true')
    options = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This tool runs on macOS')
    app, installer = options.host_app.resolve(), options.installer.resolve()
    work, output = options.work.resolve(), options.output.resolve()
    if work.exists() or output.exists():
        parser.error('--work and --output must not exist')
    if (app / 'Contents/Resources/ClientLayer').exists():
        parser.error('The host app already carries a client layer; use an app built without one')

    signature = authenticode.verify(installer, publisher=PUBLISHER, expected_root='DigiCert Trusted Root G4')
    if not signature.ok:
        raise SystemExit('The installer is not signed by %s: %s' % (PUBLISHER, signature.problems))
    installer_sha = layer.sha256_file(installer)
    if options.expect_installer_sha256 and installer_sha != options.expect_installer_sha256:
        raise SystemExit('The installer does not match the pinned SHA-256')
    log('installer %s signed by %s, valid %s to %s, SHA-256 %s' % (
        installer.name, signature.signer_subject.split('CN=')[-1], signature.not_before, signature.not_after, installer_sha))

    work.mkdir(parents=True)
    try:
        host = Host(app, work / 'Support')
        prepare_prefix(host, app)
        install_mono_if_missing(host)
        baseline_dir = work / 'baseline'
        log('baseline: %d paths' % layer.snapshot_prefix(host.prefix, baseline_dir))

        payload = options.payload.resolve() if options.payload else work / 'payload'
        if not options.payload:
            payload.mkdir()
            shutil.copyfile(installer, payload / installer.name)
            os.chmod(payload / installer.name, 0o755)
            download_payload(host, payload / installer.name, work / 'layout')
            for item in (work / 'layout').iterdir():
                shutil.move(str(item), payload / item.name)
        if options.save_payload:
            shutil.copytree(payload, options.save_payload)
        if layer.sha256_file(payload / installer.name) != installer_sha:
            raise SystemExit('The payload folder\'s installer is not the verified installer')
        package = find_package(payload)
        package_sha = layer.sha256_file(package)
        if options.expect_package_sha256 and package_sha != options.expect_package_sha256:
            raise SystemExit('The downloaded MSI does not match the pinned SHA-256: ' + package_sha)
        version = re.fullmatch(r'.*?-(\d+(?:\.\d+){3})-\d+\.msi', package.name)
        log('package %s, SHA-256 %s' % (package.name, package_sha))

        status, events = run_installer(host, payload / installer.name)
        log('installer exit %d; %s' % (status, '; '.join(events) or 'no client process was seen'))
        if status != 0:
            raise SystemExit('The installer did not finish (%d)' % status)
        started = [p for p in (host.prefix / 'drive_c').rglob('EADesktop.log')]
        if started:
            raise SystemExit('The client started and wrote a log: ' + str(started[0]))

        plan = layer.build_plan(layer.load_baseline(baseline_dir), host.prefix)
        for key, body in plan.unclassified.items():
            print('UNCLASSIFIED KEY', key)
            for line in body[:12]:
                print('    ', line[:200])
        client = {'name': 'EA app', 'version': version.group(1) if version else 'unknown',
                  'installer': {'fileName': installer.name, 'sha256': installer_sha, 'bytes': installer.stat().st_size,
                                'signer': PUBLISHER},
                  'package': {'fileName': package.name, 'sha256': package_sha, 'bytes': package.stat().st_size}}
        digest = layer.write_layer(plan, host.prefix, output, client)
        log('layer written: %s' % digest)

        problems = []
        manifest = layer.load_manifest(output)
        kept = {entry['path']: entry for entry in manifest['entries'] if entry['kind'] == 'file'}
        for path, entry in kept.items():
            if path.endswith('.msi') and entry['sha256'] != package_sha:
                problems.append('A cached package is not the pinned MSI: ' + path)
            if path.endswith('/' + installer.name) and entry['sha256'] != installer_sha:
                problems.append('The cached setup engine is not the verified installer: ' + path)
        if not any(path.endswith('/' + installer.name) for path in kept):
            problems.append('The setup engine was not cached')
        needles = identifiers(host, baseline_dir, host.prefix)
        files = [output / 'blobs' / name for name in sorted(os.listdir(output / 'blobs'))]
        files += [output / layer.MANIFEST_NAME] + sorted((output / 'registry').iterdir())
        decoded = [('attribute of ' + entry['path'], base64.b64decode(value)) for entry in manifest['entries']
                   for value in entry.get('xattrs', {}).values()]
        hits = scan_for(needles, files, decoded)
        problems += ['Host or machine identifier %r in %s' % (needle[:8] + '...', Path(path).name) for path, needle in hits]
        log('identifier scan: %d needles, %d files, %d hits' % (len(needles), len(files), len(hits)))
        problems += check_against_install(output, baseline_dir, host.prefix, work)
        report = {'client': client, 'layerSHA256': digest, 'installerExit': status, 'events': events,
                  'dropped': {rule: len(paths) for rule, paths in sorted(plan.dropped.items())},
                  'droppedKeys': {rule: len(keys) for rule, keys in sorted(plan.dropped_keys.items())},
                  'keptFiles': len(manifest['entries']), 'identifiersScanned': len(needles),
                  'signature': {'signer': signature.signer_subject, 'issuer': signature.issuer,
                                'notBefore': signature.not_before, 'notAfter': signature.not_after,
                                'algorithm': signature.digest_algorithm}}
        output.with_name(output.name + '.report.json').write_text(json.dumps(report, indent=1, sort_keys=True) + '\n')
        if problems:
            for problem in problems:
                print('PROBLEM', problem)
            raise SystemExit('The layer failed its capture gates; it was written but must not be used')
        log('all capture gates passed')
        print(digest)
    finally:
        try:
            Host(app, work / 'Support').stop()
        except Exception as error:  # the scratch prefix is deleted next, so a failed stop only costs a log line
            log('could not stop Wine: %s' % error)
        if not options.keep:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    main()
