# Launcher settings and save tools

Requested 2026-09-26: settings-first SwiftUI starter, extensive individual graphics controls, separate granular Cheats menu, save import/backups, Xbox/PlayStation layouts and action mapping. Apply the configuration before Play. Preserve analog triggers and drift compensation.

## Constraints

Swift 6, macOS 15, existing helper owns the process lock. No external dependencies. All game/config/save mutations require that lock and a clear game lease. Never modify the user's career merely by opening settings or pressing Play. Keep the previous signed preview until its replacement passes verification. Personal saves remain outside shared artifacts.

## Phase 1: configuration and controller mappings

Write failing tests for validated ranges, INI and Wine registry updates, retained unrelated settings, analog bindings, profile-specific mappings and transaction rollback. Build a typed catalog from the shipped renderer and input plugin sources. Persist preferences and apply all files as a recoverable transaction before launch. Expose resolution, presentation, MetalFX scale, individual game quality settings, shadows, effects, camera and controller controls. No automatic game start on opening the app.

## Phase 2: save tools and cheats

Write save-format tests before native Swift implementations; compare checksums and edited copies with the independent existing Python validator. Validate file size, checksums, native car numbering and referenced records. Implement profile selection, import/export, backups/restore, exact cash operations and individual garage/performance edits. Require explicit edit actions; reject stale snapshots and running games. Back up before every save replacement. Trace finer availability controls rather than representing the global unlock byte as several independent toggles.

## Phase 3: integration and delivery

Test helper request/response handling, concurrent app exclusion, invalid input and recovery. Build warnings-as-errors, run Swift Testing and formatting, inspect the native UI and verify a disposable game/config/save round trip. Rebuild, sign, audit and archive the app. Report actual MetalFX behavior and hardware/controller tests without claiming unmeasured FPS or untested Xbox hardware behavior.

## Evidence and open work

The existing build supports MetalFX spatial scaling when render/output dimensions differ; render.scale defaults to 1 and RetinaMode to N. No DLSS or ray tracing integration is present. The global unlock plugin writes game byte 0x926124. Per-category availability has not been verified. The previous physical DualShock analog and rumble tests passed; Xbox hardware has not been tested on this Mac.

## Phase 4: player tasks and isolation

Review the UI against Apple HIG and research on progressive disclosure, recognition and recovery. Start on a Play overview. Keep common display/quality choices concise; disclose detailed graphics and mappings on demand. Keep career context visible and explicit save edits separate from next-launch settings. Test derived summaries and filtered control groups.

Audit bundled dependencies and Wine drive, home, temporary and network access. Test App Sandbox inheritance in a disposable bundle before deciding production entitlements. Removing guest drive mappings is configuration isolation, not an OS security boundary. Do not describe this application as fully secure. Opt in to macOS Game Mode through documented bundle metadata; verify activation separately from metadata.

## Phase 5: public source forks

The user authorized public repositories under g-cqd for patched tools. Publish the renderer, x87 sidecar and Wine source changes on reviewable branches based on their pinned upstream revisions. Preserve upstream licenses. Exclude game payloads, extracted shaders, personal saves, binaries, prefixes and diagnostic captures. Verify staged diffs and remote commit identities. Publish native launcher source after the new bundle behavior passes verification.

## Phase 6: garage catalog, profile lifecycle, and upstream refresh

Add stock cars selected by model to a selected career with independent bounded records. Verify stock initialization against game-generated data; reject unknown signatures and over-capacity changes. Fresh profiles use a game-generated clean template with a validated new name. Removal backs up first and keeps a restore entry. All requests keep the helper lock and stale-save checks. Test each behavior before implementing it, then load disposable profiles in the game.

Rebase mtld3d onto the current upstream on a separate candidate branch. Keep the existing public patch branch and installed renderer until the upstream candidate passes its required gates and game verification. Assemble the new app with corrected analog trigger defaults, latest launcher changes, and a verified renderer; personal saves stay in the user data folder.

## Current verification and remaining gates

- The user wants to perform all in-game navigation. Give short manual tests; do not inject keys or interrupt a running career.
- The user confirmed analog throttle and graphics in a real race at 2560×1600, 8192 shadows, MSAA off and light streaks off. The 120 FPS cap is configured; sustained 120 FPS is not verified.
- mtld3d candidate `nfsmw-upstream-update` is based on upstream `1b0bf1f` and published at `251360250aa3713f27ac9447d51da52c0cdfdc2a`. Its required build/check/test gates passed: 1557 Windows-host tests, 642 Unix-host tests, and 881 passed/11 ignored/zero failed per Wine architecture.
- Fresh career creation loaded and started the opening race in a disposable profile. The packaged template contains no personal progress.
- Maximum quality detects display modes, selects full resolution/fullscreen and highest scene settings. A startup conflict remains under game verification: Rendering.ixx removes a store inside Resolution.ixx's search pattern when light streaks are enabled. The pinned plugin patch preserves the resolution target by matching its first three unchanged stores. The offline regression proves the old pattern fails and the new pattern still finds the same unique target. Packaging applies this patch; it has not yet been tested in the game.
- Added cars initially had empty installed visual parts. Structural/checksum tests missed this and an added Porsche crashed. A new regression fails on the missing stock base/body/wheel handles. `Evidence/StockCapture` contains a bounded diagnostic for exporting stock parts using the game's own initialization routines; only the disposable GarageTestPlayer has this diagnostic. Complete native capture, implement stock records, and ask the user to test an added car before delivery.
- Importing over a removed profile incorrectly supplied an empty stale fingerprint. The launcher now sends no fingerprint for backup-only entries; the failing-first UI model regression passes.
- The assembled preview3 app and `.pending.zip` are provisional. Refresh the binaries, source archives, signatures, manifests, audit and archive after these gates pass. Preserve the current Gigi save after the user quits. Do not distribute the pending archive as a verified build.
