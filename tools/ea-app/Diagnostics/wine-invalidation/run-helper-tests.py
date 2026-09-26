#!/usr/bin/env python3
"""Test a specified Wine virtual.c; compiler outputs are temporary and self-cleaning."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def extract_function(source, name):
    """Extract the named definition, ignoring braces inside C comments and literals."""
    tokens = re.compile(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', re.S)
    code = tokens.sub(lambda match: "".join("\n" if c == "\n" else " " for c in match[0]), source)
    declaration = re.search(r"(?m)^(?:static\s+(?:void|NTSTATUS)|NTSTATUS\s+WINAPI)\s+" +
                            re.escape(name) + r"\s*\(", code)
    if declaration is None:
        raise ValueError(f"definition not found: {name}")
    start = code.find("{", declaration.end())
    if start < 0:
        raise ValueError(f"function body not found: {name}")
    depth = 0
    for end in range(start, len(code)):
        depth += (code[end] == "{") - (code[end] == "}")
        if depth == 0:
            return source[declaration.start():end + 1]
    raise ValueError(f"unterminated function body: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("virtual_c", type=Path, help="baseline or patched Wine dlls/ntdll/unix/virtual.c")
    parser.add_argument("--temp-root", type=Path, help="parent for the temporary compiler directory")
    args = parser.parse_args()
    try:
        if args.virtual_c.stat().st_size > 2 * 1024 * 1024:
            raise ValueError("virtual.c exceeds the 2 MiB input limit")
        source = args.virtual_c.read_text()
        extracted = "\n".join(extract_function(source, name) for name in
                              ("toggle_executable_pages_for_rosetta", "NtWriteVirtualMemory"))
        print("SOURCE_SHA256", hashlib.sha256(source.encode()).hexdigest(), flush=True)
        with tempfile.TemporaryDirectory(prefix="wine-invalidation-helper-", dir=args.temp_root) as temporary:
            work = Path(temporary)
            (work / ".owned-helper-tests").write_text("temporary Wine invalidation contract tests\n")
            (work / "production-under-test.inc").write_text(extracted + "\n")
            binary = work / "helper-contract-tests"
            env = dict(os.environ, TMPDIR=str(work))
            subprocess.run(["clang", "-D__APPLE__", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
                            "-fsanitize=address,undefined", "-g", "-I", str(work),
                            str(Path(__file__).resolve().parent / "helper-contract-tests.c"),
                            "-o", str(binary)], env=env, check=True, timeout=60)
            result = subprocess.run([str(binary)], env=env, timeout=15)
            return result.returncode if result.returncode >= 0 else 2
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"INFRA {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
