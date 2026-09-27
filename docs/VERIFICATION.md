# macOS bundle verification

## Runtime refresh and CoD4 release — 2026-09-27

Current candidates are in `~/Desktop/Game Builds`: Most Wanted Bundled, Most Wanted Import,
Call of Duty 4 Bundled, and Call of Duty 4 Import. They require Apple Silicon, Rosetta,
and macOS 15 or newer. This release is separate from the retained version 5 apps below.

- Renderer source: `5f5331a2d8762356bd49d128271c1b186c31e7ec`.
- x87sidecar source: `dbd680d4cbe14afa12774d53670a18758f15110e`.
- Shared recipe assembly supports both games and both data editions. No personal save,
  product key, EA account state, or existing Wine prefix is distributed.
- Swift 6 release compilation with warnings as errors, strict formatting, the complete
  pre-push test gate, and eight packaging checks passed.
- Both Most Wanted editions completed fresh private-prefix setup. The import edition
  verified and copied the original installation. Original game files remained unchanged.
- Both CoD4 editions completed setup; profile import preserved every Gigi file byte.
  The user's first campaign launch exposed Wine's working-directory fallback to
  `C:\windows`. The archives were intact. A temporary private game-only `G:` mapping
  made the exact bundled Wine resolve `main\iw_00.iwd`; the helper now creates and
  removes that mapping around play. Two focused regression tests pass. User gameplay
  verification of this correction is pending. The corrected live process opened both
  `iw_00.iwd` and `iw_01.iwd` and loaded the bundled renderer; this does not by itself
  establish working gameplay.
- Each initial candidate passed Developer ID signing and dependency/path audit:
  50 Mach-O files, 49 nested runtime/helper hashes, and no external libraries, escaping
  payload links, or development RPATHs. Both corrected CoD4 candidates also passed
  signing, source-archive comparison, and strict signature verification after relocation.
- Apple notarization for this release is in progress: Most Wanted bundled submission
  `76f398a5-1de5-4789-86fd-fe01a5b740dc` and import submission
  `1f968688-5f95-4d0c-912f-4840502d3c1f`. Neither has a rejection. CoD4 submission
  awaits the campaign check. The accepted version 5 submissions below do not
  establish notarization of these new candidates.

Spatial MetalFX remains the shipping implementation. Native scale bypasses upscaling.
Temporal upscaling and frame interpolation are explicitly outside this release; the
[feasibility report](METALFX-ROADMAP.md) records the actual M1 capability probe.
CoD4 campaign gameplay in the new bundle and controller support remain unverified.
No new sustained frame-rate or latency claim is made. Guest drive isolation does not
provide App Sandbox confinement. NFS (2015) debugging remains paused.

## Previous delivery — 2026-09-26

## Delivered builds

Both apps require Apple Silicon, Rosetta, and macOS 15 or newer. Version 5 of both editions is Developer ID signed, notarized by Apple, stapled, and accepted by Gatekeeper. Both starters check Rosetta before invoking Wine and offer installation and refresh controls.

| Edition | App bytes | ZIP bytes | ZIP SHA-256 |
|---|---:|---:|---|
| Bundled game | 3,640,219,339 | 2,539,663,454 | `37600d6a0035f7bc5813ec451089e72d39f9ce6e82f285dea063cef42b1d894c` |
| Import game | 608,420,080 | 290,659,332 | `e8e909e26da9d5c88ffbcbd57f7e208c97ca1ef2f5346ed8ebdb4d0b8962fbd4` |

Apple accepted submission `c4575725-db82-4b64-8fed-728c5af15fd5` for the bundled edition and `e892bab8-8a74-45f4-ad15-b20d5fa73669` for the import edition. The final app and ZIP pairs are on the Desktop. All ZIP entries passed CRC verification. The bundled edition contains all game assets. The import edition contains Wine, mtld3d, x87sidecar, the starter, fixes, component notices, corresponding sources, and the pinned game inventory. Original game files and personal saves are absent from the import edition.

## Checks performed

- 75 Swift Testing tests (56 core and 19 UI model tests) passed across the core and UI model suites.
- Swift 6 release compilation passed with warnings as errors; strict formatting passed.
- Packaging regressions cover both variants, PE runtime preservation during debug stripping, the WidescreenFix resolution-pattern correction, and the distribution signing policy.
- Both final apps passed strict nested code-signature verification and dependency/path audits: no external library dependencies, escaping symbolic links, or development RPATHs.
- Each edition has 51 Mach-O files and 50 nested runtime/helper hashes. The bundled edition verifies 1,423 game files; the import edition verifies 12 compatibility files and retains the complete 1,423-entry inventory.
- The import helper copied and verified the real compatible PC installation into a disposable player folder, initialized the optimized Wine prefix, and completed repeat preparation. An independent check verified 1,419 immutable files, excluding four editable INI/config files.
- The user confirmed the menu and car look correct in the optimized runtime using a separate career copy; that earlier test exited with status 0. The later Developer ID signed runtime also passed fresh import and prefix setup, and the user confirmed the menu and car. After the user quit that signed test, the helper returned status 15. The authoritative career hash remained unchanged.
- All Mach-O files use the hardened runtime. Only the two Wine loaders receive unsigned executable memory and library validation exceptions, required for translated Windows execution. The native starter and Rosetta helper have neither exception.
- The Intel-only Rosetta helper opens and exits on this Mac, where Rosetta is installed. The installation dialog on a Mac without Rosetta has not been tested.
- Native first-use UI showed the missing-data state and disabled Play. The import button was moved above the launch summary and visually checked. The disposable player data and UI test app were then removed.

## Remaining limits

Sustained 120 FPS has not been established. The added-Porsche loading crash remains unresolved. MetalFX support is spatial scaling; native scale bypasses it. Game Mode activation and App Sandbox confinement have not been verified/enabled respectively. These bundles remain experimental despite passing notarization. The scoped Wine entitlements do not provide App Sandbox confinement.

NFS (2015) is a separate EA installation and is not included in these apps. Its initial launches exit before creating a window; that investigation is independent of this bundle verification.
