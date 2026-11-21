# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project goal

This is a Tabletop Simulator mod, converted from an existing Steam Workshop "MTG 4 player table - scripted" mod into a functional One Piece TCG (OPTCG) table, so the user and friends can do deck construction and gameplay. The source mod is still the base: most of the generic table utilities (dice, counters, hand/turn trackers, the card/deck importers, the `Encoder` property system) are inherited as-is from MTG and are not OPTCG-specific.

Key design points driving this project:

- **4 seats are retained even though OPTCG is 2-player.** Planned multiplayer modes:
  - **Split-table mode**: the table divides into two simultaneous 1v1 games between players seated across from each other, with turns passing back and forth between the two pairs.
  - **Four Emperors**: an existing non-standard 4-player OPTCG format that keeps a single continuous 4-player game with Commander-style turn order, and needs its own OPTCG rule-variant scripting.
- **Card import is an open design question**, not yet decided: maintain an external card database updated independently vs. keeping every OPTCG card as an in-mod object that gets copied into decklists (the latter would require repatching the mod on every card release). Don't assume either direction without checking with the user first.
- **First concrete use case**: using this mod to build/playtest an OPTCG equivalent of an MTG cube — i.e., a tool for visually sorting and organizing a large pile of cards, which is the main thing Tabletop Simulator offers that dedicated OPTCG sims don't.
- The whole reason for a custom mod instead of an existing OPTCG TTS sim is to support non-standard formats like Four Emperors.

## Architecture

**There is no build/lint/test tooling.** This repo is TTS Lua source files plus one Python sync script; "running" the mod means loading it in Tabletop Simulator.

### Repo ↔ live save sync pipeline

TTS stores each object's Lua source inline inside its save JSON (`...\Documents\My Games\Tabletop Simulator\Saves\TS_Save_1.json`, the "1 - One Piece TCG attempt" save), not as separate files. `tools/tts_sync.py` bridges that:

- `python tools/tts_sync.py status` — diff the repo against the live save, no writes.
- `python tools/tts_sync.py pull [--force]` — copy object scripts from the save into tracked files. Without `--force`, it only creates files for GUIDs that don't have one yet; it never silently overwrites a file that has diverged (so in-repo edits aren't clobbered by a stale save, and vice versa).
- `python tools/tts_sync.py push [--out PATH]` — write the repo's `.lua` files back into a save JSON (default: overwrite the source save, keeping a `.bak`). Use this to load repo edits into TTS.
- `python tools/tts_sync.py watch` — poll the save file and auto-pull new objects as they appear.

`scripts/manifest.json` maps object GUID → `{file, nickname}` and is maintained automatically by `pull`. `Global.lua` and `EasyModule.lua` at the repo root are "special" entries pinned to specific GUIDs (the save's top-level `LuaScript`, and GUID `b93b40` — the module chip object) rather than living under `scripts/objects/`. A VS Code task (`.vscode/tasks.json`, `TTS: Watch & auto-pull`) runs `watch` automatically on folder open.

When editing Lua in this repo, remember the source of truth can drift in *either* direction — the user edits scripts live in TTS's in-game editor as often as in the repo. Run `status` before assuming either side is current.

### OPTCG DON!!/Power system

The custom OPTCG logic hooks into `Encoder` (a vendored third-party object/property framework from the MTG source mod, `scripts/objects/Encoder_*.lua`, referenced by GUID). Encoder provides generic per-card data storage and button-drawing callbacks (`APIregisterProperty`, `APIobjGetPropData`/`APIobjSetPropData`, `APIrebuildButtons`, `APItoggleProperty`, etc.); OPTCG registers one property (`pID = "_OPTCG_DON_POWER"`) holding `donAttached`, `powerMod`, and `displayPowerMod` per card, and draws the DON!!/Power buttons through Encoder's `createButtons` callback.

This logic currently exists **twice**, not as a deliberate split:
- `EasyModule.lua` — the module chip object's own script (GUID `b93b40`), a trimmed-down adaptation of the original MTG module pattern.
- `Global.lua` — a parallel "simplified Global-script adaptation" (per its own header comment) of the same DON!!/Power logic, plus the physical DON!! deck spawner (`CreateDonDecks`, one 10-card deck per seat) which only exists here.

The two files are independently versioned (`moduleVersion` 1.0 vs 1.1) and have diverged in small ways (e.g. `GetEncoder`/`GetModuleChip` resolve by GUID in `Global.lua` but by `Global.getVar("Encoder")` in `EasyModule.lua`). Treat them as two live copies of the same feature until/unless the user consolidates them — don't assume a change to one should be mirrored into the other without checking.

### `scripts/objects/`

Everything here is inherited from the MTG source mod and mostly unmodified — dice, generic counters, hand/turn trackers, the deck/card importers, Encoder itself, etc. Treat these as vendored library objects rather than OPTCG-specific code unless told otherwise.
