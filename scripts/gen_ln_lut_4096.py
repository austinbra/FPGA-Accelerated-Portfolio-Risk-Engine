#!/usr/bin/env python3
"""Regenerate src/gen/ln_lut_4096.mem for fxlnLUT (Q16.16, 12-bit index).

Each line i is trunc(ln(x_i) * 65536) in 8-hex 32-bit two's complement, where
x_i is the left edge of the fractional bin: (i<<4)/65536 for i>0, and 1/65536
for i==0 (matches hardware addr = a>>4 with a in (0,1)).
"""
import math
import os

Q = 65536
REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(REPO, "src", "gen", "ln_lut_4096.mem")


def main() -> None:
    lines = []
    for i in range(4096):
        if i == 0:
            x = 1.0 / Q
        else:
            x = (i << 4) / float(Q)
        vi = int(math.log(x) * Q)
        lines.append(f"{(vi & 0xFFFFFFFF):08X}\n")
    with open(OUT, "w", encoding="ascii", newline="\n") as fh:
        fh.writelines(lines)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
