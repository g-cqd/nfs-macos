"""The EA client layer: classification, determinism, tamper detection and the registry merge.

Everything here runs on synthetic prefixes, so it needs no EA installer, no Wine and no network.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory

import client_layer as layer

PROJECT = Path(__file__).resolve().parents[1]
FIXTURE = PROJECT / 'Tests/LauncherCoreTests/Fixtures/client-layer'
CLIENT = {'name': 'EA app', 'version': '1.2.3.4',
          'installer': {'fileName': 'Setup.exe', 'sha256': 'a' * 64, 'bytes': 11, 'signer': 'Example Publisher'},
          'package': {'fileName': 'Setup-1.2.3.4.msi', 'sha256': 'b' * 64, 'bytes': 13}}
HIVE_HEADER = 'WINE REGEDIT4\n;; All keys relative to \\\\Machine\n\n#arch=win64\n\n'
BASE_SYSTEM = HIVE_HEADER + '[Software\\\\Wine] 1700000000\n#time=1d00000000000000\n"Version"="win10"\n\n'
BASE_USER = 'WINE REGEDIT4\n\n#arch=win64\n\n[Software\\\\Wine] 1700000000\n#time=1d00000000000000\n"Version"="win10"\n\n'
PACKAGE = b'MSI-bytes-' + b'x' * 40
INSTALLER_BYTES = b'MZ installer bytes'


def write(path, data=b'', mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def set_attribute(path, name, value):
    subprocess.run(['/usr/bin/xattr', '-wx', name, value.hex(), str(path)], check=True)


def baseline(root):
    root.mkdir(parents=True)
    write(root / 'drive_c/windows/system32/kernel32.dll', b'k32')
    for folder in ['windows/Installer', 'Program Files/Common Files', 'ProgramData/Microsoft/Windows', 'users/crossover',
                   'users/Public']:
        write(root / 'drive_c' / folder / '.keep', b'')
    write(root / 'drive_c/Program Files/EA Games/Need for Speed/NFS16.exe', b'game')
    (root / 'system.reg').write_text(BASE_SYSTEM)
    (root / 'user.reg').write_text(BASE_USER)


def install(root, *, cache_name='6417', date='20261003', stamp='1790979142', extra=None, machine_value='4242'):
    """What a run of the installer leaves: client files, state to drop, and registry entries."""
    base = root / 'drive_c'
    client = base / 'Program Files/Electronic Arts/EA Desktop'
    write(client / '1.2.3.4/EA Desktop/EADesktop.exe', b'MZ client', 0o755)
    write(client / '1.2.3.4/EA Desktop/qml/main.qml', b'import QtQuick')
    write(client / '1.2.3.4/EA Desktop/legacyPM/EACore_App.ini', b'[EACore]\r\nSharedServerId=LEGACY\r\n')
    write(client / '1.2.3.4/EA Desktop/App Recovery.lnk', b'lnk' + stamp.encode())
    junction = client / 'EA Desktop?'
    junction.mkdir()
    set_attribute(junction, 'user.WINEREPARSE', b'\x0c\x00\x00\xa0reparse')
    set_attribute(client / '1.2.3.4/EA Desktop/EADesktop.exe', 'com.apple.provenance', b'\x01\x02')
    hidden = base / 'Program Files/Common Files/EAInstaller/EA app'
    hidden.mkdir(parents=True)
    set_attribute(hidden, 'user.DOSATTRIB', b'0x2')
    cache = base / 'ProgramData/Package Cache'
    write(cache / '{C2622085-ABD2-49E5-8AB9-D3D6A642C091}v12.0.0.0/Setup-1.2.3.4.msi', PACKAGE)
    write(cache / '{b3468fcd-fa10-4a55-8d82-bed839e8189e}/Setup.exe', INSTALLER_BYTES)
    write(cache / '{b3468fcd-fa10-4a55-8d82-bed839e8189e}/state.rsm', b'Z:\\Users\\builder\\Downloads\\Setup.exe')
    write(base / ('windows/Installer/%s.msi' % cache_name), PACKAGE)
    write(base / 'windows/Installer/{C2622085-ABD2-49E5-8AB9-D3D6A642C091}/ProductIcon.ico', b'ico')
    write(base / 'ProgramData/EA Desktop/machine.ini', b'machine.experimentbucket=' + machine_value.encode())
    write(base / 'ProgramData/EA Desktop/530c11/IQ', b'af53d48ae942b6ec456e6a673893eeb94e8ec68ffd0597e6')
    write(base / 'ProgramData/EA Desktop/Logs/EADesktop.log', b'[STARTUP]')
    write(base / 'ProgramData/Microsoft/Windows/Start Menu/Programs/EA/EA.lnk', b'lnk')
    write(base / 'users/Public/Desktop/EA.lnk', b'lnk' + stamp.encode())
    write(base / ('users/crossover/AppData/Local/Temp/msi%s.tmp-/juno.dll' % cache_name), b'tmp')
    write(base / 'users/crossover/AppData/Local/Electronic Arts/EA Desktop/cache.bin', b'cache')
    for name, extra_text in (extra or {}).items():
        write(base / name, extra_text)
    system = BASE_SYSTEM + (
        '[Software\\\\Classes\\\\Installer\\\\Products\\\\5802262C2DBA5E94A89B3D6D6A240C19] %s\n#time=1dd52bb18cb39be\n'
        '"ProductName"="EA app"\n"Clients"=str(7):":\\0"\n\n'
        '[Software\\\\Electronic Arts\\\\EA Desktop] %s\n#time=1dd52bb1996b580\n'
        '"ClientPath"="C:\\\\Program Files\\\\Electronic Arts\\\\EA Desktop\\\\EA Desktop\\\\EADesktop.exe"\n\n'
        '[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Installer\\\\UserData\\\\S-1-5-18\\\\Products\\\\'
        '5802262C2DBA5E94A89B3D6D6A240C19\\\\InstallProperties] %s\n#time=1dd52bb18cb8cd4\n'
        '"InstallDate"="%s"\n"LocalPackage"="C:\\\\windows\\\\Installer\\\\%s.msi"\n"Size"=hex:01,02,\\\n  03,04\n\n'
        '[Software\\\\Microsoft\\\\SystemCertificates\\\\Root] %s\n#time=1\n"Blob"=hex:00\n\n'
        '[Software\\\\Wine\\\\HostImportedCertificates] %s\n#time=1\n"Root"=hex:00\n\n'
        '[System\\\\ControlSet001\\\\Enum\\\\HID\\\\VID_1] %s\n#time=1\n"ContainerId"="{0001-%s}"\n\n'
        '[System\\\\ControlSet001\\\\Services\\\\EABackgroundService] %s\n#time=1dd52bb17b49016\n'
        '"ImagePath"=str(2):"C:\\\\Program Files\\\\Electronic Arts\\\\EA Desktop\\\\EA Desktop\\\\EABackgroundService.exe -start"\n\n'
    ) % (stamp, stamp, stamp, date, cache_name, stamp, stamp, stamp, machine_value, stamp)
    (root / 'system.reg').write_text(system)
    (root / 'user.reg').write_text(BASE_USER + (
        '[Software\\\\Microsoft\\\\Xbox\\\\GamingApp\\\\Extensions\\\\Data\\\\XPF] %s\n#time=1\n"State"=dword:00000001\n\n'
        '[Software\\\\Microsoft\\\\SystemCertificates\\\\My] %s\n#time=1\n\n') % (stamp, stamp))


def capture(work, name, **options):
    """Make a baseline and an install in `work`, classify, and write the layer; returns (plan, folder, digest)."""
    prefix = work / (name + '-prefix')
    baseline(prefix)
    snapshot = work / (name + '-baseline')
    layer.snapshot_prefix(prefix, snapshot)
    install(prefix, **options)
    plan = layer.build_plan(layer.load_baseline(snapshot), prefix)
    output = work / (name + '-layer')
    digest = layer.write_layer(plan, prefix, output, CLIENT)
    return plan, output, digest


def tree_bytes(root):
    return {path.relative_to(root).as_posix(): path.read_bytes() for path in sorted(root.rglob('*')) if path.is_file()}


def expect_problem(problems, text, message):
    assert any(text in problem for problem in problems), message + ': ' + repr(problems)


def check_policy_table():
    ids = [rule.ident for rule in layer.FILE_RULES] + [rule.ident for rules in layer.KEY_RULES.values() for rule in rules]
    assert len(ids) == len(set(ids)), 'Rule identifiers must be unique'
    for rules in [layer.FILE_RULES] + list(layer.KEY_RULES.values()):
        for rule in rules:
            assert len(rule.reason) > 20, 'Every decision needs its reason: ' + rule.ident
    documentation = (PROJECT / 'docs/NFS2015.md').read_text()
    for ident in ids:
        assert '| %s |' % ident in documentation, 'docs/NFS2015.md does not document rule ' + ident
    print('PASS policy: %d rules, each with a reason and a row in docs/NFS2015.md' % len(ids))


def check_classification(work):
    plan, output, digest = capture(work, 'one')
    kept = set(plan.files)
    assert 'Program Files/Electronic Arts/EA Desktop/1.2.3.4/EA Desktop/EADesktop.exe' in kept
    assert 'Program Files/Electronic Arts/EA Desktop/EA Desktop?' in kept, 'the junction folder is kept'
    assert 'Program Files/Electronic Arts/EA Desktop/1.2.3.4/EA Desktop/legacyPM/EACore_App.ini' in kept
    for path in kept:
        assert not path.startswith(('users/', 'ProgramData/EA Desktop')), 'State was kept: ' + path
        assert not path.endswith(('.lnk', 'machine.ini', 'state.rsm')), 'State was kept: ' + path
    assert set(plan.dropped) == {'F01', 'F02', 'F03', 'F04', 'F05', 'F12'}, sorted(plan.dropped)
    assert 'ProgramData/EA Desktop/machine.ini' in plan.dropped['F03']
    assert set(plan.dropped_keys) == {'R01', 'R02', 'R03', 'U01'}, sorted(plan.dropped_keys)
    manifest = layer.load_manifest(output)
    paths = [entry['path'] for entry in manifest['entries']]
    assert paths == sorted(paths, key=lambda item: item.encode()), 'Entries are sorted'
    assert layer.CANONICAL_PACKAGE in paths and not any(path.startswith('users') for path in paths)
    blobs = list((output / 'blobs').iterdir())
    packages = [entry for entry in manifest['entries'] if entry['path'].endswith('.msi')]
    assert len(packages) == 2 and packages[0]['sha256'] == packages[1]['sha256']
    assert len(blobs) == len({entry['sha256'] for entry in manifest['entries'] if entry['kind'] == 'file'}), \
        'The package is stored once'
    byname = {entry['path']: entry for entry in manifest['entries']}
    assert list(byname['Program Files/Electronic Arts/EA Desktop/EA Desktop?']['xattrs']) == ['user.WINEREPARSE']
    assert 'xattrs' not in byname['Program Files/Electronic Arts/EA Desktop/1.2.3.4/EA Desktop/EADesktop.exe'], \
        'macOS provenance is never carried'
    assert byname['Program Files/Electronic Arts/EA Desktop/1.2.3.4/EA Desktop/EADesktop.exe']['mode'] == 0o755
    assert byname['Program Files/Common Files/EAInstaller/EA app']['xattrs'] == {'user.DOSATTRIB': 'MHgy'}
    system = (output / 'registry/system.reg.part').read_text()
    assert '"LocalPackage"="C:\\\\windows\\\\Installer\\\\eaapp.msi"' in system
    assert '"InstallDate"="20260101"' in system
    assert 'SystemCertificates' not in system and 'HostImported' not in system and 'Enum' not in system
    assert 'hex:01,02,\\\n  03,04' in system, 'A continued hex value survives byte for byte'
    assert '[Software\\\\Microsoft\\\\Xbox' in (output / 'registry/user.reg.part').read_text()
    assert layer.verify_layer(output, digest, CLIENT) == []
    print('PASS classification: kept, dropped and normalized exactly what policy says')


def check_unreviewed_items(work):
    for name, change, expected in [
        ('stray', {'extra': {'windows/system32/new.dll': b'x'}}, 'Unclassified new path'),
        ('ini', {'extra': {'Program Files/Electronic Arts/EA Desktop/1.2.3.4/EA Desktop/user_1.ini': b'x'}}, 'Forbidden new path'),
        ('log', {'extra': {'Program Files/Electronic Arts/EA Desktop/1.2.3.4/EA Desktop/trace.log': b'x'}}, 'Forbidden new path'),
    ]:
        prefix = work / (name + '-prefix')
        baseline(prefix)
        layer.snapshot_prefix(prefix, work / (name + '-baseline'))
        install(prefix, **change)
        plan = layer.build_plan(layer.load_baseline(work / (name + '-baseline')), prefix)
        expect_problem(plan.problems, expected, name)
        try:
            layer.write_layer(plan, prefix, work / (name + '-layer'), CLIENT)
        except ValueError:
            pass
        else:
            raise AssertionError('A layer was written from an unresolved capture: ' + name)
        assert not (work / (name + '-layer')).exists()
    # A changed baseline file and an unknown registry key both stop the build.
    prefix = work / 'edit-prefix'
    baseline(prefix)
    layer.snapshot_prefix(prefix, work / 'edit-baseline')
    install(prefix)
    (prefix / 'drive_c/windows/system32/kernel32.dll').write_bytes(b'patched')
    with (prefix / 'system.reg').open('a') as stream:
        stream.write('[Software\\\\Unknown\\\\Thing] 1\n#time=1\n"a"="b"\n\n')
    plan = layer.build_plan(layer.load_baseline(work / 'edit-baseline'), prefix)
    expect_problem(plan.problems, 'A baseline path was changed', 'changed baseline file')
    expect_problem(plan.problems, 'Unclassified registry key', 'unknown key')
    print('PASS unreviewed items: unclassified, forbidden, changed and unknown entries stop the build')


def check_reproducible(work):
    first = capture(work, 'a', cache_name='6417', date='20261003', stamp='1790979142', machine_value='1111')
    second = capture(work, 'b', cache_name='ed43', date='20270102', stamp='1800000000', machine_value='2222')
    assert first[2] == second[2], 'Two installs with different random names, dates and machine values differ'
    assert tree_bytes(first[1]) == tree_bytes(second[1]), 'The layer folders are not byte for byte equal'
    print('PASS reproducible: two independent installs give the same layer, digest %s' % first[2][:12])
    return first[1], first[2]


def check_tamper(work, good, digest):
    def fresh(name):
        copy = work / name
        shutil.copytree(good, copy)
        return copy

    def edit_manifest(folder, change):
        manifest = layer.load_manifest(folder)
        change(manifest)
        (folder / layer.MANIFEST_NAME).write_text(layer.canonical_json(manifest))

    blob = fresh('t-blob')
    victim = next(iter((blob / 'blobs').iterdir()))
    victim.write_bytes(victim.read_bytes() + b'!')
    expect_problem(layer.verify_layer(blob), 'Blob does not match', 'a changed blob')
    extra = fresh('t-extra')
    (extra / 'blobs' / ('c' * 64)).write_bytes(b'unlisted')
    expect_problem(layer.verify_layer(extra), 'blob folder does not match', 'an unlisted blob')
    missing = fresh('t-missing')
    next(iter((missing / 'blobs').iterdir())).unlink()
    expect_problem(layer.verify_layer(missing), 'Missing blob', 'a missing blob')
    pinned = layer.verify_layer(good, '0' * 64)
    expect_problem(pinned, 'does not match its pin', 'a wrong pin')
    other = layer.verify_layer(good, digest, {**CLIENT, 'version': '9'})
    expect_problem(other, 'different client', 'a different client')
    for name, path in [('t-state', 'ProgramData/EA Desktop/machine.ini'), ('t-user', 'users/crossover/AppData/x'),
                       ('t-game', 'Program Files/EA Games/Need for Speed/NFS16.exe'),
                       ('t-escape', 'Program Files/Electronic Arts/../../evil'), ('t-ini', 'Program Files/Electronic Arts/x/machine.ini')]:
        folder = fresh(name)
        digest_of_blob = next(iter((folder / 'blobs').iterdir())).name
        edit_manifest(folder, lambda m, p=path, d=digest_of_blob: m['entries'].append(
            {'path': p, 'kind': 'file', 'mode': 0o644, 'size': (folder / 'blobs' / d).stat().st_size, 'sha256': d}))
        assert layer.verify_layer(folder), 'A forbidden entry passed: ' + path
    folder = fresh('t-xattr')
    edit_manifest(folder, lambda m: m['entries'][0].setdefault('xattrs', {}).update({'com.apple.quarantine': 'AA=='}))
    expect_problem(layer.verify_layer(folder), 'Unreviewed extended attribute', 'a quarantine attribute')
    folder = fresh('t-noncanonical')
    (folder / layer.MANIFEST_NAME).write_text(json.dumps(layer.load_manifest(folder)))
    expect_problem(layer.verify_layer(folder), 'canonical', 'a non-canonical manifest')
    folder = fresh('t-registry')
    part = folder / 'registry/system.reg.part'
    text = part.read_text() + '[Software\\\\Electronic Arts\\\\Leak] 1\n#time=1\n"Path"="C:\\\\users\\\\crossover\\\\AppData"\n\n'
    part.write_text(text)
    problems = layer.verify_layer(folder)
    assert problems, 'A tampered registry part passed'
    folder = fresh('t-extra-item')
    (folder / 'notes.txt').write_text('hello')
    expect_problem(layer.verify_layer(folder), 'Unexpected item', 'a stray file')
    folder = fresh('t-link')
    victim = next(iter((folder / 'blobs').iterdir()))
    victim.unlink()
    victim.symlink_to('/etc/hosts')
    assert layer.verify_layer(folder), 'A linked blob passed'
    print('PASS tamper: 14 mutations of a good layer are each refused')


def check_apply(work):
    """The reference apply gives, on a fresh prefix, the installed files, attributes and registry keys that policy keeps."""
    plan, output, digest = capture(work, 'applied')
    twin = work / 'applied-twin'
    baseline(twin)
    layer.apply_layer(output, twin)
    installed = work / 'applied-prefix'
    manifest = layer.load_manifest(output)
    for entry in manifest['entries']:
        source = installed / 'drive_c' / (entry['path'] if entry['path'] != layer.CANONICAL_PACKAGE
                                          else 'windows/Installer/6417.msi')
        copy = twin / 'drive_c' / entry['path']
        if entry['kind'] == 'file':
            assert copy.read_bytes() == source.read_bytes(), 'Different bytes: ' + entry['path']
        else:
            assert copy.is_dir(), 'Missing folder: ' + entry['path']
        assert oct(copy.stat().st_mode & 0o777) == oct(entry['mode']), 'Different mode: ' + entry['path']
        for name in entry.get('xattrs', {}):
            assert layer.xattr_value(copy, name) == layer.xattr_value(source, name), 'Different attribute ' + name
    for part in manifest['registry']:
        merged = layer.read_hive(twin / part['hive'])
        for key, section in layer.Hive.parse((output / part['file']).read_text()).keys.items():
            assert merged.keys[key]['body'] == section['body'], 'Registry key not reproduced: ' + key
    assert not (twin / 'drive_c/users/crossover/AppData').exists() and not (twin / 'drive_c/ProgramData/EA Desktop').exists()
    try:
        layer.apply_layer(output, twin)
    except FileExistsError:
        pass
    else:
        raise AssertionError('A second apply overwrote files')
    print('PASS apply: the reference apply reproduces every kept file, attribute and registry key on a fresh prefix')


def check_app_parity():
    """The app's policy (ClientLayerPolicy.swift) and this one agree on every path in the shared fixture."""
    cases = json.loads((PROJECT / 'Tests/LauncherCoreTests/Fixtures/client-layer-paths.json').read_text())
    for path in cases['accepted']:
        assert layer.app_policy_problem(path) is None, 'The app policy refuses ' + path
    for path in cases['rejected']:
        assert layer.app_policy_problem(path) is not None, 'The app policy accepts ' + path
    print('PASS parity: %d accepted and %d refused paths agree with the app policy' % (
        len(cases['accepted']), len(cases['rejected'])))


def check_merge():
    part = ('[Software\\\\Electronic Arts\\\\EA Desktop] 1767225600\n#time=%s\n"ClientPath"="C:\\\\x"\n\n' % layer.CANONICAL_TIME)
    merged = layer.merge_hive(BASE_SYSTEM, part)
    parsed = layer.Hive.parse(merged)
    assert set(parsed.keys) == {'Software\\\\Wine', 'Software\\\\Electronic Arts\\\\EA Desktop'}
    assert merged.startswith(BASE_SYSTEM) and merged.endswith(part)
    assert layer.merge_hive(BASE_SYSTEM.rstrip('\n'), part).count('\n\n[Software') == 2, 'A hive without a final blank line'
    try:
        layer.merge_hive(merged, part)
    except ValueError:
        pass
    else:
        raise AssertionError('A colliding key was merged')
    try:
        layer.merge_hive(BASE_SYSTEM, '[Software\\\\WINE] 1\n#time=1\n"a"="b"\n\n')
    except ValueError:
        pass
    else:
        raise AssertionError('A colliding key differing only in case was merged')
    print('PASS merge: appends sections, keeps the hive, refuses a colliding key')


def check_fixture(work):
    """The Swift tests load this fixture; it must be exactly what the builder writes."""
    plan, output, digest = capture(work, 'fixture')
    expected = tree_bytes(output)
    if '--write-fixture' in sys.argv:
        if FIXTURE.exists():
            shutil.rmtree(FIXTURE)
        FIXTURE.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(output, FIXTURE)
        print('fixture written:', FIXTURE, digest)
    assert FIXTURE.is_dir(), 'Run Packaging/check_client_layer.py --write-fixture once'
    assert tree_bytes(FIXTURE) == expected, 'The Swift fixture is stale; run check_client_layer.py --write-fixture'
    assert layer.verify_layer(FIXTURE, digest) == []
    print('PASS fixture: Tests/LauncherCoreTests/Fixtures/client-layer is the builder\'s output (%s)' % digest[:12])


def main():
    check_policy_table()
    with TemporaryDirectory(prefix='client-layer-check-') as temporary:
        work = Path(temporary)
        check_classification(work)
        check_unreviewed_items(work)
        good, digest = check_reproducible(work)
        check_tamper(work, good, digest)
        check_apply(work)
        check_app_parity()
        check_merge()
        check_fixture(work)
    print('EA client layer checks passed')


if __name__ == '__main__':
    main()
