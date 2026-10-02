# macOS address-ceiling diagnostic

The original EA-lab Wine passed the completed narrow/wide/narrow comparison.
This probe did not reproduce an allocation failure caused by enlarging the
permitted address range. No runtime or game change was made.

## Probe contract

`address-ceiling-probe.c` calls `NtAllocateVirtualMemoryEx` in its own process.
Each call requests one 64 KiB reservation with `MEM_RESERVE | MEM_TOP_DOWN` and
`PAGE_NOACCESS`. The probe never commits, accesses, or executes the reservation.
It immediately calls `NtFreeVirtualMemory` after every successful reservation.

The three calls use the same lower bound, `0x700000000000`:

| Call | Highest permitted address, inclusive |
| --- | --- |
| Narrow before | `0x7000001fffff` |
| Wide | `0x7ffffffeffff` |
| Narrow after | `0x7000001fffff` |

The narrow calls establish that the process can allocate within a subset of the
wide range. A failed control makes the comparison inconclusive. The program
checks returned bounds, alignment, size, and release status. It prints native
status codes and addresses from its own allocations only.

Both native exports must exist. The reported maximum application address must
permit the wide range, and the reported allocation units must support a 64 KiB
reservation. Setup or cleanup failures return `2`. A failed comparison with
valid controls returns `1`. A completed passing comparison returns `0`.

The executable takes no arguments. It uses no game offsets, account files,
other-process handles, registry changes, polling loops, or timing assertions.
There are three allocation attempts and at most one live reservation. Native
API calls require an external watchdog if the runtime hangs.

## Build

```sh
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  -o address-ceiling-probe.exe address-ceiling-probe.c
```

The build completed without warnings or errors. The executable is a Windows
x86-64 PE. Its SHA-256 for the final baseline run was
`884fe60edc8cf8ab852a86d736dac329bb21dc4b34ee7737d160bd0ceb078667`.

## Results on 2026-09-26

The runner used
`~/Games/NFSMW-tools/ea-app-lab/Wine/bin/wine` and its adjacent server.
The final run used a freshly created prefix within this diagnostic's private
session directory. The external watchdog was 45 seconds. The output limit was
128 KiB, and the diagnostic stream retained only allocation metadata and virtual
memory errors. The watchdog did not fire.

| Call | Allocation NTSTATUS | Returned address | Release NTSTATUS |
| --- | --- | --- | --- |
| Narrow before | `00000000` | `00007000001f0000` | `00000000` |
| Wide | `00000000` | `00007ff001da0000` | `00000000` |
| Narrow after | `00000000` | `00007000001f0000` | `00000000` |

Local `baseline-low-control.log` records three cases, zero
failures, zero infrastructure errors, valid controls, and exit code zero. Wine
reported its inferred host limit as `0x7fffffff0000`. The wide allocation still
succeeded below that limit. This result does not establish NFS compatibility.

### Initial control-range attempt

The initial probe used a lower bound of `0x7ffffc000000` and a narrow upper bound
of `0x7ffffdffffff`. All three allocations returned `STATUS_NO_MEMORY`
(`0xc0000017`), so both controls failed and the program returned `2`.
Local `baseline.log` and Local `baseline-virtual.log`
retain that inconclusive result.

The diagnostic trace showed the wide request attempting
`0x7ffffffe0000` through `0x7fffffff0000` and receiving a host allocation error.
The narrower window also had no usable slot. The final source moved the narrow
control to a lower, available window while preserving the three-call comparison.
These observations do not prove that the address-ceiling bug causes game startup
failure. No address-limit patch was applied.

## Prefix ownership and cleanup

Both prefixes used during this investigation were stopped and removed:

- `prefix-baseline`
- `session-zm93n7xc/prefix-i2j62gon`

Local `cleanup.log` records the paths. The final run's server stop and
wait commands both returned zero. The first run's stop command returned one;
its subsequent wait returned zero. A later diagnostic stop and wait both
returned zero before that prefix was removed.

Future runs must use `tempfile.mkdtemp` to create a private session directory
under this diagnostic, record an ownership marker there, and create a unique
prefix inside it with `tempfile.mkdtemp`. Set `WINEPREFIX` to that exact directory.
Use the original runtime's matching `wine` and `wineserver`. Keep the external
watchdog and bounded output, stop and wait for that prefix's server in cleanup,
validate the marker and parent directory, and remove only that owned prefix.
Do not use the EA prefix. The retained session marker contains no account data.

## Source basis

Wine's [macOS host address-space limit correction](https://github.com/wine-mirror/wine/commit/8ad60112690b0171bcd6e07f1d604ba70f7ac003)
changes the ceiling to `0x7ffffe000000`. The current runtime source still uses
the earlier inference algorithm. In `dlls/ntdll/unix/virtual.c`, `map_view`
bounds allocations with that ceiling, and `try_map_free_area` stops searching
one gap when the host error is not `EEXIST`. Other gaps or reserved areas can
still satisfy the allocation.

Microsoft documents the supported address-range restrictions in
[MEM_ADDRESS_REQUIREMENTS](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-mem_address_requirements)
and the reservation semantics in
[VirtualAlloc2](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualalloc2).
The probe calls the underlying native allocation function to retain NTSTATUS.

Local logs, generated binaries, and prefixes are not included in this source repository.
