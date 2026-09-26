"""Check the code-write profile without reading any write-buffer contents."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

path = Path(__file__).with_name("collect-code-writes.py")
spec = importlib.util.spec_from_file_location("code_writes", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

prefix = b"41000.123:05dc:05e0:"
calls = {
    "KERNEL32.WriteProcessMemory": "ffffffffffffffff,000000014547de70,0000000000123456,0000000000000010,0000000000123460",
    "ntdll.NtWriteVirtualMemory": "ffffffffffffffff,14547de70,123456,10,123460",
    "KERNEL32.FlushInstructionCache": "ffffffffffffffff,14547de70,10",
    "ntdll.NtFlushInstructionCache": "ffffffffffffffff,14547de70,10",
    "KERNEL32.VirtualProtect": "14547de70,1000,00000040,123460",
    "KERNEL32.VirtualProtectEx": "ffffffffffffffff,14547de70,1000,00000040,123460",
    "KERNEL32.TerminateProcess": "ffffffffffffffff,fffffffa",
    "ntdll.NtTerminateProcess": "ffffffffffffffff,fffffffa",
}
for api, arguments in calls.items():
    record = module.parse_record(prefix + f"Call {api}({arguments}) ret=1455d8813\n".encode())
    assert record["args"] == arguments.split(",")
    returned = module.parse_record(prefix + f"Ret  {api}() retval=00000001 ret=1455d8813\n".encode())
    assert returned["result"] == "00000001" and returned["args"] == []

invalid = [
    b'Call KERNEL32.WriteProcessMemory(ffffffffffffffff,14547de70,"private-payload",10,123460) ret=1',
    b"Call KERNEL32.WriteProcessMemory(1,2,3,4,5,6) ret=1",
    b"Call KERNEL32.WriteProcessMemory(1,2,3,4) ret=1",
    b"Call KERNEL32.VirtualProtect(1,2,100000000,4) ret=1",
    b"Call KERNEL32.VirtualProtectEx(1,2,3,100000000,5) ret=1",
    b"Call KERNEL32.FlushInstructionCache(1,10000000000000000,3) ret=1",
    b"Call ntdll.RtlQueryProcessDebugInformation(5dc,1,2) ret=1",
    b"Call KERNEL32.ReadProcessMemory(1,2,3,4,5) ret=1",
    b"Call KERNEL32.WriteProcessMemory(1,2,3,4,5) ret=1 private-payload",
]
for line in invalid:
    assert module.parse_record(prefix + line + b"\n") is None, line

with tempfile.TemporaryDirectory(prefix="nfs-code-write-check-") as directory:
    folder = Path(directory)
    (folder / "ownership.txt").write_text("ea_app_setup scalar profile test; no Wine prefix\n")
    observer = folder / "observer.txt"
    observer.write_text("observing_pid=1500 hex=05dc parent_pid=12\n")
    output = folder / "tail.jsonl"
    good = prefix + b"Call KERNEL32.WriteProcessMemory(1,2,3,4,5) ret=1\n"
    payload = good + good.replace(b":05dc:", b":05dd:") + prefix + invalid[0] + b"\n"
    run = subprocess.run([sys.executable, str(path), "--pid-source", str(observer),
                          "--output", str(output)], input=payload,
                         capture_output=True, check=True)
    assert not run.stdout and not run.stderr
    data = output.read_bytes()
    assert len(data) <= 1048576 and b"private-payload" not in data
    records = [json.loads(line) for line in data.splitlines()]
    assert records[0]["accepted_records"] == 1
    assert records[0]["discarded_lines"] == 2
    assert records[1]["args"] == ["1", "2", "3", "4", "5"]

print("Code-write scalar profile checks passed.")
