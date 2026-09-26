# Astra NFS 2015 startup profiling, 2026-09-27

NFS 2015 still exits before opening a game window on the original Wine runtime. The new resource measurements establish substantial CPU activity during startup. They do not identify the reason for the game's `-6` exit or demonstrate an x87 fault.

## Scope and provenance

Astra performed the resource collection and sample analysis. The EA setup agent exclusively launched the legitimate installed game, observed its Windows process lifecycle, and stopped successors. No game files, EA configuration, runtime libraries, or account data were changed by this profiling task. The original signed-in EA process remained running.

Host: Apple M1, macOS 27.0 build 26A5388g. Runtime: original `ea-app-lab/Wine`, reporting Wine 11.0, with D3DMetal 4.0b2. The private evidence manifest records the actual Wine, server, and ntdll hashes. Other workers were not controlled throughout; these runs are diagnostic observations, not comparative performance benchmarks.

## Measured results

| Run | Coverage | CPU and memory | Outcome |
| --- | --- | --- | --- |
| First, native PID 43745 | Resource observations at process age 19–28 seconds; active endpoints 9.005 seconds apart | 7.98 CPU seconds between endpoints; RSS 260.81–387.35 MiB | Full Windows process `07c4` exited `-6` after 27,969 ms of lifecycle observation. |
| Second, native PID 49563 | Collector started 0.363 seconds after the sample report's process launch time; active endpoints 39.999 seconds apart | 29.36 CPU seconds between endpoints; observed peak RSS 409.97 MiB | Full Windows process `08b4` exited `-6` after 40,728 ms of lifecycle observation. |

CPU time is the difference between cumulative process CPU counters, not the smoothed `ps %cpu` value. The respective ratios are approximately 88.6% and 73.4% of one CPU core over the stated intervals. RSS is sampled once per second; the observed maximum is not a guaranteed lifetime peak. A zero-RSS disappearance record was excluded from the first interval. Different coverage and uncontrolled concurrent work prevent interpreting the two durations as a speed comparison.

The first sampler was canceled by collector cleanup when its target exited, 11.044 seconds after collection began. It produced no callgraph. Its output did not confirm completed sampling. That is a collection failure, not evidence that NFS cannot be sampled.

An owned Windows console control then waited in `Sleep` under the original Wine in a fresh, marked prefix. A requested three-second sample at ten-millisecond intervals completed in 10.291 seconds including processing, with 278 samples per thread. Its Wine server stopped and its private prefix was removed.

The second collector was armed before EA launched NFS. It waited for the bootstrap's `100010` exit and identified the full process using both the exact executable name and its mapped game file. This excludes the wineserver, which also holds the file open. The sampler was allowed to finish within a 30-second deadline even if the target exited.

The second native sample completed successfully. Its report timestamp is 1.259 seconds after its recorded process launch. It contains 268 samples for each long-lived thread over the requested three-second interval. The host main thread shows AppKit initialization and run-loop waits. The guest thread has repeated Wine dispatcher frames and unresolved Rosetta/JIT frames. The owned sleeping control also has repeated dispatcher frames, so those repeated frames do not establish actual recursion or a hot Wine function. No defensible guest-function or x87 bottleneck can be extracted from this unwind.

No D3DMetal callframe appeared in that short early sample. This does not establish that the process never created a graphics device later. Loaded graphics libraries alone do not establish device creation.

## Next discriminating boundary

The separate EA setup track has reported a successful D3D11 device, exact GPU readback, and presentation probe with stock Wine 11.18 plus DXVK-macOS. That complete runtime comparison is more informative now than another unchanged original-runtime launch. This report does not claim that the new combination runs NFS.

If the new game attempt self-exits, first capture only relevant DXVK device-creation markers while the lifecycle observer identifies the full NFS process. Verify the loaded DLLs and the marker behavior with the owned D3D11 control first.

Published [Gcenx DXVK-macOS device source](https://github.com/Gcenx/DXVK-macOS/blob/1.10.x/src/d3d11/d3d11_main.cpp) logs feature-level probing, unsupported requested feature levels, and device-creation failure. Its selected-feature-level message precedes device construction: that message proves entry, not success. If the logs remain ambiguous, the next narrow boundary is the public D3D11 device-creation return HRESULT in the compatibility library.

The [logger source](https://github.com/Gcenx/DXVK-macOS/blob/1.10.x/src/util/log/log.cpp) selects `DXVK_LOG_PATH`, reads `DXVK_LOG_LEVEL`, and creates files named from the executable basename. It opens a new output stream rather than appending. A successor can overwrite the first process's file. Preserve allowed markers live with lifecycle attribution; the final file alone cannot reliably describe the first failing process. Do not merge EA's graphics initialization with NFS's initialization.

Earlier DXMT logs contain feature-level messages without process identifiers. [DXMT v0.80 source](https://github.com/3Shain/dxmt/blob/v0.80/src/d3d11/d3d11.cpp) places those messages in device creation, but the retained merged log does not securely attribute them to a particular NFS process.

## Retained evidence and cleanup

The two numeric profiles, successful private native sample, control sample, sampler diagnostics, and runtime manifest remain in the private `diagnostics/nfs2015-astra-owned` directory. Its `artifact-hashes.json` identifies retained evidence. Raw samples remain outside the source repository. The EA owner's matching lifecycle files are `astra-profile-20260927.lifecycle.log` and `astra-profile-early-20260927.lifecycle.log`.

The temporary Windows control source, executable, collector scripts, and Python bytecode were removed. The control prefix and server were stopped and removed. No profiling process remains. The EA owner stopped only each observed NFS successor; those cleanup exits are not game results.

## Follow-on diagnostic tool

At the EA owner's request, `collect-dxvk-markers.py`, `check-dxvk-markers.py`, and `DXVK-COLLECTOR.md` are retained as reusable source. Nineteen behavior checks and the earlier CLI smoke pass. Review caught a failed final child wait that escaped cleanup; a mocked regression failed before the correction and now confirms pipe closure and a fixed failure summary. Oversized dropped observer lines and later corruption now invalidate the whole lifecycle attribution and clear any recorded full-game exit. They preserve only exact enumerated renderer markers and numeric observer metadata, with explicit incomplete coverage and ambiguous file-emission attribution. A subsequent owned D3D11 control emitted the expected markers and rendered successfully. The first Wine 11.18 NFS launch then exited `-6` with zero markers and incomplete coverage. See [the launch record](WINE-11.18.md#existing-installation-clone-and-first-nfs-attempt); this absence does not establish that the game never called a graphics API.
