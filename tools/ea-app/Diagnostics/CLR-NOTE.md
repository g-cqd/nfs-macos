# Isolated 32-bit CLR startup boundary

The owned CLR probe narrows the fresh EA installer problem to runtime activation. It does not establish an x87 arithmetic defect or explain the original 64-bit NFS process's separate `-6` exit.

## Evidence read

Astra read `ea-app-lab/Diagnostics/clr-smoke.c`, the EA owner's `clr-32.log` and `clr-64.log`, and the private `msi-clr.sample`. No probe, Wine, installer, or game was launched for this source analysis. The private `clr-evidence-hashes.json` identifies those inputs.

Both probes successfully load mscoree and receive `S_OK` from `CorBindToRuntimeEx` for runtime v4. The 64-bit probe also receives `S_OK` from `ICorRuntimeHost::Start`. The 32-bit log ends at the marker immediately before `Start`; its owner reports enforcing the 25-second deadline. The probe does not load an application assembly or perform explicit floating-point calculations. Runtime initialization can still execute internal Mono code.

The installer sample contains 94 samples per long-lived thread. Its macOS main thread waits in the run loop. Several guest threads repeat the same unresolved ntdll frame. This matches the native-unwinding limitation already seen with our owned sleeping Wine control. It cannot identify a recursive loop, x87 operation, or guest lock owner. The EA owner's isolated zero-percent CPU observation is not a complete utilization interval.

## Public source boundary

In [Wine 11.18 corruntimehost.c](https://github.com/wine-mirror/wine/blob/wine-11.18/dlls/mscoree/corruntimehost.c#L594), `ICorRuntimeHost::Start` calls `RuntimeHost_GetDefaultDomain`. That function first obtains the root domain, then acquires the host lock and emits its existing `setting base_dir` trace before configuring the domain.

In [Wine 11.18 metahost.c](https://github.com/wine-mirror/wine/blob/wine-11.18/dlls/mscoree/metahost.c#L366), root-domain creation acquires `runtime_list_cs` and calls `mono_jit_init_version`. Successful binding therefore does not establish successful Mono initialization. The source leaves possible stalls before, inside, and after that call; current observations do not distinguish them.

The Wine Mono 11.3.0 release pins its [Mono submodule](https://github.com/wine-mono/wine-mono/tree/wine-mono-11.3.0/mono) to `73610cc7350b7b51dd3bde3323a8ae28eaf5f7fc`. Its [driver](https://github.com/wine-mono/mono/blob/73610cc7350b7b51dd3bde3323a8ae28eaf5f7fc/mono/mini/driver.c#L2888) runs `mini_init` and then enters a GC-safe state. [Domain initialization](https://github.com/wine-mono/mono/blob/73610cc7350b7b51dd3bde3323a8ae28eaf5f7fc/mono/metadata/domain.c#L503) initializes synchronization, the GC, thread attachment, and metadata before loading the core library. The version-specific code has substantial work unrelated to application arithmetic.

## Cheapest next observation

The EA owner can rerun only the owned CLR probe, followed by its 64-bit control, with these temporary process environment settings and the existing enforced 25-second deadline:

```text
WINEDEBUG=-all,+mscoree,+timestamp,+pid
MONO_LOG_LEVEL=debug
MONO_LOG_MASK=asm,gc
```

The pinned [Mono logger](https://github.com/wine-mono/mono/blob/73610cc7350b7b51dd3bde3323a8ae28eaf5f7fc/mono/utils/mono-logger.c#L41) reads those Mono environment settings and recognizes both masks. Wine installs Mono logging callbacks; [mscoree_main.c](https://github.com/wine-mirror/wine/blob/wine-11.18/dlls/mscoree/mscoree_main.c#L225) forwards their messages to its debug output. This is a proposed probe-only diagnostic, not a setting to apply to EA or NFS.

Retain at most 256 KiB privately and summarize phase names only. The useful boundaries are:

1. Entry into `corruntimehost_Start`.
2. Mono core-library assembly loading or GC messages, if emitted.
3. The `RuntimeHost_GetDefaultDomain` configuration trace, proving that root-domain initialization returned and the host lock was acquired.
4. The probe's existing Start HRESULT marker.

First verify the expected messages in the successful 64-bit control. A message establishes a reached phase; a missing message does not by itself prove the preceding lock is blocked. Pair the log with cumulative process CPU counters at entry and the deadline to distinguish sustained execution from waiting over the measured interval.

If that logging leaves the first boundary unresolved, the next narrow owned-code experiment would call the already-loaded Mono initialization export directly in a separate probe process, after binding has installed Wine's Mono hooks. It must replace the Start call for that run, never precede a second initialization in the same process. This would test Wine's wrapper/lock path against the Mono initialization call. No such probe was implemented or run here.

The installed-prefix comparison remains independent work owned by the EA agent. This CLR note is not evidence that a graphics change, x87 optimization, or Mono environment toggle fixes NFS.
