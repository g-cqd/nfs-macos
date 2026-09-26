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

## Release procedure

1. Run Swift Testing, the WidescreenFix regression, strict concurrency/warnings-as-errors build, and formatting checks.
2. Stage a new app without overwriting the last usable app. Python 3.11+ is required for `hashlib.file_digest`; the local tool is Python 3.13.
3. Run `Packaging/sign.py`: remove development RPATHs, sign native libraries/helpers first, then sign the outer bundle. Apple runtime licenses/signatures require separate handling in the EA track; the Most Wanted bundle uses mtld3d.
4. Run `Packaging/audit.py` against the staged app. Verify game hashes, runtime pins, escaping links, external dylib references, development RPATHs, and strict nested signatures.
5. Relocate the candidate and test first run with disposable support data. Ask the user to perform game navigation and controller checks. Never use a synthetic fixture as a playable career.
6. Verify imported saves and current profile mappings. Preserve the user's newest progress before switching sessions.
7. Archive only the verified candidate with macOS metadata preserved, verify every ZIP entry, compute SHA-256, and label unresolved limits accurately.

Previous bundle audits passed 1,423 game files, 51 runtime/helper hashes and 52 Mach-O files. Those results apply to those builds only; repeat after any binary change. Ad-hoc signing is currently available, Developer ID notarization is not. Game Mode metadata is included, but actual Game Mode activation has not been verified.

## Performance builds

Use a separate renderer/runtime copy for `PERF=1 PROD=1 FP=1`. Keep its logs and counter settings out of normal launchers. Compare the same parked scene and save, recording render/output resolution, MSAA, cap, focus and elapsed windows. Report interval distributions and GPU/CPU scope. Do not infer racing performance from a main-menu cap or a single HUD sample.
