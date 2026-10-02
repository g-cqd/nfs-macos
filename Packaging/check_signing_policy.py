"""Distribution signing accepts Developer ID and scopes Wine's memory exception."""
from privacy import DEVICE_ENTITLEMENTS
from signing_policy import resolve_identity, executable_entitlements, signing_entitlements

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
memory = {'com.apple.security.cs.allow-unsigned-executable-memory': True,
          'com.apple.security.cs.disable-library-validation': True}
for loader in ['Contents/SharedSupport/Wine/bin/wine',
               'Contents/SharedSupport/Wine/lib/wine/x86_64-unix/wine']:
    # Wine's memory exception stays scoped to the loaders; they also carry the device entitlements.
    assert executable_entitlements(loader) == memory | DEVICE_ENTITLEMENTS, loader
# The starter and the session helper carry the device entitlements and nothing else.
for path in ['Contents/MacOS/NFSMWLauncher', 'Contents/Helpers/NFSMWSession',
             'Contents/MacOS/NFS2015Launcher', 'Contents/Helpers/NFS2015Session']:
    assert executable_entitlements(path) == DEVICE_ENTITLEMENTS, path
for path in ['Contents/Helpers/x87sidecar', 'Contents/SharedSupport/Wine/bin/wineserver']:
    assert executable_entitlements(path) == {}, path
# An ad-hoc signature keeps only the device entitlements; Developer ID keeps all of them.
assert signing_entitlements('Contents/SharedSupport/Wine/bin/wine', '-') == DEVICE_ENTITLEMENTS
assert signing_entitlements('Contents/SharedSupport/Wine/bin/wine', developer_id) == (
    memory | DEVICE_ENTITLEMENTS)
assert signing_entitlements('Contents/Helpers/x87sidecar', '-') == {}
print('Distribution signing policy regression passed')
