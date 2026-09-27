# Compatibility source forks

| Component | Fork branch | Pinned revision |
|---|---|---|
| mtld3d | [g-cqd/mtld3d: development](https://github.com/g-cqd/mtld3d/tree/development) | `5f5331a2d8762356bd49d128271c1b186c31e7ec` |
| x87sidecar | [g-cqd/x87sidecar: development](https://github.com/g-cqd/x87sidecar/tree/development) | `dbd680d4cbe14afa12774d53670a18758f15110e` |
| NFS Wine | [g-cqd/wine: nfsmw-macos](https://github.com/g-cqd/wine/tree/nfsmw-macos) | `f064add996bbf4819acf49f48bab263735279800` (CX26.3 / Wine11.0, cursor recovery) |
| WidescreenFixesPack | [ThirteenAG/WidescreenFixesPack](https://github.com/ThirteenAG/WidescreenFixesPack) | Reference `e9550ff793a50744b6569f3cace8ca551680b861`; retained NFS compatibility patch |

Both development forks were clean and matched `origin/development` after fetching on
2026-09-27. No reset, rebase or source-tree build was needed for this package refresh.

The retained CoD4 production renderer was originally recorded as `b5cc720` plus a dirty
diff. Every one of its 535 recorded source hashes matches the now-committed mtld3d
revision above. Its exact i386 Windows DLLs and x86_64 Unix bridge passed 923 tests,
with zero failures and 11 benchmark tests ignored. It was built with `PROD=1 PERF=1`;
normal app launches disable performance logging. These tests establish renderer
correctness coverage, not a new game performance measurement.

The flat arm64 x87sidecar artifact is byte-identical in the working CoD4 installation
and the fork's build directory: SHA-256
`4ff36ccd907c5f11f399233d04c7e8318c18a08f6751beab8323120400446be0`.
The pinned head adds documentation after the native allocator changes at `961db88`.
This is the tested existing artifact; no new sidecar build or performance claim is
implied. The cooperative Wine handshake uses `ROSETTA_X87_PATH`; the entitled
attachment helper is not bundled.

`Packaging/runtime-inputs.json` records exact input hashes. Signing and safe removal
of debug information can change packaged hashes; the final `runtime-files.json` is
generated after signing. Corresponding fork archives, retained Wine/dependency sources
and component notices accompany each app. The current renderer needs macOS15 and
matching i386 PE / x86_64 Unix components under the bundled x86_64 Wine.

Fetch future source updates without resetting users' working trees. Stage candidate
artifacts separately, retain the previous app, verify the required compatibility gates,
and update pins only with evidence. A source update alone is not evidence of improved
frame rate. The retained CoD4 result and its limits are summarized in [CoD4](COD4.md).
