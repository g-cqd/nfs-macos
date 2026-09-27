"""Separate a bounded wait for process creation from its observation interval."""
import math

class CaptureWindow:
    """Start the active deadline once; later processes cannot extend it."""
    def __init__(self, armed_at, wait_seconds=900.0, active_seconds=180.0):
        if not all(math.isfinite(x) for x in (armed_at, wait_seconds, active_seconds)):
            raise ValueError('non-finite timing value')
        if wait_seconds <= 0 or active_seconds <= 0:
            raise ValueError('non-positive interval')
        self._armed_at = armed_at
        self._active_seconds = active_seconds
        self._started_at = None
        self._deadline = armed_at + wait_seconds
        if not math.isfinite(self._deadline):
            raise ValueError('deadline overflow')

    @property
    def phase(self):
        return 'waiting' if self._started_at is None else 'active'

    @property
    def deadline(self):
        return self._deadline

    def remaining(self, now):
        if not math.isfinite(now) or now < self._armed_at:
            return 0.0
        return max(0.0, self._deadline - now)

    def observe_start(self, now):
        if self._started_at is not None or self.remaining(now) == 0:
            return False
        deadline = now + self._active_seconds
        if not math.isfinite(deadline):
            return False
        self._started_at = now
        self._deadline = deadline
        return True
