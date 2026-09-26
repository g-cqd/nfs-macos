# Bundle construction and operation

## Layout

```text
Most Wanted.app/Contents/
  MacOS/NFSMWLauncher
  Helpers/NFSMWSession
  Helpers/x87sidecar
  SharedSupport/Wine/
  Resources/Game/
  Resources/game-manifest.json
  Resources/runtime-provenance.json
  Resources/Defaults/
  Resources/Sources/
  Resources/Licenses/
```

Keep Wine under SharedSupport. Placing the mixed PE/Mach-O runtime under Frameworks caused code signing to treat Windows DLLs as native code bundles.

The installed app stays immutable. A helper creates writable, hash-verified generations under `~/Library/Application Support/NFSMW/Data/Versions`. `Data/Current` points atomically to one complete generation. `Data/Prefix` and `Data/Saves` persist across updates. Wine sees `C:\NFSMW` and `C:\NFSMWSaves` through relative links, while host drive mappings are restricted. This is guest drive isolation, not App Sandbox confinement.

The helper holds a process lock and records the game PID plus kernel start time. This protects a running game even if the parent launcher exits. Stage a complete replacement before publishing it. Preserve controller profile maps and configuration files during a generation update. Save and settings edits use bounded, recoverable transactions.

## Local assembly inputs

`Packaging/package.py` currently resolves these pinned external inputs relative to the project parent (`TOOLS`):

| Input | Local relative location |
|---|---|
| Supported game files | `../NFSMW` |
| Base runtime | `wine-nfsmw-vertex-20260926` |
| Installed production renderer | `public-sources/mtld3d-clean/.wine-isolated/sdk/lib/wine/d3d9/mtld3d` |
| Cursor-corrected Wine loader | `wine-cursor-build/loader/wine` |
| Exact conversion sidecar | `x87sidecar-nfsmw-20260926` |
| Corresponding source forks | `public-sources/{mtld3d-clean,x87sidecar,wine}` |
| Additional source recipes | `wine-build`, `NFS-XtendedInput`, `diagnostics/{cursor-source,rumble-lab,garage-edit}` |
| Dependency sources/notices | local `Evidence/wine-deps.tar.xz`, `Evidence/DependencySources`, and component license files |

These external runtime and source archives must exist before full packaging. Keep their origins and hashes in the generated provenance. The supported game executable SHA-256 is `bde12bdd158b7f861078ad4527f5a656f34c6068e4a2120f28044f92f0fa158c`.

The packager copies only the declared game folders, compatibility files, and runtime components. It strips unused renderers, developer headers, static libraries, and tools. It applies the hash-gated WidescreenFix patch, fixes simulation rate at 120, writes per-file hashes, and includes notices and corresponding modified sources. It does not copy personal saves or an existing Wine prefix.

## Import your game data

In the starter, open Play and select **Import game data**. Choose an installed Most Wanted (2005) PC 1.3 folder containing `speed.exe`. The current compatibility build accepts the exact asset hashes in its manifest; unsupported executables or modified assets produce an explicit error. ISO images and installer archives must be installed/extracted into a compatible game folder first.

The app copies only required original assets from that folder and uses its own compatibility files. Your source folder and careers remain unchanged. The imported copy remains active on later launches; an app update verifies its original assets again and updates the bundled compatibility files.

## Build either variant

Use Python 3.11 or newer. Both commands run the tests, release build, formatter, packaging regressions, signing, dependency/hash audit, ZIP verification, and SHA-256 generation:

```sh
python3 Packaging/build.py --game-data bundled --output "Build/Most Wanted Bundled.app"
python3 Packaging/build.py --game-data import --output "Build/Most Wanted Import.app"
```

| Mode | Included | First use |
|---|---|---|
| `bundled` | Whole game, Wine, mtld3d, x87sidecar, launcher, compatibility files, notices and sources | Prepare the player folder and play |
| `import` | Same runtime, launcher and fixes; no original game assets | Select **Import game data…** and choose the supported PC installation |

Each command creates the `.app`, adjacent `.zip`, and `.zip.sha256`. Choose an unused output name; previous builds are preserved. The low-level `package.py` also accepts `--with-game-data` and `--without-game-data`, followed by `sign.py` and `audit.py` if running phases individually.

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

The optimized bundled candidate audit passed 1,423 game files, 49 runtime/helper hashes and 50 Mach-O files. The import candidate passed 12 bundled compatibility files and retained all 1,423 inventory entries. The user verified the menu and car with the optimized full runtime after a real-file import. Repeat audits after any binary change. Ad-hoc signing is currently available, Developer ID notarization is not. Game Mode metadata is included, but actual Game Mode activation has not been verified.

## Performance builds

Use a separate renderer/runtime copy for `PERF=1 PROD=1 FP=1`. Keep its logs and counter settings out of normal launchers. Compare the same parked scene and save, recording render/output resolution, MSAA, cap, focus and elapsed windows. Report interval distributions and GPU/CPU scope. Do not infer racing performance from a main-menu cap or a single HUD sample.
