#!/usr/bin/env python3
"""Retain bounded NFS-only API metadata from an argument-free Wine relay.

The input must come from the diagnostic relay that never formats arguments.
Process IDs come from a fresh watch-nfs lifecycle file. All other lines are
discarded. A fixed byte ring holds at most 8 MiB; each atomic output is at
most 1 MiB. No captured argument or raw input line is persisted.
"""

import argparse
import json
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import time

RING_LIMIT = 8 * 1024 * 1024
PERSIST_LIMIT = 1024 * 1024
LINE_LIMIT = 65536
PID_LIMIT = 64
RECORD = re.compile(
    rb"(\d{1,12}\.\d{3}):([0-9a-fA-F]{4,8}):([0-9a-fA-F]{4,8}):"
    rb"(MetaCall|MetaRet) ([A-Za-z0-9_]{1,40}\.[A-Za-z0-9_@$?]{1,160})\(\)"
    rb"(?: retval=([0-9a-fA-F]{1,16}))? ret=([0-9a-fA-F]{1,16})\r?\n?"
)
OBSERVER = re.compile(rb"observing_pid=(\d{1,10}) hex=([0-9a-fA-F]{4,8}) parent_pid=(\d{1,10})")
EXIT_APIS = {
    "kernel32.terminateprocess", "kernelbase.terminateprocess", "ntdll.ntterminateprocess",
    "kernel32.exitprocess", "kernelbase.exitprocess", "ntdll.rtlexituserprocess",
}


def parse_record(line):
    """Accept only argument-free API metadata with bounded ASCII fields."""
    match = RECORD.fullmatch(line)
    if match is None:
        return None
    returned = match[4] == b"MetaRet"
    if returned != (match[6] is not None):
        return None
    return {
        "time": match[1].decode("ascii"),
        "pid": format(int(match[2], 16), "04x"),
        "tid": format(int(match[3], 16), "04x"),
        "kind": "return" if returned else "call",
        "api": match[5].decode("ascii"),
        "result": match[6].decode("ascii").lower() if returned else None,
        "caller": match[7].decode("ascii").lower(),
    }


def parse_observer_ids(data):
    """Validate at most 64 NFS IDs from a lifecycle file of at most 64 KiB."""
    if len(data) > LINE_LIMIT:
        raise ValueError("Lifecycle file exceeds 64 KiB")
    ids = set()
    for line in data.splitlines():
        match = OBSERVER.fullmatch(line)
        if match is None:
            continue
        pid = int(match[1])
        if pid == 0 or pid > 0xffffffff or pid != int(match[2], 16):
            raise ValueError("Lifecycle PID fields disagree")
        ids.add(format(pid, "04x"))
        if len(ids) > PID_LIMIT:
            raise ValueError("Too many NFS process IDs")
    return ids


class TraceRing:
    """Own a fixed byte ring containing length-prefixed metadata records."""

    def __init__(self, capacity=RING_LIMIT):
        if capacity < 16 or capacity > RING_LIMIT:
            raise ValueError("Invalid ring capacity")
        self.storage = bytearray(capacity)
        self.start = 0
        self.used = 0
        self.evicted_records = 0

    def _read(self, offset, length):
        first = min(length, len(self.storage) - offset)
        return bytes(self.storage[offset:offset+first]) + bytes(self.storage[:length-first])

    def _length(self, offset, remaining):
        length = struct.unpack("<I", self._read(offset, 4))[0]
        if remaining < 4 or length > remaining - 4:
            raise RuntimeError("Corrupt internal ring record")
        return length

    def _write(self, offset, data):
        first = min(len(data), len(self.storage) - offset)
        self.storage[offset:offset+first] = data[:first]
        self.storage[:len(data)-first] = data[first:]

    def append(self, record):
        size = 4 + len(record)
        if size > len(self.storage):
            raise ValueError("Record exceeds ring capacity")
        while self.used + size > len(self.storage):
            removed = 4 + self._length(self.start, self.used)
            self.start = (self.start + removed) % len(self.storage)
            self.used -= removed
            self.evicted_records += 1
        offset = (self.start + self.used) % len(self.storage)
        self._write(offset, struct.pack("<I", len(record)))
        self._write((offset + 4) % len(self.storage), record)
        self.used += size

    def tail_bytes(self, limit):
        """Return complete recent records fitting within the byte limit."""
        if limit < 0:
            raise ValueError("Negative tail limit")
        offset, remaining = self.start, self.used
        while remaining > limit:
            removed = 4 + self._length(offset, remaining)
            offset = (offset + removed) % len(self.storage)
            remaining -= removed
        output = bytearray()
        while remaining:
            length = self._length(offset, remaining)
            offset = (offset + 4) % len(self.storage)
            output.extend(self._read(offset, length))
            offset = (offset + length) % len(self.storage)
            remaining -= 4 + length
        return bytes(output)


def encoded(record):
    return (json.dumps(record, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")


class Collector:
    """Keep NFS metadata and fixed-size counters, discarding every other record."""

    def __init__(self, ring_capacity=RING_LIMIT):
        self.ring = TraceRing(ring_capacity)
        self.allowed_pids = set()
        self.stats = {}
        self.exits_snapshotted = set()
        self.accepted_records = 0
        self.discarded_lines = 0

    def register_pids(self, ids):
        combined = self.allowed_pids | ids
        if len(combined) > PID_LIMIT:
            raise ValueError("Too many NFS process IDs")
        self.allowed_pids = combined

    def feed_line(self, line):
        record = parse_record(line)
        if record is None or record["pid"] not in self.allowed_pids:
            self.discarded_lines += 1
            return False
        pid = record["pid"]
        stats = self.stats.setdefault(pid, {
            "first_time": record["time"], "last_time": record["time"],
            "calls": 0, "returns": 0, "records": 0,
        })
        stats["last_time"] = record["time"]
        stats["records"] += 1
        stats["calls" if record["kind"] == "call" else "returns"] += 1
        self.accepted_records += 1
        self.ring.append(encoded(record))
        if record["kind"] == "call" and record["api"].lower() in EXIT_APIS and pid not in self.exits_snapshotted:
            self.exits_snapshotted.add(pid)
            return True
        return False

    def snapshot(self, max_bytes=PERSIST_LIMIT):
        header = encoded({
            "type": "summary", "accepted_records": self.accepted_records,
            "discarded_lines": self.discarded_lines,
            "evicted_records": self.ring.evicted_records,
            "ring_bytes": self.ring.used, "processes": self.stats,
        })
        if max_bytes > PERSIST_LIMIT or len(header) > max_bytes:
            raise ValueError("Invalid snapshot limit")
        return header + self.ring.tail_bytes(max_bytes - len(header))


def write_snapshot(path, data):
    """Atomically replace the explicitly selected output, with private permissions."""
    if len(data) > PERSIST_LIMIT:
        raise ValueError("Snapshot exceeds 1 MiB")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".api-tail-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    collector = Collector()
    next_refresh = 0.0
    while True:
        now = time.monotonic()
        if now >= next_refresh:
            try:
                with args.pid_source.open("rb") as stream:
                    ids = parse_observer_ids(stream.read(LINE_LIMIT + 1))
            except FileNotFoundError:
                # A fresh watcher may create its lifecycle file after the pipe starts.
                ids = set()
            collector.register_pids(ids)
            next_refresh = now + 0.25
        line = sys.stdin.buffer.readline(LINE_LIMIT + 1)
        if not line:
            write_snapshot(args.output, collector.snapshot())
            return
        if len(line) > LINE_LIMIT:
            while line and not line.endswith(b"\n"):
                line = sys.stdin.buffer.readline(LINE_LIMIT + 1)
            collector.discarded_lines += 1
            continue
        if collector.feed_line(line):
            write_snapshot(args.output, collector.snapshot())


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print("API tail collection failed: " + str(error), file=sys.stderr)
        sys.exit(1)
