"""Check that diagnostics retain API metadata and discard unrelated data."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys

path = Path(__file__).with_name("filter-context.py")
spec = importlib.util.spec_from_file_location("context_filter", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

record = module.filtered("05e0: set_thread_context( handle=fffffffe, native_flags=00000010, contexts={{machine=x86_64,dr0=1455d8000,dr1=0,dr2=0,dr3=0,dr6=0,dr7=401}} )\n")
assert record["fields"]["dr0"] == "1455d8000"
assert record["fields"]["dr7"] == "401"
assert record["kind"] == "request"
assert module.filtered("05e0: set_thread_context() = UNSUCCESSFUL { self=1 }\n")["status"] == "UNSUCCESSFUL"
assert module.filtered("35826.010:05dc:05e0:Call KERNEL32.TerminateProcess(ffffffffffffffff,fffffffa) ret=144bdf5a6\n")["args"].endswith("fffffffa")
assert module.filtered("35794.028:05dc:05e0:Ret  KERNEL32.GetThreadContext() retval=00000001 ret=1455d8755\n")["result"] == "00000001"
assert module.filtered('05e0: create_file( name="private-account-data" )\n') is None
assert module.filtered('35826.010:05dc:05e0:Call KERNEL32.GetProcAddress(1234,"private-account-data") ret=1234\n') is None
exception = module.filtered("36044.123:05cc:05d0:trace:seh:dispatch_exception code=80000004 (SINGLE_STEP) flags=0 addr=000000014547DE70\n")
assert exception["fields"] == {"code": "80000004", "flags": "0", "addr": "000000014547DE70"}
assert module.filtered('36044.123:05cc:05d0:trace:seh:dispatch_exception "private-account-data"\n') is None
payload = b"05e0: set_thread_context( dr0=1," + b"private-account-data" * 4000 + b" )\n"
payload += b'05e0: create_file( name="private-account-data" )\n'
payload += b"05e0: get_thread_context() = SUCCESS { self=1 }\n"
result = subprocess.run([sys.executable, str(path)], input=payload, capture_output=True, check=True)
assert b"private-account-data" not in result.stdout
assert result.stdout.count(b"\n") == 1
assert b"SUCCESS" in result.stdout
many_records = b"05e0: get_thread_context() = SUCCESS { self=1 }\n" * 8000
bounded = subprocess.run([sys.executable, str(path)], input=many_records, capture_output=True, check=True)
assert 0 < len(bounded.stdout) <= module.OUTPUT_LIMIT
assert bounded.stdout.count(b"\n") < 8000
for line in bounded.stdout.splitlines():
    assert json.loads(line)["source"] == "server"
print("Context filter checks passed.")
