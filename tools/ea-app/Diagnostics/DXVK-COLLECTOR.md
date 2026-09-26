# Bounded DXVK marker collector

`collect-dxvk-markers.py` reads only the exact `NFS16_d3d11.log` in an explicit directory, a fresh lifecycle observer file, and an optional fresh numeric PID map. It writes enumerated markers and numeric metadata to a new private JSONL file. It neither launches nor stops Wine, EA, or NFS. It reads no EA application logs, launch arguments, or process memory.

## Run and integration

Run these commands from this Diagnostics directory. Verify the retained tests first:

```sh
python3 -B ./check-dxvk-markers.py
```

The suite uses owned fixtures and an owned open-file descriptor for its lsof check. It does not launch Wine or a game. Nineteen behavior checks currently pass. Tests were written before implementation; the initial run failed because the collector did not exist. Subsequent output-alias, deadline, and writer-cleanup tests also failed before their corrections.

For a real attempt, the EA owner should create a unique log directory and use the same `DXVK_LOG_PATH` spelling already validated by the owned D3D11 probe. Enable `DXVK_LOG_LEVEL=info` in the EA/game launch environment. Pass the corresponding host directory to this collector. Confirm that the owned D3D11 probe emits the expected markers before interpreting game output.

Start the collector **before** starting a fresh lifecycle observer and the launch:

```sh
python3 -B ./collect-dxvk-markers.py \
  --log-dir /absolute/path/to/owned-dxvk-logs \
  --lifecycle /absolute/path/to/fresh.lifecycle.log \
  --pid-map /absolute/path/to/fresh-native-pids.txt \
  --output /absolute/path/to/new-marker-capture.jsonl \
  --seconds 180
```

The lifecycle and PID-map files must be absent or empty at startup. Their parent directories must exist. The output must not exist and cannot alias an input. Existing contents of `NFS16_d3d11.log` are skipped. The collector never truncates any input file.

The lifecycle format is the existing `watch-nfs.c` output. After its observed bootstrap exits `100010`, the next observed NFS process is classified as the full game. Later processes are successors. Malformed, conflicting, or oversized dropped observer data makes the lifecycle permanently ambiguous and clears any recorded full-game exit. This also applies to invalid data after an otherwise valid exit in the same read batch. A detected observer/map replacement stops collection.

When the EA owner has independently established both IDs for a process, append this exact numeric record to the fresh PID map:

```text
windows_pid=1988 native_pid=49563
```

The numbers above are examples from an earlier attempt. Supply the actual IDs from the current attempt. Do not equate Windows PIDs with host PIDs. The PID map is optional; without it, lifecycle correlation remains ambiguous. A conflicting native-PID mapping stays unknown.

The collector asks lsof only about the exact NFS log file, retaining only PIDs of writable descriptors. No command lines, open-file paths, or raw lsof output are saved. Writer queries have a one-second maximum and bounded output. A timed-out child is killed, followed by a final wait of at most one second. If that wait expires, the collector closes the pipe and stops with the fixed summary reason `writer_cleanup_timeout` and exit status 2; it does not claim the child was reaped. The game owner's separate launch watchdog remains responsible for game cleanup.

## Output and interpretation

Each marker record contains its elapsed collection time, file generation, an enumerated marker, an optional numeric feature level, observed writer status/PID, mapped Windows PID, and mapped lifecycle stage.

**Every marker explicitly says `attribution: ambiguous_file_poll`.** A current writable descriptor is useful context; it does not prove which process emitted an earlier buffered line. `lifecycle_stage: full` describes the mapped writer at observation time, not exact historical emission attribution.

The final summary records the stopping reason, accepted marker count, consumed log bytes, oversized-line count, observer ambiguity, dropped observer-line count, and the first full-process exit if established without subsequent detected corruption. It always says `coverage_complete: false`. Missing markers cannot prove that no graphics call occurred. File buffering, process overlap, and rewriting between polls can hide evidence.

The collector detects inode replacement, visible truncation, and changes to a short hash anchor before the read offset. It resets partial-line state at a detected generation change. A same-inode rewrite that preserves that anchor may escape detection. Accepted earlier markers remain in the separate output file when a successor overwrites the renderer's file.

The allowed markers cover feature-level probing/selection, unsupported features, adapter/factory failures, device creation failure, swapchain creation failure, and the unimplemented D3D11-on-D3D12 entry. All other lines are discarded. The selected-feature-level message occurs **before** device construction and is not a success result. An API return HRESULT or successful GPU work is needed to establish successful device creation.

Source contracts were checked against [DXVK-macOS device creation](https://github.com/Gcenx/DXVK-macOS/blob/1.10.x/src/d3d11/d3d11_main.cpp) and its [logger](https://github.com/Gcenx/DXVK-macOS/blob/1.10.x/src/util/log/log.cpp). Validate the actual installed build's output on the owned probe because these source links describe the published branch.

## Bounds and checks

- Maximum requested duration: 180 seconds; polling interval up to 0.5 seconds.
- Each input file: at most 4 MiB consumed, in chunks up to 64 KiB.
- Partial line: at most 4 KiB; an oversized line is discarded through its newline.
- PID map: at most 32 host PIDs; lsof output: at most 16 KiB.
- Output: at most 256 marker records and 64 KiB including the summary, with mode `0600`.
- Symlinks and nonregular input files are rejected. Existing output is never overwritten.
- Stop at the first established full-game exit, a limit, an input error, or the deadline.

The checks exercise exact accepted markers; secret-bearing, malformed and oversized input rejection; split lines; generation changes; stale inputs; process-ID ambiguity; observer corruption before and after an exit, including oversized discarded lines; output count/byte caps and permissions; input caps; deadlines; output/input aliasing; real lsof reader/writer discrimination; and a mocked cleanup timeout that closes the pipe and records a fixed failure reason without persisting the command. No performance optimization or startup success is claimed by this diagnostic tool.
