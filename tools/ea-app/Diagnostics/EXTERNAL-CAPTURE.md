# Bounded external observation helpers

These helpers repair the private launch observer. They do not launch EA,
collect API arguments, or identify the cause of the NFS startup failure.
The account-specific wrapper and its runtime/prefix paths remain private.

## Contract

- `capture-window.py` separates a 900-second wait for the first observed process
  from 180 seconds of active observation. Later processes cannot extend it.
  An event consumed at or after the wait deadline cannot start a capture.
- `capture-lifecycle.py` composes that clock with the existing bounded `Tail`,
  `Lines` and `Lifecycle` types from `collect-dxvk-markers.py`. It consumes each
  complete record once. Rewritten, malformed, oversized or incomplete terminal
  records invalidate attribution. An early observer exit stops collection.
- Full-game attribution requires observing a bootstrap exit of `100010` and
  the subsequent process sequence. Joining an existing process may leave its
  stage unclassified. Windows/native PID equivalence is not inferred.
- `finish_capture` preserves the primary stop reason when cleanup fails.
  It attempts stream closure and final status writing, and returns fixed
  step/exception-type identifiers. If status writing fails, only its returned
  in-memory state can report that failure; callers must surface it.
- The finalizer's observer must be the exact child owned by the caller. It
  waits at most five seconds after termination and two seconds after a kill
  fallback. Callers must separately bound and scope their game cleanup callback.
  A failed cleanup is reported; termination is not guaranteed.
- `watch-nfs.c` keeps its original 180-second default. The optional compile-time
  `OBSERVATION_LIMIT_MS` accepts 1 through 1,080,000 ms. The longer value lets
  an outer supervisor enforce both the waiting and active phases.

The clock uses caller-supplied monotonic observations, not game startup time.
The existing tail reader has bounded input and samples a rewrite anchor;
same-inode changes preserving that anchor can escape detection. No missing
record proves that the corresponding game action did not occur.

## Verification

Run from this directory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 check-capture-window.py
PYTHONDONTWRITEBYTECODE=1 python3 check-capture-lifecycle.py
```

The original file-replay bug was reproduced before the incremental correction.
Regression cases cover separated bootstrap/full events with an idle poll,
observer exit, split records, file truncation, an invalid suffix after an exit,
partial EOF and an expired wait. Clock checks cover late and immediate starts,
exact expiry, repeated starts, backward time and invalid intervals.

Cleanup controls cover scoped-query failure, observer termination/wait/kill
failure, bounded fallback waits, stream-close failure, final-status failure and
an already-exited observer. They exercise injected failures without launching
Wine. Default and maximum observer limits compile with `-Wall -Wextra -Werror`;
zero and an above-maximum limit fail with the intended preprocessing error.
The corrected private wrapper has not yet captured another game attempt.
