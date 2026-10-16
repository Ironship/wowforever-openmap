# Contributing to OpenMap

Thanks for helping. A few things make changes easy to review.

- **How to work on it**: [docs/development.md](docs/development.md) (set up, the change /
  check loop, regenerating data, pitfalls, performance rules).
- **How it works**: [ARCHITECTURE.md](ARCHITECTURE.md).
- **Using an AI coding assistant?** Point it at [AGENTS.md](AGENTS.md); its rules apply
  to the code it writes for you, and you're responsible for that code.
- **Be kind**: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). **Security problems**: report
  privately, see [SECURITY.md](SECURITY.md).

## Ground rules

- **Only contribute what you may license under MIT.** Don't copy code, data or
  art from addons that aren't openly licensed (for example Leatrix Maps or
  HiddenMaps, which are "all rights reserved"). Game facts (positions, level
  ranges) are fine; prefer generating them from the game's own tables
  (`tools/map-data`).
- **Generated files are generated.** Everything under `OpenMap/Data` except
  `Levels.lua` and `Labels.lua`, and everything in `OpenMap/Media/Textures`, comes from scripts in
  `tools/`. Change the script and regenerate; don't hand-edit the output.
  `Levels.lua` is entered by hand from the source named at its top: a correction
  needs a source too. `Labels.lua` is measured from the map art (see its top).
  Hand edits of Blizzard's art go in `art-edits/` (see its README).
- **Show blending changes with pictures.** `tools/map-preview/render.py` renders
  the stitched map out of game. Attach before / after renders to pull requests
  that touch how the map looks.

## Before a pull request

```bash
pip install lupa pillow numpy scipy
python tools/offline-test/run.py plain
python tools/offline-test/run.py secret
python tools/offline-test/lint.py
```

All three must pass (they also run on every pull request). They load the addon
in a stubbed client: they catch load errors, bad options and broken slash
commands, but not how the map looks or behaves. Check that in game.

## Triaging reports from players

Players report from the map itself (**Report a problem**): their issue carries a code
(`OM1|...`). Render exactly what they saw, what they drew and all (a dungeon map's report: that floor's picture):

```bash
python -P tools/map-preview/report.py <db2 dir> <texture cache> report.png "OM1|..."
```

## Reporting blending problems

Players: the "Report a problem" button on the map (draw where it's wrong, add a note, paste the
code into an issue). Contributors: `/openmap notes` (or the menu's Tools → Map notes) opens the
map notes tool: pick what a note is (fix this, look into this, an idea), paint the area on the
map (or just click) and say what's there; as many as you like, all over the map. **Export**
gives them all as text to paste into an issue; `tools/map-preview/notes.py` renders each note
at its place. They're also saved in `WTF/Account/<account>/SavedVariables/OpenMap.lua` after a
`/reload`.

Lag: `/openmap debug` shows the frame rate on the map, a graph of frame times (hitches are
spikes) and what OpenMap's own updates cost; a screenshot of it while it's slow helps.

## Code style

Tabs, short comments that say why, names that read like the surrounding code.
WoW runs Lua 5.1: watch for `a and f()` truncating `f`'s multiple returns, and
read values the client may keep secret through `ns.Safe`.
