"""Consume bounded observer deltas without replaying earlier process records."""
class LifecycleCapture:
    """Combine existing Tail/Lines/Lifecycle objects with an observation clock.

    The caller supplies the bounded common helpers. Each complete line is fed
    once, and malformed input permanently invalidates lifecycle attribution.
    """
    def __init__(self, window, tail, framing, lifecycle):
        self.window = window
        self.tail = tail
        self.framing = framing
        self.lifecycle = lifecycle
        self.observer_exit = None

    def poll(self, now, observer_returncode):
        """Return a stop reason, or None while valid observation can continue."""
        if self.window.remaining(now) == 0:
            return 'wait_deadline' if self.window.phase == 'waiting' else 'active_deadline'
        _, change, data = self.tail.poll()
        if change in ('replaced', 'truncated', 'rewritten'):
            self.lifecycle.invalidate()
            return 'observer_changed'
        lines = self.framing.feed(data)
        if self.framing.dropped:
            self.lifecycle.invalidate()
        for line in lines:
            self.lifecycle.feed(line)
            if not self.lifecycle.ambiguous and line.startswith(b'observing_pid='):
                self.window.observe_start(now)
        if self.lifecycle.ambiguous:
            return 'observer_ambiguous'
        if observer_returncode is not None:
            self.observer_exit = observer_returncode
            if self.framing.pending or self.framing.discarding:
                self.lifecycle.invalidate()
                return 'observer_partial'
        if self.lifecycle.first_full_exit:
            return 'first_full_exit'
        if self.window.remaining(now) == 0:
            return 'wait_deadline' if self.window.phase == 'waiting' else 'active_deadline'
        if observer_returncode is not None:
            return 'observer_exited'
        return None


def finish_capture(observer, stream, state, stop_reason, cleanup_games, write_status):
    """Finalize state even when bounded cleanup operations fail.

    The observer must be the exact child owned by this capture. Its termination
    waits are bounded to five seconds, then two seconds after a kill fallback.
    The caller bounds cleanup_games. Failures contain only step/type identifiers,
    preserve stop_reason, and never prevent the stream-close or status-write
    attempts. A failed status write is reported in the returned in-memory state.
    """
    errors = []
    state.update(capture_active=False, stop_reason=stop_reason,
                 cleanup_errors=errors, status_persisted=False)

    def attempt(step, action):
        try:
            return True, action()
        except Exception as error:
            # Cleanup must not replace the primary observation result.
            errors.append({'step': step, 'error': type(error).__name__})
            return False, None

    try:
        if cleanup_games is not None:
            success, stopped = attempt('game_cleanup', cleanup_games)
            if success:
                state['stopped_retry_native_pids'] = stopped
        success, code = attempt('observer_poll', observer.poll)
        if not success or code is None:
            attempt('observer_terminate', observer.terminate)
            waited, _ = attempt('observer_wait', lambda: observer.wait(timeout=5))
            if not waited:
                attempt('observer_kill', observer.kill)
                attempt('observer_final_wait', lambda: observer.wait(timeout=2))
    finally:
        try:
            attempt('stream_close', stream.close)
        finally:
            state['cleanup_complete'] = not errors
            state['status_persisted'] = True
            written, _ = attempt('status_write', lambda: write_status(state))
            if not written:
                state['status_persisted'] = False
                state['cleanup_complete'] = False
    return state
