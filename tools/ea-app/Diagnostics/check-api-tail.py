"""Privacy, boundary, and retention checks for the NFS API tail collector."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(__file__).with_name("collect-api-tail.py")
spec = importlib.util.spec_from_file_location("api_tail", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def event(pid=b"05dc", kind=b"MetaCall", api=b"KERNEL32.WaitForSingleObject", time=b"100.001"):
    result = b" retval=00000102" if kind == b"MetaRet" else b""
    return time + b":" + pid + b":05e0:" + kind + b" " + api + b"()" + result + b" ret=1455d894c\n"


def expect_error(kind, operation):
    try:
        operation()
    except kind:
        return
    raise AssertionError("Expected " + kind.__name__)


call = module.parse_record(event())
assert call["api"] == "KERNEL32.WaitForSingleObject"
assert call["kind"] == "call" and call["result"] is None
assert module.parse_record(event(kind=b"MetaRet"))["result"] == "00000102"
assert module.parse_record(event().replace(b"MetaCall", b"Call")) is None
assert module.parse_record(event(kind=b"MetaRet").replace(b"MetaRet", b"Ret ")) is None
assert module.parse_record(event().replace(b"()", b'(1234,"private-secret")')) is None
assert module.parse_record(event() + b"private-secret") is None
assert module.parse_record(b"unrelated private-secret\n") is None
assert module.parse_record(event(api=b"x." + b"a" * 200)) is None
assert module.parse_record(event(kind=b"MetaRet").replace(b" retval=00000102", b"")) is None

assert module.parse_observer_ids(b"observing_pid=1500 hex=05dc parent_pid=12\r\n") == {"05dc"}
assert module.parse_observer_ids(b"compatdb: ignored\n") == set()
expect_error(ValueError, lambda: module.parse_observer_ids(b"observing_pid=1501 hex=05dc parent_pid=12\n"))
expect_error(ValueError, lambda: module.parse_observer_ids(b"x" * 65537))
too_many = b"".join(("observing_pid=%d hex=%04x parent_pid=1\n" % (i, i)).encode() for i in range(1, 66))
expect_error(ValueError, lambda: module.parse_observer_ids(too_many))

ring = module.TraceRing(64)
for i in range(20):
    ring.append(("record-%02d\n" % i).encode())
assert len(ring.storage) == 64 and ring.used <= 64
assert ring.tail_bytes(64) == b"record-16\nrecord-17\nrecord-18\nrecord-19\n"
assert ring.tail_bytes(20) == b"record-19\n"
assert ring.evicted_records == 16
expect_error(ValueError, lambda: ring.append(b"x" * 61))

collector = module.Collector(ring_capacity=2048)
collector.register_pids({"05dc"})
assert not collector.feed_line(event(pid=b"0230"))
assert collector.accepted_records == 0
for i in range(40):
    collector.feed_line(event(time=("%d.001" % (100+i)).encode()))
assert collector.accepted_records == 40
assert collector.stats["05dc"]["first_time"] == "100.001"
assert collector.stats["05dc"]["last_time"] == "139.001"
assert collector.feed_line(event(api=b"KERNEL32.TerminateProcess", time=b"140.001"))
assert not collector.feed_line(event(api=b"KERNEL32.TerminateProcess", time=b"140.002"))
snapshot = collector.snapshot(max_bytes=2048)
assert len(snapshot) <= 2048
rows = [json.loads(line) for line in snapshot.splitlines()]
assert rows[0]["accepted_records"] == 42
assert rows[0]["processes"]["05dc"]["calls"] == 42
assert rows[-1]["api"] == "KERNEL32.TerminateProcess"
assert all(row.get("pid", "05dc") == "05dc" for row in rows)
assert b"0230" not in snapshot and b"private-secret" not in snapshot

with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    observer = directory / "lifecycle.txt"
    output = directory / "tail.jsonl"
    observer.write_text("observing_pid=1500 hex=05dc parent_pid=12\n")
    payload = b"x" * 70000 + b"private-secret\n" + event(pid=b"0230")
    payload += event() + event(kind=b"MetaRet")
    completed = subprocess.run([sys.executable, str(source), "--pid-source", str(observer), "--output", str(output)],
        input=payload, capture_output=True, check=True)
    assert completed.stdout == b""
    result = output.read_bytes()
    assert b"private-secret" not in result and len(result) <= module.PERSIST_LIMIT
    assert json.loads(result.splitlines()[0])["accepted_records"] == 2
    assert sorted(p.name for p in directory.iterdir()) == ["lifecycle.txt", "tail.jsonl"]

print("API tail collector checks passed.")
