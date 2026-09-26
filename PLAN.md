# Portable NFSMW app

The user prioritized a shareable macOS app on 2026-09-26. Task mode: implement the existing bundle plan in three verifiable phases. Performance research is on hold while this work proceeds.

## Detected constraints

- New directory, no enclosing Git repository, CI, branch convention or existing Swift project.
- Swift 6 language mode, complete concurrency checking; macOS 15 deployment target, matching Wine and mtld3d. Build toolchain: Xcode 27 beta / Swift 6.4.
- Apple Silicon initially; friend hardware question pending. Rosetta is a system prerequisite.
- Native Foundation, SwiftUI, CryptoKit and Darwin APIs; no external Swift dependencies.
- Native session helper owns the process lock and game lifetime. Closing the launcher must not terminate a save write.
- Preserve the existing live game, original installation, and private save. Never include personal saves in the shared archive.
- No performance claim: the configured cap is 120 FPS; sustained 120 FPS racing remains unachieved.

## 1. Freeze and stage the runtime

Inventory game files and essential plugins; omit logs, caches, backups and development tools. Retain the tested renderer and cursor/rumble/x87 fixes. Audit Mach-O dependencies and symlinks. Include component licenses and modified source provenance. Record hashes in a manifest. Verify the source executable before packaging.

The mixed Wine tree belongs in Contents/SharedSupport/Wine. A signing trial under Frameworks failed because macOS treated the Windows PE DLLs as unsigned native nested code. Native Mach-O files are signed individually before the outer bundle seals the mixed resources.

## 2. Build the native launcher

Write failing Swift Testing cases for relocation, environment isolation, failed initialization, save preservation, update isolation and duplicate sessions. Implement a synchronous session helper for disk/process work and a responsive native launcher. Store a private prefix, writable game generations and saves in Application Support. Construct process arguments without a shell. Initialize beside the destination and publish only after setup succeeds. Use a process advisory file lock rather than an in-memory lock because separate app copies must coordinate.

## 3. Validate and archive

Build with warnings as errors. Test first and repeat launch, failure recovery, preserved saves and moved/renamed bundle paths. Check no bundle writes or development-path runtime dependencies. Sign nested code and the app, verify signatures, and create a shareable archive with concise installation notes. Record actual signing/notarization status and hardware test coverage.

## Gates

Unit/integration tests: Swift Testing. Formatter: Xcode swift-format. Real game smoke test uses a disposable Application Support root and occurs when it will not interrupt the existing player. Source files should keep one main type and remain below 250 lines where practical. No commits are required for this new non-repository directory.

## Verification status

18 Swift tests pass with warnings treated as errors, including failed initialization, failed updates, unchanged saves, duplicate sessions, helper-exit protection with PID reuse checks, malformed paths, and shell-free argument handling. Release build and swift-format lint pass. The process information wrapper uses the macOS 10.5+ proc_pidinfo API with a bounded nonescaping struct borrow; its real-process and invalid-PID tests pass.

The app and all native code are ad-hoc signed. Signing and a moved-app Wine executable check pass. Full game startup, new-profile controls, GUI lifecycle and real-user save migration remain unverified until the open private session ends. This is a preview, not a completed portability qualification.

Suggested future gates: CI should run `swift test -Xswiftc -warnings-as-errors`, release builds and the artifact audit; build-time strict Swift 6 checking and swift-format should remain enabled. Runtime validation rejects unsafe manifests and incomplete generations. A game benchmark needs a repeatable scene and a quiet Mac before becoming a performance regression gate.

Archive completed: `/Users/gc/Desktop/NFSMW-macOS-preview.zip` (2,744,586,356 bytes). ZIP integrity verification passed for all 7,294 entries. The final relocated artifact audit and binary deployment-target checks passed. Full first game launch remains pending while the existing session is running.

## Preview build 2

The update regression now verifies per-profile controller maps as well as the career and graphics settings. It failed because the original update copied only three settings files. GameInstaller now carries `scripts/XtendedInputMaps` into the prepared generation, retaining the old copy until publication succeeds. All 18 tests pass. Rebuild and re-sign the helper and launcher, audit the staged artifact, then replace the public archive only after its ZIP integrity check passes. The full-game smoke test remains pending while the existing session runs.
