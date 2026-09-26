"""Developer ID selection and the executable-memory exception required by Wine."""
import re


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
    if relative_path in {'Contents/SharedSupport/Wine/bin/wine',
                         'Contents/SharedSupport/Wine/lib/wine/x86_64-unix/wine'}:
        # Wine maps executable Windows modules that have no Apple code signature.
        return {'com.apple.security.cs.allow-unsigned-executable-memory': True,
                'com.apple.security.cs.disable-library-validation': True}
    return {}
