#!/usr/bin/env python3
"""Run only the owned contract probe in a private runtime and prefix copy."""

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tempfile
import time
import uuid

CASES = ("initial", "disabled", "remote-user", "remote-syscall", "rf", "guest-tf", "flags", "flags-set")
SUPPLEMENT = {"sticky-dr6": None, "flag-mask": None, "slot-matches": None,
              "push-rf": None, "push-guest-tf": None, "mov-ss": "mov-ss-shadow-unsupported",
              "flag16": "prefixed-flag-instruction-unsupported",
              "icebp": "control-or-exception-instruction-unsupported",
              "push-fault": "flag-stack-write-fault-unsupported",
              "pop-fault": "flag-stack-read-fault-unsupported",
              "nx-flag": "instruction-fetch-fault-unsupported",
              "budget": "instruction-budget", "elapsed": "elapsed-budget"}
LOG_LIMIT = 65536
LINE_LIMIT = 4096
PREFIXES = (b"PROBE ", b"PASS ", b"FAIL ", b"EVENT ", b"SUMMARY ", b"ERROR ", b"TFEMU STOP ")


def capture(command, environment, timeout, stop_server):
    """Bound time, line storage, and persisted output; retain only probe messages."""
    process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = bytearray()
    retained = bytearray()
    dropping = False
    exceeded = False
    deadline = time.monotonic() + timeout
    try:
        while True:
            if time.monotonic() >= deadline:
                stop_server()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                return {"exit": None, "timeout": True, "output_overflow": exceeded}, bytes(retained)
            available = selector.select(timeout=0.1)
            if not available:
                if process.poll() is not None:
                    break
                continue
            data = os.read(process.stdout.fileno(), 4096)
            if not data:
                break
            for byte in data:
                if byte == 10:
                    if not dropping and bytes(pending).startswith(PREFIXES):
                        if len(retained) + len(pending) + 1 <= LOG_LIMIT:
                            retained.extend(pending)
                            retained.append(10)
                        else:
                            exceeded = True
                    pending.clear()
                    dropping = False
                elif not dropping:
                    if len(pending) == LINE_LIMIT:
                        pending.clear()
                        dropping = True
                    else:
                        pending.append(byte)
        return {"exit": process.wait(timeout=5), "timeout": False, "output_overflow": exceeded}, bytes(retained)
    finally:
        selector.close()
        process.stdout.close()


def remove_owned_directory(session, marker, owner, remove_tree=shutil.rmtree):
    """Retry a bounded Finder metadata race while retaining the ownership marker."""
    identity = (session.stat().st_dev, session.stat().st_ino)
    for attempt in range(3):
        if (session.stat().st_dev, session.stat().st_ino) != identity or marker.read_text() != owner:
            raise RuntimeError("Ownership changed; preserving the private directory")
        try:
            for child in session.iterdir():
                if child == marker:
                    continue
                if child.is_dir() and not child.is_symlink():
                    remove_tree(child)
                else:
                    child.unlink()
            marker.unlink()
            try:
                session.rmdir()
            except OSError:
                if (session.stat().st_dev, session.stat().st_ino) == identity:
                    with marker.open("x") as file:
                        file.write(owner)
                raise
            return
        except OSError as error:
            if error.errno != errno.ENOTEMPTY or attempt == 2:
                raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--emulation", action="store_true", help="enable the private Wine diagnostic")
    parser.add_argument("--state-details", action="store_true")
    parser.add_argument("--wow64", action="store_true")
    parser.add_argument("--supplement", action="append", choices=SUPPLEMENT)
    parser.add_argument("--label", default="baseline")
    parser.add_argument("--case", action="append", choices=CASES, dest="cases")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,40}", args.label):
        parser.error("label must contain only ASCII letters, digits, underscores, or hyphens")
    if args.wow64 and not args.state_details:
        parser.error("WOW64 is supported only for state-details")
    if sum(bool(v) for v in (args.state_details, args.supplement, args.cases)) > 1:
        parser.error("select one probe family")
    source = Path(__file__).resolve().parent
    runtime_source = args.runtime.resolve(strict=True)
    session = Path(tempfile.mkdtemp(prefix="nfs2015-tf-contract-", dir=Path.home() / "Library/Caches"))
    owner = uuid.uuid4().hex
    marker = session / ".owner"
    marker.write_text(owner)
    runtime = session / "runtime"
    environment = os.environ.copy()
    for name in list(environment):
        if name.startswith(("WINE", "DXVK", "DXMT", "D3DM", "CX_", "DYLD_")):
            del environment[name]
    environment.update(WINEPREFIX=str(session / "prefix"), WINEDEBUG="-all",
                       WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree,mshtml=")

    if args.emulation:
        environment["WINE_TF_EMULATION"] = "1"

    def check_owner():
        if marker.read_text() != owner:
            raise RuntimeError("Ownership changed; preserving the private directory")

    def stop_server():
        check_owner()
        if (runtime / "bin/wineserver").is_file():
            subprocess.run([str(runtime / "bin/wineserver"), "-k"], env=environment,
                           timeout=10, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run([str(runtime / "bin/wineserver"), "-w"], env=environment,
                           timeout=15, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    try:
        with (source / ".owned-runs.jsonl").open("a") as journal:
            journal.write(json.dumps({"session_name": session.name, "owner": owner, "label": args.label}) + "\n")
        subprocess.run(["/bin/cp", "-cR", str(runtime_source), str(runtime)], check=True, timeout=60)
        fingerprints = {}
        for relative in ("bin/wineserver", "lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-windows/ntdll.dll"):
            expected = hashlib.sha256((runtime_source / relative).read_bytes()).hexdigest()
            actual = hashlib.sha256((runtime / relative).read_bytes()).hexdigest()
            if expected != actual:
                raise RuntimeError("Runtime changed during copying: " + relative)
            fingerprints[relative] = actual
        executable = session / "contract-probe.exe"
        inputs = ([source / "state-details-probe.c"] if args.state_details
                  else [source / "supplement-probe.c", source / "supplement-fixtures.S"] if args.supplement
                  else [source / "contract-probe.c", source / "contract-fixtures.S"])
        compiler_name = ("i686" if args.wow64 else "x86_64") + "-w64-mingw32-gcc"
        compiler = shutil.which(compiler_name)
        if compiler is None:
            raise RuntimeError("Required compiler is not on PATH: " + compiler_name)
        subprocess.run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra",
                        "-Werror", "-pedantic", "-o", str(executable),
                        *map(str, inputs), "-lntdll"], check=True, timeout=30)
        wine = str(runtime / "bin/wine")
        boot, _ = capture([wine, "wineboot.exe", "--init"], environment, 120, stop_server)
        source_hashes = {name: hashlib.sha256((source / name).read_bytes()).hexdigest()
                         for name in ("contract-probe.c", "contract-fixtures.S", "run-contract.py")}
        summary = {"fingerprints": fingerprints,
                   "source_hashes": source_hashes, "emulation": args.emulation, "wow64": args.wow64,
                   "probe_inputs": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
                   "bootstrap": boot, "cases": {}}
        if boot["timeout"] or boot["exit"] != 0 or boot["output_overflow"]:
            raise RuntimeError("Private prefix initialization failed: " + json.dumps(boot))
        for case in (("state-details",) if args.state_details else args.supplement or args.cases or CASES):
            command = [wine, str(executable)] + ([] if args.state_details else [case])
            case_environment = environment.copy()
            if args.emulation and case == "budget":
                case_environment["WINE_TF_MAX_STEPS"] = "1000"
            result, output = capture(command, case_environment, 15, stop_server)
            reason = SUPPLEMENT.get(case) if args.supplement and args.emulation else None
            result["expected_exit"] = 86 if reason else 0
            result["passed"] = (result["exit"] == result["expected_exit"] and not result["timeout"]
                                and not result["output_overflow"] and
                                (not reason or ("TFEMU STOP " + reason + "\n").encode() in output))
            summary["cases"][case] = result
            (source / (args.label + "." + case + ".log")).write_bytes(output)
            print(case + " " + json.dumps(result), flush=True)
            print(output.decode("ascii", errors="replace"), flush=True)
        (source / (args.label + ".json")).write_text(json.dumps(summary, indent=2) + "\n")
        return int(any(not result["passed"]
                       for result in summary["cases"].values()))
    finally:
        stop_server()
        check_owner()
        remove_owned_directory(session, marker, owner)
        print("Owned runtime and prefix removed", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
