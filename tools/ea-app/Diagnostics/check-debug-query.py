"""Check exact scalar signatures and reuse of the bounded NFS collector."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

path = Path(__file__).with_name("collect-debug-query.py")
spec = importlib.util.spec_from_file_location("debug_query", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

calls = {
    "ntdll.RtlCreateQueryDebugBuffer": "00000000,00000000",
    "ntdll.RtlQueryProcessDebugInformation": "000005dc,00000001,0000000000190000",
    "ntdll.RtlDestroyQueryDebugBuffer": "0000000000190000",
    "KERNEL32.TerminateProcess": "ffffffffffffffff,fffffffa",
    "ntdll.NtTerminateProcess": "ffffffffffffffff,fffffffa",
}
prefix = b"39617.267:05dc:05e0:"
for profile in ({"bad-name.X": (8,)}, {"valid.X": ()},
                {"valid.X": (4,)}, {"valid.X": (16,) * 6}):
    try:
        module.make_parser(profile)
    except ValueError:
        rejected = True
    else:
        rejected = False
    assert rejected, profile

widths = [8, 8]
profile = {"ntdll.RtlCreateQueryDebugBuffer": widths}
frozen = module.make_parser(profile)
widths.clear()
profile.clear()
assert frozen(prefix + b"Call ntdll.RtlCreateQueryDebugBuffer(0,0) ret=1\n") is not None

for api, arguments in calls.items():
    call = prefix + f"Call {api}({arguments}) ret=1455d8813\n".encode()
    result = module.parse_record(call)
    assert result["api"] == api and result["args"] == arguments.split(",")
    returned = module.parse_record(prefix + f"Ret  {api}() retval=c000000b ret=1455d8813\n".encode())
    assert returned["result"] == "c000000b" and returned["args"] == []

invalid = [
    b'Call ntdll.RtlQueryProcessDebugInformation(05dc,"private-data",190000) ret=1',
    b"Call ntdll.RtlQueryProcessDebugInformation(100000000,1,190000) ret=1",
    b"Call ntdll.RtlQueryProcessDebugInformation(5dc,100000000,190000) ret=1",
    b"Call ntdll.RtlQueryProcessDebugInformation(5dc,1,10000000000000000) ret=1",
    b"Call ntdll.RtlQueryProcessDebugInformation(5dc,1) ret=1",
    b"Call ntdll.RtlQueryProcessDebugInformation(5dc,1,190000,1) ret=1",
    b"Call ntdll.RtlQueryProcessDebugInformation(5dc,1,190000) ret=1 secret",
    b"Call ntdll.RtlCreateQueryDebugBuffer() ret=1",
    b"Ret  ntdll.RtlDestroyQueryDebugBuffer(190000) retval=0 ret=1",
    b"Call KERNEL32.GetCommandLineW() ret=1",
    b"MetaCall ntdll.RtlQueryProcessDebugInformation() ret=1",
    b"Call ntdll.RtlQueryProcessDebugInformation(5dc,1,190000) retval=0 ret=1",
]
for line in invalid:
    assert module.parse_record(prefix + line + b"\n") is None, line

with tempfile.TemporaryDirectory(prefix="nfs-scalar-check-") as directory:
    folder = Path(directory)
    (folder / "ownership.txt").write_text("ea_app_setup collector unit test; no Wine prefix\n")
    observer = folder / "observer.txt"
    observer.write_text("observing_pid=1500 hex=05dc parent_pid=12\n")
    output = folder / "tail.jsonl"
    good = prefix + b"Call ntdll.RtlQueryProcessDebugInformation(5dc,1,190000) ret=1455d8813\n"
    payload = b"private-data" * 7000 + b"\n" + good
    payload += good.replace(b":05dc:", b":05dd:")
    payload += prefix + invalid[0] + b"\n"
    result = subprocess.run([sys.executable, str(path), "--pid-source", str(observer),
                             "--output", str(output)], input=payload,
                            capture_output=True, check=True)
    assert not result.stdout and not result.stderr
    data = output.read_bytes()
    assert len(data) <= 1048576 and b"private-data" not in data
    records = [json.loads(line) for line in data.splitlines()]
    assert records[0]["accepted_records"] == 1
    assert records[0]["discarded_lines"] == 3
    assert records[1]["args"] == ["5dc", "1", "190000"]
    assert records[1]["pid"] == "05dc"

print("Debug-query scalar collector checks passed.")
