#!/usr/bin/env python3
"""Start the EA client that comes with a bundled app in a THROWAWAY prefix, look at its window, and close it.

This answers one question: does the client that the app installs on first launch really start from the seed?

    tools/client-start-check.py --app <app> --work <new scratch folder> [--offline] [--wait 120] [--picture <png>]

What it does: it runs the app's own `--prepare` against a new private support folder and a throwaway HOME, runs
the session helper's `--open-client` (the same call the starter's Open EA App button makes), waits for the first
on-screen window of that prefix, captures that window alone by its window id (never the screen), and ends the
Windows side at once. With --offline the sandbox also denies every IP connection, which is the "no network at
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
  $.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0)));
JSON.stringify(list.map(function (w) { return {id: w.kCGWindowNumber, owner: w.kCGWindowOwnerName,
  pid: w.kCGWindowOwnerPID, layer: w.kCGWindowLayer, w: w.kCGWindowBounds.Width, h: w.kCGWindowBounds.Height}; }))
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
    parser.add_argument('--wait', type=int, default=120, help='seconds to wait for the first window')
    parser.add_argument('--picture', type=Path, help='where to write the window-only capture (a new .png path)')
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
        client = subprocess.Popen(wrapper + helper + ['--open-client'], env=environment,
                                  stdout=(work / 'open-client.log').open('wb'), stderr=subprocess.STDOUT)
        opened = time.monotonic()
        window = None
        while time.monotonic() - opened < options.wait and window is None:
            owners = processes_of(app)
            for candidate in windows():
                if candidate['pid'] in owners and candidate['layer'] == 0 and candidate['w'] >= 150 and candidate['h'] >= 150:
                    window = candidate
                    break
            time.sleep(0.5)
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
    print(json.dumps(result, indent=1))
    shutil.rmtree(work, ignore_errors=True)
    return 0 if result.get('window') else 1


if __name__ == '__main__':
    sys.exit(main())
