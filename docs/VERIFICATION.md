# macOS bundle verification — 2026-09-26

## Delivered builds

Both apps require Apple Silicon, Rosetta, and macOS 15 or newer. They are ad-hoc signed. Developer ID signing and notarization have not completed.

| Edition | App bytes | ZIP bytes | ZIP SHA-256 |
|---|---:|---:|---|
| Bundled game | 3,639,193,539 | 2,539,356,524 | `6aaf113ee24d2ac03e706ed7ad502ebd6ea6d6cb7ec4cb5f56ef1072306a1627` |
| Import game | 607,394,289 | 290,352,490 | `16acb85917e6e92677dbe21132189be0c2e6e76c549e743080280f8c8291be4b` |

All ZIP entries passed CRC verification. The bundled edition contains all game assets. The import edition contains Wine, mtld3d, x87sidecar, the starter, fixes, component notices, corresponding sources, and the pinned game inventory. Original game files and personal saves are absent from the import edition.

## Checks performed

- 70 Swift Testing tests passed across the core and UI model suites.
- Swift 6 release compilation passed with warnings as errors; strict formatting passed.
- Packaging regressions cover both variants, PE runtime preservation during debug stripping, and the WidescreenFix resolution-pattern correction.
- Both final apps passed strict nested code-signature verification and dependency/path audits: no external library dependencies, escaping symbolic links, or development RPATHs.
- Each edition has 50 Mach-O files and 49 nested runtime/helper hashes. The bundled edition verifies 1,423 game files; the import edition verifies 12 compatibility files and retains the complete 1,423-entry inventory.
- The import helper copied and verified the real compatible PC installation into a disposable player folder, initialized the optimized Wine prefix, and completed repeat preparation. An independent check verified 1,419 immutable files, excluding four editable INI/config files.
- The user confirmed the menu and car look correct in the optimized runtime using a separate copy of their career. The game exited with status 0. The authoritative career hash remained unchanged.
- Native first-use UI showed the missing-data state and disabled Play. The import button was moved above the launch summary and visually checked. The disposable player data and UI test app were then removed.

## Remaining limits

Sustained 120 FPS has not been established. The added-Porsche loading crash remains unresolved. MetalFX support is spatial scaling; native scale bypasses it. Game Mode activation and App Sandbox confinement have not been verified/enabled respectively. These bundles are experimental and have not been notarized.

NFS (2015) is a separate EA installation and is not included in these apps. Its initial launches exit before creating a window; that investigation is independent of this bundle verification.
