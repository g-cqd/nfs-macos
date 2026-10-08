# Rebuilding the Need for Speed (2015) Wine runtime

This directory is the complete description of the modified Wine that the Need for Speed
(2015) bundle ships: the exact upstream base, the four patches applied to it, the configure
flags used, and the toolchain that actually produced the delivered binaries.

**This description is of the runtime rebuilt on 2026-10-07/08** (runtime profile
`nfs2015-tf-cx11-rebuild-20261008`), built from the patched source tree at commit `1e98e299`
that `wine-nfs2015-source.tar.gz` archives. It is not bit-identical to the runtime the earlier
apps shipped; the section "The rebuild of 2026-10-07/08" says exactly how it differs.

## Upstream base

| | |
|---|---|
| Repository | `https://github.com/athei/wine` |
| Branch | `cx-26-patched` |
| Commit | `1a7b0c76` — *ntdll, win32u: Let compatdb.so set the process DPI awareness.* |
| Reported version | `wine-11.0` |

## Patches

Exported with `git format-patch 1a7b0c76..nfs2015-fix`, applied in numbered order. The commit
column is the commit the patch file was exported from (the `From` line of the file); applying
the files with `git am` onto `1a7b0c76` makes new commits with the same content, which are the
last column and the ones in the source archive:

| Patch | Exported from | In the source archive | What it does |
|---|---|---|---|
| `0001-wine-Rosetta-debug-register-state-TF-based-execution.patch` | `b69c5ca` | `074d36b` | Keeps Rosetta debug-register state across context operations and delivers execution breakpoints by emulating the trap flag |
| `0002-wine-make-the-execution-breakpoint-budgets-configura.patch` | `2400584` | `88ee74f` | Replaces a fixed five-second cap with the configurable `WINE_TF_MAX_STEPS` and `WINE_TF_MAX_NS` budgets |
| `0003-wine-decode-prefixes-on-PUSHF-POPF-in-the-execution-.patch` | `d7c4a19` | `eb40ef7` | Decodes instruction prefixes on `PUSHF`/`POPF` inside the emulator |
| `0004-tests-add-the-execution-breakpoint-regression-fixtur.patch` | `52582b2` | `1e98e29` | Adds the execution-breakpoint regression fixture |

The archived tree is `1a7b0c76` plus exactly these four commits (`1e98e299ad2900fce2ab4f103cc1f98608fc7bfa`);
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

The runtime in this app was rebuilt from the source in `wine-nfs2015-source.tar.gz` because the
build tree of the earlier apps no longer existed. What is the same and what is not:

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
  four patches with `git am`, configure with the flags above and the deviations, run
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
