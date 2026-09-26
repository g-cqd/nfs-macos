# Bounded execution-breakpoint diagnostic for Wine on Rosetta

This source bundle tests whether Wine can deliver execution breakpoints through a bounded trap-flag (TF) interpreter. It preserves separate guest TF/RF state and checks execution-breakpoint addresses before instruction effects. It is an explicit diagnostic experiment; general emulation and game startup remain unverified.

## Source and provenance

`tf-emulation-v6.patch` is the frozen, independently reviewed patch. Its SHA-256 is `a919ed6b1721ab3d786ccf1c28f02277ee00a718d9e7816ec273c71dbcda7202`.

The base is a Wine 11 / CrossOver 26.3-derived source tree with an earlier Rosetta debug-register state-retention change. `source-hashes.json` identifies the exact six base and resulting source files. Reproduce those files in this order:

1. Use [g-cqd/wine revision f064add996bbf4819acf49f48bab263735279800](https://github.com/g-cqd/wine/tree/f064add996bbf4819acf49f48bab263735279800).
2. Apply the published [rosetta-debug-state-experimental.patch](https://github.com/g-cqd/nfs-macos/blob/b8ba68b4938da7bccc5e382f6880ae06f46a6c93/tools/ea-app/Diagnostics/rosetta-debug-state-experimental.patch), SHA-256 `0911cd9f04c62236c2e789e7bde41765c3f7164aa752627587f9672212ac5123`.
3. Apply the bundled `frozen-base-comment.patch`. It restores one `server/mach.c` comment to the frozen test snapshot; it changes no behavior. The published prerequisite alone matches five of the six base hashes. This normalization makes all six match exactly.
4. Verify all six `base` hashes, apply `tf-emulation-v6.patch`, then verify all six `candidate` hashes. Apply each patch with `patch -p1` from the Wine source root.

These steps were checked against the exact Git revision and all six frozen before/after files without building or running Wine. This verifies the changed source files; it does not establish clean-checkout runtime integration. Use the source tree's existing Wine configuration and build procedure. Build and install a matching private `wineserver` and Unix `ntdll.so`; do not mix them with a different source revision. No complete Wine tree, new build system, or prebuilt runtime is supplied. Stock Wine compatibility is unverified.

The patch modifies Wine's existing files without replacing their copyright/license headers. `contract-probe.c` retains the Wine test attribution for its guest-TF ordering. The patch and bundled probe/runner sources are provided under LGPL-2.1-or-later; `COPYING.LIB` preserves Wine's LGPL 2.1 license text. The relative `SHA256SUMS` covers every other bundle file.

## Diagnostic contract

`WINE_TF_EMULATION=1` enables the experiment only for translated Apple x64 clients. WOW64 retains the original debug-register route. The client and server cache the environment separately: a fresh private prefix, matching binaries, and uniform environment are required. There is no capability handshake.

The diagnostic keeps per-thread DR0–DR3/DR6/DR7 state through initial entry, suspension, syscall return, and exception continuation. It handles execution enables, RF suppression, guest TF, DR6 status, and separate BS then B0 events. Plain 64-bit PUSHFQ/POPFQ receive finite CPL3/IOPL0 handling so an internal TF does not appear as guest TF. This covers the owned fixtures below; it does not establish all x86 instruction interactions.

Recognized unsupported paths print `TFEMU STOP <reason>` and terminate the process with exit 86. These include MOV SS/LSS shadow, prefixed flag instructions, ICEBP and selected control/exception instructions, data breakpoints, GD, debugger presence at a checked boundary, unsupported privilege/mode, instruction-fetch/stack faults, and native faults while the interpreter is active. Fault stops do not reproduce normal guest fault delivery.

The default cap is 250,000 boundary/arming checks, not a precise retired-instruction count. `WINE_TF_MAX_STEPS` can lower it to an integer from 1 through 250000. A five-second elapsed budget is checked at boundaries after first activation. Neither limit can interrupt a blocked syscall or a long native instruction; an external watchdog is required.

Unproven interactions include other POPF privilege modes, 16-bit forms, nested exception breakpoint targets, debugger attachment races, REP restart, concurrent code changes, and arbitrary native fault continuation. No sustained performance or game-fix claim is made. Independent frozen v6 source/evidence review was clean; the reviewer did not execute the runtime. Rebuilt-runtime integration remains a separate unresolved gate.

## Recorded results

Owned probes ran on Apple silicon/macOS 27 with the matching private Wine-derived runtime. They compiled using MinGW GCC 16.1 with C11, `-O2 -Wall -Wextra -Werror -pedantic`. All listed runs completed without timeout or retained-output overflow.

| Gate | Snapshot and result | Bundled source |
| --- | --- | --- |
| Initial entry, disabled state, remote user/syscall suspension, RF, guest TF, PUSHFQ/POPFQ | v6: eight cases, 52/52 checks | `contract-probe.c`, `contract-fixtures.S` |
| DR6 status, flag masks, slot matches, RF/TF flag images, explicit stops | v6: 13/13 cases | `supplement-probe.c`, `supplement-fixtures.S` |
| Enabled DR7, DR6, pseudo/real self aliases, clear | v5: x64 and actual i686, mode on/off, 8/8 each | `state-details-probe.c` |
| Original TF-only probe | v6 mode on: 7/7; v5 mode on/off: 7/7 each | Shared original, omitted |
| Original context-state probe | v6 mode on: 24/24; v5 mode on/off: 24/24 each | Shared original, omitted |
| Ownership-preserving cleanup and bounded retry | 3/3 checks | `check-runner.py` |
| Bootstrap output overflow rejects further cases | Portable runner: 1/1 mocked regression, verified red then green | `check-runner.py` |

The only runtime change from v5 to v6 rejects ICEBP before execution in the opt-in decoder. The v5 controls are reported as v5 runs. The eight expected-stop supplements require exit 86 and the exact diagnostic reason. The original state-only baseline failed seven delivery cases and passed the disabled control: 24 of 52 assertions failed, including consequences of missing events, while fixture workers returned normally.

## Reproduce the bundled probes

Requirements: macOS with APFS cloning, Python 3.9 or newer, the existing Wine runtime layout (`bin/wine`, `bin/wineserver`, `lib/wine/x86_64-unix/ntdll.so`, `lib/wine/x86_64-windows/ntdll.dll`), and `x86_64-w64-mingw32-gcc` on `PATH`. The WOW64 control also needs `i686-w64-mingw32-gcc` and a runtime supporting 32-bit Windows clients.

Run from a writable copy of this bundle. In these commands, `./Runtime` is your matching private runtime. Use a separate label for each result set.

```sh
shasum -a 256 -c SHA256SUMS
PYTHONDONTWRITEBYTECODE=1 python3 check-runner.py
python3 run-contract.py --runtime ./Runtime --emulation --label delivery
python3 run-contract.py --runtime ./Runtime --emulation --label supplements \
  --supplement sticky-dr6 --supplement flag-mask --supplement slot-matches \
  --supplement push-rf --supplement push-guest-tf --supplement mov-ss \
  --supplement flag16 --supplement icebp --supplement push-fault \
  --supplement pop-fault --supplement nx-flag --supplement budget --supplement elapsed
python3 run-contract.py --runtime ./Runtime --state-details --emulation --label state-on
python3 run-contract.py --runtime ./Runtime --state-details --label state-off
python3 run-contract.py --runtime ./Runtime --state-details --wow64 --emulation --label wow-on
python3 run-contract.py --runtime ./Runtime --state-details --wow64 --label wow-off
```

`--case` selects one or more delivery cases; `--help` lists them. Omitting `--emulation` gives the ordinary-mode control; delivery cases that require the missing capability are expected to fail on the state-only runtime. The runner compiles only the included fixtures, creates a uniquely named owned runtime/prefix beneath `~/Library/Caches`, and stops only that prefix's server before removing it. An ownership mismatch or failed server wait preserves the directory and reports failure.

Each case has a 15-second watchdog; prefix initialization has 120 seconds. Retained output is limited to selected probe/diagnostic lines of at most 4,096 bytes and 64 KiB per invocation. The runner writes labeled JSON and filtered probe logs beside itself, plus an ownership journal with a random session basename. Timeouts, output overflow, failed assertions, or an unexpected stop return failure. These generated results are local artifacts and are not part of this source publication.

The portable runner removes the original runner's selectors for the two omitted shared probes, locates MinGW on `PATH`, and omits absolute source/runtime paths from result metadata. It also rejects retained-output overflow during bootstrap. Its syntax, CLI, three cleanup checks, and mocked bootstrap regression were validated separately; the extraction did not rerun Wine.
