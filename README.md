# Windows game bundles for macOS

Native SwiftUI starters, composable bundle recipes, compatibility patches, and reproducible setup notes for Apple Silicon.

This is an experimental project. Most Wanted (2005) can reach gameplay with corrected graphics and analog controller input. Sustained 120 FPS has not been established. The added-car workflow still has an unresolved loading crash.

## Games and verification

| Game | Runtime | Current evidence |
|---|---|---|
| Most Wanted (2005), PC 1.3 | Wine + x87sidecar + mtld3d (Direct3D 9 to Metal) | Gameplay and analog throttle verified; maximum-quality menu verified; garage additions under investigation |
| Call of Duty 4, PC 1.0 build 525 | Wine + x87sidecar + mtld3d | Prior campaign rendering verified; native settings/profile starter and bundled/import recipes added |
| Need for Speed (2015) | Separate diagnostic EA/Wine prefixes | Startup still fails; diagnostics remain paused |

The repository contains launcher code, test fixtures, patches, and build recipes. Game installations, Wine prefixes, personal saves, EA account data, and Apple runtime binaries are external inputs.

## Read the setup knowledge

- [Tuning and measured results](docs/TUNING.md)
- [Bundle layout and release procedure](docs/BUNDLING.md)
- [Call of Duty 4 configuration and profiles](docs/COD4.md)
- [EA app and NFS (2015)](docs/EA-APP.md)
- [Current work and verification gates](docs/WORK-PLAN.md)
- [Delivered build sizes, checksums and verification](docs/VERIFICATION.md)
- [Compatibility source forks](docs/UPSTREAMS.md)

## Build the native starter

The project declares Swift 6 and macOS 15. The current development toolchain is Xcode 27 beta / Swift 6.4. The complete runtime requires Apple Silicon and Rosetta.

```sh
xcrun swift test
xcrun swift build -c release -Xswiftc -warnings-as-errors
xcrun swift-format lint --strict --recursive Sources Tests
```

Packaging also requires Python 3.11 or newer and the pinned external inputs described in [Bundling](docs/BUNDLING.md). A clean source checkout alone does not contain these runtime/game inputs. Developer ID signing is available with `--identity`; see [Verification](docs/VERIFICATION.md) for delivered notarization status. Guest drive isolation is implemented; App Sandbox confinement is not enabled.

## Build the complete app or an import edition

```sh
python3 Packaging/build.py --game-data bundled --output "Build/Most Wanted Bundled.app"
python3 Packaging/build.py --game-data import --output "Build/Most Wanted Import.app"
python3 Packaging/build.py --game cod4 --game-data bundled --output "Build/Call of Duty 4 Bundled.app"
python3 Packaging/build.py --game cod4 --game-data import --output "Build/Call of Duty 4 Import.app"
```

Each command builds, tests, signs, audits, and creates a verified ZIP with a SHA-256 sidecar. Both editions offer Rosetta installation and recheck automatically when you return to the starter. Import editions ask for the complete PC installation matching the game's manifest. Recipes specify game data, compatibility files, runtime pins, defaults and native executables; shared stages handle copying, verification, signing and archives. Settings and save formats use separate game adapters. See [Bundling](docs/BUNDLING.md) for adding a game and relocating input folders.

The current size reduction preserves every original game asset: the full candidate is about 684 MB smaller (15.83%) after removing runtime debug information and a duplicate source archive.
