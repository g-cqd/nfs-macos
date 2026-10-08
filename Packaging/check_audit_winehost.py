"""The arm64 route audit accepts a consistent helper and names each way one can be wrong.

The provisioning profile is synthetic: a property list wrapped in a CMS envelope signed by a
throwaway self-signed certificate made here. The real profile is never read.
"""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
from tempfile import TemporaryDirectory

from audit_winehost import audit_winehost, decode_profile, profile_problems, run_tool
from signing_policy import WINEHOST_BUNDLE_IDENTIFIER, WINEHOST_TEAM, signing_entitlements
from winehost import APP_RELATIVE, EXECUTABLE_RELATIVE, PROFILE_RELATIVE, info_plist

NOW = datetime(2026, 10, 7, tzinfo=timezone.utc)
OPENSSL = '/usr/bin/openssl'


def make_certificate(root, name):
    key, pem, der = root / (name + '.key'), root / (name + '.pem'), root / (name + '.der')
    subprocess.run([OPENSSL, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key),
                    '-out', str(pem), '-days', '3650', '-subj', '/CN=Synthetic ' + name],
                   check=True, capture_output=True)
    subprocess.run([OPENSSL, 'x509', '-in', str(pem), '-outform', 'DER', '-out', str(der)],
                   check=True, capture_output=True)
    return key, pem, der.read_bytes()


def make_profile(root, certificate, **overrides):
    """A CMS-wrapped profile like Apple's, signed with the throwaway certificate."""
    key, pem, der = certificate
    body = {'Name': 'synthetic winehost', 'TeamIdentifier': [WINEHOST_TEAM],
            'ExpirationDate': NOW + timedelta(days=3650), 'DeveloperCertificates': [der],
            'Entitlements': {'com.apple.developer.cross-architecture-support': True,
                             'com.apple.application-identifier': WINEHOST_TEAM + '.' + WINEHOST_BUNDLE_IDENTIFIER,
                             'com.apple.developer.team-identifier': WINEHOST_TEAM}}
    body.update(overrides)
    source, target = root / 'profile.plist', root / 'profile.cms'
    source.write_bytes(plistlib.dumps(body))
    subprocess.run([OPENSSL, 'smime', '-sign', '-binary', '-nodetach', '-outform', 'DER',
                    '-signer', str(pem), '-inkey', str(key), '-in', str(source), '-out', str(target)],
                   check=True, capture_output=True)
    return body, target


def make_app(root, profile_file, signing=None):
    """A minimal app whose helper is a real arm64 executable, optionally signed ad-hoc."""
    app = root / 'Test.app'
    helper = app / APP_RELATIVE
    (helper / 'Contents/MacOS').mkdir(parents=True)
    source = root / 'main.c'
    source.write_text('int main(void) { return 0; }\n')
    subprocess.run(['/usr/bin/xcrun', 'clang', '-arch', 'arm64', str(source), '-o',
                    str(app / EXECUTABLE_RELATIVE)], check=True, capture_output=True)
    (helper / 'Contents/Info.plist').write_bytes(plistlib.dumps(info_plist({})))
    if profile_file is not None:
        shutil.copy(profile_file, app / PROFILE_RELATIVE)
    if signing is not None:
        entitlements = root / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps(signing))
        command = ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none']
        if signing: command += ['--entitlements', str(entitlements)]
        subprocess.run(command + [str(helper)], check=True, capture_output=True)
    return app


with TemporaryDirectory() as temporary:
    root = Path(temporary)
    certificate = make_certificate(root, 'good')
    other = make_certificate(root, 'other')
    body, profile = make_profile(root, certificate)

    # The CMS envelope decodes with the system tool, as the audit decodes a real profile.
    decoded = decode_profile(profile)
    assert decoded['TeamIdentifier'] == [WINEHOST_TEAM]
    assert decoded['Entitlements']['com.apple.developer.cross-architecture-support'] is True

    # An ad-hoc helper signed by the project's policy passes, and says what it leaves out.
    ad_hoc = signing_entitlements(APP_RELATIVE, '-')
    assert 'com.apple.developer.cross-architecture-support' not in ad_hoc
    (root / 'a').mkdir()
    app = make_app(root / 'a', profile, ad_hoc)
    report, problems = audit_winehost(app, NOW)
    assert problems == [], problems
    assert report['signature'] == 'ad-hoc' and 'omitted' in report['note']

    # An ad-hoc helper that claims the restricted entitlement is rejected: it would be killed.
    claimed = signing_entitlements(APP_RELATIVE, 'Developer ID')
    (root / 'b').mkdir()
    _, problems = audit_winehost(make_app(root / 'b', profile, claimed), NOW)
    assert any('extra' in text and 'cross-architecture-support' in text for text in problems), problems

    # A missing entitlement set, a missing profile and an Intel executable are each reported.
    (root / 'c').mkdir()
    _, problems = audit_winehost(make_app(root / 'c', profile, {}), NOW)
    assert any('Unexpected winehost entitlements' in text for text in problems), problems
    (root / 'd').mkdir()
    _, problems = audit_winehost(make_app(root / 'd', None, ad_hoc), NOW)
    assert any('no embedded.provisionprofile' in text for text in problems), problems
    (root / 'e').mkdir()
    intel = make_app(root / 'e', profile, ad_hoc)
    data = bytearray((intel / EXECUTABLE_RELATIVE).read_bytes())
    data[4:8] = bytes.fromhex('07000001')
    (intel / EXECUTABLE_RELATIVE).write_bytes(bytes(data))
    _, problems = audit_winehost(intel, NOW)
    assert any('thin arm64' in text for text in problems), problems

    # An undecodable profile is a problem, not a crash.
    (root / 'f').mkdir()
    (root / 'garbage').write_bytes(b'not a CMS message')
    _, problems = audit_winehost(make_app(root / 'f', root / 'garbage', ad_hoc), NOW)
    assert any('cannot be decoded' in text for text in problems), problems

    # Developer ID: the audit expects the full set and the profile's certificate to match.
    full = signing_entitlements(APP_RELATIVE, 'Developer ID')
    fingerprint = hashlib.sha1(certificate[2]).hexdigest()
    assert profile_problems(body, full, NOW, fingerprint) == []
    cases = {
        'is not for team': dict(TeamIdentifier=['AAAAAAAAAA']),
        'expired on': dict(ExpirationDate=NOW - timedelta(days=1)),
        'no expiration': dict(ExpirationDate='soon'),
        'names no certificate': dict(DeveloperCertificates=[]),
        'does not carry': dict(Entitlements={**body['Entitlements'],
                                             'com.apple.developer.cross-architecture-support': False}),
        'App ID': dict(Entitlements={**body['Entitlements'],
                                     'com.apple.application-identifier': WINEHOST_TEAM + '.other.app'}),
    }
    for expected, change in cases.items():
        altered = {**deepcopy(body), **change}
        found = profile_problems(altered, full, NOW, fingerprint)
        assert any(expected in text for text in found), (expected, found)
    # The key not granted by the profile, the wrong signer and an expired signer.
    assert any('not granted' in text for text in profile_problems(
        body, {**full, 'com.apple.application-identifier': 'XXXXXXXXXX.other'}, NOW, fingerprint))
    assert any('does not name' in text for text in profile_problems(
        body, full, NOW, hashlib.sha1(other[2]).hexdigest()))
    expiry = lambda der: NOW - timedelta(days=1)
    found = profile_problems(body, full, NOW, fingerprint, expiry)
    assert any('Every certificate' in text for text in found) and any('has expired' in text for text in found), found
    # Certificate validity is read with the system openssl; a 10-year certificate outlives NOW but not 2040.
    assert profile_problems(body, full, NOW + timedelta(days=4000), fingerprint) != []
print('Winehost audit regressions passed')
