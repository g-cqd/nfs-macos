"""Distribution signing accepts Developer ID and scopes Wine's memory exception."""
from signing_policy import resolve_identity, executable_entitlements

development = '1' * 40
distribution = '2' * 40
developer_id = '3' * 40
listing = f'''  1) {development} "Apple Development: Example (TEAM)"
  2) {distribution} "Apple Distribution: Example (TEAM)"
  3) {developer_id} "Developer ID Application: Example (TEAM)"
     3 valid identities found'''
assert resolve_identity('-', listing) == '-'
assert resolve_identity(developer_id, listing) == developer_id
assert resolve_identity('Developer ID Application: Example (TEAM)', listing) == developer_id
for invalid in [development, distribution, 'Example', '4' * 40]:
    try: resolve_identity(invalid, listing)
    except ValueError: pass
    else: raise AssertionError('Accepted a missing or incorrect signing identity')
assert executable_entitlements('Contents/SharedSupport/Wine/bin/wine') == {
    'com.apple.security.cs.allow-unsigned-executable-memory': True,
    'com.apple.security.cs.disable-library-validation': True}
assert executable_entitlements('Contents/SharedSupport/Wine/lib/wine/x86_64-unix/wine')
for path in ['Contents/MacOS/NFSMWLauncher', 'Contents/Helpers/NFSMWSession',
             'Contents/Helpers/x87sidecar', 'Contents/SharedSupport/Wine/bin/wineserver']:
    assert executable_entitlements(path) == {}, path
print('Distribution signing policy regression passed')
