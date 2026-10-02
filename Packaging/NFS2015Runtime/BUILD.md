# Rebuilding the Need for Speed (2015) Wine runtime

This directory is the complete description of the modified Wine that the Need for Speed
(2015) bundle ships: the exact upstream base, the four patches applied to it, the configure
flags used, and the toolchain that actually produced the delivered binaries.

## Upstream base

| | |
|---|---|
| Repository | `https://github.com/athei/wine` |
| Branch | `cx-26-patched` |
| Commit | `1a7b0c76` — *ntdll, win32u: Let compatdb.so set the process DPI awareness.* |
| Reported version | `wine-11.0` |

## Patches

Exported with `git format-patch 1a7b0c76..nfs2015-fix`, applied in numbered order:

| Patch | Commit | What it does |
|---|---|---|
| `0001-wine-Rosetta-debug-register-state-TF-based-execution.patch` | `b69c5ca` | Keeps Rosetta debug-register state across context operations and delivers execution breakpoints by emulating the trap flag |
| `0002-wine-make-the-execution-breakpoint-budgets-configura.patch` | `2400584` | Replaces a fixed five-second cap with the configurable `WINE_TF_MAX_STEPS` and `WINE_TF_MAX_NS` budgets |
| `0003-wine-decode-prefixes-on-PUSHF-POPF-in-the-execution-.patch` | `d7c4a19` | Decodes instruction prefixes on `PUSHF`/`POPF` inside the emulator |
| `0004-tests-add-the-execution-breakpoint-regression-fixtur.patch` | `52582b2` | Adds the execution-breakpoint regression fixture |

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

The build script selects llvm-mingw at `/opt/llvm-mingw` for the PE builtins. **The delivered
binaries were not built with it.** `lib/wine/x86_64-windows/ntdll.dll` in the shipped runtime
reports `GCC: (GNU) 16.1.0`, which is Homebrew's mingw-w64 GCC, so the PE side was produced by
a different compiler from the one CI uses.

This is verified by reading the delivered binary, not inferred. It was a deliberate decision
not to rebuild for it, so the runtime that was actually tested is the one that ships. The
consequence is that this runtime's PE builtins are not bit-for-bit comparable with a CI build,
and any future bug that looks compiler-dependent should be re-checked against an llvm-mingw
build before being reported upstream.

## Third-party runtime components

These are fetched by the build's `redist.env` rather than built from the Wine tree, and each
is pinned by SHA-256 there:

| Component | Version | Source | Used by |
|---|---|---|---|
| dxmt | v0.80 | `3Shain/dxmt`, release asset `dxmt-v0.80-builtin.tar.gz` | The Direct3D 11 backend that serves `NFS16.exe` |
| Apple D3DMetal (Game Porting Toolkit) | 4.0 beta 2 | Apple, mirrored as a release asset because Apple's download needs an Apple ID session | The `gptk` backend that serves `EADesktop.exe` |
| mtld3d | v0.7.0 | `athei/mtld3d` | Direct3D 9; **not used by this title** and not retained in this bundle |

See [NOTICE.md](NOTICE.md) for the licence position, including the unresolved question about
redistributing Apple's framework.
