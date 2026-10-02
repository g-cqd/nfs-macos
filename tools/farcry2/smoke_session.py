#!/usr/bin/env python3
"""End-to-end smoke test of a built Far Cry 2 app's session helper with a SYNTHETIC game folder.

No game files are used. The stand-in executable is the bundled Wine's own cmd.exe (padded and
unmarked as a builtin), `Dunia.dll` and the archives are invented. Everything runs in a throwaway
folder with its own Wine prefix; only that prefix's wineserver is ever stopped.

    python3 tools/farcry2/smoke_session.py "/path/Far Cry 2 Import.app" [--keep]
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent

def tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob('*') if p.is_file()):
        digest.update(path.relative_to(root).as_posix().encode())
        with path.open('rb') as stream:
            digest.update(hashlib.file_digest(stream, 'sha256').digest())
    return digest.hexdigest()


def cache_identifier(key):
    """Mirrors ShaderCacheKey.identifier, so a drift between Swift and this script shows up as a failure."""
    canonical = '\n'.join(['farcry2-shader-cache', 'revision=' + key['mtld3dRevision'],
                           'format=%d' % key['cacheFormatVersion'], 'schema=%d' % key['shaderSchemaVersion'],
                           'emitter=' + key['emitterDigest']])
    return hashlib.sha256(canonical.encode()).hexdigest()[:16]


def synthetic_cache(name, key):
    """A cache written by the real mtld3d writers from invented entries, under the app's header.

    The chunk checksums do not cover the file header, so the header can be set to what this build writes.
    """
    data = bytearray((HERE / name).read_bytes())
    data[8:12] = key['cacheFormatVersion'].to_bytes(4, 'little')
    data[12:16] = key['shaderSchemaVersion'].to_bytes(4, 'little')
    return bytes(data)


def export_container(payload, key):
    manifest = {'formatVersion': 1, 'created': '2026-10-02T00:00:00Z', 'key': key,
                'payloadBytes': len(payload), 'payloadSHA256': hashlib.sha256(payload).hexdigest(),
                'origin': {'gpu': 'Synthetic GPU', 'system': 'Synthetic macOS'}}
    body = json.dumps(manifest, sort_keys=True).encode()
    return b'FC2SHCEX' + len(body).to_bytes(4, 'little') + body + payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--keep', action='store_true', help='keep the throwaway folder')
    options = parser.parse_args()
    app = options.app.resolve()
    session = app / 'Contents/Helpers/FarCry2Session'
    cmd = app / 'Contents/SharedSupport/Wine/lib/wine/i386-windows/cmd.exe'
    assert session.is_file() and cmd.is_file(), 'not a Far Cry 2 app with a bundled Wine'
    work = Path(__file__).resolve().parents[3] / ('smoke-' + uuid.uuid4().hex[:8])
    work.mkdir()
    game = work / 'Far Cry 2'
    support = work / 'Support'
    failures = []
    wineserver = app / 'Contents/SharedSupport/Wine/bin/wineserver'
    wine_env = {'WINEPREFIX': str(support / 'Data/Prefix'), 'PATH': '/usr/bin:/bin'}

    def check(condition, message):
        print(('PASS ' if condition else 'FAIL ') + message)
        if not condition: failures.append(message)

    def run(*arguments):
        result = subprocess.run([str(session), str(app), '--support', str(support), *arguments],
                                capture_output=True, text=True, timeout=300)
        (work / 'last.log').write_text(result.stdout + result.stderr)
        return result

    try:
        (game / 'bin').mkdir(parents=True)
        (game / 'Data_Win32').mkdir()
        image = bytearray(cmd.read_bytes())
        if image[0x40:0x50] == b'Wine builtin DLL':
            image[0x40:0x50] = bytes(16)
        (game / 'bin/FarCry2.exe').write_bytes(bytes(image) + bytes(1_200_000))
        (game / 'bin/Dunia.dll').write_bytes(b'synthetic engine' + bytes(1_100_000))
        (game / 'Data_Win32/common.fat').write_bytes(b'synthetic table')
        with (game / 'Data_Win32/common.dat').open('wb') as stream:
            stream.truncate(1_100_000_000)  # sparse: satisfies the 1 GiB floor without disk use
        before = tree_digest(game)

        result = run('--import-game', '--request', str(game))
        print(result.stdout.strip())
        check(result.returncode == 0, 'import-game exits 0')
        state = json.loads((support / 'launcher-state.json').read_text())
        check(state['profile'] == 'missing', 'no profile yet: reported missing, not invented')
        check(state['installation'].get('build') is None, 'unlisted build is reported as unverified')
        check(len(state['installation']['executableSHA256']) == 64, 'executable digest recorded')
        check(tree_digest(game) == before, 'the selected folder is unchanged')
        current = support / 'Data/Current/Game'
        check((current / 'bin/FarCry2.exe').stat().st_size == (game / 'bin/FarCry2.exe').stat().st_size,
              'private copy has the executable')
        check(not (current / 'bin/mtld3d.conf').read_text().strip().startswith('#!'),
              'renderer config present next to the executable')
        users = [p for p in (support / 'Data/Prefix/drive_c/users').iterdir() if p.name != 'Public']
        check(len(users) == 1, 'one Wine profile: ' + ', '.join(p.name for p in users))
        link = users[0] / 'Documents/My Games/Far Cry 2'
        check(link.is_symlink() and link.resolve() == (support / 'Data/Saves/FarCry2/Documents').resolve(),
              'Documents link reaches persistent storage')
        check((users[0] / 'AppData/Local/My Games/Far Cry 2').is_symlink(), 'AppData link present')
        check(not (support / 'Data/Prefix/dosdevices/g:').exists(), 'no G: drive while idle')

        profile = support / 'Data/Saves/FarCry2/Documents/GamerProfile.xml'
        profile.write_text('<GamerProfile><RenderProfile MultiSampleMode="0" ResolutionX="800" '
                           'ResolutionY="600" Platform="d3d10a" Quality="customd3d10" Fullscreen="0">'
                           '<CustomQuality><quality id="custom" ResolutionX="800" ResolutionY="600"/>'
                           '</CustomQuality></RenderProfile></GamerProfile>\n')
        request = work / 'request.json'
        request.write_text(json.dumps({'settings': {'values': {
            'resolution': '1920x1080', 'antialiasing': '4', 'fullscreen': '1', 'render.scale': '1'}}}))
        result = run('--configure', '--request', str(request))
        check(result.returncode == 0, 'configure exits 0')
        edited = profile.read_text()
        check('Platform="d3d9"' in edited and 'Quality="custom"' in edited, 'Direct3D 9 forced in the profile')
        check(edited.count('ResolutionX="1920"') == 2 and 'MultiSampleMode="4"' in edited,
              'resolution written to render profile and quality entry; MSAA set')
        check('present.maxFps' in (current / 'bin/mtld3d.conf').read_text(), 'renderer keys written')
        state = json.loads((support / 'launcher-state.json').read_text())
        check(state['profile'] == 'ready' and state['settings']['values']['resolution'] == '1920x1080',
              'snapshot reflects the edited profile')

        backup = work / 'backup.json'
        backup.write_text(json.dumps({'action': 'create'}))
        result = run('--backups', '--request', str(backup))
        check(result.returncode == 0 and len(json.loads((support / 'launcher-state.json').read_text())['backups']) == 1,
              'backup created and listed')

        play = work / 'play.json'
        play.write_text(json.dumps({'settings': {'values': {}}}))
        result = run('--play', '--request', str(play))
        print(result.stdout.strip()[-600:])
        print('play exit status:', result.returncode)
        check(not (support / 'Data/Prefix/dosdevices/g:').exists(), 'G: drive removed after play')
        check(not (support / 'game-session.json').exists(), 'game lease cleared')
        check('G:\\bin' in result.stdout or 'G:\\bin' in (work / 'last.log').read_text(),
              'the game process started with G:\\bin as its working directory')
        # `wineserver -k` succeeds only when a server for THIS prefix is still running.
        leftover = subprocess.run([str(wineserver), '-k'], env=wine_env, capture_output=True)
        check(leftover.returncode != 0, 'no wineserver of this prefix remains')

        key_file = app / 'Contents/Resources/renderer-cache-key.json'
        if key_file.is_file():
            key = json.loads(key_file.read_text())
            identifier = cache_identifier(key)
            saved = support / 'ShaderCache' / identifier / 'mtld3d_shaders.bin'
            binfolder = current / 'bin'
            state_file = support / 'launcher-state.json'
            check('Shader cache: none yet' in result.stdout, 'the first launch is reported as cold')
            check(not (binfolder / 'mtld3d_shaders.bin.owner').exists()
                  and not (binfolder / 'mtld3d_shaders.bin').exists(), 'no cache or marker left in bin after play')
            check(json.loads(state_file.read_text())['shaderCache']['state'] == 'empty', 'empty cache reported')
            singles = synthetic_cache('synthetic-cache-singles.bin', key)
            bundle = synthetic_cache('synthetic-cache-bundle.bin', key)
            incoming = work / 'incoming.fc2shadercache'
            incoming.write_bytes(export_container(singles, key))
            request.write_text(json.dumps({'action': 'import', 'path': str(incoming)}))
            result = run('--shader-cache', '--request', str(request))
            check(result.returncode == 0 and saved.read_bytes() == singles, 'import installs the cache outside the game folder')
            check(json.loads(state_file.read_text())['shaderCache']['state'] == 'warm', 'warm cache reported')
            result = run('--shader-cache', '--request', str(request))
            check(result.returncode == 0 and 'already imported' in result.stdout, 'importing the same file again changes nothing')
            check(saved.read_bytes() == singles, 'the saved cache is unchanged by a repeated import')
            garbage = work / 'garbage.fc2shadercache'
            garbage.write_bytes(b'not a cache export')
            request.write_text(json.dumps({'action': 'import', 'path': str(garbage)}))
            result = run('--shader-cache', '--request', str(request))
            check(result.returncode != 0 and saved.read_bytes() == singles, 'a damaged export is refused and changes nothing')
            result = run('--play', '--request', str(play))
            check('starting from %d saved bytes' % len(singles) in result.stdout, 'play starts from the saved cache')
            check(saved.read_bytes() == singles and not (binfolder / 'mtld3d_shaders.bin').exists()
                  and not (binfolder / 'mtld3d_shaders.bin.owner').exists(), 'the cache is back in storage after play')
            # A killed session leaves the file mtld3d wrote in bin; the next session must keep it.
            (binfolder / 'mtld3d_shaders.bin').write_bytes(bundle)
            (binfolder / 'mtld3d_shaders.bin.owner').write_text(identifier + '\n')
            result = run('--prepare')
            check(result.returncode == 0 and saved.read_bytes() == bundle, 'a crashed session loses nothing')
            check(not (binfolder / 'mtld3d_shaders.bin').exists(), 'the recovered file leaves bin')
            (binfolder / 'mtld3d_shaders.bin').write_bytes(singles)  # not placed by the starter: no marker
            result = run('--prepare')
            check(result.returncode == 0 and saved.read_bytes() == bundle
                  and not (binfolder / 'mtld3d_shaders.bin').exists(), 'a cache the starter did not place is never saved')
            outgoing = work / 'outgoing.fc2shadercache'
            request.write_text(json.dumps({'action': 'export', 'path': str(outgoing)}))
            result = run('--shader-cache', '--request', str(request))
            data = outgoing.read_bytes() if outgoing.exists() else b''
            length = int.from_bytes(data[8:12], 'little')
            manifest = json.loads(data[12:12 + length]) if data[:8] == b'FC2SHCEX' else {}
            check(result.returncode == 0 and data[12 + length:] == bundle
                  and manifest.get('payloadSHA256') == hashlib.sha256(bundle).hexdigest()
                  and manifest.get('key') == key, 'export writes a verified file for this renderer build')
            request.write_text(json.dumps({'action': 'export', 'path': str(support / 'inside.fc2shadercache')}))
            result = run('--shader-cache', '--request', str(request))
            check(result.returncode != 0 and not (support / 'inside.fc2shadercache').exists(),
                  'export refuses a destination inside the player folder')
            other = dict(key, mtld3dRevision='0' * 40)
            foreign = work / 'foreign.fc2shadercache'
            foreign.write_bytes(export_container(singles, other))
            request.write_text(json.dumps({'action': 'import', 'path': str(foreign)}))
            result = run('--shader-cache', '--request', str(request))
            check(result.returncode != 0 and saved.read_bytes() == bundle, "another renderer build's cache is refused")
            request.write_text(json.dumps({'action': 'reset'}))
            result = run('--shader-cache', '--request', str(request))
            check(result.returncode == 0 and not saved.exists(), 'reset deletes the saved cache')
            check(json.loads(state_file.read_text())['shaderCache']['state'] == 'empty', 'reset is reported')
        else:
            print('SKIP shader cache checks: this app carries no renderer cache key')
    finally:
        if support.exists():
            subprocess.run([str(wineserver), '-k'], env=wine_env, capture_output=True)
        if not options.keep: shutil.rmtree(work, ignore_errors=True)
    print('FAILED: ' + '; '.join(failures) if failures else 'All smoke checks passed')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
