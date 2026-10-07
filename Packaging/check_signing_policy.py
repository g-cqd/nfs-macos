"""Distribution signing accepts Developer ID and scopes Wine's memory exception."""
from privacy import DEVICE_ENTITLEMENTS
from signing_policy import (resolve_identity, executable_entitlements, signing_entitlements,
                            WINEHOST_BUNDLE_IDENTIFIER, WINEHOST_TEAM)

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
winehost_app = 'Contents/Helpers/winehost.app'
winehost_executable = winehost_app + '/Contents/MacOS/winehost'
expected_winehost = {
    'com.apple.developer.cross-architecture-support': True,
    'com.apple.security.cs.allow-jit': True,
    'com.apple.security.cs.disable-library-validation': True,
    'com.apple.application-identifier': WINEHOST_TEAM + '.' + WINEHOST_BUNDLE_IDENTIFIER,
    'com.apple.developer.team-identifier': WINEHOST_TEAM}
# The helper's executable and its bundle are signed with the same set: re-signing the nested
# app replaces the inner signature, so the bundle call has to carry the entitlements.
for path in [winehost_app, winehost_executable]:
    assert executable_entitlements(path) == expected_winehost, path
    assert signing_entitlements(path, developer_id) == expected_winehost, path
    # Ad-hoc: only the unrestricted keys; a restricted one without a profile gets the process killed.
    assert signing_entitlements(path, '-') == {
        'com.apple.security.cs.allow-jit': True,
        'com.apple.security.cs.disable-library-validation': True}, path
assert executable_entitlements('Contents/Helpers/Rosetta Request.app') == {}
assert executable_entitlements('Contents/Helpers/winehost.app/Contents/Resources/other') == {}
# Every other ad-hoc path keeps signing without entitlements, as before the arm64 route.
for path in ['Contents/Helpers/x87sidecar', winehost_app + '/Contents/MacOS/other']:
    assert signing_entitlements(path, '-') == {}, path
    assert signing_entitlements(path, developer_id) == executable_entitlements(path), path
print('Distribution signing policy regression passed')
