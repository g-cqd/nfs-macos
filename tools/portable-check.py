#!/usr/bin/env python3
"""Clean-room first-run test of the portable Need for Speed (2015) bundled app.

It never starts EA Desktop or the game, and never signs in to anything. It runs the app's own session helper with `--prepare`, the
first-launch operation the starter runs, against a fresh private support folder and a throwaway HOME,
and it does so under a macOS sandbox profile that KILLS the process the moment it tries to read the
original payload, the debug prefix, the user's own player folder or Wine caches, or the build checkout.
So a pass means the app never reached for any of them, not that it merely coped when they were missing.

    tools/portable-check.py --app <app> --copy-to <parent folder> --work <scratch folder> --forbid <path> ... \
        [--no-network]

An app that carries a client layer (its game manifest has `clientLayer`) must come out of `--prepare` with the EA
client files, registry entries and service registration in place and with no account, machine or user state of
EA's. With --no-network the sandbox also denies every IP connection, so a pass shows that the first start needs no
network at all.
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Packaging'))
from client_layer import xattr_names  # noqa: E402

FAILURES = []


def check(ok, message, detail=''):
    print(('PASS ' if ok else 'FAIL ') + message + ((' :: ' + detail) if detail else ''), flush=True)
    if not ok:
        FAILURES.append(message)
    return ok


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


NO_NETWORK = '(deny network-outbound (remote ip))\n(deny network-bind (local ip))\n'


def profile(forbidden, destination, network=True):
    """Kill the process on a read of a forbidden path; optionally also deny every IP connection."""
    rules = ''.join('  (subpath "%s")\n' % path for path in forbidden)
    destination.write_text('(version 1)\n(allow default)\n(deny file-read*\n%s  (with send-signal SIGKILL))\n%s'
                           % (rules, '' if network else NO_NETWORK))


def first_run(app, name, work, forbidden, network=True):
    """Run --prepare twice on a fresh support folder; returns the support folder."""
    run = work / name
    support, home, temp = run / 'Support', run / 'Home', run / 'Temp'
    for folder in (home, temp):
        folder.mkdir(parents=True)
    sandbox = run / 'forbid.sb'
    profile(forbidden, sandbox, network)
    session = app / 'Contents/Helpers/NFS2015Session'
    env = {'HOME': str(home), 'TMPDIR': str(temp) + '/', 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
           'NFS2015_SUPPORT_FOLDER': str(support), 'USER': 'portabletest', 'LOGNAME': 'portabletest'}
    command = ['/usr/bin/sandbox-exec', '-f', str(sandbox), str(session), str(app), '--support', str(support),
               '--prepare']
    started = time.monotonic()
    with (run / 'prepare.log').open('wb') as log:
        done = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
    took = time.monotonic() - started
    check(done.returncode == 0, name + ': --prepare exits 0 under the read ban',
          'exit %d in %.0f s (a SIGKILL would show as -9)' % (done.returncode, took))
    started = time.monotonic()
    with (run / 'prepare-again.log').open('wb') as log:
        again = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    check(again.returncode == 0, name + ': a second --prepare is a no-op that exits 0',
          '%.1f s' % (time.monotonic() - started))
    return support, home, run


STATE_NAMES = {'machine.ini', 'backgroundservice.ini', 'cookies', 'cookies.sqlite', 'local state', 'login data',
               'web data', 'session.json', 'credentials.json', 'tokens.json', 'iq', 'eadesktop.log'}


def account_state(prefix):
    """Every path in the prefix that holds EA machine, user or account state; empty for a clean seed."""
    root = prefix / 'drive_c'
    found = []
    for folder in ['ProgramData/EA Desktop', 'ProgramData/Origin', 'ProgramData/Electronic Arts',
                   'users/crossover/AppData/Local/Electronic Arts', 'users/crossover/AppData/Roaming/Electronic Arts',
                   'users/crossover/Documents/Electronic Arts', 'Program Files/Origin', 'Program Files (x86)/Origin']:
        if (root / folder).exists():
            found.append(folder)
    for path in root.rglob('*'):
        name = path.name.lower()
        relative = path.relative_to(root).as_posix()
        if relative.startswith('Program Files/EA Games'):
            continue
        if name in STATE_NAMES or (name.startswith('user_') and name.endswith('.ini')) or name.startswith('profileoptions'):
            found.append(relative)
    return found


def verify_client_layer(app, support, name, forbidden_text):
    """The client layer is in the new prefix exactly as pinned, registered, and free of state."""
    layer_manifest = json.loads((app / 'Contents/Resources/ClientLayer/client-layer.json').read_text())
    prefix, root = support / 'Data/Prefix', support / 'Data/Prefix/drive_c'
    broken = []
    for entry in layer_manifest['entries']:
        target = root / entry['path']
        if entry['kind'] == 'directory':
            if not target.is_dir():
                broken.append(entry['path'])
        elif not target.is_file() or target.stat().st_size != entry['size'] or sha256(target) != entry['sha256']:
            broken.append(entry['path'])
    files = sum(1 for e in layer_manifest['entries'] if e['kind'] == 'file')
    check(not broken, name + ': all %d client layer entries (%d files) are in the prefix, byte for byte' % (
        len(layer_manifest['entries']), files), str(broken[:3]))
    client = root / 'Program Files/Electronic Arts/EA Desktop'
    version = layer_manifest['client']['version']
    check((client / version / 'EA Desktop/EADesktop.exe').is_file() and (client / version / 'EA Desktop/EALauncher.exe').is_file()
          and (client / version / 'EA Desktop/EABackgroundService.exe').is_file(),
          name + ': EADesktop.exe, EALauncher.exe and EABackgroundService.exe %s are installed' % version)
    system = (prefix / 'system.reg').read_text(errors='replace')
    user = (prefix / 'user.reg').read_text(errors='replace')
    for key, what in [('System\\ControlSet001\\Services\\EABackgroundService', 'the EABackgroundService registration'),
                      ('Software\\Electronic Arts\\EA Desktop', 'the EA Desktop install record'),
                      (uninstall_key(app), 'the EA app uninstall entry'),
                      ('Software\\Classes\\origin2\\shell\\open\\command', 'the origin2 protocol handler')]:
        check(has_key(system, key), name + ': the prefix registry holds ' + what)
    check(has_key(user, 'Software\\Wine\\Mac Driver'), name + ': the display setting is still in the user hive')
    check((root / 'windows/mono/mono-2.0/bin/libmono-2.0-x86_64.dll').is_file(), name + ': Wine Mono was installed first')
    # What the starter reads after --prepare: the client is found without any installer step, and the only
    # step left is to sign in (Open EA App), never "Install EA App".
    launcher = json.loads((support / 'launcher-state.json').read_text())
    check(launcher.get('clientVersion') == version and launcher.get('setup') == 'signIn'
          and launcher.get('ownsWindowsFolder') is True and 'Open EA App' in (launcher.get('blocker') or ''),
          name + ': the starter finds the EA app (%s) and asks only for the sign-in, not for the installer' % version,
          json.dumps({key: launcher.get(key) for key in ('clientVersion', 'setup', 'ownsWindowsFolder')}))
    state = account_state(prefix)
    check(not state, name + ': no EA machine, user or account state exists in the prefix', ', '.join(state[:6]))
    leaks = []
    for path in [prefix / 'system.reg', prefix / 'user.reg', prefix / 'userdef.reg']:
        data = path.read_bytes()
        for needle in forbidden_text:
            if needle.encode() in data or needle.encode('utf-16-le') in data:
                leaks.append('%s: %s' % (path.name, needle))
    check(not leaks, name + ': the registry names none of the build or user locations', '; '.join(leaks[:4]))
    reparse = root / 'Program Files/Electronic Arts/EA Desktop/EA Desktop?'
    check(reparse.is_dir() and 'user.WINEREPARSE' in xattr_names(reparse), name + ': the EA Desktop junction keeps its reparse attribute')
    quarantine = [p.relative_to(root).as_posix() for p in (root / 'Program Files/Electronic Arts').rglob('*')
                  if 'com.apple.quarantine' in xattr_names(p)]
    check(not quarantine, name + ': no file of the client carries a quarantine mark', ', '.join(quarantine[:3]))


def uninstall_key(app):
    """The EA app's uninstall key as the layer carries it: its MSI product code changes with each client version."""
    part = (app / 'Contents/Resources/ClientLayer/registry/system.reg.part').read_text(errors='replace')
    prefix = '[Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\'
    keys = [line[1:line.index(']')].replace('\\\\', '\\') for line in part.splitlines() if line.startswith(prefix)]
    return keys[0] if len(keys) == 1 else 'Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\<exactly one expected, found %d>' % len(keys)


def has_key(hive_text, key):
    """Whether a Wine hive file has the key; Wine writes each backslash of a key path doubled."""
    return ('[' + key.replace('\\', '\\\\') + '] ').lower() in hive_text.lower()


def verify_seed(app, support, name, forbidden_text):
    manifest = json.loads((app / 'Contents/Resources/game-manifest.json').read_text())
    game = support / 'Data/Prefix/drive_c/Program Files/EA Games/Need for Speed'
    check((support / 'Data/seed.json').is_file(), name + ': seed.json record published')
    check((support / 'Data/Prefix/system.reg').is_file(), name + ': a fresh Wine prefix was created')
    present = {p.relative_to(game).as_posix() for p in game.rglob('*') if p.is_file()} if game.is_dir() else set()
    listed = {e['path'] for e in manifest['gameFiles']}
    check(present == listed and len(listed) == 144, name + ': the prefix holds exactly the 144 pinned game files',
          '%d present, %d listed' % (len(present), len(listed)))
    bad = [e['path'] for e in manifest['gameFiles']
           if (game / e['path']).stat().st_size != e['size'] or sha256(game / e['path']) != e['sha256']]
    check(not bad, name + ': every seeded file matches its manifest hash byte for byte', str(bad[:3]))
    if manifest.get('clientLayer'):
        verify_client_layer(app, support, name, forbidden_text)
    else:
        for forbidden in ['Program Files/Electronic Arts', 'ProgramData/EA Desktop', 'AppData/Local/Electronic Arts',
                          'ProgramData/Electronic Arts', 'ProgramData/Origin']:
            check(not (support / 'Data/Prefix/drive_c' / forbidden).exists(),
                  name + ': no EA client or account folder exists: ' + forbidden)
        names = {p.name.lower() for p in (support / 'Data/Prefix').rglob('*')}
        check('machine.ini' not in names and not any(n.startswith('profileoptions') for n in names),
              name + ': no machine.ini and no profile options in the new prefix')
    registry = (support / 'Data/Prefix/system.reg').read_text(errors='replace')
    check('EA Games\\\\Need for Speed' in registry and 'Install Dir' in registry,
          name + ': the game registration was written to the new prefix')
    leaks = []
    for path in (support / 'Data/Prefix').glob('*.reg'):
        text = path.read_bytes()
        for needle in forbidden_text:
            if needle.encode() in text:
                leaks.append('%s: %s' % (path.name, needle))
    check(not leaks, name + ': the new prefix hives name none of the build or user locations', '; '.join(leaks))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--copy-to', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--forbid', action='append', default=[])
    parser.add_argument('--no-network', action='store_true', help='deny every IP connection during the first start')
    options = parser.parse_args()
    app, work = options.app.resolve(), options.work.resolve()
    work.mkdir(parents=True)
    forbidden = [str(Path(p).resolve()) if Path(p).exists() else p for p in options.forbid]
    forbid_text = [str(Path.home()), 'NFS2015-debug', 'NFS2015-game', 'NFS2015Mac']
    print('# forbidden to read (SIGKILL on any attempt):', *forbidden, sep='\n#   ')

    # Control: the profile really kills a read of a forbidden path, so a pass below means no read was tried.
    control_profile = work / 'control.sb'
    profile(forbidden, control_profile)
    control = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(control_profile), '/bin/ls', forbidden[0]],
                             capture_output=True)
    check(control.returncode == -9, 'control: a read of a forbidden path is killed by the profile',
          'exit %d' % control.returncode)

    network = not options.no_network
    if not network:
        # Control: the profile really refuses a connection, so a pass below means no network was needed.
        offline = work / 'offline.sb'
        profile(forbidden, offline, network=False)
        probe = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(offline), '/usr/bin/curl', '-sS', '-m', '5', '-o',
                                '/dev/null', 'https://www.apple.com'], capture_output=True)
        check(probe.returncode == 7, 'control: an IP connection is refused by the profile (curl exit 7)',
              'exit %d' % probe.returncode)

    # (b) the app where it was built, fresh support folder, throwaway HOME, original payload banned.
    support, home, run = first_run(app, 'original-location', work, forbidden, network)
    verify_seed(app, support, 'original-location', forbid_text)
    leftover = subprocess.run(['/usr/bin/pgrep', '-f', str(support)], capture_output=True, text=True).stdout.split()
    check(not leftover, 'original-location: no process of the private prefix is left running', ' '.join(leftover))

    # (c) a COPY at a different path with a different name, the original app also banned.
    destination = options.copy_to / 'Moved Elsewhere' / 'Racing Copy.app'
    destination.parent.mkdir(parents=True)
    subprocess.run(['/bin/cp', '-c', '-R', str(app), str(destination)], check=True)
    verified = subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(destination)],
                              capture_output=True, text=True)
    check(verified.returncode == 0, 'copy: codesign --verify --deep --strict still passes at the new path',
          verified.stderr.strip())
    support2, home2, run2 = first_run(destination, 'relocated-copy', work, forbidden + [str(app)], network)
    verify_seed(destination, support2, 'relocated-copy', forbid_text + [str(app)])
    leftover = subprocess.run(['/usr/bin/pgrep', '-f', str(support2)], capture_output=True, text=True).stdout.split()
    check(not leftover, 'relocated-copy: no process of the private prefix is left running', ' '.join(leftover))
    # What each run wrote outside its support folder: only the throwaway HOME may hold anything.
    for run_name, home_folder in [('original-location', home), ('relocated-copy', home2)]:
        wrote = sorted(p.relative_to(home_folder).as_posix() for p in home_folder.rglob('*'))[:12]
        print('# throwaway HOME of', run_name, 'holds:', wrote)
    shutil.rmtree(destination.parent)
    print('RESULT', 'FAILED: ' + '; '.join(FAILURES) if FAILURES else 'ALL PASSED')
    sys.exit(1 if FAILURES else 0)


main()
