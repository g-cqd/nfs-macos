# Wine Rosetta write invalidation: patch and regression tests

This source-only bundle contains a Wine repair and owned-code regression probes.
It contains no runtime binary, application data, prefix, session configuration or
raw execution log. See `REPORT.md` for the measured results and remaining limits,
and `NOTICE.md` for attribution and licensing information.

## Patch

`rosetta-write-invalidation.patch` changes only `dlls/ntdll/unix/virtual.c`.
It applies to the file at commit
`f064add996bbf4819acf49f48bab263735279800` in the tested Wine 11.0 /
CrossOver 26.3-derived source tree. Its SHA-256 is
`3708674bea68744917186dcf4583edffc13bfe91795ac7e66bdd0d1d3d79b698`.
Check applicability before applying it to another revision:

```sh
git -C /path/to/wine apply --check /path/to/bundle/rosetta-write-invalidation.patch
git -C /path/to/wine apply /path/to/bundle/rosetta-write-invalidation.patch
```

Use an isolated source/build/runtime for evaluation. The repair checks current
protection region by region, preserves access permissions and modifiers, checks
both protection transitions, and reports invalidation errors without discarding
the server's written-byte count. It adds no game-specific condition or global
cache flush.

## Portable helper/caller tests

Requirements: Python 3.9 or newer and Clang with AddressSanitizer and
UndefinedBehaviorSanitizer on a POSIX host. No Wine runtime or Windows compiler
is needed for this suite.

Pass the specific baseline or patched `virtual.c` file. The runner extracts the
actual helper and `NtWriteVirtualMemory` definitions; the checked-in C harness
provides controlled NT query/protection and server-write results. It does not
replace the production algorithm with a test implementation.

```sh
python3 run-helper-tests.py /path/to/baseline/virtual.c
python3 run-helper-tests.py /path/to/patched/virtual.c
```

The original helper produces 32 checks / 29 failures and exits 1. The candidate
produces 32 checks / 0 failures and exits 0. Compiler, input or watchdog errors
exit 2. The runner compiles with warnings as errors and both sanitizers. It
prints results to standard output/error and creates no persistent logs.

Generated include files, compiler intermediates and the test executable live in
a randomly named `TemporaryDirectory` and are removed on normal or error exit.
Use `--temp-root /path/to/owned/temp-parent` to select its parent. Compiler and
test watchdogs are 60 and 15 seconds. The supplied C source is bounded to 2 MiB.

To keep baseline and candidate output for comparison, redirect output outside
this bundle. `MANIFEST.sha256` describes only the publication files, using
relative names suitable for relocation.

## Native Windows probes

The two local probe sources and the unchanged original matrix in
`../rosetta-feasibility/translation-invalidation-matrix.c` test real Wine behavior and compile as x86-64 Windows
executables using MinGW-w64 GCC. Set `PROBE_BUILD` to an owned temporary build
directory outside this bundle:

```sh
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic ../rosetta-feasibility/translation-invalidation-matrix.c -o "$PROBE_BUILD/translation-invalidation-matrix.exe"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic range-probe.c -lntdll -o "$PROBE_BUILD/range-probe.exe"
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic cross-process-probe.c -o "$PROBE_BUILD/cross-process-probe.exe"
```

Run each executable with the runtime being evaluated and a fresh, uniquely
owned `WINEPREFIX`. Use that runtime's adjacent `bin/wineserver`; the tested
Wine loader prefers it over a different `WINESERVER` environment setting.
The recorded comparisons used `WINEDEBUG=-all`, `WINEMSYNC=1`, and
`WINEDLLOVERRIDES=winemenubuilder.exe=d`. Wrap the whole fresh-prefix run with an
external watchdog; the recorded limit was 180 seconds, including Wine's initial
prefix setup. Stop and wait for that exact prefix's server before deleting the
prefix. Remove the temporary Windows build products after evaluation.

The native probes use owned processes and memory only. Event handshakes place
threads outside the modified page during writes; internal waits are bounded.
The matrix and range probes test warmed code in the controller and an owned
worker. The cross-process probe starts its own child, inherits only three owned
IPC handles, and writes through the real child-process handle. These probes do
not attach to games or inspect another application's memory.
