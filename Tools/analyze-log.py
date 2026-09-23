#!/usr/bin/env python3
"""Report on a Void# log, one block per play session. Usage: Tools/analyze-log.py [log] [--last N]"""

import os
import re
import sys
import statistics as st
from collections import Counter

LOG = "~/Library/Logs/VoidMac.log"

# Sessions must never be pooled: timestamps repeat across days and track ids restart at 1 on every
# launch, so any id- or time-keyed comparison across sessions is meaningless.
START = "Void# for macOS"

RE = {
    "attack": re.compile(r"^(\d\d:\d\d:\d\d\.\d\d\d) \[i\] attack #(\d+): (\w[\w']*) lvl.*?fill (\d+)/(\d+)"
                         r".*?(\d+) u below the head of (\d+)"),
    "cadence": re.compile(r"gap (\d+) ms vs period (\d+) ms \((-?\d+) late(?:, click to click (\d+) ms)?\)"),
    "slow": re.compile(r"attack confirmation slow: (.*?) \((\d+) ms after the click"),
    "combo": re.compile(r"\[i\] combo ([QWER]): .*?\(between attacks, (-?\d+) ms to the next\)"),
    "body": re.compile(r"\[i\] body of (\w[\w']*): (.*?) \(mesh (\d+) u\)"),
    "drop": re.compile(r"\[i\] attack #(\d+): bar (\d+) -> (\d+) px \(drop (\d+)\) in (\d+) ms, clicked (\d+) u"),
    "identity": re.compile(r"\[i\] track #(\d+) identity (\w[\w']*) -> (\w[\w']*)"),
    "refused": re.compile(r"cast ([QWER]) did nothing"),
    "located": re.compile(r"HUD icons located: size (\d+) px, pitch (\d+) px, (\w+) match ([\d.]+)"),
    "nohud": re.compile(r"no HUD icon reading"),
    "miss": re.compile(r"probable miss \((\w[\w']*) lvl"),
    "oor": re.compile(r"nearest (\d+) units feet to feet, limit (\d+)"),
    "nowindow": re.compile(r"not found; SCK windows"),
    "own": re.compile(r"\[i\] own bar: .*?; (\w[\w' ]*) mesh"),
    "lasthit": re.compile(r"\[i\] last hit m\d+: \d+ % in the frame"),
    "outcome": re.compile(r"\[i\] last hit m\d+: (killed|gone without|survived at)"),
    "learned": re.compile(r"our hit took \d+ %: a (\w+) minion, damage ([\d.]+) of the model \(efficiency now ([\d.]+)\)"),
    "defense": re.compile(r"\[i\] auto (Heal|Barrier) \(\w, key \w+\): health (\d+) %"),
}


def sessions(lines):
    marks = [i for i, l in enumerate(lines) if START in l]
    return [(marks[k], marks[k + 1] if k + 1 < len(marks) else len(lines)) for k in range(len(marks))]


def quantiles(values):
    v = sorted(values)
    return v[len(v) // 2], v[int(len(v) * 0.9)] if len(v) > 1 else v[0]


def interesting(block):
    """A session worth a block: ten champion attacks or five last-hit attacks."""
    return sum(1 for l in block if RE["attack"].match(l)) >= 10 or sum(1 for l in block if RE["lasthit"].search(l)) >= 5


def report(block, label):
    attacks = [RE["attack"].match(l) for l in block]
    attacks = [m for m in attacks if m]
    if not interesting(block):
        return
    champ = next((RE["own"].search(l).group(1) for l in block if RE["own"].search(l)), "?")
    print("\n=== %s   champion %s   attacks %d ===" % (label, champ, len(attacks)))

    late = [int(m.group(3)) for l in block for m in [RE["cadence"].search(l)] if m]
    if late:
        med, p90 = quantiles(late)
        within = 100 * sum(1 for x in late if abs(x) <= 100) / len(late)
        print("  cadence      n=%-4d  late median %+d ms  p90 %+d ms  within 100 ms: %.0f%%"
              % (len(late), med, p90, within))
    else:
        print("  cadence      no chained-attack samples")

    real = sorted(int(m.group(4)) - int(m.group(2)) for l in block for m in [RE["cadence"].search(l)] if m and m.group(4))
    if real:
        print("  true cadence n=%-4d  click to click minus period: median %+d ms  p90 %+d ms"
              % (len(real), real[len(real) // 2], real[int(len(real) * 0.9)]))

    slow = [m.group(1) for l in block for m in [RE["slow"].search(l)] if m]
    if slow:
        kinds = Counter(re.sub(r"\+?\d+", "N", s) for s in slow)
        print("  slow confirm n=%-4d  %s" % (len(slow), "  ".join("%s x%d" % (k[:34], v) for k, v in kinds.most_common(3))))

    casts = [int(m.group(2)) for l in block for m in [RE["combo"].search(l)] if m]
    skips = sum(1 for l in block if "combo" in l and "skipped" in l)
    refused = sum(1 for l in block if RE["refused"].search(l))
    if casts or skips:
        med, _ = quantiles(casts) if casts else (0, 0)
        print("  combos       cast %-4d skipped %-4d refused %-4d  slack at cast median %d ms" % (len(casts), skips, refused, med))

    located = [RE["located"].search(l) for l in block]
    located = [m for m in located if m]
    nohud = sum(1 for l in block if RE["nohud"].search(l))
    if located or nohud:
        where = "  ".join("%s %s/%s px (%s)" % (m.group(3), m.group(1), m.group(2), m.group(4)) for m in located[:3])
        print("  ability hud  located %-4d no reading %-4d  %s" % (len(located), nohud, where))

    drops = [(int(m.group(4)), int(m.group(6))) for l in block for m in [RE["drop"].search(l)] if m]
    if drops:
        depth_med = st.median([d for _, d in drops])
        deep = [px for px, d in drops if d > depth_med]
        shallow = [px for px, d in drops if d <= depth_med]
        print("  hit drops    n=%-4d  median %d px" % (len(drops), st.median([p for p, _ in drops])), end="")
        if deep and shallow:
            print("  | deep clicks %d px vs shallow %d px  (equal => the drop is not ours)"
                  % (st.median(deep), st.median(shallow)))
        else:
            print()

    body = [(m.group(1), m.group(2), int(m.group(3))) for l in block for m in [RE["body"].search(l)] if m]
    if body:
        print("  body learner %d moves" % len(body))
        for name, note, mesh in body[-4:]:
            print("     %-12s %s (mesh %d u)" % (name, note[:64], mesh))

    flips = [(m.group(1), m.group(2), m.group(3)) for l in block for m in [RE["identity"].search(l)] if m]
    if flips:
        print("  identity     %d changes: %s" % (len(flips), ", ".join("#%s %s->%s" % f for f in flips[:4])))

    misses = Counter(m.group(1) for l in block for m in [RE["miss"].search(l)] if m)
    hit_by = Counter(m.group(3) for m in attacks)
    if misses:
        worst = sorted(misses.items(), key=lambda kv: -kv[1])[:3]
        print("  misses       %d  %s" % (sum(misses.values()),
              "  ".join("%s %d/%d" % (c, n, hit_by.get(c, 0)) for c, n in worst)))


    attempts = sum(1 for l in block if RE["lasthit"].search(l))
    if attempts:
        outcomes = Counter(m.group(1) for l in block for m in [RE["outcome"].search(l)] if m)
        learned = [(m.group(1), float(m.group(2)), float(m.group(3))) for l in block for m in [RE["learned"].search(l)] if m]
        kinds = Counter(k for k, _, _ in learned)
        print("  last hits    attempts %-4d killed %d (%.0f%%)  taken by others %d  survived %d%s"
              % (attempts, outcomes["killed"], 100 * outcomes["killed"] / attempts, outcomes["gone without"], outcomes["survived at"],
                 ("  | learned %s, efficiency %.2f" % (" ".join("%s x%d" % kv for kv in kinds.most_common()), learned[-1][2])) if learned else ""))

    heals = [(m.group(1), int(m.group(2))) for l in block for m in [RE["defense"].search(l)] if m]
    if heals:
        print("  auto defense %d casts at health %s" % (len(heals), ", ".join("%s %d%%" % h for h in heals[:6])))

    oor = [(int(m.group(1)), int(m.group(2))) for l in block for m in [RE["oor"].search(l)] if m]
    nowin = sum(1 for l in block if RE["nowindow"].search(l))
    tail = []
    if oor:
        tail.append("out of range %d (nearest median %d vs limit %d)"
                    % (len(oor), st.median([a for a, _ in oor]), st.median([b for _, b in oor])))
    if nowin:
        tail.append("game window not found %d" % nowin)
    if tail:
        print("  " + "  |  ".join(tail))


def main():
    argv, path, last, i = sys.argv[1:], None, 3, 0
    while i < len(argv):
        if argv[i] == "--last" and i + 1 < len(argv):
            last, i = int(argv[i + 1]), i + 2
            continue
        if not argv[i].startswith("--"):
            path = argv[i]
        i += 1
    path = path or os.path.expanduser(LOG)
    lines = open(path, errors="replace").read().split("\n")
    segs = sessions(lines)
    print("%s: %d lines, %d sessions (showing the last %d with attacks or last hits)" % (path, len(lines), len(segs), last))
    shown = 0
    for a, b in reversed(segs):
        if shown >= last:
            break
        report(lines[a:b], lines[a].split(" ")[0])
        if interesting(lines[a:b]):
            shown += 1


if __name__ == "__main__":
    main()
