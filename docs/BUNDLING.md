# Bundle construction and operation

## Layout

```text
<Game>.app/Contents/
  MacOS/<recipe launcher>
  Helpers/<recipe session>
  Helpers/x87sidecar
  Helpers/Rosetta Request.app
  SharedSupport/Wine/
  Resources/Game/
  Resources/game-manifest.json
  Resources/runtime-provenance.json
  Resources/Defaults/
  Resources/Sources/
  Resources/Licenses/
```

Keep Wine under SharedSupport. Placing the mixed PE/Mach-O runtime under Frameworks caused code signing to treat Windows DLLs as native code bundles.

The installed app stays immutable. Its helper creates writable, hash-verified generations under `~/Library/Application Support/<game support name>/Data/Versions` (`NFSMW` or `CoD4Mac`). `Data/Current` points atomically to one complete generation. `Data/Prefix` and `Data/Saves` persist across updates. Wine sees the selected game through relative links (`C:\NFSMW` or `C:\CoD4`), while host drive mappings are restricted. NFS careers use `C:\NFSMWSaves`; CoD4 uses its persistent `players` tree. This is guest drive isolation, not App Sandbox confinement.

The helper holds a process lock and records the game PID plus kernel start time. This protects a running game even if the parent launcher exits. Stage a complete replacement before publishing it. Preserve controller profile maps and configuration files during a generation update. Save and settings edits use bounded, recoverable transactions.

## Shared packaging stages and recipes

`Packaging/build.py` runs the shared verify → assemble → sign → audit → archive pipeline.
`Packaging/assemble.py` composes input verification, runtime staging, game inventory,
compatibility/default resources, corresponding sources, and app metadata. `package.py`
remains the low-level entry point. Both games use these same stages.

`Packaging/Recipes/{nfsmw,cod4,nfs2015}.json` declare the app identity, Swift
launcher/session products, runtime profile, input roots, original file/directory allowlists,
executable hashes, compatibility resources and clean defaults. `editions` states which
editions a recipe can produce; `requiredRuntimeCapabilities` and a profile's `capabilities`
refuse a runtime that lacks what the game needs; `runtimeRetention` names the runtime paths a
game keeps, and `renderers` selects which backend serves each graphics API, optionally per
executable, so a measured result can change a renderer choice without changing code. A backend
measured to break a game is recorded against that game and refused in both the recipe and the
manifest, scoped to that game's own executable so another program in the same prefix may still
use it. Before staging, the packager measures the runtime rather than trusting the profile:
every selected backend must exist in it, and a recipe needing the trap-flag gate must find its
switches in the built ntdll.
A recipe with `referencesInstallation` packages no game bytes and no inventory at all: it
declares recognition and launch rules instead, which are copied into `game-manifest.json`.
See [Need for Speed (2015)](NFS2015-RECIPE.md) for that contract and its open questions. `Packaging/runtime-inputs.json`
pins the source revisions and tested runtime artifacts. A recipe selects resources;
it does not claim that an arbitrary game works with Wine.

The current inputs are retained local artifacts:

| Input | Default |
|---|---|
| NFS original assets | `~/Games/NFSMW` |
| NFS cursor-corrected Wine, compatibility assets, notices and dependency sources | `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Shared/Shared - Games/Most Wanted Bundled.app` (preserved v5) |
| CoD4 original assets / working Wine base | `~/Games/CoD4` / `~/Games/CoD4-tools/wine` |
| Tested latest mtld3d overlay | `~/Games/renderer-pins-20261002/retained-overlay/wine/lib/wine` |
| Renderer source evidence | `~/Games/renderer-pins-20261002/source-sha256.json` |
| Latest sidecar / corresponding forks | `~/Developer/x87sidecar/build/bin/x87sidecar`, `~/Developer/{mtld3d,x87sidecar}` |

The mtld3d inputs apply only to the Direct3D 9 recipes. That divergence is resolved: the
renderer was rebuilt at `b22073b` and all four pins moved together, which is the only way
they may move. The revision pin, `rendererSourceManifestSHA256` and `rendererFiles` describe
one built renderer, so bumping the revision alone would claim provenance the staged binaries
do not have. `~/Games/renderer-pins-20261002` is that build: `build-command.txt` records the
exact recipe, `source-sha256.json` the 631 files tracked at the revision, and
`artifacts-sha256.json` the seven pinned binaries. The build is `PROD=1 PERF=0`, so the perf
telemetry is compiled out rather than silenced at runtime; `docs/UPSTREAMS.md` explains why
that matters. `nfs2015` is unaffected because it declares no mtld3d input.

These are assembly inputs, never runtime dependencies on the destination Mac. The
packager uses APFS clones, keeps source installations unchanged, and rejects artifact
hash mismatches or a dirty/unpinned source checkout. All 631 renderer source hashes
match the pinned mtld3d revision. The two Wine bases have identical code sections
in their outer loader, server and Unix ntdll and identical i386 ntdll runtime contents;
NFS retains its separate cursor-corrected inner loader.

The retained app is the **v5** build, and it is the only acceptable source of the
`nfsmw-cursor` Wine: the pinned hashes are the artifacts as they were *before* signing, and
the v6 app in `~/Desktop/Game Builds` carries the same Wine re-signed, so every one of those
five hashes differs there and `verify_inputs` rejects it. v5 now lives in iCloud Drive under
`Shared - Games`, not on the Desktop. Keep it materialised locally; an evicted copy makes the
build stall on download rather than fail.

Override a relocated input with `--input NAME=/absolute/path`. The declared names are
in each recipe. For example, `--input baseApp=/archive/Most\ Wanted\ Bundled.app` changes
the retained source/notices input; also override `runtime` if that app supplies the
Wine base. No source path is inferred from a user's existing Wine prefix.

NFS copies its existing hash-pinned compatibility files from v5, including the patched
WidescreenFix and fixed simulation rate. CoD4 copies only declared original SP/MP assets
and clean defaults; no player files, keys, logs, or shader caches enter the bundle.
Import builds keep the complete per-file inventory and compatibility files while
omitting original game bytes. See [CoD4](COD4.md) for its payload and first-run contract.

## Add a game recipe

1. Add a recipe JSON with a unique `gameID`, bundle identifier, app name, and existing
   launcher/session executable targets. Use `--recipe /path/game.json` while developing it.
2. Declare input roots with `{home}`, `{games}`, `{tools}` or `{project}` placeholders.
   List original files and directory suffix filters explicitly. An empty suffix list
   selects all files in that directory. Linked files, traversal paths, duplicate or
   overlapping selections and payloads above 20 GiB are rejected.
3. Pin supported executables and select a verified runtime profile. A new runtime
   profile belongs in `runtime-inputs.json` with corresponding source/license inputs;
   changing an artifact requires new pins and compatibility evidence.
4. Declare compatibility resources and clean defaults separately. `path` is the
   destination relative to `Game` or `Defaults`; `input` and `source` identify the
   original. An optional `sha256` pins a compatibility resource. Original executables
   and assets are never patched by the generic stage.
5. Supply the launcher's game adapter for preparation, settings, persistent files and
   arguments. Recipes do not replace game-specific runtime behavior. Any new binary
   transform must be an explicit, tested adapter, like the retained NFS compatibility
   workflow, rather than a universal game patch.
6. Run the focused `Packaging/check_*.py` gates and the normal build pipeline, then test
   the relocated app. `compatibilityFiles` in the manifest defines the import payload;
   `gameDataIncluded`, `supportsSP` and `supportsMP` describe package contents, not online
   service availability or successful gameplay verification.

## Import-only recipes

A recipe may declare `"editions": ["import"]` and an `importRules` block instead of an original-file
inventory and executable hashes (`Packaging/Recipes/farcry2.json`). The packager then needs no game
input: the manifest carries the rules and the compatibility files, and the session recognises and
hashes the player's installation at import time. `build.py` and `assemble.py` refuse a bundled edition
for such a recipe, and a recipe may offer a bundled edition only if it pins executable hashes. See
[Far Cry 2](FARCRY2.md) for the rules, the player-data layout and what is still unverified.

## Rosetta setup

Both editions check Intel execution before preparing or launching Wine. If Rosetta is absent, the Play screen offers **Install Rosetta…** and **Refresh**. Installation opens an Intel-only helper through Launch Services so macOS presents its own installation request. The starter checks again after the request and whenever it becomes active. Cancelling or failing the installation keeps Play disabled and leaves the setup retryable. An external installation is detected by Refresh; no app restart is required.

The helper exits immediately when Rosetta is available. It contains no game data and requests no administrator privileges itself. Tests cover unavailable/available states, external installation, cancellation, failure/retry, and gating Wine. This development Mac already has Rosetta; the actual first-install system dialog still requires verification on a Mac without it.

## Developer ID signing

Pass `--identity` with a valid **Developer ID Application** name or fingerprint to `build.py` or `sign.py`. The default remains ad-hoc signing. Distribution signing uses hardened runtime and secure timestamps, signs nested helpers and apps before the outer bundle, and regenerates runtime hashes after signing.

Only the two Wine executables receive `allow-unsigned-executable-memory` and `disable-library-validation`. Wine must map executable Windows modules without Apple signatures. Without the second exception, the signed build repeatedly faults on denied PE executable mappings during wineboot; the same direct startup completes with the exception. The native starter, session helper and x87sidecar retain library validation and receive no entitlement exceptions. No `get-task-allow`, debugger, or executable-page-protection exception is used.

Notarization uses a Keychain profile, never a password in source or build arguments:

```sh
xcrun notarytool submit "Build/Most Wanted Import.zip" --keychain-profile nfs-macos --wait
xcrun stapler staple "Build/Most Wanted Import.app"
xcrun stapler validate "Build/Most Wanted Import.app"
spctl --assess --type execute --verbose=2 "Build/Most Wanted Import.app"
```

Recreate the ZIP and regenerate SHA-256 after stapling using the shared archive stage:

```sh
python3 Packaging/app_archive.py "Build/Most Wanted Import.app" "Build/Most Wanted Import.zip"
```

Use a new output path, or remove only the superseded ZIP before recreating it. The
stage verifies every entry's CRC before publishing, preserves executable permissions
and internal links, and supports ZIP64 for bundles above 4 GiB. Signatures and stapled
tickets remain in the archived files; Finder metadata and ACLs are not copied. The
signing stage clears extended attributes before signing. A regression fixture forces
ZIP64 and verifies extraction with macOS `ditto`. This avoids the invalid central
directory offsets observed when `ditto` created the large CoD4 release ZIP.
Check Apple's submission result before labeling a build notarized.

## Import your game data

In the starter, open Play and select **Import game data**. Choose an installed Most Wanted (2005) PC 1.3 folder containing `speed.exe`. The current compatibility build accepts the exact asset hashes in its manifest; unsupported executables or modified assets produce an explicit error. ISO images and installer archives must be installed/extracted into a compatible game folder first.

The app copies only required original assets from that folder and uses its own compatibility files. Your source folder and careers remain unchanged. The imported copy remains active on later launches; an app update verifies its original assets again and updates the bundled compatibility files.

## Build either variant

Use Python 3.11 or newer. Both commands run the tests, release build, formatter, packaging regressions, signing, dependency/hash audit, ZIP verification, and SHA-256 generation:

```sh
python3 Packaging/build.py --game nfsmw --game-data bundled --output "Build/Most Wanted Bundled.app"
python3 Packaging/build.py --game nfsmw --game-data import --output "Build/Most Wanted Import.app"
```

| Mode | Included | First use |
|---|---|---|
| `bundled` | Whole game, Wine, mtld3d, x87sidecar, launcher, compatibility files, notices and sources | Prepare the player folder and play |
| `import` | Same runtime, launcher and fixes; no original game assets | Select **Import game data…** and choose the supported PC installation |

Each command creates the `.app`, adjacent `.zip`, and `.zip.sha256`. Add `--no-archive` to retain only the audited app when disk space is limited. Use `--game cod4` for the CoD4 recipe, `--game farcry2 --game-data import` for Far Cry 2, and `--game nfs2015` for Need for Speed (2015); the last two accept `--game-data import` only. Choose an unused output name; previous builds are preserved. The low-level `package.py` accepts the same `--game`, `--recipe` and `--input` selection plus `--with-game-data` and `--without-game-data`, followed by `sign.py` and `audit.py` if running phases individually.

Both modes currently need the pinned local assembly inputs above, including the source game installation used to generate the complete import inventory. The import variant retains that inventory but omits the original payload. Builds do not include personal careers or an existing Wine prefix.

## Bundle size reduction

The release packager removes PE debug information with `llvm-strip --strip-debug` only after checking that the Wine marker, entry point, runtime section contents/addresses/flags, and non-debug data directories match. A failed comparison keeps the original file. Separate PDB/dSYM artifacts and a redundant unmodified Wine source archive are omitted; the corresponding modified Wine source remains included. Original runtime/source/debug working directories are untouched.

On the 2026-09-26 candidate, the Wine payload changed from **1,085,198,699 to 454,360,344 bytes**. Debug information was removed from **1,531 PE files**. The full signed app changed from **4,323,756,750 to 3,639,192,107 bytes**, a **684,564,643-byte (15.83%)** reduction. These measurements compare the previous app with the import-enabled candidate before final documentation refresh. All **1,411 original game files** have identical sizes and SHA-256 hashes. No rendering or frame-rate improvement is claimed from this change.

The optimizer uses existing LLVM tooling; if `llvm-strip` is absent it keeps PE debug information and reports that fact. It does not remove textures, movies, languages, cars, or tracks.

## Release procedure

1. Run Swift Testing, the WidescreenFix regression, strict concurrency/warnings-as-errors build, and formatting checks.
2. Stage a new app without overwriting the last usable app. Python 3.11+ is required for `hashlib.file_digest`; the local tool is Python 3.13.
3. Run `Packaging/sign.py`: remove development RPATHs, sign native libraries/helpers first, then sign the outer bundle. Apple runtime licenses/signatures require separate handling in the EA track; the Most Wanted bundle uses mtld3d.
4. Run `Packaging/audit.py` against the staged app. Verify game hashes, runtime pins, escaping links, external dylib references, development RPATHs, and strict nested signatures.
5. Relocate the candidate and test first run with disposable support data. Ask the user to perform game navigation and controller checks. Never use a synthetic fixture as a playable career.
6. Verify imported saves and current profile mappings. Preserve the user's newest progress before switching sessions.
7. Archive only the verified candidate with macOS metadata preserved, verify every ZIP entry, compute SHA-256, and label unresolved limits accurately.

The optimized bundled candidate audit passed 1,423 game files, 49 runtime/helper hashes and 50 Mach-O files. The import candidate passed 12 bundled compatibility files and retained all 1,423 inventory entries. The user verified the menu and car with the optimized full runtime after a real-file import. Repeat audits after any binary change. Developer ID signing is available; see VERIFICATION.md for the notarization status of delivered artifacts. Game Mode metadata is included, but actual Game Mode activation has not been verified.

## Performance builds

Use a separate renderer/runtime copy for `PERF=1 PROD=1 FP=1`. Keep its logs and counter settings out of normal launchers. Compare the same parked scene and save, recording render/output resolution, MSAA, cap, focus and elapsed windows. Report interval distributions and GPU/CPU scope. Do not infer racing performance from a main-menu cap or a single HUD sample.
