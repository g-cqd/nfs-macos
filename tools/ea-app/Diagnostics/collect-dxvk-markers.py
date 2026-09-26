#!/usr/bin/env python3
"""Persist only allowlisted DXVK markers and numeric NFS lifecycle metadata.

File polling cannot prove the emitter of a buffered line. Every marker therefore
retains ambiguous attribution, even when the observed writer maps to a known
Windows process. Missing markers never establish absence of a device call.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import time

LOG_NAME = 'NFS16_d3d11.log'
CHUNK = 65536
INPUT_LIMIT = 4 * 1024 * 1024
STATIC = {
    b'warn: D3D11CoreCreateDevice: Adapter is not a DXVK adapter': 'foreign_adapter',
    b'err:   D3D11CoreCreateDevice: Requested feature level not supported': 'unsupported_feature_level',
    b'err:   D3D11CoreCreateDevice: Failed to create D3D11 device': 'device_creation_failed',
    b'warn: D3D11CreateDevice: Unsupported driver type': 'unsupported_driver',
    b'err:   D3D11CreateDevice: Failed to create a DXGI factory': 'factory_creation_failed',
    b'err:   D3D11CreateDevice: No default adapter available': 'no_adapter',
    b'err:   D3D11CreateDevice: Failed to query DXGI factory from DXGI adapter': 'factory_query_failed',
    b'err:   D3D11CreateDevice: Failed to create swap chain': 'swapchain_creation_failed',
    b'err:   D3D11On12CreateDevice: Not implemented': 'd3d11on12_unimplemented',
}
FEATURE = re.compile(rb'info:  D3D11CoreCreateDevice: (Probing|Using feature level) D3D_FEATURE_LEVEL_([0-9]{1,2}_[0-9])')


class InputError(Exception):
    """A fixed diagnostic code; never includes input contents or paths."""


def parse_marker(line):
    """Return a fixed marker identifier and optional bounded numeric feature level."""
    marker = STATIC.get(line)
    if marker:
        return {'marker': marker}
    match = FEATURE.fullmatch(line)
    if match:
        return {'marker': 'feature_probe' if match[1] == b'Probing' else 'feature_selected',
                'feature_level': match[2].decode('ascii')}
    return None


class Lines:
    """Frame complete lines with bounded storage, dropping an oversized whole line."""
    def __init__(self, limit=4096):
        self.limit, self.pending, self.discarding, self.dropped = limit, bytearray(), False, 0

    def reset(self):
        self.pending.clear()
        self.discarding = False

    def feed(self, data):
        if len(data) > CHUNK:
            raise InputError('chunk_limit')
        result = []
        for byte in data:
            if byte == 10:
                if not self.discarding:
                    result.append(bytes(self.pending).removesuffix(b'\r'))
                self.reset()
            elif not self.discarding:
                if len(self.pending) == self.limit:
                    self.pending.clear()
                    self.discarding = True
                    self.dropped += 1
                else:
                    self.pending.append(byte)
        return result


class Tail:
    """Read one explicit regular file, with a fixed input cap and rewrite detection.

    A same-inode rewrite preserving the sampled anchor can escape detection.
    Callers must report incomplete coverage and must not infer a missing call.
    """
    def __init__(self, path, skip_existing=False):
        self.path = Path(path)
        self.parent = self.path.parent.resolve(strict=True)
        self.key, self.offset, self.anchor = None, 0, None
        self.generation, self.bytes_read = 0, 0
        if skip_existing:
            fd = self._open()
            if fd is not None:
                try:
                    meta = os.fstat(fd)
                    self.key = (meta.st_dev, meta.st_ino)
                    self.offset = meta.st_size
                    self.anchor = self._anchor(fd)
                    self.generation = 1
                finally:
                    os.close(fd)

    def _open(self):
        directory = os.open(self.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            try:
                fd = os.open(self.path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            except FileNotFoundError:
                return None
            except OSError:
                raise InputError('unsafe_input_file') from None
        finally:
            os.close(directory)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            raise InputError('nonregular_input_file')
        return fd

    def _anchor(self, fd):
        size = min(self.offset, 64)
        return hashlib.sha256(os.pread(fd, size, self.offset-size)).digest()

    def poll(self):
        fd = self._open()
        if fd is None:
            return self.generation, None, b''
        try:
            meta = os.fstat(fd)
            key = (meta.st_dev, meta.st_ino)
            reason = None
            if self.key is None:
                reason = 'created'
            elif key != self.key:
                reason = 'replaced'
            elif meta.st_size < self.offset:
                reason = 'truncated'
            elif self.anchor is not None and self._anchor(fd) != self.anchor:
                reason = 'rewritten'
            if reason:
                self.generation += 1
                self.offset = 0
                self.key = key
            remaining = INPUT_LIMIT - self.bytes_read
            if remaining <= 0 and meta.st_size > self.offset:
                raise InputError('input_limit')
            data = os.pread(fd, min(CHUNK, remaining), self.offset)
            self.offset += len(data)
            self.bytes_read += len(data)
            self.anchor = self._anchor(fd)
            return self.generation, reason, data
        finally:
            os.close(fd)


class Lifecycle:
    """Classify only the observer's numeric bootstrap/full/successor sequence."""
    def __init__(self):
        self.active = self.full = self.first_full_exit = None
        self.bootstrap_done = self.ambiguous = False

    def invalidate(self):
        """Permanently discard lifecycle attribution, including a previously seen exit."""
        self.ambiguous = True
        self.first_full_exit = None

    def feed(self, line):
        if self.ambiguous:
            return
        observed = re.fullmatch(rb'observing_pid=([0-9]{1,10}) hex=([0-9a-f]{4,8}) parent_pid=([0-9]{1,10})', line)
        exited = re.fullmatch(rb'pid=([0-9]{1,10}) exit_code=0x([0-9a-f]{8}) elapsed_observation_ms=([0-9]{1,12})', line)
        if observed:
            pid = int(observed[1])
            if not 0 < pid <= 0xffffffff or pid != int(observed[2], 16) or int(observed[3]) > 0xffffffff:
                self.invalidate()
                return
            if self.active is not None and self.active != pid:
                self.invalidate()
                return
            self.active = pid
            if self.bootstrap_done and self.full is None:
                self.full = pid
        elif exited:
            pid, code, elapsed = int(exited[1]), int(exited[2], 16), int(exited[3])
            if pid != self.active:
                self.invalidate()
                return
            if self.full == pid and self.first_full_exit is None:
                self.first_full_exit = {'windows_pid': pid, 'exit_code': code, 'observation_ms': elapsed}
            elif self.full is None and code == 100010:
                self.bootstrap_done = True
            self.active = None
        elif line:
            # Unknown observer errors or malformed records cannot validate a stage.
            self.invalidate()

    def context(self, windows_pid):
        if self.ambiguous or windows_pid is None or windows_pid != self.active:
            return {'stage': 'ambiguous', 'windows_pid': windows_pid}
        stage = 'full' if windows_pid == self.full else 'successor' if self.full is not None else 'unclassified'
        return {'stage': stage, 'windows_pid': windows_pid}


class PidMap:
    """Accept at most 32 explicit Windows/native PID pairs; conflicts stay unknown."""
    def __init__(self):
        self.values = {}

    def feed(self, line):
        match = re.fullmatch(rb'windows_pid=([0-9]{1,10}) native_pid=([0-9]{1,10})', line)
        if not match:
            return
        windows, native = int(match[1]), int(match[2])
        if not 0 < windows <= 0xffffffff or not 1 < native <= 0x7fffffff:
            return
        if native in self.values and self.values[native] != windows:
            self.values[native] = None
        elif native not in self.values:
            if len(self.values) >= 32:
                raise InputError('pid_map_limit')
            self.values[native] = windows

    def lookup(self, native):
        return self.values.get(native)


def parse_writers(data):
    """Extract only numeric PIDs of writable lsof descriptors; reject malformed output."""
    if len(data) > 16384:
        return None
    writers, pid = set(), None
    for line in data.splitlines():
        if re.fullmatch(rb'p[0-9]{1,10}', line):
            pid = int(line[1:])
            if not 1 < pid <= 0x7fffffff:
                return None
        elif re.fullmatch(rb'f[0-9]+', line) or line in (b'ftxt', b'fmem', b'fcwd', b'frtd'):
            continue
        elif line in (b'aw', b'au'):
            if pid is None:
                return None
            writers.add(pid)
        elif line in (b'ar', b'a '):
            continue
        else:
            return None
    return writers


def writer_pids(path, timeout):
    """Bound lsof time/output; raise InputError if the final cleanup wait expires."""
    process = subprocess.Popen(['/usr/sbin/lsof', '-F', 'pfa', '--', str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    data = bytearray()
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                if selector.select(max(0, deadline-time.monotonic())):
                    block = os.read(process.stdout.fileno(), 4096)
                    if not block:
                        process.wait(timeout=max(0.001, deadline-time.monotonic()))
                        return parse_writers(bytes(data)) if process.returncode in (0, 1) else None
                    data.extend(block)
                    if len(data) > 16384:
                        return None
        return None
    except subprocess.TimeoutExpired:
        return None
    finally:
        try:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            raise InputError('writer_cleanup_timeout') from None
        finally:
            process.stdout.close()


class Output:
    """Create a private, exclusive JSONL file; reserve space for the final summary."""
    def __init__(self, path, max_records=256, max_bytes=65536):
        self.file = os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), 'wb')
        self.max_records, self.max_bytes = max_records, max_bytes
        self.count, self.size = 0, 0

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.file.close()

    def emit(self, record):
        data = json.dumps(record, separators=(',', ':'), allow_nan=False).encode('ascii') + b'\n'
        if self.count >= self.max_records or self.size + len(data) > self.max_bytes-512:
            return False
        self.file.write(data)
        self.file.flush()
        self.count += 1
        self.size += len(data)
        return True

    def finish(self, summary):
        data = json.dumps({'kind': 'summary', **summary}, separators=(',', ':'), allow_nan=False).encode('ascii') + b'\n'
        if self.size + len(data) > self.max_bytes:
            raise InputError('summary_limit')
        self.file.write(data)
        self.file.flush()


def collect(log_dir, lifecycle_path, pid_map_path, output, seconds=180, clock=time.monotonic, pause=time.sleep, writer_probe=writer_pids):
    """Observe for a bounded duration; never launch or terminate a game process."""
    if not 0 <= seconds <= 180:
        raise InputError('invalid_duration')
    log_dir = Path(log_dir).resolve(strict=True)
    inputs = [log_dir / LOG_NAME, Path(lifecycle_path)]
    if pid_map_path:
        inputs.append(Path(pid_map_path))
    if Path(output).resolve() in {item.resolve() for item in inputs}:
        raise InputError('output_aliases_input')
    log = Tail(log_dir / LOG_NAME, skip_existing=True)
    life = Tail(lifecycle_path)
    mapping = Tail(pid_map_path) if pid_map_path else None
    # Fresh observer/map inputs prevent previous launches from becoming this run's evidence.
    for tail in [life] + ([mapping] if mapping else []):
        _, _, old = tail.poll()
        if old:
            raise InputError('observer_inputs_not_fresh')
    lines, life_lines, map_lines = Lines(), Lines(), Lines()
    state, pids = Lifecycle(), PidMap()
    start, reason, markers = clock(), 'deadline', 0
    with Output(output) as out:
        try:
            while clock()-start < seconds:
                for tail, framing, sink in [(life, life_lines, state.feed)] + ([(mapping, map_lines, pids.feed)] if mapping else []):
                    _, reset, raw = tail.poll()
                    if reset:
                        framing.reset()
                        if reset != 'created':
                            raise InputError('observer_input_replaced')
                    completed = framing.feed(raw)
                    if framing is life_lines and framing.dropped:
                        state.invalidate()
                    for line in completed:
                        sink(line)
                generation, reset, raw = log.poll()
                if reset:
                    lines.reset()
                parsed = [value for line in lines.feed(raw) if (value := parse_marker(line)) is not None]
                if parsed:
                    remaining = seconds-(clock()-start)
                    if remaining <= 0:
                        break
                    writers = writer_probe(log.path, min(1.0, remaining))
                    if clock()-start >= seconds:
                        break
                    native = next(iter(writers)) if writers is not None and len(writers) == 1 else None
                    context = state.context(pids.lookup(native))
                    for marker in parsed:
                        record = {'kind': 'marker', 'elapsed_s': round(clock()-start, 3), 'generation': generation,
                                  'observed_writer_pid': native, 'windows_pid': context['windows_pid'],
                                  'writer_state': 'unknown' if writers is None else 'single' if len(writers) == 1 else 'multiple' if writers else 'none',
                                  'lifecycle_stage': context['stage'], 'attribution': 'ambiguous_file_poll', **marker}
                        if not out.emit(record):
                            reason = 'output_limit'
                            break
                        markers += 1
                    if reason == 'output_limit':
                        break
                if state.first_full_exit is not None:
                    reason = 'first_full_exit'
                    break
                remaining = seconds-(clock()-start)
                if remaining > 0:
                    pause(min(0.5, remaining))
        except InputError as error:
            reason = str(error)
        except OSError:
            reason = 'io_error'
        finally:
            out.finish({'reason': reason, 'elapsed_s': round(clock()-start, 3), 'markers': markers,
                        'input_bytes': log.bytes_read, 'dropped_lines': lines.dropped, 'coverage_complete': False,
                        'first_full_exit': state.first_full_exit, 'observer_ambiguous': state.ambiguous,
                        'observer_dropped_lines': life_lines.dropped})
    return reason


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log-dir', required=True, type=Path)
    parser.add_argument('--lifecycle', required=True, type=Path)
    parser.add_argument('--pid-map', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--seconds', type=float, default=180)
    args = parser.parse_args()
    try:
        reason = collect(args.log_dir, args.lifecycle, args.pid_map, args.output, args.seconds)
    except (InputError, OSError):
        print('DXVK collector refused unsafe, stale, or unavailable inputs/output.', file=__import__('sys').stderr)
        return 2
    return 0 if reason in ('deadline', 'first_full_exit') else 2


if __name__ == '__main__':
    raise SystemExit(main())
