#!/usr/bin/env python3
"""Writes TravelCoords.lua from tools/place-coords.json.

    python3 tools/gen_travel_coords.py > TravelCoords.lua

Where a place stands in the game is given the way the game itself gives it:
the zone, and how far across and down that zone's own map, from 0 to 1.
From that the addon can ask the client where the place lies on any map it
shows, so a dot on the real map sits on the real place.
"""
import json
import os
import re
import sys

here = os.path.dirname(os.path.abspath(__file__))
places = json.load(open(os.path.join(here, "place-coords.json"), encoding="utf-8"))["places"]


def num(value):
    text = ("%.4f" % value).rstrip("0").rstrip(".")
    return text if text else "0"


out = []
w = out.append
w("--[[")
w("Where each place stands in the game: its zone, and how far across and down")
w("that zone's own map it lies, from 0 to 1. Written by")
w("tools/gen_travel_coords.py from tools/place-coords.json; do not edit by hand.")
w("A place that is not listed has only its drawn spot on the site's map, and")
w("is put on the game's map by its neighbors (see Places.lua).")
w("]]")
w("")
w("local ADDON_NAME, EW = ...")
w("")
w("EW.TRAVEL_COORDS = {")
for key in sorted(places):
    zone, x, y = places[key]
    name = key if re.match(r"^[a-z_][a-z0-9_]*$", key) else '["%s"]' % key
    w('  %s = { zone = "%s", x = %s, y = %s },' % (name, zone, num(x / 100.0), num(y / 100.0)))
w("}")
sys.stdout.write("\n".join(out) + "\n")
sys.stderr.write("%d places\n" % len(places))
