#!/usr/bin/env python3
"""Search every byte of a built app for the build Mac's account and build locations.

Text and binary files are both searched, as raw bytes and as UTF-16LE (Windows binaries), and every
.tar.gz inside the app is opened and searched member by member, because a compressed source archive
hides its text from a plain grep. The report groups hits by where they sit, so third-party runtime
binaries can be told apart from files this project writes.

    tools/portability-scan.py <app> [--json out.json]

The needles are the build Mac's own home folder, its generic `/Users/`, and the names of the folders this
project builds in; a hit under the home folder in a file of ours is a defect, a hit in the third-party Wine
runtime is listed, not fixed.
"""
import io, json, os, sys, tarfile
from collections import defaultdict
from pathlib import Path

NEEDLES = [str(Path.home()), '/Users/', 'NFS2015-debug', 'NFS2015Mac', 'tools-integrate', 'rebuild-bundles',
           'release-build', 'NFS2015-game', 'Mobile Documents', 'CloudDocs', 'The_Board', 'Desktop/Game Builds',
           '/Games/', 'nfs-setup-debug', '/private/var/folders']
PATTERNS = {}
for n in NEEDLES:
    PATTERNS[n.encode()] = n
    PATTERNS[n.encode('utf-16-le')] = n + ' (UTF-16)'
LONGEST = max(len(p) for p in PATTERNS)
CHUNK = 8 << 20


def scan_stream(stream, hits):
    tail = b''
    while True:
        block = stream.read(CHUNK)
        if not block:
            break
        data = tail + block
        for pattern, label in PATTERNS.items():
            index = data.find(pattern)
            while index != -1:
                hits[label] += 1
                index = data.find(pattern, index + 1)
        # Keep only the last bytes that could still start a pattern, so a hit that straddles two blocks is found
        # once; a hit wholly inside the kept bytes is counted twice, which only inflates a count.
        tail = data[-(LONGEST - 1):]


def scan_file(path, hits):
    with open(path, 'rb') as stream:
        scan_stream(stream, hits)


def main():
    app = Path(sys.argv[1]).resolve()
    report = defaultdict(lambda: defaultdict(int))
    files = 0
    for path in sorted(app.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        files += 1
        relative = path.relative_to(app).as_posix()
        hits = defaultdict(int)
        if path.name.endswith('.tar.gz'):
            try:
                with tarfile.open(path, 'r:gz') as archive:
                    for member in archive:
                        if member.isfile():
                            inner = defaultdict(int)
                            scan_stream(archive.extractfile(member), inner)
                            for label, count in inner.items():
                                report[relative + '!' + member.name][label] += count
            except tarfile.TarError as error:
                report[relative]['unreadable archive: ' + str(error)] += 1
            continue
        scan_file(path, hits)
        for label, count in hits.items():
            report[relative][label] += count
    print('files scanned:', files)
    groups = defaultdict(lambda: defaultdict(int))
    for relative, hits in report.items():
        parts = relative.split('/')
        key = '/'.join(parts[:4]) if relative.startswith('Contents/SharedSupport') else '/'.join(parts[:3])
        for label, count in hits.items():
            groups[key][label] += count
    for key in sorted(groups):
        print(key, dict(groups[key]))
    if '--json' in sys.argv:
        Path(sys.argv[sys.argv.index('--json') + 1]).write_text(json.dumps(report, indent=1, sort_keys=True))


main()
