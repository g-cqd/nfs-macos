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


def executable_entitlements(relative_path):
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
        return {key: value for key, value in entitlements.items() if key in DEVICE_ENTITLEMENTS}
    return entitlements
