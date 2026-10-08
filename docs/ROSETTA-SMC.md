# The Rosetta 2 self-modifying-code defect and the Need for Speed (2015) workaround

This page is the short version of what was learned about one crash of `NFS16.exe` on Apple silicon, how
the app works around it, and where the pieces live. The long, dated account is in
[NFS2015.md](NFS2015.md) sections 24 to 28.

## The symptom

`NFS16.exe` (64-bit, protected by an anti-tamper layer) died a few seconds after its display mode change with

    wine: Unhandled page fault on write access to 85BC35850173FF31 at address 0000000001B30159

The "bad pointer" is not a corrupted data pointer. The bytes at the faulting address are `A2 31 FF 73 01 85 35 BC 85 ...`,
and in 64-bit code `A2` is `mov [moffs64], al` whose 8-byte operand is exactly `0x85BC35850173FF31`: the CPU was decoding the
second byte of an instruction that had just been built.

The page is a private 4 KiB read-write-execute page at `0x1B30000` with obfuscated code. At offset `0x146` it runs

    66 C7 05 09 00 00 00 90 F0     mov word [rip+9], 0xF090   ; stores 90 F0 at 0x158
    66 81 35 00 00 00 00 9F 52     xor word [rip+0], 0x529F   ; 0xF090 ^ 0x529F = 0xA20F -> bytes 0F A2 = CPUID

and falls through into the `CPUID` it has just made. On an x86 processor that works. Under Rosetta 2 execution resumed one byte
late, at `0x159`, so the same bytes were decoded as `A2 <moffs64>`.

## What is established

- The defect is in Rosetta 2, not in Wine: a 76-line x86-64 program that makes its next instruction with two stores
  reproduces it 2000 of 2000 times natively, with one store it never does, and the gap between the stores and the built
  instruction does not matter. The report that was prepared for Apple has the program and the controls.
- The two stores must both happen before the instruction runs. This is why the failure needs this kind of code and not
  ordinary self-modifying code with one store.
- With the workaround below on, the game ran past the point where it used to fail, with MetalFX on, on the app built from
  runtime profile `nfs2015-tf-cx11-rebuild-0010-20261008`.

## What is not established

- Why the crash was only ever seen with MetalFX on. Every fault of this signature had MetalFX on, and the rebuilt runtime was
  never seen to fault with it off; the older runtime did fault with it off (other signatures). The workaround does not depend
  on MetalFX. The reason MetalFX changes the odds is unexplained (timing is a guess).
- Whether the workaround is needed or harmful for other games, for i386 processes, or for the native arm64 Wine route
  (the workaround is x86-64 under Rosetta only).

## What the app does

- **Settings > Wine experiments**: the toggle *Rosetta self-modifying-code workaround* sets `WINE_RWX_WX_EMULATION=1` for the Wine
  session. It is **on by default** (fresh install, reset, missing or damaged file); a saved "off" is respected; the
  developer override `NFS2015_AB_WINE_RWX_WX_EMULATION=0|1` wins over the saved choice. The other three experiment
  toggles (instruction-cache flush toggle, protect toggle, page trace) are off and are labelled as not needed.
- While the workaround is on, the session also sets `WINE_RWX_WX_LOG=1B30000-1B31000`, so every report carries the history of
  that page.
- The crash report has these sections when the runtime prints the matching lines: *Crash context (wine-crash block)*,
  *RWX W^X emulation (wine-rwx lines)*, *Page trace (wine-trace lines)*, and a `wine experiment switches:` line. A log
  without such lines gives an unchanged report.

## How the workaround works (patch 0008 to 0010)

With the switch on, the runtime maps a private PAGE_EXECUTE_READWRITE page as read plus execute on the host. A store from guest
code faults; the runtime makes the page writable, runs exactly that one store under a single step, and makes the page
read plus execute again, so Rosetta translates from the stored bytes before the next instruction. Pages that Wine itself writes
to for a system call are released (made writable for good). A store costs about 60 to 80 microseconds
while a page is protected.

## The runtime lineage

All patches are on the base `athei/wine` `cx-26-patched` commit `1a7b0c76`; the patch files are in
[`Packaging/NFS2015Runtime/patches/`](../Packaging/NFS2015Runtime/patches/).

| Patch | What it changed |
| --- | --- |
| 0001 to 0004 | Rosetta debug-register state and execution-breakpoint delivery by the trap flag, configurable budgets, `PUSHF`/`POPF` prefixes, the regression fixture |
| 0005 | `kernelbase` prints a register and memory snapshot (`wine-crash:` lines) before the debugger starts, because `winedbg` cannot capture the first exception here |
| 0006 | the block gains 256-byte code windows around the instruction pointer, allocation history of the page, a checksum of the page, thread count, return addresses |
| 0007 | `WINE_ROSETTA_FLUSH_TOGGLE` and `WINE_ROSETTA_PROTECT_TOGGLE` (protection round trips after a cache flush or an executable protection change), and `WINE_TRACE_PAGE` (numeric `wine-trace:` lines). They did not help for this defect: the stores are plain stores. |
| 0008 | the workaround: `WINE_RWX_WX_EMULATION` |
| 0009 | the trap flag no longer leaks to the program (it was cleared in the wrong frame and carried by thread context captures), stores that cross two protected pages no longer loop, the busy-page limit raised |
| 0010 | a page that stores into itself is never released for being busy (`WINE_RWX_WX_NEAR_LIMIT`, 0 never), a released page is evaluated again after a protection change, faults under the trap-flag emulation are emulated (`WINE_RWX_WX_TF_RELEASE=1` restores the earlier release), per-page log `WINE_RWX_WX_LOG` |

Source of the exact trees: see [SOURCE-OFFER.md](SOURCE-OFFER.md).

## Developer environment variables

`NFS2015_AB_WINE_ROSETTA_FLUSH_TOGGLE`, `..._PROTECT_TOGGLE` and `..._RWX_WX_EMULATION` take `0` or `1`;
`NFS2015_AB_WINE_TRACE_PAGE` and `NFS2015_AB_WINE_RWX_WX_LOG` take `<hexstart>-<hexend>` (or `off`, and `all` for the log);
`NFS2015_AB_WINE_RWX_WX_HOT_LIMIT`, `..._NEAR_LIMIT` and `..._TF_RELEASE` are for developers only. The Wine variables they
set are `WINE_ROSETTA_FLUSH_TOGGLE`, `WINE_ROSETTA_PROTECT_TOGGLE`, `WINE_TRACE_PAGE`, `WINE_RWX_WX_EMULATION`,
`WINE_RWX_WX_HOT_LIMIT`, `WINE_RWX_WX_LOG`, `WINE_RWX_WX_NEAR_LIMIT` and `WINE_RWX_WX_TF_RELEASE`.

## Reading the log

- `wine-crash: ...` is the block of patches 0005 and 0006 (registers, `pc-bytes`, `vq[...]` allocation lines, `pagesum`,
  `code[...]` rows).
- `wine-rwx: active pid=<n> first page <addr>` appears once per process that uses the workaround;
  `wine-rwx: pid=<n> stores=<n> released(host=<a> carrier=<b> hot=<c>)` at its exit.
- `wine-rwx: page <addr> protect(reason=alloc|commit|protect|other) vprot=<hex>`: the page entered the emulation;
  `store #<n> rip=<hex> tid=<hex>`: the first stores; `release(reason=hot|hot-smc|host|host-kernel|cross|tf) stores=<n>`:
  it left it and why; `skipped(reason=...)`: it never entered.
- A healthy run of the page `0x1B30000` shows `protect(reason=alloc)` and stores from `nfs16` code, and no `release`.

## Open items

- EA's client update (`ClientUpdateDestaging`) is treated as a failed start by the launcher; the destager is killed before it
  applies the update. Not fixed.
- Untested: i386 processes under the workaround, the native arm64 Wine route (it handles the same code with its own
  translator), EA's own browser process over a long session.
- The cost on pages that mix code and data is bounded by the release rules but not measured on a real game other than this one.
- The minimal reproducer and its report for Apple's Feedback Assistant exist; filing it is the owner's decision.
