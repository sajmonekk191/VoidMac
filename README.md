# Void#

A native orbwalker and autoaim for League of Legends on Apple Silicon Macs, written in Swift.

**It never reads or writes game memory.** Everything comes from four public sources: the screen
(ScreenCaptureKit), Riot's Live Client Data API on `127.0.0.1:2999`, published champion/spell data,
and synthesized input. There is no injection, no hooking and no process access.

## Demo

[▶ Gameplay clip (9 s)](media/gameplay.mp4) — orbwalking and combos in a practice game.

### In-game menu

![In-game menu](media/IngameMenu.png)

### Settings panel

![Settings panel](media/Menu.png)

## Requirements

- macOS 14+ on Apple Silicon, Swift 5.9 toolchain (`xcode-select --install`)
- League of Legends running on the same Mac
- Three permissions, granted on first launch: **Accessibility**, **Screen Recording**, **Input Monitoring**

## Quick start

```bash
git clone https://github.com/sajmonekk191/VoidMac.git
cd VoidMac
./run.sh          # builds, packages build/VoidMac.app, launches it
```

The app lives in the menu bar (scope icon). Grant the three permissions when macOS asks, then restart it once.

## Controls

| Key | What it does |
|---|---|
| **Space** (hold) | Orbwalk: attack → stand through the windup → move-click → attack again at 1/attack speed |
| **Q W E R** (+ D F) | With autoaim on, the spell is aimed at the predicted target and the cursor returns to your hand |
| **Right ⌘** | Open/close the panel; while it is open everything is paused |
| **C** | Hold to show attack range (bound to the game's own range key) |
| **'** | Attack champions only |
| **3** | Emote after a kill |

Flee and the helicopter are unbound by default. Every key is rebindable in the panel.

## What it does

- **Orbwalks** with per-champion windup data (172 champions), so the attack is never cancelled early and the
  move-click goes out the moment the windup is done.
- **Tracks targets from health bars** — one pass over the frame finds enemy bars, your own bar and the level box;
  a track keeps its identity for 1.5 s and its speed is fitted by regression over the last 160 ms.
- **Aims spells** at where the target will be, with a confidence from how linear its motion is; vector spells
  (Viktor E, Rumble R) are drawn with two points.
- **Weaves abilities between attacks** and reads whether each one is castable from the gold border of its HUD icon,
  falling back to a cooldown estimate from your own casts, the ability rank and ability haste.
- **Learns the click depth per champion**: a hit proves the body reaches that far below the health bar, two misses
  put the feet higher, and the estimate settles between them.
- **Calibrates itself from the attack-range ring** the game draws, which gives the pixels-per-unit and the ground
  perspective without any hardcoded resolution.
- **In-game menu** in the style of injected scripts: collapsible sections, each poppable into its own floating
  window, plus optional HUD overlays (status pills, an attack timer under your champion, the target's name).

## How it works

| Layer | Detail |
|---|---|
| Capture | ScreenCaptureKit window stream at native resolution, 120 fps in a match, 12 fps outside; a new frame wakes the waiting threads through a condition variable |
| Detection | One pass per frame (every 9th row at 2x): red fill + outline above and below + the level box; ~0.4 ms on a 3600×2338 frame |
| Timing | The orbwalker and vision threads run under a real-time (time-constraint) policy and wait on `mach_wait_until`; a background process otherwise gets its timers coalesced by up to 100 ms |
| Game state | Attack speed, attack range, champion, death and summoner spells come from the Live Client API |
| Data | 692 spells (targeting, range, speed, cast time, cooldown, cost) and 172 champion windups, generated from Data Dragon and CommunityDragon |

## Layout

```
Sources/VoidMac/      the app: capture, detection, orbwalker, autoaim, combos, UI
Tools/                generators, log analysis, the HUD regression check, packaging
media/                the gameplay clip and the UI screenshots used above
CLAUDE.md             the full engineering write-up (in Czech): every subsystem and why it is built that way
```

Config lives in `~/Library/Application Support/VoidMac/config.json`, the log in `~/Library/Logs/VoidMac.log`.

## Development

```bash
swift build -c release                        # build only
Tools/analyze-log.py --last 3                 # per-session report: cadence, combos, misses, HUD state
Tools/hud-regression-check/check.sh           # replays labelled frames through the real HUD reader
.build/release/VoidMac --analyze frame.png --hud Ashe    # offline: locate the ability icons in a screenshot
.build/release/VoidMac --ui-shot out/         # render the in-game UI to PNGs without a game
python3 Tools/generate_spells.py              # regenerate the spell table for a new patch
```

The regression check is not optional: the HUD reader decides when a combo may cast, and two changes to it have
already shipped broken. It replays frames with known answers through the real reader and fails on both of them.

## Limits

- Verified on a 3600×2338 (Retina 2x) game window; other resolutions rely on the ring calibration and are less tested.
- Champion identification reads the name plate above the bar, so it needs the name to be visible at least once.
- Full-screen mode delivers no window frames, so capture falls back to display capture with a source rect.

## Disclaimer

Automating input in League of Legends violates Riot's Terms of Service and can get the account banned.
This is a personal project published for reference; use it at your own risk.
