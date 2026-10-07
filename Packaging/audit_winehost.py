"""Audit of the native arm64 route's nested helper, Contents/Helpers/winehost.app.

Runs only when the helper is present, so the audit of every existing build is unchanged. It
checks, without launching anything: the executable is a thin arm64 Mach-O; the signed
entitlements are the expected set (the full set for Developer ID, the unrestricted subset for an
ad-hoc build); the embedded provisioning profile decodes, belongs to the right team and App ID,
carries the cross-architecture entitlement and has not expired; its certificates have not
expired; and, for a Developer ID build, that the certificate the helper was signed with is one
the profile names.
"""
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile

from signing_policy import (WINEHOST_APP, WINEHOST_BUNDLE_IDENTIFIER, WINEHOST_TEAM,
                            signing_entitlements)
from winehost import EXECUTABLE_NAME, PROFILE_RELATIVE, macho_header, MACH_O_ARM64

CROSS_ARCHITECTURE = 'com.apple.developer.cross-architecture-support'


def run_tool(command):
    """Run a system tool and return (stdout bytes, stderr text); a missing tool raises."""
    done = subprocess.run(command, capture_output=True)
    if done.returncode != 0:
        raise ValueError(command[0] + ' failed: ' + done.stderr.decode(errors='replace').strip()[:200])
    return done.stdout, done.stderr.decode(errors='replace')


def decode_profile(path, tool=run_tool):
    """The profile's property list, decoded from its CMS envelope by `security cms -D`."""
    output, _ = tool(['/usr/bin/security', 'cms', '-D', '-i', str(path)])
    profile = plistlib.loads(output)
    if not isinstance(profile, dict):
        raise ValueError('The provisioning profile is not a property list')
    return profile


def certificate_expiry(der, tool=run_tool):
    with tempfile.NamedTemporaryFile(suffix='.der') as temporary:
        temporary.write(der); temporary.flush()
        output, _ = tool(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-noout', '-enddate',
                          '-in', temporary.name])
    text = output.decode().strip()
    assert text.startswith('notAfter='), text
    return datetime.strptime(' '.join(text[len('notAfter='):].split()), '%b %d %H:%M:%S %Y %Z').replace(
        tzinfo=timezone.utc)


def profile_problems(profile, signed_entitlements, now, signing_fingerprint=None, expiry=certificate_expiry):
    """Everything wrong with a decoded profile; an empty list means it can authorize the helper."""
    problems = []
    entitlements = profile.get('Entitlements', {})
    if profile.get('TeamIdentifier') != [WINEHOST_TEAM]:
        problems.append('The provisioning profile is not for team ' + WINEHOST_TEAM + ': '
                        + str(profile.get('TeamIdentifier')))
    if entitlements.get('com.apple.developer.team-identifier') != WINEHOST_TEAM:
        problems.append('The profile entitles a different team identifier')
    if entitlements.get('com.apple.application-identifier') != WINEHOST_TEAM + '.' + WINEHOST_BUNDLE_IDENTIFIER:
        problems.append('The profile is not for the App ID ' + WINEHOST_TEAM + '.' + WINEHOST_BUNDLE_IDENTIFIER)
    if entitlements.get(CROSS_ARCHITECTURE) is not True:
        problems.append('The profile does not carry ' + CROSS_ARCHITECTURE)
    expires = profile.get('ExpirationDate')
    if not isinstance(expires, datetime):
        problems.append('The profile has no expiration date')
    elif expires.replace(tzinfo=timezone.utc) <= now:
        problems.append('The provisioning profile expired on ' + expires.isoformat())
    # Every restricted entitlement the helper claims must be one the profile grants with the same value.
    for key in ('com.apple.developer.cross-architecture-support', 'com.apple.application-identifier',
                'com.apple.developer.team-identifier'):
        if key in signed_entitlements and entitlements.get(key) != signed_entitlements[key]:
            problems.append('The signed entitlement ' + key + ' is not granted by the profile')
    certificates = profile.get('DeveloperCertificates', [])
    if not certificates:
        problems.append('The profile names no certificate')
    alive = {}
    for der in certificates:
        alive[hashlib.sha1(der).hexdigest()] = expiry(der) > now
    if certificates and not any(alive.values()):
        problems.append('Every certificate in the provisioning profile has expired')
    if signing_fingerprint is not None:
        if signing_fingerprint not in alive:
            problems.append('The helper is signed with a certificate the profile does not name')
        elif not alive[signing_fingerprint]:
            problems.append('The certificate the helper is signed with has expired')
    return problems


def signed_entitlements_of(path, tool=run_tool):
    output, _ = tool(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(path)])
    return plistlib.loads(output) if output.strip() else {}


def signing_state(path, tool=run_tool):
    """(is_ad_hoc, leaf certificate SHA-1 or None) from the helper's own signature."""
    _, details = tool(['/usr/bin/codesign', '-d', '--verbose=2', str(path)])
    if 'Signature=adhoc' in details:
        return True, None
    with tempfile.TemporaryDirectory() as temporary:
        prefix = Path(temporary) / 'cert'
        tool(['/usr/bin/codesign', '-d', '--extract-certificates=' + str(prefix), str(path)])
        leaf = Path(str(prefix) + '0')
        return False, hashlib.sha1(leaf.read_bytes()).hexdigest()


def audit_winehost(app, now=None, tool=run_tool, expiry=certificate_expiry):
    """Return (report, problems) for the helper in `app`."""
    app = Path(app)
    now = now or datetime.now(timezone.utc)
    helper = app / WINEHOST_APP
    problems = []
    report = {'helper': WINEHOST_APP}
    executable = helper / 'Contents/MacOS' / EXECUTABLE_NAME
    try:
        if macho_header(executable) != MACH_O_ARM64:
            problems.append('The winehost executable is not a thin arm64 Mach-O')
    except (OSError, ValueError):
        problems.append('The winehost executable is missing or not a Mach-O')
    info_path = helper / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
    if info.get('CFBundleIdentifier') != WINEHOST_BUNDLE_IDENTIFIER:
        problems.append('The helper bundle identifier must be ' + WINEHOST_BUNDLE_IDENTIFIER)
    if info.get('CFBundleExecutable') != EXECUTABLE_NAME:
        problems.append('The helper executable name must be ' + EXECUTABLE_NAME)
    profile_path = app / PROFILE_RELATIVE
    if not profile_path.is_file():
        problems.append('The helper has no embedded.provisionprofile')
    try:
        ad_hoc, fingerprint = signing_state(helper, tool)
        signed = signed_entitlements_of(helper, tool)
    except (OSError, ValueError) as error:
        return report, problems + ['The helper signature cannot be read: ' + str(error)]
    report['signature'] = 'ad-hoc' if ad_hoc else 'Developer ID'
    expected = signing_entitlements(WINEHOST_APP, ad_hoc)
    if signed != expected:
        missing = sorted(set(expected) - set(signed))
        extra = sorted(set(signed) - set(expected))
        wrong = sorted(key for key in set(expected) & set(signed) if expected[key] != signed[key])
        problems.append('Unexpected winehost entitlements: missing %s, extra %s, wrong %s'
                        % (missing, extra, wrong))
    if ad_hoc:
        report['note'] = ('ad-hoc: ' + CROSS_ARCHITECTURE + ' is deliberately omitted; the helper '
                          'cannot get a 4 GiB address space until it is signed with Developer ID')
    if profile_path.is_file():
        try:
            profile = decode_profile(profile_path, tool)
        except (ValueError, plistlib.InvalidFileException, OSError) as error:
            problems.append('The provisioning profile cannot be decoded: ' + str(error))
        else:
            problems += profile_problems(profile, signed, now, fingerprint, expiry)
            report['profile'] = {'name': profile.get('Name'),
                                 'expires': profile['ExpirationDate'].isoformat()
                                 if isinstance(profile.get('ExpirationDate'), datetime) else None}
    return report, problems
