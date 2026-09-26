#!/usr/bin/env python3
"""Keep only numeric context/exit trace fields; discard all other input.

Input lines are bounded to 64 KiB and output to 1 MiB. This filter must run
before persistence when wineserver tracing is enabled. It never writes raw lines.
"""

import json
import re
import sys
import time

LINE_LIMIT = 65536
OUTPUT_LIMIT = 1048576
SERVER = re.compile(r"^([0-9a-f]{4,8}): ((?:get|set)_thread_context)\(")
FIELD = re.compile(r"\b(handle|context|flags|native_flags|machine|self|dr0|dr1|dr2|dr3|dr6|dr7)=([0-9a-f]+)\b")
STATUS = re.compile(r"\(\) = ([A-Z0-9_]+)\b")
RELAY = re.compile(
    r"^(\d+\.\d+):([0-9a-f]{4,8}):([0-9a-f]{4,8}):(Call|Ret ) "
    r"((?:KERNEL32|kernelbase|ntdll)\.(?:GetThreadContext|SetThreadContext|"
    r"NtGetContextThread|NtSetContextThread|TerminateProcess|NtTerminateProcess))"
    r"\(([0-9a-f,]*)\)(?: retval=([0-9a-f]+))? ret=([0-9a-f]+)$"
)
EXCEPTION = re.compile(
    r"^(\d+\.\d+):([0-9a-f]{4,8}):([0-9a-f]{4,8}):trace:seh:"
    r"(?:dispatch_exception|raise_exception) code=([0-9a-fA-F]+)"
    r"(?: \([A-Z0-9_]+\))? flags=([0-9a-fA-F]+) addr=([0-9a-fA-F]+)"
    r"(?: ip=[0-9a-fA-F]+ tid=[0-9a-fA-F]+)?\s*$"
)


def filtered(line):
    """Return allowlisted numeric fields, or None for all other input."""
    match = SERVER.match(line)
    if match:
        status = STATUS.search(line)
        return {
            "source": "server", "tid": match[1], "api": match[2],
            "kind": "reply" if status else "request",
            "status": status[1] if status else None,
            "fields": dict(FIELD.findall(line)),
        }
    match = RELAY.fullmatch(line.rstrip("\r\n"))
    if match:
        return {
            "source": "relay", "wine_seconds": match[1], "pid": match[2],
            "tid": match[3], "kind": match[4].strip(), "api": match[5],
            "args": match[6], "result": match[7], "caller": match[8],
        }
    match = EXCEPTION.fullmatch(line)
    if match:
        return {
            "source": "exception", "wine_seconds": match[1],
            "pid": match[2], "tid": match[3],
            "fields": {"code": match[4], "flags": match[5], "addr": match[6]},
        }
    return None


def main():
    written = 0
    while True:
        line = sys.stdin.buffer.readline(LINE_LIMIT + 1)
        if not line:
            return
        if len(line) > LINE_LIMIT:
            while line and not line.endswith(b"\n"):
                line = sys.stdin.buffer.readline(LINE_LIMIT + 1)
            continue
        record = filtered(line.decode("ascii", errors="replace"))
        if record is None:
            continue
        record["observed_monotonic_seconds"] = time.monotonic()
        output = json.dumps(record, separators=(",", ":")) + "\n"
        if written + len(output) <= OUTPUT_LIMIT:
            sys.stdout.write(output)
            sys.stdout.flush()
            written += len(output)


if __name__ == "__main__":
    main()
