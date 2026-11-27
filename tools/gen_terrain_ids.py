#!/usr/bin/env python3
"""Writes TerrainIds.lua from the community listfile.

    python3 -I tools/gen_terrain_ids.py <community-listfile.csv>

The minimap's pictures of the ground are files of the game client, one for
each square of a continent. WoW Forever does not give them to an addon by
name; it gives them by the number the client keeps each file under. Those
numbers are not something the game tells an addon, so they are read here
from the community listfile of the wowdev project
(github.com/wowdev/wow-listfile), which pairs each of the client's file
numbers with its name. Only the numbers of the two continents' squares are
taken: no picture and no other line of the list.

A line of the list is "number;name". A square's name is
world/minimaps/<folder>/mapCC_RR.blp, CC its column and RR its row.
"""
import os
import re
import sys

FOLDERS = {"azeroth": 0, "kalimdor": 1}
LINE = re.compile(rb"^(\d+);world/minimaps/(azeroth|kalimdor)/map(\d\d)_(\d\d)\.blp\r?$")

squares = {0: {}, 1: {}}
with open(sys.argv[1], "rb") as handle:
    for line in handle:
        if b"world/minimaps/" not in line:
            continue
        match = LINE.match(line.rstrip(b"\n"))
        if not match:
            continue
        number, folder = int(match.group(1)), match.group(2).decode("ascii")
        column, row = int(match.group(3)), int(match.group(4))
        if column > 63 or row > 63:
            continue
        squares[FOLDERS[folder]][column * 64 + row] = number

out = [
    "--[[",
    "The client's own file numbers of the minimap's pictures of the ground.",
    "",
    "Written by tools/gen_terrain_ids.py from the community listfile of the",
    "wowdev project; do not edit it by hand. EW.TERRAIN_IDS[continent] is a",
    "table from a square, as its column times 64 plus its row, to the number",
    "of that square's picture. The continent is the number the client counts",
    "it under: 0 for the Eastern Kingdoms and 1 for Kalimdor. Nothing here is",
    "a picture: the pictures are the client's, asked for by these numbers.",
    "]]",
    "",
    "local ADDON_NAME, EW = ...",
    "",
    "EW.TERRAIN_IDS = {",
]
for instance in sorted(squares):
    out.append("  [%d] = {" % instance)
    keys = sorted(squares[instance])
    for start in range(0, len(keys), 8):
        out.append("    " + " ".join("[%d]=%d," % (key, squares[instance][key]) for key in keys[start:start + 8]))
    out.append("  },")
out.append("}")
out.append("")
out.append("EW.TERRAIN_ID_COUNTS = { [0] = %d, [1] = %d }" % (len(squares[0]), len(squares[1])))
out.append("")

here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "..", "TerrainIds.lua"), "w") as handle:
    handle.write("\n".join(out))
print("Eastern Kingdoms %d squares, Kalimdor %d squares" % (len(squares[0]), len(squares[1])))
