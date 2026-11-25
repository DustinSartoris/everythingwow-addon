#!/usr/bin/env python3
"""Writes TravelData.lua from the site's own atlas files.

    python3 tools/gen_travel_data.py <site>/src/data/forever-atlas > TravelData.lua

The site's planner and the addon's planner then run on the same facts, so
the same trip gets the same answer in the game and on everythingwow.com.
tools/zone-maps.json holds the one thing the site's files do not: the number
the game gives each zone's map, and each capital's.
"""
import json
import os
import sys

src = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))


def load(name):
    with open(os.path.join(src, name + ".json"), encoding="utf-8") as handle:
        return json.load(handle)


def lua(value):
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return repr(value) if isinstance(value, float) and not float(value).is_integer() else str(int(value)) if float(value).is_integer() else repr(value)
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    raise TypeError(type(value))


def num(value):
    """A number with every digit the site's file carries."""
    return repr(float(value)) if not float(value).is_integer() else str(int(value))


def row(pairs):
    return "{ " + ", ".join(f"{key} = {text}" for key, text in pairs if text != "nil") + " }"


zones = []
for name in ("zones-kalimdor", "zones-eastern-kingdoms", "zones-skywall"):
    zones += load(name)
landmarks = load("landmarks")
routes = load("transport-routes")
edges = load("land-edges")
links = load("city-links")
flights = load("flight-times")
model = load("travel-model")
with open(os.path.join(here, "zone-maps.json"), encoding="utf-8") as handle:
    maps = json.load(handle)

out = []
w = out.append
w("--[[")
w("The travel planner's facts: the zones, places, crossings, boats and flights")
w("of WoW Forever as everythingwow.com's own map holds them.")
w("")
w("Written by tools/gen_travel_data.py from the site's atlas files. Do not edit")
w("it by hand: change the site's files and write it again, so the game and the")
w("website keep giving one answer.")
w("]]")
w("")
w("local ADDON_NAME, EW = ...")
w("")
w("local T = {}")
w("EW.TRAVEL = T")
w("")
w("T.ZONES = {")
for z in zones:
    w("  " + lua(z["zone_key"])[1:-1] + " = " + row([
        ("name", lua(z["name"])), ("continent", lua(z["continent"])), ("faction", lua(z["faction"])),
        ("status", lua(z["forever_status"])), ("x", num(z["center_x"])), ("y", num(z["center_y"])),
    ]) + ",")
w("}")
w("")
w("-- In the site's own order, which the planner's pairings keep.")
w("T.ZONE_ORDER = { " + ", ".join(lua(z["zone_key"]) for z in zones) + " }")
w("")
w("T.PLACES = {")
for p in landmarks:
    w("  " + row([
        ("key", lua(p["landmark_key"])), ("name", lua(p["name"])), ("kind", lua(p["kind"])),
        ("zone", lua(p["zone_key"])), ("x", num(p["x"])), ("y", num(p["y"])),
        ("faction", lua(p["faction"])), ("fm", lua(p["flight_master"])), ("isNew", lua(True) if p["is_new"] else "nil"),
    ]) + ",")
w("}")
w("")
w("T.LAND_EDGES = {")
for e in edges:
    w("  " + row([
        ("from", lua(e["from_key"])), ("to", lua(e["to_key"])), ("crossing", lua(e["crossing"])),
        ("claim", lua(e["claim"])), ("caution", lua(e["caution"])), ("gx", num(e["gate_x"])), ("gy", num(e["gate_y"])),
    ]) + ",")
w("}")
w("")
w("T.CITY_LINKS = {")
for c in links:
    w("  " + row([
        ("from", lua(c["from_key"])), ("to", lua(c["to_key"])), ("crossing", lua(c["crossing"])),
        ("fixed", "nil" if c["fixed_seconds"] is None else num(c["fixed_seconds"])), ("verb", lua(c["verb"])),
        # A way one faction alone may take, walked rather than a step inside a city.
        ("faction", lua(c.get("faction"))),
        ("walkFactor", "nil" if c.get("walk_factor") is None else num(c["walk_factor"])),
        ("caution", lua(c.get("caution"))),
    ]) + ",")
w("}")
w("")
w("T.ROUTES = {")
for r in routes:
    w("  " + row([
        ("key", lua(r["route_key"])), ("kind", lua(r["kind"])), ("faction", lua(r["faction"])),
        ("from", lua(r["from_key"])), ("to", lua(r["to_key"])),
        ("stops", "{ " + ", ".join(lua(s) for s in r["stop_keys"]) + " }" if r["stop_keys"] else "nil"),
        ("skyborne", lua(True) if r["skyborne_only"] else "nil"), ("oneWay", lua(True) if r["one_way"] else "nil"),
        ("claim", lua(r["claim"])), ("note", lua(r["note"])),
    ]) + ",")
w("}")
w("")
w("-- Measured flight seconds, by faction, then by the two flight masters' names.")
w("T.FLIGHTS = {")
for faction in ("alliance", "horde"):
    w("  " + faction + " = {")
    for f in flights:
        if f["faction"] == faction:
            w("    { " + lua(f["from_name"]) + ", " + lua(f["to_name"]) + ", " + num(f["seconds"]) + " },")
    w("  },")
w("}")
w("")
m = model
w("T.MODEL = {")
w("  footSecondsPerUnit = " + num(m["foot_seconds_per_unit"]) + ",")
w("  footYardsDefault = " + num(m["foot_yards_per_unit_default"]) + ",")
w("  footYards = { " + ", ".join(f"{k} = {num(v)}" for k, v in m["foot_yards_per_unit"].items()) + " },")
w("  speeds = { " + ", ".join(f"{k} = {num(v)}" for k, v in m["speed_multipliers"].items()) + " },")
w("  rides = {")
for key, ride in m["ride_seconds"].items():
    w(f"    {key} = {{ onBoard = {num(ride['on_board'])}, waitMin = {num(ride['wait_min'])}, waitMax = {num(ride['wait_max'])} }},")
w("  },")
w("  ferryRoutes = { " + ", ".join(f"[{lua(k)}] = true" for k in m["ferry_route_keys"]) + " },")
w("  flightBoard = " + num(m["flight_board_seconds"]) + ",")
w("  flightSecondsPerUnit = " + num(m["flight_seconds_per_unit"]) + ",")
w("  flightFixed = " + num(m["flight_fixed_seconds"]) + ",")
w("  flightLinks = {")
for key, ends in m["flight_links"].items():
    w(f"    {key} = {{ " + ", ".join(lua(e) for e in ends) + " },")
w("  },")
w("  seaPenalty = " + num(m["sea_crossing_penalty_seconds"]) + ",")
w("  enemyZonePenalty = " + num(m["enemy_zone_penalty_seconds"]) + ",")
w("  entryFactor = " + num(m["landmark_entry_factor"]) + ",")
w("  entryMinimum = " + num(m["landmark_entry_minimum_seconds"]) + ",")
w("  landFactors = { " + ", ".join(num(v) for v in m["land_weight_factors"]) + " },")
w("  enemyTransportPenalty = " + num(m["enemy_transport_penalty_seconds"]) + ",")
w("  walkMinimum = " + num(m["zone_walk"]["minimum_seconds"]) + ",")
w("  ferryOnly = { " + ", ".join(f"[{lua(k)}] = true" for k in m["zone_walk"]["ferry_only_landmark_keys"]) + " },")
w("}")
w("")
w("-- The number the game gives each zone's map, and each capital's.")
w("T.ZONE_MAPS = {")
for key in sorted(k for k in maps if not k.startswith("city:")):
    w(f"  [{maps[key]}] = {lua(key)},")
w("}")
w("T.CITY_MAPS = {")
for key in sorted(k for k in maps if k.startswith("city:")):
    w(f"  [{key[5:]}] = {lua(maps[key])},")
w("}")
print("\n".join(out))
