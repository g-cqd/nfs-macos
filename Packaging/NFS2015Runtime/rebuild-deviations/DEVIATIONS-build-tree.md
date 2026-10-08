# Build-tree deviations (wine-rebuild)
- build/tools/sfnt2fon/sfnt2fon replaced by a bash wrapper (original kept as sfnt2fon.real) that sets
  DYLD_FALLBACK_LIBRARY_PATH=<build root>/deps/lib: the host tool links freetype by the
  install name /usr/local/opt/freetype/lib/libfreetype.6.dylib, which does not exist (deps unpacked in user space).
  Build-time font tool only; no effect on shipped binaries other than that it can run.
