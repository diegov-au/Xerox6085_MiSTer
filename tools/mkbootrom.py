#!/usr/bin/env python3
"""THE BOOT IMAGE FOR THE BOARD (X5): games/Xerox-6085/boot0.rom.

Its contents (the EEPROM arrays in fw/iop/iop.c: fw/README.md):

    fw/iop/iop.hex        the IOP firmware (make -C fw/iop)
    tools/seat.txt        the register file the boot hands the microcode

Xerox's microcode and germ are NOT in it: the IOP reads them off the user's
own disk (iop_boot in fw/iop/iop.c), as the 80186 did.

Layout (rtl/xerox_loader.v reads it; change both or neither):

    0x0000  IOP firmware   8192 x 4 bytes, little-endian
    0x8000  the seat       0x122 x 2 bytes, big-endian: U[256] R[16] RH[16] Q cs_n

THE SEAT MAY ONLY SET WHAT THE LOADER CAN: U, R, RH, Q and cs_n. Every other
field must be its reset value - the engine gets those from `reset` - and this
refuses a seat that says otherwise rather than build an image that would
start somewhere the simulator does not.

    python3 tools/mkbootrom.py [-o release/boot0.rom]
"""
import argparse
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

# What xerox_cp48's reset leaves in each scalar field the seat names.
RESET = {"pc": 0, "phase": 0, "stackP": 0, "MAR": 0, "MD": 0, "pc16": 0,
         "mint": 0, "intstat": 0, "trapcode": 1, "click_mar": 0, "io_ref": 0,
         "pending_or": 0, "pend_ibdisp": 0, "pend_always": 0, "ib_taken_v": 0,
         "ib_taken": 0, "prev_page_cross": 0, "prev_y": 0, "ibPtr": 0,
         "ibFront": 0, "IB0": 0, "IB1": 0, "trap_cd": 0, "cycles": 0,
         "last_op": 0, "ibdisps": 0}


def read_seat(path):
    seat = {}
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        k, *v = line.split()
        seat[k] = [int(x, 16) for x in v]
    return seat


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--fw", default=REPO / "fw/iop/iop.hex")
    ap.add_argument("--seat", default=REPO / "tools/seat.txt")
    ap.add_argument("-o", "--out", default=REPO / "release/boot0.rom")
    a = ap.parse_args()

    fw = [int(l, 16) for l in Path(a.fw).read_text().split()]
    if len(fw) != 8192:
        sys.exit(f"firmware {len(fw)} words, want 8192 - rebuild with make -C fw/iop")

    seat = read_seat(a.seat)
    for k, v in seat.items():
        if k in ("U", "R", "RH", "Q", "cs_n", "links"):
            continue
        if k not in RESET:
            sys.exit(f"seat: '{k}' is not something the board can load")
        if v[0] != RESET[k]:
            sys.exit(f"seat: {k} = {v[0]:X}, but reset leaves {RESET[k]:X} and the board has no way to set it")
    if any(seat.get("links", [0])):
        sys.exit("seat: nonzero links; the board has no way to set them")

    words = [0] * 0x122
    for i, x in enumerate(seat.get("U", [])[:256]):
        words[i] = x
    for i, x in enumerate(seat.get("R", [])[:16]):
        words[0x100 + i] = x
    for i, x in enumerate(seat.get("RH", [])[:16]):
        words[0x110 + i] = x
    words[0x120] = seat.get("Q", [0])[0]
    words[0x121] = seat.get("cs_n", [0xEFB])[0]

    out = bytearray()
    for w in fw:
        out += struct.pack("<I", w)
    assert len(out) == 0x8000
    for w in words:
        out += struct.pack(">H", w)

    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_bytes(out)
    print(f"{a.out}: {len(out)} bytes - IOP firmware and the seat (cs_n {words[0x121]:#x}); "
          f"the microcode and the germ come off the disk")


if __name__ == "__main__":
    main()
