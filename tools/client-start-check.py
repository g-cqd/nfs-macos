#!/usr/bin/env python3
"""Start the EA client that comes with a bundled app in a THROWAWAY prefix, look at its window, and close it.

This answers one question: does the client that the app installs on first launch really start from the seed?

    tools/client-start-check.py --app <app> --work <new scratch folder> [--offline] [--virtual-desktop] [--wait 120] [--picture <png>]

What it does: it runs the app's own `--prepare` against a new private support folder and a throwaway HOME, runs
the session helper's `--open-client` (the same call the starter's Open EA App button makes) or, with
--virtual-desktop, starts the client the other way the project has used (`explorer /desktop`), waits for the first
on-screen window of that prefix tall enough to be the sign-in window, captures that window alone by its window id
(never the screen), and ends the Windows side at once. The client's own log is the second witness: a start
line, `app.strt.ready` and `Login page load succeeded` say the client booted and loaded EA's sign-in page even when
macOS shows no window (in some sessions Wine's windows are created ordered out, `kCGWindowIsOnscreen` 0, for a client
started directly, for a seeded client and an installer-made one alike). With --offline the sandbox also denies every IP connection, which is the "no network at
first start" case: the client must come up and say so, not crash.

It never types, clicks or sends any input, never reads a credential, and never uses a prefix that holds an
account: the scratch folder must not exist, and it is deleted at the end. A visible sign-in form can be
completed by anyone at the keyboard, so run it with nobody to answer it and keep --wait short.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

OFFLINE_PROFILE = '(version 1)\n(allow default)\n(deny network-outbound (remote ip))\n(deny network-bind (local ip))\n'
WINDOWS = """
ObjC.import('CoreGraphics');
var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(
  $.kCGWindowListOptionAll, 0)));
JSON.stringify(list.map(function (w) { return {id: w.kCGWindowNumber, owner: w.kCGWindowOwnerName,
  pid: w.kCGWindowOwnerPID, layer: w.kCGWindowLayer, w: w.kCGWindowBounds.Width, h: w.kCGWindowBounds.Height,
  on: w.kCGWindowIsOnscreen ? 1 : 0}; }))
"""


def processes_of(app):
    listing = subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
    return {int(line.split()[0]) for line in listing.splitlines() if str(app) in line}


def windows():
    done = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', WINDOWS], capture_output=True, text=True)
    return json.loads(done.stdout) if done.returncode == 0 and done.stdout.strip() else []


def names_below(folder):
    return sorted(path.name for path in folder.iterdir()) if folder.is_dir() else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True, help='a new scratch folder, deleted at the end')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--virtual-desktop', action='store_true', help='start the client with `wine explorer /desktop` instead of --open-client')
    parser.add_argument('--wait', type=int, default=120, help='seconds to wait for the first window')
    parser.add_argument('--picture', type=Path, help='where to write the window-only capture (a new .png path)')
    parser.add_argument('--min-height', type=int, default=380, help='capture the first window at least this tall (the EA sign-in window is about 430 points)')
    parser.add_argument('--keep', action='store_true', help='keep the scratch folder (it holds a throwaway prefix, never an account)')
    options = parser.parse_args()
    app, work = options.app.resolve(), options.work.resolve()
    if work.exists() or (options.picture and options.picture.exists()):
        parser.error('--work and --picture must not exist')
    work.mkdir(parents=True)
    support, home, temp = work / 'Support', work / 'Home', work / 'Temp'
    home.mkdir()
    temp.mkdir()
    environment = {'HOME': str(home), 'TMPDIR': str(temp) + '/', 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                   'NFS2015_SUPPORT_FOLDER': str(support), 'USER': 'startcheck', 'LOGNAME': 'startcheck'}
    helper = [str(app / 'Contents/Helpers/NFS2015Session'), str(app), '--support', str(support)]
    profile = work / 'offline.sb'
    profile.write_text(OFFLINE_PROFILE)
    wrapper = ['/usr/bin/sandbox-exec', '-f', str(profile)] if options.offline else []
    result = {'offline': options.offline}
    client = None
    try:
        started = time.monotonic()
        with (work / 'prepare.log').open('wb') as log:
            done = subprocess.run(wrapper + helper + ['--prepare'], env=environment, stdout=log,
                                  stderr=subprocess.STDOUT, timeout=3600)
        result['prepareExit'], result['prepareSeconds'] = done.returncode, round(time.monotonic() - started)
        if done.returncode != 0:
            raise SystemExit('--prepare failed (%d); see the log in the scratch folder' % done.returncode)
        if options.virtual_desktop:
            version = json.loads((app / 'Contents/Resources/ClientLayer/client-layer.json').read_text())['client']['version']
            executable = 'C:\\Program Files\\Electronic Arts\\EA Desktop\\%s\\EA Desktop\\EADesktop.exe' % version
            recipe = json.loads((app / 'Contents/Resources/bundle-recipe.json').read_text())
            rules = ['v=3'] + ['name=nfs2015-%d;exe=%s;%s=%s' % (i, r['executable'], r['api'], r['backend'])
                               for i, r in enumerate(recipe['renderers'])]
            wine_environment = {'HOME': str(support / 'RuntimeHome/Player'), 'USER': 'Player', 'LOGNAME': 'Player',
                                'TMPDIR': str(support / 'Temporary'), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                                'LANG': 'en_US.UTF-8', 'WINEPREFIX': str(support / 'Data/Prefix'), 'WINEDEBUG': '-all',
                                'WINEDLLOVERRIDES': 'IGOProxy32.exe=d;winemenubuilder.exe=d;mshtml=',
                                'ROSETTA_X87_PATH': str(app / 'Contents/Helpers/x87sidecar'), 'WINEMSYNC': '1',
                                'WINE_COMPATDB': '\n'.join(rules), **recipe.get('runtimeTuning', {})}
            client = subprocess.Popen(wrapper + [str(app / 'Contents/SharedSupport/Wine/bin/wine'), 'explorer',
                                                 '/desktop=EA,900x700', executable, '--in-process-gpu'],
                                      env=wine_environment, cwd=support, stdout=(work / 'open-client.log').open('wb'),
                                      stderr=subprocess.STDOUT)
        else:
            client = subprocess.Popen(wrapper + helper + ['--open-client'], env=environment,
                                      stdout=(work / 'open-client.log').open('wb'), stderr=subprocess.STDOUT)
        opened = time.monotonic()
        window, seen = None, {}
        while time.monotonic() - opened < options.wait and window is None:
            owners = processes_of(app)
            for candidate in windows():
                ours = candidate['pid'] in owners or 'wine' in (candidate.get('owner') or '').lower()
                if ours:
                    seen[candidate['id']] = (candidate.get('owner'), candidate['layer'], candidate['w'], candidate['h'],
                                             candidate['on'])
                if ours and candidate['on'] and candidate['layer'] == 0 and candidate['w'] >= 150 \
                        and candidate['h'] >= options.min_height:
                    window = candidate
                    break
            time.sleep(0.5 if window is None else 0)
        if window is not None:
            time.sleep(2)   # the page behind a splash window needs a moment to paint
        result['windowsSeen'] = sorted(seen.values(), key=str)
        if window is None:
            result['window'] = None
        else:
            result['window'] = {'seconds': round(time.monotonic() - opened, 1), 'id': window['id'], 'width': window['w'],
                                'height': window['h']}
            if options.picture:
                subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(window['id']), str(options.picture)],
                               check=True)
                result['picture'] = options.picture.name
    finally:
        # End the Windows side at once, whatever happened.
        if client is not None and client.poll() is None:
            client.terminate()
        wine = app / 'Contents/SharedSupport/Wine/bin/wineserver'
        prefix = support / 'Data/Prefix'
        if prefix.is_dir():
            subprocess.run([str(wine), '-k'], env={'WINEPREFIX': str(prefix), 'PATH': '/usr/bin:/bin'}, cwd=work,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)
        left = [pid for pid in processes_of(app) if str(support) in subprocess.run(
            ['/bin/ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout]
        result['processesLeft'] = left
        for pid in left:
            os.kill(pid, 9)
    root = support / 'Data/Prefix/drive_c'
    result['createdByTheClient'] = {
        'ProgramData/EA Desktop': names_below(root / 'ProgramData/EA Desktop'),
        'AppData/Local/Electronic Arts/EA Desktop': names_below(root / 'users/crossover/AppData/Local/Electronic Arts/EA Desktop'),
    }
    log = root / 'ProgramData/EA Desktop/Logs/EADesktop.log'
    result['clientLog'] = {'exists': log.is_file(),
                           'startLines': log.read_text(errors='replace').count('[STARTUP]') if log.is_file() else 0}
    if log.is_file():
        text = log.read_text(errors='replace')
        events = ['app.strt.ready', 'user.lgin.ckld', 'login', 'client.boot.ready', 'Network service crashed',
                  'Login page load succeeded', 'app.strt.fatal', 'offline', 'Offline', 'crash']
        result['clientLog']['mentions'] = {event: text.count(event) for event in events if text.count(event)}
        result['clientLog']['lines'] = text.count('\n')
    print(json.dumps(result, indent=1))
    if not options.keep:
        shutil.rmtree(work, ignore_errors=True)
    return 0 if result.get('window') else 1


if __name__ == '__main__':
    sys.exit(main())
