#!/usr/bin/env python3
"""Writes TravelMap.lua from the site's own atlas files.

    python3 tools/gen_travel_map.py <site>/src/data/forever-atlas > TravelMap.lua

The window's map is drawn from the same zone outlines the site's map draws.
Each outline is thinned to the points a small map needs, the two continents
are moved closer together so the sea between them does not take a third of
the picture, and every number is given in the map's own units, from its top
left corner.
"""
import json
import os
import re
import sys

src = sys.argv[1]
TOLERANCE = 3.0   # atlas units a thinned outline may stray from the full one
SEA = 70.0        # atlas units of empty sea left where a wider band is closed up
MARGIN = 12.0     # atlas units of room round the land


def load(name):
    with open(os.path.join(src, name + ".json"), encoding="utf-8") as handle:
        return json.load(handle)


def rings(path):
    """The closed rings of an outline path of M, L and Z commands."""
    found = []
    for part in re.findall(r"M([^MZ]*)Z?", path):
        numbers = [float(n) for n in re.findall(r"-?\d+\.?\d*", part)]
        ring = list(zip(numbers[0::2], numbers[1::2]))
        if len(ring) >= 3:
            found.append(ring)
    return found


def thin(points, tolerance):
    """Douglas and Peucker's thinning of an open line."""
    if len(points) < 3:
        return points
    (ax, ay), (bx, by) = points[0], points[-1]
    dx, dy = bx - ax, by - ay
    length = (dx * dx + dy * dy) ** 0.5
    worst, at = -1.0, 0
    for index in range(1, len(points) - 1):
        px, py = points[index]
        if length == 0:
            distance = ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
        else:
            distance = abs(dy * px - dx * py + bx * ay - by * ax) / length
        if distance > worst:
            worst, at = distance, index
    if worst <= tolerance:
        return [points[0], points[-1]]
    return thin(points[: at + 1], tolerance)[:-1] + thin(points[at:], tolerance)


def thin_ring(ring, tolerance):
    """A closed ring, thinned in two halves so its two ends are kept."""
    half = len(ring) // 2
    first = thin(ring[: half + 1], tolerance)
    second = thin(ring[half:] + [ring[0]], tolerance)
    return first[:-1] + second[:-1]


zones = load("zones-kalimdor") + load("zones-eastern-kingdoms")
outlines = {}
extent = {}
for zone in zones:
    found = rings(zone["outline_path"])
    outlines[zone["zone_key"]] = found
    box = extent.setdefault(zone["continent"], [1e9, 1e9, -1e9, -1e9])
    for ring in found:
        for x, y in ring:
            box[0], box[1] = min(box[0], x), min(box[1], y)
            box[2], box[3] = max(box[2], x), max(box[3], y)

west, east = extent["kalimdor"], extent["eastern_kingdoms"]

# What stands on the map from west to east: the two continents, and each
# place that lies off both, such as an island between them. Every band of
# empty sea wider than SEA is closed up to SEA: a cut is the atlas x in the
# middle of the band and how far everything east of it moves west.
landmarks = load("landmarks")
spans = [[west[0], west[2]], [east[0], east[2]]]
for mark in landmarks:
    if not any(a <= mark["x"] <= b for a, b in spans[:2]):
        spans.append([mark["x"] - 20, mark["x"] + 20])
spans.sort()
merged = [spans[0][:]]
for a, b in spans[1:]:
    if a <= merged[-1][1]:
        merged[-1][1] = max(merged[-1][1], b)
    else:
        merged.append([a, b])
cuts = []
for (_, left), (right, _) in zip(merged, merged[1:]):
    if right - left > SEA:
        cuts.append(((left + right) / 2, right - left - SEA))

origin_x = west[0] - MARGIN
origin_y = min(west[1], east[1]) - MARGIN
width = east[2] - sum(move for _, move in cuts) - origin_x + MARGIN
height = max(west[3], east[3]) - origin_y + MARGIN


def place(x, y):
    moved = x
    for at, move in cuts:
        if x >= at:
            moved -= move
    return round(moved - origin_x, 1), round(y - origin_y, 1)


def num(value):
    text = ("%.1f" % value).rstrip("0").rstrip(".")
    return text if text else "0"


out = []
w = out.append
w("--[[")
w("The map the window draws: every zone's outline, thinned, in the map's own")
w("units from its top left corner. Written by tools/gen_travel_map.py from the")
w("site's atlas files; do not edit by hand.")
w("")
w("A point of the atlas is put on the map by EW.MapPoint in Window.lua: for")
w("each cut it lies east of, it is moved west by that cut's shift, the wide")
w("empty sea between the continents being closed up, and then the origin is")
w("taken off.")
w("]]")
w("")
w("local ADDON_NAME, EW = ...")
w("")
w("EW.TRAVEL_MAP = {")
w("  width = %s," % num(width))
w("  height = %s," % num(height))
w("  originX = %s," % num(origin_x))
w("  originY = %s," % num(origin_y))
w("  CUTS = { %s }," % ", ".join("{ x = %s, shift = %s }" % (num(at), num(move)) for at, move in cuts))
w("  -- Each zone: its rings, each a flat run of x and y.")
w("  OUTLINES = {")
points_before = points_after = 0
for zone in zones:
    key = zone["zone_key"]
    parts = []
    for ring in outlines[key]:
        points_before += len(ring)
        kept = thin_ring(ring, TOLERANCE)
        if len(kept) < 3:
            continue
        points_after += len(kept)
        flat = []
        for x, y in kept:
            mx, my = place(x, y)
            flat.append(num(mx))
            flat.append(num(my))
        parts.append("{ " + ", ".join(flat) + " }")
    name = key if re.match(r"^[a-z_][a-z0-9_]*$", key) else '["%s"]' % key
    w("    %s = { %s }," % (name, ", ".join(parts)))
w("  },")
w("}")
sys.stdout.write("\n".join(out) + "\n")
sys.stderr.write("%d zones, %d points thinned to %d, map %s by %s units, %d cuts\n"
                 % (len(zones), points_before, points_after, num(width), num(height), len(cuts)))
