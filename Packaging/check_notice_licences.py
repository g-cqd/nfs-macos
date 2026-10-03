"""Every component the shipped NOTICE.md names has its licence file in the app.

Regression for the Need for Speed (2015) apps of 2026-10-02: NOTICE.md said DXMT's licence travels
with the app, but `Contents/Resources/Licenses` held no DXMT text. The MIT licence asks for its notice
to accompany copies. The recipe now pins the verbatim v0.80 text, the packager stages exactly those
bytes, and the audit compares the app against the NOTICE section by section.

Every fixture is synthetic; the one real file read is the pinned licence text in this tree.
"""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory

from assemble import stage_third_party_licenses
from bundle_hygiene import (LICENSE_TEXTS, NOTICE_NOT_SHIPPED, audit_notice_licences, notice_components,
                            third_party_licence_bytes, third_party_licence_provenance)
from recipes import load_recipe, validate_recipe

PROJECT = Path(__file__).resolve().parents[1]
NOTICE = (PROJECT / 'Packaging/NFS2015Runtime/NOTICE.md').read_text()


def refuses(action, fragment):
    try:
        action()
    except ValueError as error:
        assert fragment in str(error), (fragment, str(error))
        return
    raise AssertionError('Expected a refusal mentioning: ' + fragment)


recipe = load_recipe('nfs2015')
(dxmt,) = recipe['thirdPartyLicenses']

# 1. The pin names the real text, and the text is the upstream v0.80 file, not something close to it.
text = third_party_licence_bytes(dxmt)
assert hashlib.sha256(text).hexdigest() == dxmt['sha256']
assert hashlib.sha1(b'blob %d\0' % len(text) + text).hexdigest() == dxmt['blobSHA1'], 'Not the git blob of the tag'
assert text.startswith(b'MIT License\n') and b'Permission is hereby granted, free of charge' in text
assert b'Copyright (c) 2023 Feifan He' in text and b'LGPL' not in text.upper() and len(text) == 1065
assert dxmt['version'] == 'v0.80' and dxmt['licence'] == 'MIT' and dxmt['url'].endswith('/v0.80/LICENSE')
assert dxmt['path'] == 'Licenses/dxmt.txt' and (LICENSE_TEXTS / dxmt['source']).is_file()
print('PASS the dxmt licence is the pinned verbatim v0.80 text (SHA-256 %s)' % dxmt['sha256'])

# 2. The recipe loader refuses a malformed declaration.
broken = [({**dxmt, 'sha256': 'abc'}, 'SHA-256'), ({**dxmt, 'path': '../Licenses/dxmt.txt'}, 'without traversal'),
          ({**dxmt, 'path': 'Elsewhere/dxmt.txt'}, 'Licenses/<name>.txt'), ({**dxmt, 'source': '../x.txt'}, 'plain file'),
          ({**dxmt, 'url': 'http://example.invalid/'}, 'https'), ({**dxmt, 'tagCommit': 'main'}, 'tagCommit'),
          ({**dxmt, 'blobSHA1': 'z' * 40}, 'blobSHA1'), ({**dxmt, 'extra': 1}, 'declares exactly'),
          ({key: value for key, value in dxmt.items() if key != 'licence'}, 'declares exactly')]
for entry, fragment in broken:
    candidate = deepcopy(recipe)
    candidate['thirdPartyLicenses'] = [entry]
    refuses(lambda: validate_recipe(candidate), fragment)
for entries, fragment in [([dxmt, dict(dxmt, path='Licenses/other.txt')], 'Duplicate'), ([], 'non-empty'),
                          ([dxmt, dict(dxmt, component='DXMT', path='Licenses/other.txt')], 'Duplicate'),
                          ([dxmt, dict(dxmt, component='other')], 'Duplicate')]:
    candidate = deepcopy(recipe)
    candidate['thirdPartyLicenses'] = entries
    refuses(lambda: validate_recipe(candidate), fragment)
print('PASS the recipe loader refuses malformed or duplicate licence declarations')

# 3. The packager stages exactly the pinned bytes, replacing any inherited file, and refuses a changed text.
with TemporaryDirectory() as temporary:
    resources = Path(temporary) / 'Resources'
    (resources / 'Licenses').mkdir(parents=True)
    (resources / 'Licenses/dxmt.txt').write_text('inherited from another app')
    staged = stage_third_party_licenses(resources, recipe)
    assert (resources / 'Licenses/dxmt.txt').read_bytes() == text
    assert staged == [third_party_licence_provenance(dxmt)] and staged[0]['sha256'] == dxmt['sha256']
    assert set(staged[0]) == {'component', 'version', 'licence', 'path', 'sha256', 'url', 'tagCommit'}
    assert stage_third_party_licenses(resources, {}) == []
    wrong = deepcopy(recipe)
    wrong['thirdPartyLicenses'][0]['sha256'] = '0' * 64
    refuses(lambda: stage_third_party_licenses(Path(temporary) / 'None', wrong), 'does not match its pin')
    assert not (Path(temporary) / 'None').exists(), 'Something was staged before the refusal'
    missing = deepcopy(recipe)
    missing['thirdPartyLicenses'][0]['source'] = 'not-there.txt'
    refuses(lambda: stage_third_party_licenses(Path(temporary) / 'None', missing), 'is missing')
print('PASS the packager stages the pinned bytes and refuses a text that is not its pin')


# 4. The audit, on a synthetic app that has what the shipped NOTICE.md promises.
def synthetic_app(root):
    resources = root / 'Contents/Resources'
    (resources / 'Sources/wine-nfs2015').mkdir(parents=True)
    (resources / 'Sources/wine-nfs2015/NOTICE.md').write_text(NOTICE)
    licences = resources / 'Licenses'
    (licences / 'Wine-dependencies/freetype/2.14.3').mkdir(parents=True)
    (licences / 'Wine-dependencies/freetype/2.14.3/LICENSE.TXT').write_text('FreeType licence')
    (licences / 'Wine-COPYING.LIB.txt').write_text('\t\t  GNU LESSER GENERAL PUBLIC LICENSE\n\t\t       Version 2.1, February 1999\n')
    (licences / 'dxmt.txt').write_bytes(text)
    return root


assert notice_components(NOTICE) == ['Wine', 'dxmt', 'Apple D3DMetal', 'Everything else'], notice_components(NOTICE)
assert 'Contents/Resources/Licenses/dxmt.txt' in NOTICE and dxmt['sha256'] in NOTICE and dxmt['tagCommit'] in NOTICE
with TemporaryDirectory() as temporary:
    app = synthetic_app(Path(temporary) / 'good.app')
    assert audit_notice_licences(app, recipe) == [], audit_notice_licences(app, recipe)
    # An app that carries no NOTICE and declares no licence has nothing to check.
    bare = Path(temporary) / 'bare.app'
    (bare / 'Contents/Resources').mkdir(parents=True)
    assert audit_notice_licences(bare, {}) == []

    def mutated(change):
        app = synthetic_app(Path(temporary) / ('mutant-%d.app' % len(list(Path(temporary).iterdir()))))
        change(app / 'Contents/Resources')
        return audit_notice_licences(app, recipe)

    def drop(path):
        return lambda resources: (resources / path).unlink()

    def write(path, content):
        return lambda resources: (resources / path).write_bytes(content)

    mutants = {
        'dxmt licence missing': (drop('Licenses/dxmt.txt'),
                                 ['The licence of dxmt is missing: Licenses/dxmt.txt',
                                  'dxmt is named in Contents/Resources/Sources/wine-nfs2015/NOTICE.md without its licence file']),
        'dxmt licence altered by one byte': (write('Licenses/dxmt.txt', text.replace(b'2023', b'2024')),
                                              ['The licence of dxmt is not the pinned text']),
        'dxmt licence is the LGPL text': (write('Licenses/dxmt.txt', b'GNU LESSER GENERAL PUBLIC LICENSE'),
                                          ['The licence of dxmt is not the pinned text']),
        'dxmt licence empty': (write('Licenses/dxmt.txt', b''), ['The licence of dxmt is not the pinned text']),
        'Wine licence missing': (drop('Licenses/Wine-COPYING.LIB.txt'),
                                 ['Wine is named in Contents/Resources/Sources/wine-nfs2015/NOTICE.md but Licenses/Wine-COPYING.LIB.txt is not the LGPL 2.1 text']),
        'Wine licence is another text': (write('Licenses/Wine-COPYING.LIB.txt', b'GNU GENERAL PUBLIC LICENSE Version 3'),
                                         ['Wine is named in Contents/Resources/Sources/wine-nfs2015/NOTICE.md but Licenses/Wine-COPYING.LIB.txt is not the LGPL 2.1 text']),
        'library notice empty': (write('Licenses/Wine-dependencies/freetype/2.14.3/LICENSE.TXT', b''),
                                 ['No licence file for freetype 2.14.3']),
        'library notices missing': (lambda resources: (resources / 'Licenses/Wine-dependencies/freetype/2.14.3/LICENSE.TXT').unlink(),
                                    ['No licence file for freetype 2.14.3']),
        'NOTICE names an unknown component': (
            write('Sources/wine-nfs2015/NOTICE.md', NOTICE.encode() + b'\n## Brand new library \xe2\x80\x94 added later\n'),
            ["Contents/Resources/Sources/wine-nfs2015/NOTICE.md names 'Brand new library', which has no licence rule in the audit"]),
        'NOTICE names nothing': (write('Sources/wine-nfs2015/NOTICE.md', b'no headings here'),
                                 ['Contents/Resources/Sources/wine-nfs2015/NOTICE.md names no component']),
    }
    for name, (change, expected) in mutants.items():
        assert mutated(change) == expected, (name, mutated(change))

    # A licence that is a link is not a licence file, even when it points at the pinned text.
    def link(resources):
        target = resources / 'real.txt'
        target.write_bytes(text)
        (resources / 'Licenses/dxmt.txt').unlink()
        (resources / 'Licenses/dxmt.txt').symlink_to(target)
    assert mutated(link) == ['The licence of dxmt is missing: Licenses/dxmt.txt'], mutated(link)

    # D3DMetal is said not to ship, so any file named for it, or for the GPTK backend, anywhere in the app fails.
    for relative, reported in [
            ('Contents/SharedSupport/Wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal',
             'Contents/SharedSupport/Wine/lib/external/D3DMetal.framework'),
            ('Contents/SharedSupport/Wine/lib/external/libd3dshared.dylib',
             'Contents/SharedSupport/Wine/lib/external/libd3dshared.dylib'),
            ('Contents/SharedSupport/Wine/lib/wine/dxgi/gptk/dxgi.dll',
             'Contents/SharedSupport/Wine/lib/wine/dxgi/gptk')]:
        app = synthetic_app(Path(temporary) / ('d3dmetal-%d.app' % len(list(Path(temporary).iterdir()))))
        (app / relative).parent.mkdir(parents=True, exist_ok=True)
        (app / relative).write_bytes(b'\xcf\xfa\xed\xfe')
        assert audit_notice_licences(app, recipe) == [
            'Apple D3DMetal is said not to ship but ' + reported + ' is in the app'], relative
    assert NOTICE_NOT_SHIPPED == {'apple d3dmetal': ('d3dmetal', 'libd3dshared', 'gptk')}

    # The pinned text is required even when the app carries no NOTICE.
    app = Path(temporary) / 'no-notice.app'
    (app / 'Contents/Resources/Licenses').mkdir(parents=True)
    assert audit_notice_licences(app, recipe) == ['The licence of dxmt is missing: Licenses/dxmt.txt']
print('PASS the audit holds every component NOTICE.md names to its licence file (%d mutants refused)' % (len(mutants) + 5))

# 5. No other recipe is affected: the games that do not ship dxmt declare nothing and still validate.
for path in sorted((PROJECT / 'Packaging/Recipes').glob('*.json')):
    loaded = load_recipe(path.stem)
    assert ('thirdPartyLicenses' in loaded) == (path.stem == 'nfs2015'), path.name
shipped = json.loads(json.dumps(recipe))
assert validate_recipe(shipped)['thirdPartyLicenses'] == recipe['thirdPartyLicenses']
print('PASS notice licence gate: all checks passed')
