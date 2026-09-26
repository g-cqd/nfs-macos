# Argument-free x64 Wine relay diagnostic

This diagnostic records export names, numeric return values, caller addresses,
and Wine timestamps/process/thread IDs. Its x64 relay entry never formats
arguments or follows string pointers. It preserves the argument count used by
the existing call thunk. `MetaCall` and `MetaRet` distinguish this build from
ordinary relay output.

## Verified synthetic control

`relay-probe.c` calls `CompareStringOrdinal` with a fake private marker and a
lowercase copy. A nonzero fifth argument must produce equality; zero must
produce a case-sensitive difference. `MulDiv` checks another returned result.
Both baseline and candidate returned exit 0 with
`comparison=2 case_sensitive=1 arithmetic=3`.

The baseline trace contained the fake marker. The candidate trace contained
neither case of it and emitted the expected metadata tags. This establishes
this synthetic privacy and calling-convention control, not complete ABI
coverage or a game compatibility fix.

Build the probe with:

```sh
x86_64-w64-mingw32-gcc -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  -o relay-probe.exe relay-probe.c
```

## Runtime construction

`metadata-relay.patch` applies to `dlls/ntdll/relay.c` at g-cqd/wine commit
`f064add996bbf4819acf49f48bab263735279800`. Build the
`dlls/ntdll/x86_64-windows/ntdll.dll` target from a configured matching Wine tree.
The verified build used Homebrew Bison 3.8.2 first on PATH; Apple's older Bison
rejected the existing resource grammar. The resource grammar reports five
pre-existing shift/reduce conflicts. The C compilation reported no warnings.

The diagnostic PE SHA-256 is
`1a8b2c3dd66348431077f3e2ad3f8aec46cc71e2fde7498b04f299a92806d653`.
It was installed only into a separate runtime clone. That clone also retains
the previously tested server register-state correction; its Unix ntdll and
renderers remain unchanged. The original installed PE SHA-256 remains
`506b6d16c4e2af9f8f45433ff6e5bdaff02bad1cf24d017ffd57496c50ce2f4d`.

## Capture limits

Enable relay only for the x64 NFS executable. Other architectures retain
ordinary Wine argument logging. Pipe output directly through
`collect-api-tail.py`; never persist a raw game/EA relay stream. The collector
accepts only these tags and independently observed NFS process IDs. Its memory
ring is limited to 8 MiB and its persisted tail to 1 MiB. Ordinary loader relay
messages are rejected.

The marker control ran in an owned probe prefix with no EA account or game.
For new runs, allocate a uniquely named private directory (for example with
`tempfile.mkdtemp`), put the prefix inside it, and remove it only after its
matching wineserver has stopped. Never reuse a collaborator’s prefix.
Generated binaries, prefixes, and raw logs stay outside source control.
This trace has overhead and must not be used as a performance measurement.
