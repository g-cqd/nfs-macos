#!/usr/bin/env python3
"""Clean-room first-run test of the portable Need for Speed (2015) bundled app.

It never starts EA Desktop or the game. It runs the app's own session helper with `--prepare`, the
first-launch operation the starter runs, against a fresh private support folder and a throwaway HOME,
and it does so under a macOS sandbox profile that KILLS the process the moment it tries to read the
original payload, the debug prefix, the user's own player folder or Wine caches, or the build checkout.
So a pass means the app never reached for any of them, not that it merely coped when they were missing.

    tools/portable-check.py --app <app> --copy-to <parent folder> --work <scratch folder> --forbid <path> ...
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, time
from pathlib import Path

FAILURES = []


def check(ok, message, detail=''):
    print(('PASS ' if ok else 'FAIL ') + message + ((' :: ' + detail) if detail else ''), flush=True)
    if not ok:
        FAILURES.append(message)
    return ok


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def profile(forbidden, destination):
    rules = ''.join('  (subpath "%s")\n' % path for path in forbidden)
    destination.write_text('(version 1)\n(allow default)\n(deny file-read*\n%s  (with send-signal SIGKILL))\n' % rules)


def first_run(app, name, work, forbidden, extra_env=None):
    """Run --prepare twice on a fresh support folder; returns the support folder."""
    run = work / name
    support, home, temp = run / 'Support', run / 'Home', run / 'Temp'
    for folder in (home, temp):
        folder.mkdir(parents=True)
    sandbox = run / 'forbid.sb'
    profile(forbidden, sandbox)
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

    # (b) the app where it was built, fresh support folder, throwaway HOME, original payload banned.
    support, home, run = first_run(app, 'original-location', work, forbidden)
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
    support2, home2, run2 = first_run(destination, 'relocated-copy', work, forbidden + [str(app)])
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
