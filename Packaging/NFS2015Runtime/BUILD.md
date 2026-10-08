# Rebuilding the Need for Speed (2015) Wine runtime

This directory is the complete description of the modified Wine that the Need for Speed
(2015) bundle ships: the exact upstream base, the nine patches applied to it, the configure
flags used, and the toolchain that actually produced the delivered binaries.

**This description is of the runtime rebuilt on 2026-10-07/08, with patches 0005 to 0009** (runtime profile
`nfs2015-tf-cx11-rebuild-0009-20261008`), built from the patched source tree at commit `b5ac45cf`
that `wine-nfs2015-source-0009.tar.gz` archives. The same runtime without patches 0005 to 0009 (profile
`nfs2015-tf-cx11-rebuild-20261008`, tree `1e98e299`) differs in three files: both `kernelbase.dll` and
`lib/wine/x86_64-unix/ntdll.so`; the profile of patch 0008 (`nfs2015-tf-cx11-rebuild-0008-20261008`) differs from this one in `ntdll.so` only.
It is not bit-identical to the runtime the earlier apps shipped; the section "The rebuild of 2026-10-07/08" says exactly how it differs.

## Upstream base

| | |
|---|---|
| Repository | `https://github.com/athei/wine` |
| Branch | `cx-26-patched` |
| Commit | `1a7b0c76` — *ntdll, win32u: Let compatdb.so set the process DPI awareness.* |
| Reported version | `wine-11.0` |

## Patches

Patches 0001 to 0004 were exported with `git format-patch 1a7b0c76..nfs2015-fix` and patches 0005 to 0009 each from its own commit, applied in numbered order. The commit
column is the commit the patch file was exported from (the `From` line of the file); applying
the files with `git am` onto `1a7b0c76` makes new commits with the same content, which are the
last column and the ones in the source archive:

| Patch | Exported from | In the source archive | What it does |
|---|---|---|---|
| `0001-wine-Rosetta-debug-register-state-TF-based-execution.patch` | `b69c5ca` | `074d36b` | Keeps Rosetta debug-register state across context operations and delivers execution breakpoints by emulating the trap flag |
| `0002-wine-make-the-execution-breakpoint-budgets-configura.patch` | `2400584` | `88ee74f` | Replaces a fixed five-second cap with the configurable `WINE_TF_MAX_STEPS` and `WINE_TF_MAX_NS` budgets |
| `0003-wine-decode-prefixes-on-PUSHF-POPF-in-the-execution-.patch` | `d7c4a19` | `eb40ef7` | Decodes instruction prefixes on `PUSHF`/`POPF` inside the emulator |
| `0004-tests-add-the-execution-breakpoint-regression-fixtur.patch` | `52582b2` | `1e98e29` | Adds the execution-breakpoint regression fixture |
| `0005-kernelbase-crash-context-snapshot.patch` | `ed16a3c` | `ce7b8ea` | Prints a `wine-crash:` block (registers, bytes at the program counter, page state and module of the program counter and the fault address, eight stack words, trap-flag emulation counters) from `UnhandledExceptionFilter` before the debugger starts; adds compile-time checks of the three TEB offsets it reads. Changes the two `kernelbase.dll` files and no other binary |
| `0006-kernelbase-crash-context-code-windows-and-page-history.patch` | `473ffab` | `473ffab` | Extends the `wine-crash:` block: `NtQueryVirtualMemory` of the page of the program counter and its two neighbours, an FNV-1a checksum and zero-group count of that page, the thread count and TEB, up to six return-address candidates as `module+offset`, 512 bytes of code around the program counter and 128 bytes around up to three registers that point within 4 KiB of it, and the registers that point near it. Changes both `kernelbase.dll` files only |
| `0007-ntdll-rosetta-exec-page-toggles-and-page-trace.patch` | `c2afb95` | `c2afb95` | Three environment switches, all off unless set: `WINE_ROSETTA_FLUSH_TOGGLE=1` (after `NtFlushInstructionCache`, round-trip the protection of the executable regions of the range), `WINE_ROSETTA_PROTECT_TOGGLE=1` (the same after `NtProtectVirtualMemory` gives execute) and `WINE_TRACE_PAGE=<hexstart>-<hexend>` (a numeric `wine-trace:` line on standard error for each allocate, free, protect, write, flush, map and unmap call that touches the window, with the caller's return address). Changes `lib/wine/x86_64-unix/ntdll.so` only; also adds the probe `tests/nfs2015/exec-page-stale.c` |
| `0008-ntdll-rwx-wx-emulation-for-rosetta-late-resume.patch` | `dae832f` | `dae832f` | With `WINE_RWX_WX_EMULATION=1` (off by default, x86-64 Wine under Rosetta only) private committed `PAGE_EXECUTE_READWRITE` pages are mapped read-execute on the host; a store faults, the page is opened for exactly one instruction with the trap flag and closed again by the single-step trap, so Rosetta retranslates between the stores. Works around Rosetta resuming one byte late after code built by two stores right ahead of the instruction pointer (the game's fault at `0x1B30159`). Pages written by host code or by the kernel, pages written more than `WINE_RWX_WX_HOT_LIMIT` (default 300) times within 100 ms, and every fault while the trap-flag emulation is active are released instead. Prints `wine-rwx:` lines. Changes `lib/wine/x86_64-unix/ntdll.so` only (`signal_x86_64.c`, `virtual.c`) |
| `0009-ntdll-wx-emulation-trap-flag-leak-and-straddling-stores.patch` | `b5ac45c` | `b5ac45c` | Fixes four faults of the emulation of patch 0008: Rosetta takes the single-step trap while the thread is still in the signal-return trampoline, and 0008 cleared the trap flag in the trampoline's frame instead of the program's, so the program resumed with the trap flag set and took a stray `EXCEPTION_SINGLE_STEP` (seen in the EA client's `libcef`); a thread context captured while a store window was open (SuspendThread, Get/SetThreadContext) carried the trap flag; a store that straddles two protected pages could never complete (a fault on a second page now releases the open page); and the busy-page limit released a page that was merely being filled before its code ran (the default is now 4096 stores per second, `WINE_RWX_WX_HOT_LIMIT` still overrides, 0 never). Changes `lib/wine/x86_64-unix/ntdll.so` only |

The archived tree is `1a7b0c76` plus exactly these nine commits (`b5ac45cf36e57d12cd916b6ef9ad57945d8e7f63`);
the content of each commit equals its patch file, apart from the `From` hash line and the
`git` version trailer that `git format-patch` writes.

Why they are needed: the game arms an x86 hardware execution breakpoint (`Dr0`, `Dr7`) on a
worker thread and waits for `#DB`, and wineserver refuses debug registers for translated
processes. See [the synthesis document](../../docs/NFS2015.md) for the evidence chain and the
caveats.

To reproduce:

```sh
git clone https://github.com/athei/wine wine-src && cd wine-src
git checkout 1a7b0c76
git am /path/to/Packaging/NFS2015Runtime/patches/*.patch
```

## Configure flags

```sh
arch -x86_64 "$WINE_SRC/configure" \
  --enable-archs=i386,x86_64 \
  --with-coreaudio --with-gnutls --with-mingw --with-opencl --with-sdl --with-unwind \
  --without-alsa --without-capi --without-cups --without-dbus --without-ffmpeg \
  --without-fontconfig --without-gettext --without-gphoto --without-gssapi \
  --without-gstreamer --without-hwloc --without-inotify --without-krb5 --without-netapi \
  --without-oss --without-pcap --without-pcsclite --without-pulse --without-sane \
  --without-udev --without-usb --without-v4l2 --without-vulkan --without-wayland --without-x \
  CC="clang -arch x86_64" CROSSCC="clang -arch x86_64" \
  --host=x86_64-apple-darwin \
  PKG_CONFIG_PATH="$DEPS_PREFIX/lib/pkgconfig" \
  CFLAGS="-I$DEPS_PREFIX/include" LDFLAGS="-L$DEPS_PREFIX/lib"
```

`--without-vulkan` is deliberate: this title is served by the Metal-backed `dxmt` Direct3D 11
backend, so no Vulkan, MoltenVK or DXVK component is built or shipped.

The build script also rewrites `SONAME_LIBFREETYPE`, `SONAME_LIBGNUTLS` and `SONAME_LIBSDL2`
in `include/config.h` so the bundle can relocate through `@loader_path`.

## Toolchain note, which is a known gap

The upstream build script selects llvm-mingw at `/opt/llvm-mingw` for the PE builtins. **The
delivered binaries were not built with it.** `lib/wine/x86_64-windows/ntdll.dll` and
`lib/wine/i386-windows/ntdll.dll` in the shipped runtime report `GCC: (GNU) 16.1.0`, which is
Homebrew's mingw-w64 GCC, so the PE side was produced by a different compiler from the one CI
uses. The Mach-O binaries (`wine`, `wineserver`, `ntdll.so` and the other unix libraries) were
built with Apple clang 21.0.0 from Xcode, with a macOS deployment target of 15.0.

This is verified by reading the delivered binary, not inferred. The consequence is that this
runtime's PE builtins are not bit-for-bit comparable with a CI build, and any future bug that
looks compiler-dependent should be re-checked against an llvm-mingw build before being
reported upstream.

## The rebuild of 2026-10-07/08

The runtime in this app was rebuilt from the source in `wine-nfs2015-source-0009.tar.gz` because the
build tree of the earlier apps no longer existed. What is the same and what is not:

- **Patch 0009** (2026-10-08, after owner tests of the apps with patch 0008) changes `lib/wine/x86_64-unix/ntdll.so` again (`8f593e28…9d35` to `610ecca6…0bfe`); every other file is byte-identical to the runtime of patch 0008 (the build session's manifest and this build's own sha256 of both trees agree).
- **Patch 0008** (2026-10-08, after the Rosetta defect behind the fault was reproduced without Wine) changes `lib/wine/x86_64-unix/ntdll.so` again (`b1bddee4…0de4` to `8f593e28…9d35`); every other file is byte-identical to the runtime of patch 0007 (the build session's manifest and this build's own sha256 of both trees agree). Its switch does nothing unless the environment sets it.
- **Patches 0006 and 0007** (2026-10-08, after the first capture of the game's fault): 0006 changes both `kernelbase.dll` again (`14e82c52…56e5` to `ec494aca…2f66`, `09ce21ff…289c2c` to `15c1001c…b4a3`), 0007 changes `lib/wine/x86_64-unix/ntdll.so` (`82cf3d48…7689` to `b1bddee4…0de4`); every other file is byte-identical to the runtime of patch 0005 (the build session's manifest and this build's own sha256 of both trees agree). The switches of 0007 do nothing unless the environment sets them.
- **Patch 0005** changes `lib/wine/x86_64-windows/kernelbase.dll` (`4cdca0f5…39b6` to `14e82c52…56e5`) and `lib/wine/i386-windows/kernelbase.dll` (`c1efceb5…1a726` to `09ce21ff…289c2c`); `ntdll.so` is unchanged because the patch adds only compile-time offset checks to `signal_x86_64.c`. The other 1790 files are byte-identical to the rebuild without it (the build session's manifest).
- **Same as the runtime of the earlier apps:** `bin/wine` (`03985ed9…0ff360`) and
  `lib/wine/x86_64-unix/wine` (`86283fa8…5a1f`) are byte-identical, which indicates that the
  configure flags, deployment target and linker settings are close to the original.
- **Different:** `bin/wineserver` (`11a0d304…0529`, earlier `e4aacddb…d8bc`),
  `lib/wine/x86_64-unix/ntdll.so` (`82cf3d48…7689`, earlier `171e363d…5270`) and
  `lib/wine/i386-windows/ntdll.dll` (`10b33abc…6978`, earlier `e64165eb…d86`). The PE
  `ntdll.dll` embeds the absolute path of the source folder and a link time, so it cannot match a
  build made in another folder at another time. The cause for the two Mach-O files is **not
  isolated**; the candidates are a different Apple clang build (the Xcode on the build Mac
  changed during the work), a different SDK, or source content that differs from the earlier
  build. Both carry the same `WINE_TF_*` strings and pass the fixture below.
- **Checked:** `wine --version` is `wine-11.0`; a throwaway prefix runs `cmd /c ver` and
  `reg query`; the compatibility library selects `dxmt` for a test program; the execution-breakpoint
  fixture (`tests/nfs2015/exec-breakpoint-prefix.c`, built with GCC 16.1.0) reports 2 failures
  with `WINE_TF_EMULATION` unset and 0 failures in 4 of 4 runs with `WINE_TF_EMULATION=1
  WINE_TF_MAX_STEPS=0 WINE_TF_MAX_NS=0`. Nothing was run through the game or the EA client by
  the build.
- **Deviations from the upstream scripts**, each recorded in `rebuild-deviations/` (the build
  folder's path is replaced there by `<build root>`):
  1. The `athei/wine-build` scripts at revision `0813ba8` were used (the last revision with the
     macOS 15 floor). The revision of the original build is not recorded anywhere; this is an
     inference.
  2. llvm-mingw is not installed, so its presence gates were removed and the PE side was built by
     Homebrew mingw-w64 GCC 16.1.0 for both architectures. The ARM64X link library tree was not
     built; it is not part of any runtime.
  3. `make -j4` instead of one job per core.
  4. The dependency tarball (`deps-2026-09-06`, SHA-256
     `e88f2070e305b29a21cad490cb243bd4e40cbefb570505c9fefc2bc2b1877c6e`) was unpacked in user space,
     not in `/usr/local`; `PKG_CONFIG_SYSROOT_DIR` and `-I`/`-L` flags point at it and the bundle
     script resolves `/usr/local/...` library references into it. The host font tool `sfnt2fon`
     needed a wrapper that sets `DYLD_FALLBACK_LIBRARY_PATH` for the same reason.
  5. Apple's Game Porting Toolkit was neither fetched nor installed, so the runtime has no
     `gptk` tree and no D3DMetal; this game does not use them.
  6. Only the runtime layout was bundled (no headers or `d3d9` test programs); Wine Mono is not
     part of the runtime and is installed by the app from its own pinned installer.
  7. The compatibility library (`compatdb.so`) was built with the official Rust 1.97.1 toolchain,
     not necessarily the original's.
- **Rebuild recipe:** fetch `athei/wine` at `1a7b0c766262276e7e7bb50c80abe5ccd08e292b`, apply the
  nine patches with `git am`, configure with the flags above and the deviations, run
  `make`, then the bundle script of `athei/wine-build` with `--runtime-only`.

## Third-party runtime components

These are fetched by the build's `redist.env` rather than built from the Wine tree, and each
is pinned by SHA-256 there:

| Component | Version | Source | Used by |
|---|---|---|---|
| dxmt | v0.80 | `3Shain/dxmt`, release asset `dxmt-v0.80-builtin.tar.gz` | The Direct3D 11 backend that serves both `NFS16.exe` and `EADesktop.exe` |
| Apple D3DMetal (Game Porting Toolkit) | 4.0 beta 2 | Apple, mirrored as a release asset because Apple's download needs an Apple ID session | The `gptk` backend; **not selected and not shipped by this recipe** |
| mtld3d | v0.7.0 | `athei/mtld3d` | Direct3D 9; **not used by this title** and not retained in this bundle |

Only dxmt is retained in the bundle. See [NOTICE.md](NOTICE.md) for the licence position.
