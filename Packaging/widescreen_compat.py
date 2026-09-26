"""Compatibility patch for the pinned September 12, 2026 widescreen plugin."""
import hashlib

ORIGINAL_SHA256 = "f3a7f8c04db295154e10987303a7237a8dc70e2ba944d38a79f895ad1f570dd1"
PATCHED_SHA256 = "8f0e3f1d0e9e33cd2944e1930884030e49fb1e4db8a739e9800abcdb6f835823"
OLD_PATTERN = b"89 35 ? ? ? ? 89 35 ? ? ? ? 89 35 ? ? ? ? 89 35 ? ? ? ? 89 35 ? ? ? ? 89 35 ? ? ? ? 89 35"
NEW_PATTERN = b"89 35 1C 18 90 00 89 35 08 18 90 00 89 35 28 18 90 00"


def patched_widescreen(data: bytes) -> bytes:
    """Keep Resolution.ixx's target valid after Rendering.ixx removes a later store.

    The first three stores uniquely identify the same PC 1.3 instruction. The
    same-length string keeps the compiled string_view and all PE offsets valid.
    Unknown plugin builds are rejected before any file is changed.
    """
    fingerprint = hashlib.sha256(data).hexdigest()
    if fingerprint == PATCHED_SHA256:
        return data
    if fingerprint != ORIGINAL_SHA256 or data.count(OLD_PATTERN) != 1:
        raise ValueError("Unsupported widescreen plugin for the light-streak compatibility patch")
    result = data.replace(OLD_PATTERN, NEW_PATTERN.ljust(len(OLD_PATTERN), b" "))
    if hashlib.sha256(result).hexdigest() != PATCHED_SHA256:
        raise ValueError("Widescreen compatibility patch checksum mismatch")
    return result
