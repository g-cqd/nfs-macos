"""Generate the native save-part table from the bounded in-game diagnostic."""
import base64
import csv
import hashlib
import io
from pathlib import Path
import re
import struct
import sys


def parse_capture(text: str, expected: set[str]) -> dict[str, bytes]:
    if len(text) > 262_144:
        raise ValueError("Oversized stock capture")
    result = {}
    for fields in csv.reader(io.StringIO(text)):
        if len(fields) != 141:
            raise ValueError("Incomplete stock record")
        signature, name = fields[:2]
        if signature not in expected or signature in result or not re.fullmatch(r"[A-Z0-9_]{1,16}", name):
            raise ValueError("Unknown or duplicated stock model")
        indices = [int(field) for field in fields[2:]]
        if any(value != 65535 and not 0 <= value < 11925 for value in indices):
            raise ValueError("Stock part outside the pinned game catalog")
        if indices[0] == 65535 or indices[23] == 65535:
            raise ValueError("Stock model has no base or body")
        result[signature] = struct.pack("<139H", *indices)
    if result.keys() != expected:
        raise ValueError("Missing stock models")
    return result


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: generate.py stock-capture.csv")
    project = Path(__file__).resolve().parents[2]
    capture = Path(sys.argv[1])
    with capture.open("rb") as stream:
        raw = stream.read(262_145)
    if len(raw) > 262_144:
        raise ValueError("Oversized stock capture")
    source = (project / "Sources/LauncherCore/CarModel.swift").read_text()
    expected = set(re.findall(r'"([0-9a-f]{16})":', source))
    records = parse_capture(raw.decode("ascii"), expected)
    rows = [f'    "{signature}": "{base64.b64encode(block).decode()}",'
            for signature, block in sorted(records.items())]
    generated = '''import Foundation

/// Native PC 1.3 stock visual records; each block contains 139 little-endian part handles.
package enum StockCarParts {
  package static func block(for signature: String) throws(LauncherError) -> Data {
    guard let encoded = records[signature], let block = Data(base64Encoded: encoded),
      block.count == 278
    else { throw .operation("The selected model has no validated stock parts.") }
    return block
  }

  private static let records: [String: String] = [
''' + "\n".join(rows) + "\n  ]\n}\n"
    destination = project / "Sources/LauncherCore/StockCarParts.swift"
    temporary = destination.with_suffix(".swift.tmp")
    temporary.write_text(generated)
    temporary.replace(destination)
    print(f"Generated {len(records)} native stock records; capture SHA256 {hashlib.sha256(raw).hexdigest()}")


if __name__ == "__main__":
    main()
