"""Regression: enabling light streaks must not invalidate the resolution hook."""
from pathlib import Path
import re
from widescreen_compat import OLD_PATTERN, NEW_PATTERN, patched_widescreen

ROOT = Path(__file__).resolve().parents[2]
game = bytearray((ROOT.parent / "NFSMW/speed.exe").read_bytes())
original = (ROOT.parent / "NFSMW/scripts/NFSMostWanted.WidescreenFix.asi").read_bytes()


def locations(pattern):
    expression = b"".join(b"." if token == b"?" else re.escape(bytes([int(token, 16)]))
                          for token in pattern.split())
    return [match.start() for match in re.finditer(expression, game, re.S)]


target = locations(OLD_PATTERN)
assert len(target) == 1
assert locations(NEW_PATTERN) == target
for pattern in [b"89 35 ? ? ? ? 89 35 ? ? ? ? 89 3D",
                b"89 35 ? ? ? ? 89 35 ? ? ? ? 83 F8 ? 7C",
                b"89 1D ? ? ? ? 89 1D ? ? ? ? 89 1D ? ? ? ? 8B 35"]:
    matches = locations(pattern)
    assert len(matches) == 1
    game[matches[0]:matches[0] + 6] = b"\x90" * 6
assert locations(OLD_PATTERN) == []
assert locations(NEW_PATTERN) == target
patched = patched_widescreen(original)
assert len(patched) == len(original)
assert patched.count(NEW_PATTERN) == 1
assert OLD_PATTERN not in patched
assert patched_widescreen(patched) == patched
try:
    patched_widescreen(original[:-1])
except ValueError:
    pass
else:
    raise AssertionError("Modified plugin was accepted")
print("Widescreen light-streak compatibility regression passed")
