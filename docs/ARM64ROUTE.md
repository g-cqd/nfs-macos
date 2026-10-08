# Native arm64 Wine route: app side

This is the packaging and launch groundwork for hosting Wine natively on arm64 with `rosetta3`
as the x86 backend. It is additive. A recipe or bundle that does not opt in is assembled,
signed, audited and launched exactly as before; no existing recipe was edited.

Why a separate helper: an arm64 binary signed with the Developer ID certificate plus a
provisioning profile carrying `com.apple.developer.cross-architecture-support` gets a hard page
zero of one page (so `mmap(MAP_FIXED)` works below 4 GiB) and, when spawned with
`posix_spawnattr_set_4k_page_size_np`, a 4 KiB page size. Foundation's `Process` cannot set spawn
attributes, hence the `posix_spawn` launcher.

## What changed

### Launching (`Sources/LauncherCore`)

* `SpawnCommand.swift`: `SpawnCommand` starts a child with `posix_spawn` and the same contract
  as `ProcessCommand` (exact environment, working directory by file action, stdin `/dev/null`,
  stdout and stderr to the log, `POSIX_SPAWN_CLOEXEC_DEFAULT`, default signal dispositions). It
  returns `SpawnedProcess` (`wait()`, `terminate()`; exit status or signal number, as
  `Process.terminationStatus`).
* `FourKilobytePageSupport` looks `posix_spawnattr_set_4k_page_size_np` up with `dlsym`, behind
  `#available(macOS 26.0, *)`. The package minimum stays macOS 15 and the code builds against an
  older SDK. When a 4 KiB page size is requested and the symbol is missing, `start` throws
  "A 4 KiB page size is unsupported on this Mac" before spawning anything; it never crashes and
  never silently falls back to 16 KiB pages.
* `SpawnProfile` is the runtime profile flag. `ProcessCommand` takes `profile:` (default
  `.foundation`); under `.arm64Wow64`, `run` goes through `SpawnCommand`, otherwise through
  `Process`, unchanged. `start` (which returns a `Process`) refuses the arm64 profile.
* The flag comes from the bundle: `AppPaths.spawnProfile()` reads
  `Contents/Resources/runtime-profile.json`. No file means `.foundation`.
  `{"profile": "arm64-wow64", "fourKilobytePages": true}` selects the new path; an unknown or
  malformed marker is an error. `WineRuntime` and `FarCry2Session` pass the profile through, and
  `FarCry2Session` skips the "install Rosetta" probe when the profile does not need it.

### Packaging (`Packaging/`)

* `winehost.py`: the optional recipe key `winehost`, its validator (called from
  `recipes.validate_recipe`) and `stage_winehost`, called from `assemble.py` right after the
  Rosetta request helper. It builds `Contents/Helpers/winehost.app` with bundle identifier
  `fr.gcqd.winehost`, executable `winehost` (a thin arm64 Mach-O from the recipe's input,
  checked by header) and `Contents/embedded.provisionprofile` (copied from the recipe's profile
  input; size-bounded; never read from or written to the repository).
* `signing_policy.py`: `winehost_entitlements()` and `signing_entitlements(path, ad_hoc)`.
  `executable_entitlements` returns the set for both the helper's executable and the helper
  bundle path, so the nested-app re-sign in `sign.py` (which replaces the inner signature)
  keeps them.
* `sign.py`: uses `signing_entitlements`; refuses a Developer ID build of a helper with no
  embedded profile; records the helper in `Evidence/signing-<game>.json`.
* `audit.py` / `audit_winehost.py`: when the helper is present, check the Mach-O is thin arm64,
  bundle identifier and executable name, signed entitlements equal the expected set, the profile
  decodes with `security cms -D`, names team `NP94WB3P75`, App ID
  `NP94WB3P75.fr.gcqd.winehost`, carries the cross-architecture key, is unexpired, that its
  certificates are unexpired and that the signing certificate is one the profile names.
* Tests (all run from `Packaging/`, registered in `build.py`): `check_winehost.py`,
  `check_audit_winehost.py` (synthetic CMS profile and a throwaway certificate; the real profile
  is not used), and the extended `check_signing_policy.py`. Swift: `SpawnCommandTests.swift`.

## Signing policy

| Build | winehost entitlements |
| --- | --- |
| Developer ID | `com.apple.developer.cross-architecture-support`, `com.apple.security.cs.allow-jit`, `com.apple.security.cs.disable-library-validation`, `com.apple.application-identifier = NP94WB3P75.fr.gcqd.winehost`, `com.apple.developer.team-identifier = NP94WB3P75` |
| Ad-hoc | only `allow-jit` and `disable-library-validation` |

An ad-hoc build omits the cross-architecture key, the application identifier and the team
identifier: they are restricted entitlements that only a provisioning profile authorizes, and a
process that claims one without it is killed at launch. `sign.py` prints a note saying so, and
the audit reports it. An ad-hoc helper therefore runs, but without the 4 GiB address space; the
arm64 route is only meaningful in a Developer ID build. Other ad-hoc paths still get no
entitlements, as before.

The team and bundle identifiers live in one place, `WINEHOST_TEAM` and
`WINEHOST_BUNDLE_IDENTIFIER` in `Packaging/signing_policy.py`; the scripts and tests import them.
`signing_entitlements(path, identity)` takes the signing identity (`'-'` for ad-hoc), as the
main-app policy does: for every other program an ad-hoc signature keeps only the device
entitlements, for the winehost helper it keeps the unrestricted subset above. The helper does
not carry the device entitlements (`privacy.py` lists only the loaders, starters and session
helpers); once Wine itself runs inside the helper, decide whether it must.

## How to enable it

Add a block to a recipe (nothing in the repository does this yet):

```json
"inputs": { "winehostBuild": "{project}/Build/winehost", "winehostProfile": "{home}/<path>/winehost.provisionprofile" },
"winehost": {
  "binary": { "input": "winehostBuild", "source": "winehost" },
  "provisioningProfile": { "input": "winehostProfile" },
  "profile": "arm64-wow64",
  "fourKilobytePages": true
}
```

`profile` is optional. Without it the helper is only staged and launches stay on the Rosetta
path; with it the bundle also gets `runtime-profile.json` and the session launches Wine through
`posix_spawn` with the 4 KiB page-size request. Inputs can be overridden per build:
`--input winehostBuild=/path/to/dir --input winehostProfile=/path/to/file.provisionprofile`.

## A real signed build

```sh
python3 Packaging/build.py --recipe <recipe-with-winehost>.json --game-data import \
  --output "Build/<name>.app" --identity "<Developer ID Application identity or SHA-1>" \
  --input winehostProfile=<path>/winehost.provisionprofile \
  --input winehostBuild=<dir containing the arm64 winehost>
```

The profile is only ever copied into the app. Evidence from this branch: a throwaway arm64
executable staged with `stage_winehost` from that profile, signed with the Developer ID identity
above and the entitlement set from `signing_policy.py`, passed `audit_winehost` with no
problems; `codesign -d --entitlements` showed the five expected keys and `codesign --verify
--strict` was satisfied on the helper. The profile decodes to team `NP94WB3P75`, App ID
`NP94WB3P75.fr.gcqd.winehost`, expiry 2044-10-02.

## Notarization (not done; exact steps)

Notarization is not part of the build. After a Developer ID build that passes the audit:

```sh
ditto -c -k --sequesterRsrc --keepParent "Build/<name>.app" "Build/<name>.zip"
xcrun notarytool store-credentials "winehost-notary" --apple-id <id> --team-id NP94WB3P75   # once
xcrun notarytool submit "Build/<name>.zip" --keychain-profile "winehost-notary" --wait
xcrun notarytool log <submission-id> --keychain-profile "winehost-notary"                  # on failure
xcrun stapler staple "Build/<name>.app"
xcrun stapler validate "Build/<name>.app"
spctl --assess --type execute --verbose=4 "Build/<name>.app"
```

Rebuild the archive after stapling.

## Open items

* There is no arm64 Wine runtime yet. `runtime_inputs.py` (`verify_inputs`, `stage_runtime`,
  the sidecar and the `runtimeProfile` pins) still describes the x86_64 Wine and `x87sidecar`;
  an arm64 recipe needs its own pinned profile (the existing `pending` mechanism fits) and the
  native `winehost` Mach-O from `r3-wine-arm64`. `AppPaths.winehost` points at the helper but
  nothing launches it yet: which process is spawned (the helper, or Wine's loader inside it)
  decides which process gets the 4 KiB page size and must be the entitled one.
* The 4 KiB spawn was exercised only through unit tests with a fake setter plus a call that sets
  the attribute without spawning; no entitled process was started from Swift here.
* The Developer ID certificate that the profile names expires 2027-02-01 although the profile
  runs to 2044; the audit flags an expired certificate, so builds need a renewed certificate and
  a regenerated profile after that date.
* Notarization and stapling are unverified for a bundle containing the helper.
* `check_nfs2015_recipe.py` and `check_widescreen_compat.py` need external game and runtime
  inputs at the machine's usual locations; they fail in a relocated worktree for that reason
  alone (`check_nfs2015_recipe.py` fails the same way in the main checkout).
