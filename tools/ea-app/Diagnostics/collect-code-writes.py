#!/usr/bin/env python3
"""Static scalar profile for code-write and instruction-cache API relevance.

This adapter only parses numeric relay fields. It never dereferences pointers
or writes memory. Wine must enable only the exports in SIGNATURES, for NFS.
The shared collector requires fresh observer IDs and bounds memory and disk.
"""

import importlib.util
from pathlib import Path
import sys

SIGNATURES = {
    "KERNEL32.WriteProcessMemory": (16, 16, 16, 16, 16),
    "ntdll.NtWriteVirtualMemory": (16, 16, 16, 16, 16),
    "KERNEL32.FlushInstructionCache": (16, 16, 16),
    "ntdll.NtFlushInstructionCache": (16, 16, 16),
    "KERNEL32.VirtualProtect": (16, 16, 8, 16),
    "KERNEL32.VirtualProtectEx": (16, 16, 16, 8, 16),
    "KERNEL32.TerminateProcess": (16, 8),
    "ntdll.NtTerminateProcess": (16, 8),
}

path = Path(__file__).with_name("collect-debug-query.py")
spec = importlib.util.spec_from_file_location("scalar_relay", path)
scalar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scalar)
parse_record = scalar.make_parser(SIGNATURES)


if __name__ == "__main__":
    try:
        scalar.main(record_parser=parse_record)
    except (OSError, ValueError, RuntimeError) as error:
        print("Code-write collection failed: " + str(error), file=sys.stderr)
        sys.exit(1)
