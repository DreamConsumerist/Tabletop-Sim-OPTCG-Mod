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

`scripts/manifest.json` maps object GUID → `{file, nickname}` and is maintained automatically by `pull`. `Global.lua` and `CardImporter.lua` at the repo root are "special" entries pinned to specific GUIDs (the save's top-level `LuaScript`, and GUID `c055f4` — the Card Importer object) rather than living under `scripts/objects/`. A VS Code task (`.vscode/tasks.json`, `TTS: Watch & auto-pull`) runs `watch` automatically on folder open.

When editing Lua in this repo, remember the source of truth can drift in *either* direction — the user edits scripts live in TTS's in-game editor as often as in the repo. Run `status` before assuming either side is current.

### Live debugging link (`tools/tts_live_console.py`)

TTS exposes a local "External Editor API" (the same protocol the official VS Code/Atom TTS extensions use) over two one-shot-per-message TCP ports: it listens on `127.0.0.1:39999` for requests, and pushes to whatever's listening on `127.0.0.1:39998`. Each message is its own connection (sender writes, closes; receiver reads until EOF) — not a persistent stream. `tools/tts_live_console.py listen` runs a small server on 39998 that logs every `print()`/`broadcastToAll` message and Lua error TTS sends, live, to `tts_debug.log` (gitignored) — far faster than asking the user to copy-paste chat output while debugging. `tools/tts_live_console.py exec -1 "<lua>"` executes arbitrary Lua on Global (`-1` targets Global specifically; any other value is an object GUID) and streams the result back through the same listener — useful for live inspection/diagnostics without a save/reload cycle. Requires TTS to have a game loaded; no explicit "enable" toggle needed, TTS just pushes to 39998 whenever something's listening there.

This is exactly how the bulk-vs-per-card fetch timing below was actually measured, not guessed — `os.clock()`/`print()` instrumentation in the live code, read back through this link in real time.

### OPTCG card properties (Encoder-based)

The custom OPTCG logic hooks into `Encoder` (a vendored third-party object/property framework from the MTG source mod, `scripts/objects/Encoder_*.lua`, referenced by GUID). Encoder provides generic per-card data storage and button-drawing callbacks (`APIregisterProperty`, `APIobjGetPropData`/`APIobjSetPropData`, `APIrebuildButtons`, `APItoggleProperty`, `APIobjIsPropEnabled`, etc.). Its established pattern (confirmed from Encoder's source, not just inferred): **one `valueID` per `propID`, where the value is a whole struct** — the per-object value store (`EncodedObjects[guid].values`) is a single flat table shared across every property on that object, so a valueID string must be globally unique; nesting a struct inside one value is the only collision-safe shape. All OPTCG properties follow this.

`Global.lua` is the single source of truth for this — it owns both:
- `pID = "_OPTCG_DON_POWER"` — `donAttached`, `powerMod`, `displayPowerMod` per card, toggled with the "PWR" button.
- `statsPID = "_OPTCG_CARD_STATS"` — imported card stats (`cost`, `power`, `counter`, `color`, `cardType`, `attribute`, `life`, `rulesText`, etc.), toggled with the "STATS" button. Populated by `CardImporter.lua` at import time via a `GMNotes = "OPTCG_CARD=<json>"` payload on the spawned card (not applied directly — a card is still packed inside a `Deck` object at spawn time and can't be called into), picked up lazily by `Global.lua`'s `onObjectDropped` the first time that card is actually drawn/dropped onto the table, the same drop-triggered timing the DON!!/Power property already relies on.

Both properties share one `createButtons(t)` dispatcher (Encoder calls this fixed function name once per *enabled* property sharing a `funcOwner`, every button rebuild) — it clears buttons once per call and gates each property's block behind its own `APIobjIsPropEnabled` check, so either or both can be enabled independently on a card without stray/duplicate buttons.

The module chip object (GUID `b93b40`) used to carry its own duplicate copy of this entire registration/button-drawing flow (`EasyModule.lua`) — both scripts independently called `RegisterModule`/`CreateModuleChipButtons` on every load, a real double-registration race, not just stylistic duplication. That file is gone and the chip's `LuaScript` is intentionally left empty now; `Global.lua` drives it remotely via `GetModuleChip()` (GUID lookup) for everything. If you ever see that GUID's script non-empty again, something regressed — it isn't supposed to have one.

### `CardImporter.lua` (GUID `c055f4`)

Fetches card data from `https://optcgapi.com/api/` (no auth) and spawns a deck from a pasted decklist (`<qty>x<cardID>` lines, e.g. `4xOP16-064` — no header/comments, matching the user's own OPTCGSim `.deck` files). `CardLookup.GetCard(cardID)` is the only entry point anything should call for card data; it's backed by `CardLookup.cache`, keyed by card ID, persisted in this object's own `script_state`. Known gap: optcgapi.com currently stops at OP-17/EB-05, one set behind the user's local OPTCGSim install (which has OP-18) — a local-asset fallback would plug into `CardLookup.GetCard` as a second branch, not implemented yet.

The paste box and Import/Clear Cache/Close buttons live in a screen-space modal (`self.UI.setXmlTable`, TTS's per-object XML UI, toggled via `self.UI.setAttribute(PANEL_ID, "active", ...)`), not drawn onto the object's physical surface. That was the original design and it covered the entire card with `createInput`/`createButton`, leaving no exposed area to grab/move/delete the object — same UX bug matched against the inherited "rikrassen" importer (`scripts/objects/_b_rikrassen_s__b__MTG Deck_Draft_Cube Importer_*.lua`), which keeps one small `createButton` on the object to open its own modal. `CardImporter.lua`'s physical object now carries just that one small "OPEN IMPORTER" button.

**Widely-distributing this mod (e.g. a public Workshop upload) would need the cache to stop being per-save.** Right now `CardLookup.cache` only persists in one save's `script_state` — every independent subscriber starts cold, so load on optcgapi.com scales with total subscribers × distinct cards touched, not with total imports. Discussed but not implemented: bundle a periodically-refreshed static snapshot of known cards with the mod, with `CardLookup.GetCard` checking it before falling back to the live API — the same "second branch" seam already planned for the OP-18 gap above, just generalized. Revisit before any wide distribution, not needed at current (single-user) scale.

**Every card is fetched individually via `CardLookup.FetchCard`, never via a bulk `/sets/{set_id}/` call — this was measured, not guessed.** The original design bulk-fetched a whole set per distinct set touched by a decklist (fewer HTTP calls). Live-tested with the external-editor link (see "Live debugging link" above): TTS's native `JSON.decode()` blocked the game for 3-5 seconds per ~100KB bulk-set response — 8 such sets in one normal deck import caused 28+ seconds of cumulative freeze. Every per-card response (the API has no documented way to filter a bulk response down to just the needed cards) decoded in under 0.3s. If bulk fetching is ever reconsidered, re-measure against the live API first — this isn't a one-time fluke, it reproduced on every large set fetched.

Spawned cards carry their stats via `GMNotes = "OPTCG_CARD=<json>"`, not pushed into Encoder directly — a card is still packed inside a `Deck` object at spawn time and can't be called into. `Global.lua`'s `TryActivateCardStatsFromGMNotes` (called from `onObjectDropped`) picks the payload up the first time a card is actually drawn/dropped onto the table.

### `scripts/objects/`

Everything here is inherited from the MTG source mod and mostly unmodified — dice, generic counters, hand/turn trackers, the deck/card importers, Encoder itself, etc. Treat these as vendored library objects rather than OPTCG-specific code unless told otherwise.
