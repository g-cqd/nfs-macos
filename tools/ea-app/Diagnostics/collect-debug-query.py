#!/usr/bin/env python3
"""Capture only five exact numeric Wine relay signatures for known NFS PIDs.

The original Wine relay must enable only these five exports. No accepted
signature formats strings or dereferences a pointer. The shared collector
provides process filtering, an 8 MiB ring, and a 1 MiB persisted tail.
"""

import importlib.util
from pathlib import Path
import re
import sys

SIGNATURES = {
    "ntdll.RtlCreateQueryDebugBuffer": (8, 8),
    "ntdll.RtlQueryProcessDebugInformation": (8, 8, 16),
    "ntdll.RtlDestroyQueryDebugBuffer": (16,),
    "KERNEL32.TerminateProcess": (16, 8),
    "ntdll.NtTerminateProcess": (16, 8),
}
RECORD = re.compile(
    rb"(\d{1,12}\.\d{3}):([0-9a-fA-F]{4,8}):([0-9a-fA-F]{4,8}):"
    rb"(Call|Ret ) ([A-Za-z0-9_]{1,40}\.[A-Za-z0-9_]{1,80})"
    rb"\(([0-9a-fA-F,]{0,84})\)(?: retval=([0-9a-fA-F]{1,16}))?"
    rb" ret=([0-9a-fA-F]{1,16})\r?\n?"
)


def _parse_record(line, signatures):
    """Reject every record outside a static scalar profile and its field bounds."""
    match = RECORD.fullmatch(line)
    if match is None:
        return None
    api = match[5].decode("ascii")
    widths = signatures.get(api)
    if widths is None:
        return None
    returned = match[4] == b"Ret "
    if returned != (match[7] is not None):
        return None
    arguments = match[6].decode("ascii").lower().split(",") if match[6] else []
    if returned:
        if arguments:
            return None
    elif len(arguments) != len(widths) or any(
        not argument or len(argument) > width
        for argument, width in zip(arguments, widths)
    ):
        return None
    return {
        "time": match[1].decode("ascii"),
        "pid": format(int(match[2], 16), "04x"),
        "tid": format(int(match[3], 16), "04x"),
        "kind": "return" if returned else "call",
        "api": api,
        "args": arguments,
        "result": match[7].decode("ascii").lower() if returned else None,
        "caller": match[8].decode("ascii").lower(),
    }


def make_parser(signatures):
    """Freeze a static profile of numeric argument widths; never dereference them."""
    profile = dict(signatures)
    for api, widths in profile.items():
        if re.fullmatch(r"[A-Za-z0-9_]{1,40}\.[A-Za-z0-9_]{1,80}", api) is None:
            raise ValueError("Invalid scalar API name")
        if not 1 <= len(widths) <= 5 or any(width not in (8, 16) for width in widths):
            raise ValueError("Invalid scalar argument widths")
        profile[api] = tuple(widths)
    return lambda line: _parse_record(line, profile)


parse_record = make_parser(SIGNATURES)


def main(record_parser=parse_record):
    path = Path(__file__).with_name("collect-api-tail.py")
    spec = importlib.util.spec_from_file_location("bounded_api_tail", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.main(record_parser=record_parser)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print("Scalar debug-query collection failed: " + str(error), file=sys.stderr)
        sys.exit(1)
