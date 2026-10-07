"""Developer ID selection, the executable-memory exception required by Wine, and device entitlements."""
import re
from privacy import DEVICE_ENTITLEMENTS, carries_device_entitlements


def resolve_identity(identity, listing):
    if identity == '-': return identity
    matches = []
    for fingerprint, name in re.findall(r'\d+\) ([0-9A-Fa-f]{40}) "([^"]+)"', listing):
        if name.startswith('Developer ID Application: ') and identity in {fingerprint, name}:
            matches.append(fingerprint)
    if len(matches) != 1:
        raise ValueError('Choose one valid Developer ID Application identity from security find-identity -v -p codesigning')
    return matches[0]


WINEHOST_BUNDLE_IDENTIFIER = 'fr.gcqd.winehost'
WINEHOST_TEAM = 'NP94WB3P75'
WINEHOST_APP = 'Contents/Helpers/winehost.app'
WINEHOST_PATHS = {WINEHOST_APP, WINEHOST_APP + '/Contents/MacOS/winehost'}
# Restricted entitlements are honoured only when a provisioning profile authorizes them; an
# ad-hoc build has no profile, and the kernel kills a process that claims one anyway.
WINEHOST_RESTRICTED = {'com.apple.developer.cross-architecture-support',
                       'com.apple.application-identifier', 'com.apple.developer.team-identifier'}


def winehost_entitlements():
    """What the arm64 host needs: the profile-backed 4 GiB/page-zero entitlement and JIT."""
    return {'com.apple.developer.cross-architecture-support': True,
            'com.apple.security.cs.allow-jit': True,
            'com.apple.security.cs.disable-library-validation': True,
            'com.apple.application-identifier': WINEHOST_TEAM + '.' + WINEHOST_BUNDLE_IDENTIFIER,
            'com.apple.developer.team-identifier': WINEHOST_TEAM}


def executable_entitlements(relative_path):
    if relative_path in WINEHOST_PATHS:
        # The arm64 host is not a device-request program; its set is fixed by the profile.
        return winehost_entitlements()
    entitlements = dict(DEVICE_ENTITLEMENTS) if carries_device_entitlements(relative_path) else {}
    if relative_path in {'Contents/SharedSupport/Wine/bin/wine',
                         'Contents/SharedSupport/Wine/lib/wine/x86_64-unix/wine'}:
        # Wine maps executable Windows modules that have no Apple code signature.
        entitlements |= {'com.apple.security.cs.allow-unsigned-executable-memory': True,
                         'com.apple.security.cs.disable-library-validation': True}
    return entitlements


def signing_entitlements(relative_path, identity):
    """What to embed when signing a program with this identity.

    An ad-hoc signature does not enable the hardened runtime, so Wine's memory exception has
    nothing to relax there and is left out. The device entitlements are kept in every build, so
    the audit can demand them of every app and a later Developer ID signature starts from the
    same declarations.
    """
    entitlements = executable_entitlements(relative_path)
    if identity == '-':
        if relative_path in WINEHOST_PATHS:
            # Restricted entitlements need the provisioning profile; without it the process is killed.
            return {key: value for key, value in entitlements.items() if key not in WINEHOST_RESTRICTED}
        return {key: value for key, value in entitlements.items() if key in DEVICE_ENTITLEMENTS}
    return entitlements
