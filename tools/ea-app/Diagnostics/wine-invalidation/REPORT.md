# Verified behavior and limits

The patch repairs reproduced Wine write-invalidation defects on Apple Silicon
under Rosetta. It has not been established as a repair for NFS 2015's startup
exit. No game was launched by these probes.

A separate EA integration trial did not reach the full NFS process with either
this candidate or an identically rebuilt unpatched Unix ntdll. The original
runtime did reach NFS, which repeated its earlier `-6` exit. The failed handoff
does not isolate this patch; rebuilt-runtime integration remains unresolved.
See the [launch evidence](../README.md#matching-unpatched-rebuild-control).
The original runtime was restored after those comparisons.

The tested stack was macOS 27.0 with a custom Wine 11.0 / CrossOver 26.3-derived
runtime. The changed translation unit and all probe sources compiled with
warnings as errors. No native Windows control or full Wine conformance suite
was run.

## Results

| Suite | Original helper | Candidate |
| --- | --- | --- |
| Original execution matrix | 4 cases, 1 failure | 4 cases, 0 failures |
| Native range probe | 14 checks, 3 failures | 14 checks, 0 failures |
| Controlled helper/caller tests | 32 checks, 29 failures | 32 checks, 0 failures |
| Native cross-process probe | 5 checks, 1 failure, 0 infrastructure errors | 5 checks, 0 failures, 0 infrastructure errors |

All completed native runs finished without an external watchdog timeout.
The controlled tests passed AddressSanitizer and UndefinedBehaviorSanitizer
with the candidate. An unpatched `ntdll.so` rebuilt with the same private
compiler flags and object set reproduced the original matrix and range
failures. Rebuilding alone did not account for the candidate result.

### Stale executable translation

For memory allocated RW and later changed to RWX, successful
`WriteProcessMemory` and `FlushInstructionCache` calls changed the physical
instruction byte from 1 to 2. The original runtime still returned 1 when both
warmed threads executed the function. The candidate returned 2. Controls using
RW-to-RX, RWX-to-RWX, or an explicit RW/RWX transition already returned 2.

### Mixed current protections

For a range originally allocated RWX but currently split into RWX and RW
regions, the original helper changed the second region from RW to RWX.
The candidate preserved each region's current protection. Other tested mixed
RW/RWX and RWX/RX ranges preserved their permissions but executed stale code on
the original helper; the candidate executed the updated code.

### Cross-process APC path

An owned child allocated RW memory, changed it to RWX, warmed a function 1,000
times, and parked outside the page. The parent wrote through its real
`CreateProcess` handle and flushed that same process. Both runtimes reported
TRUE / one byte written / TRUE for write, count and flush. The child's byte
readback was 2 and its allocation/current protection remained RW/RWX in both
runs. The original child executed 1; the candidate child executed 2.

Wine's existing `NtProtectVirtualMemory` selects its process APC branch for
that real child handle. This extends coverage beyond self-process handles.
The patch was unchanged for this comparison.

## Failure semantics and boundaries

- The helper uses current protection across the server-confirmed written range.
  Zero-length writes do nothing. It rejects overflow and nonadvancing query
  boundaries and checks both protection changes.
- If invalidation fails after a successful server write, the call returns that
  error while retaining the server's byte count. If the server already returned
  a write failure, that status remains primary. No write rollback is claimed.
- A failed restoration can leave the affected region nonexecutable. The error
  is reported; the helper does not claim the original state was restored.
- Callers must coordinate execution, mapping changes and protection changes.
  Query/remove/restore is not atomic. The tests use a stable layout and park
  threads outside the affected pages; they do not validate concurrent execution
  or remapping.
- Cross-process coverage is one parked child, one page and one successful byte
  write. It does not validate remote multiple-region or error-recovery cases.
- Controlled NT API tests cover query/removal/restoration failures, all four
  execute protection classes and modifier bits, partial-write status/count,
  range edges and malformed queries. These are deterministic API-model tests;
  they do not claim real macOS protection failures were induced.
- A direct guest store followed only by `FlushInstructionCache` does not use
  this helper and remains outside the repair.
- Existing server code can underreport bytes if restoring host permissions
  fails after a write. The existing RX branch of `WriteProcessMemory` also
  ignores its own final restore result. Those separate paths were not repaired.

The region walk uses constant auxiliary space and work proportional to the
number of queried regions. No runtime-performance claim is made.

## Identifiers

| Artifact | SHA-256 |
| --- | --- |
| Patch | `3708674bea68744917186dcf4583edffc13bfe91795ac7e66bdd0d1d3d79b698` |
| Original `virtual.c` | `1c160c713825d92333540c6fd8d88d629fdff3a086b74ec635bf13a6397bf10c` |
| Patched `virtual.c` | `c0287a604e2ea1abde3124690f1fb30015c4286e86b8d99840eccbd6bbb9c880` |
| Tested original `ntdll.so` | `3bc4baa14ae578036896e1cee462871e52a3815a7624bc35ed8292a5bc7508ba` |
| Tested rebuilt original `ntdll.so` | `88981bce904cc0236b0e69fa86196f1d541a061381dd2fed79600dabf7067125` |
| Tested candidate `ntdll.so` | `67b2eb1e04c0a8166d8c5e92a3c0dee58f9e4cb456002fee6d4c7f86c44fe8ba` |

These binary hashes identify the compared builds; binaries and raw logs are
deliberately not included in this publication bundle. `MANIFEST.sha256` lists
the current publication source files separately.
