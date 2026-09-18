#!/usr/bin/env python3
"""Builds Sources/VoidMac/SpellData.swift from Data Dragon (names, icons, cooldowns) and CommunityDragon (targeting, range, missile geometry)."""
import json, sys, urllib.request, concurrent.futures, pathlib, re

UA = {"User-Agent": "VoidMac spell data generator"}
DD = "https://ddragon.leagueoflegends.com"
CD = "https://raw.communitydragon.org/latest/game/data/characters/{c}/{c}.bin.json"
OUT = pathlib.Path(__file__).resolve().parent.parent / "Sources/VoidMac/SpellData.swift"
TARGETING = {
    "Direction": "direction", "DragDirection": "vector", "Cone": "cone",
    "Location": "location", "LocationCalc": "location", "LocationClamped": "location", "Area": "location", "AreaClamped": "location",
    "Target": "unit", "TargetOrLocation": "unit", "Self": "none", "SelfAoe": "none", "None": "none",
    "TerrainLocation": "none", "TerrainType": "none", "WallDetection": "none",
}
OVERRIDES = {"zeriw": "direction", "zerie": "none", "asheq": "none", "lucianq": "unit"}

def get(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

def first(values, default=0.0):
    if isinstance(values, list) and values:
        return float(values[0])
    if isinstance(values, (int, float)):
        return float(values)
    return default

def missile_speed(spell):
    spec = spell.get("mMissileSpec") or {}
    move = spec.get("movementComponent") or {}
    if "mSpeed" in move:
        return float(move["mSpeed"]), float(spec.get("mMissileWidth", 0) or 0)
    if "mMinSpeed" in move or "mMaxSpeed" in move:
        lo, hi = float(move.get("mMinSpeed", 0) or 0), float(move.get("mMaxSpeed", 0) or 0)
        return (lo + hi) / 2 if lo and hi else max(lo, hi), float(spec.get("mMissileWidth", 0) or 0)
    if "mInitialSpeed" in move:
        return float(move["mInitialSpeed"]), float(spec.get("mMissileWidth", 0) or 0)
    return 0.0, float(spec.get("mMissileWidth", 0) or 0)

def build_champion(champ):
    cid, name = champ["id"], champ["name"]
    dd = json.loads(get(f"{DD}/cdn/{VERSION}/data/en_US/champion/{cid}.json"))["data"][cid]
    dd_spells = dd["spells"]
    try:
        bin_data = json.loads(get(CD.format(c=cid.lower())))
    except Exception as e:
        print(f"  {cid}: no bin ({e})", file=sys.stderr)
        bin_data = {}
    root = next((v for k, v in bin_data.items() if k.endswith("/CharacterRecords/Root")), {})
    spell_names = root.get("spellNames") or []
    prefix = f"Characters/{cid}/Spells/"
    by_key = {k.lower(): v for k, v in bin_data.items()}
    results = []
    for index, slot in enumerate("QWER"):
        dd_spell = dd_spells[index] if index < len(dd_spells) else {}
        entry = {
            "id": dd_spell.get("id", ""), "champion": cid, "championName": name, "slot": slot,
            "name": dd_spell.get("name", ""), "image": (dd_spell.get("image") or {}).get("full", ""),
            "cooldown": [float(c) for c in dd_spell.get("cooldown", [])], "maxRank": int(dd_spell.get("maxrank", 5) or 5),
            "cost": [float(c) for c in dd_spell.get("cost", [])],
            "ddRange": [float(r) for r in dd_spell.get("range", []) if isinstance(r, (int, float))],
            "targeting": "unknown", "range": 0.0, "width": 0.0, "radius": 0.0, "coneAngle": 0.0, "speed": 0.0, "castTime": 0.25, "castLock": 0.25,
        }
        rel = spell_names[index] if index < len(spell_names) else ""
        record = by_key.get((prefix + rel).lower()) if rel else None
        if record is None and dd_spell.get("id"):
            record = next((v for k, v in by_key.items() if k.endswith("/" + dd_spell["id"].lower()) and "mSpell" in v), None)
        spell = (record or {}).get("mSpell") or {}
        if spell:
            ttype = (spell.get("mTargetingTypeData") or {}).get("__type", "None")
            entry["targeting"] = TARGETING.get(ttype, "unknown:" + ttype)
            entry["range"] = first(spell.get("castRangeDisplayOverride")) or first(spell.get("castRange"))
            entry["castTime"] = float(spell.get("spellCastTime", 0.25) or 0.0)
            entry["castLock"] = max(float(spell.get("mCastTime", 0) or 0), float(spell.get("spellCastTime", 0) or 0), 0.1)
            entry["width"] = float(spell.get("mLineWidth", 0) or 0)
            entry["radius"] = first(spell.get("castRadius"))
            entry["coneAngle"] = float(spell.get("castConeAngle", 0) or 0)
            speed, mwidth = missile_speed(spell)
            if not speed and rel:
                ability = by_key.get((prefix + rel.split("/")[0]).lower()) or {}
                for child in ability.get("mChildSpells") or []:
                    cs = (by_key.get(child.lower()) or {}).get("mSpell") or {}
                    speed, mwidth = missile_speed(cs)
                    if speed:
                        break
            if not speed:
                speed = float(spell.get("missileSpeed", 0) or 0)
            entry["speed"] = speed
            if not entry["width"] and mwidth:
                entry["width"] = mwidth
            if entry["targeting"] == "none" and 0 < entry["range"] < 20000 and spell.get("mMissileSpec") and speed:
                entry["targeting"] = "unit"
        entry["targeting"] = OVERRIDES.get(entry["id"].lower(), entry["targeting"])
        results.append(entry)
    return results

VERSION = json.loads(get(f"{DD}/api/versions.json"))[0]
champions = list(json.loads(get(f"{DD}/cdn/{VERSION}/data/en_US/champion.json"))["data"].values())
print(f"Data Dragon {VERSION}, {len(champions)} champions", file=sys.stderr)
table = []
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    for spells in pool.map(build_champion, champions):
        table.extend(spells)
table.sort(key=lambda s: (s["champion"], s["slot"]))
payload = json.dumps({"version": VERSION, "spells": table}, separators=(",", ":"), ensure_ascii=True)
assert '"""' not in payload and "\\" not in payload.replace("\\u", "")
swift = f'''import Foundation

/** Spell geometry for every champion, generated by Tools/generate_spells.py from Data Dragon {VERSION} and CommunityDragon. */
enum SpellData {{
    static let version = "{VERSION}"
    static let json = """
{payload}
"""
}}
'''
OUT.write_text(swift)
counts = {}
for s in table:
    counts[s["targeting"]] = counts.get(s["targeting"], 0) + 1
print(f"wrote {OUT} ({len(table)} spells): {counts}", file=sys.stderr)
