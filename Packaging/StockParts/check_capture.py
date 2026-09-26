"""Validate native capture parsing before accepting game-derived stock records."""
from generate import parse_capture

signature = "929986c4d43d0667"
values = [65535] * 139
values[0], values[23], values[66] = 10507, 10552, 10667
row = signature + ",CARRERAGT," + ",".join(map(str, values))
parsed = parse_capture(row + "\n", {signature})
assert parsed[signature][:2] == (10507).to_bytes(2, "little")
assert parsed[signature][46:48] == (10552).to_bytes(2, "little")
assert len(parsed[signature]) == 278
for text in [row + "\n" + row, row.replace("10507", "11925"),
             row.replace("10507", "-1"), row.rsplit(",", 1)[0],
             "", "ERROR,canary,1", row.replace(signature, "0000000000000000")]:
    try:
        parse_capture(text, {signature})
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid stock capture was accepted")
print("Stock capture validation passed")
