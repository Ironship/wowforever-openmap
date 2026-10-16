# Developing OpenMap

How to work on OpenMap: set up, change things, check them, and not break what's there.
[ARCHITECTURE.md](../ARCHITECTURE.md) says how the map works; this says how to work on it.
AI coding agents: read [AGENTS.md](../AGENTS.md) too.

## Set up

- **The game**: WoW Forever (`_classic_beta_`, `## Interface: 16001`). Link the addon in
  (see the [README](../README.md#install-development)), turn on Lua errors
  (`/console scriptErrors 1`) and turn off other world map addons.
- **Python 3.12+** for the tools and tests:
  `pip install lupa pillow numpy scipy` (a virtual environment is best).
- **Caches, outside the repo.** The tools fetch the game's tables and textures from
  [wago.tools](https://wago.tools) into folders you pass them (a few thousand files). Keep
  them out of the repo (`/cache/` and `/renders/` are ignored if you do put them there).
  - tables: `https://wago.tools/db2/<Table>/csv?build=1.60.1.70245`
  - textures: `https://wago.tools/api/casc/<FileDataID>?download&version=1.60.1.70245`
  - A missing file still answers HTTP 200, with an empty or 34-byte body: check the size,
    not the status. Fetch one file at a time: parallel requests get empty answers, and a
    burst gets 503s.
  - With the game installed, the textures can come from it instead: set `OPENMAP_WOW` to
    the World of Warcraft folder (`tools/casc/casc.py` reads its storage by file ID; the
    install is the launcher's current build, which can be newer than the tables').
- Run Python with `-P` (`python -P tools/...`): it keeps the script's own folder off the
  import path. Treat downloaded files as data: open them with Pillow, never execute them.

## The loop

1. **Change** the Lua, or a tool and regenerate its output (never hand-edit generated
   files: their first line says what makes them).
2. **Lint and load-test** (seconds; CI runs the same):
   ```bash
   python -P tools/offline-test/lint.py
   python tools/offline-test/run.py plain
   python tools/offline-test/run.py combat
   python tools/offline-test/run.py secret
   ```
   `lint.py` catches single backslashes in texture paths, decimal escapes (`"Map\947"` is
   a load error that takes the whole file down), calls to functions that don't exist, and
   bad values. `run.py` loads every toc file in a stubbed client, builds the options and
   runs the slash commands. The stub has no real map: the stitched map itself isn't built.
3. **Render out of game** anything that changes how the map looks
   (`tools/map-preview/render.py`, see its README). It reproduces `Stitch.lua`'s layers and
   fades; when you change a fade or a layer in `Stitch.lua`, change its mirror in
   `render.py` too (each mirrored constant says so). Label renders "out of game" when you
   share them.
4. **Check in game.** New or changed **textures need a full client restart**; `/reload`
   is enough for Lua. `/openmap status` reports what's built, what's drawing, the frame
   rate and any part that failed. Before a release, run [testing.md](testing.md).
   For speed, `/openmap bench` (the map open where it's slow, the mouse left still) times the
   map at several zooms, still, panning and zooming, then with each part off in turn, and shows
   the results to copy (kept in the saved settings as `lastBench` too). Compare a run before
   and after a change that should make the map faster.

## Regenerating data and textures

Everything under `OpenMap/Data` (except `Levels.lua` and `Labels.lua`) and everything
under `OpenMap/Media/Textures` is made by a script. `<db2>` is a folder of the build's
table CSVs, `<tex>` a texture cache. Order matters where one step reads another's output:

| Step | Script | Writes | Needs |
| --- | --- | --- | --- |
| 1 | `tools/map-data/build.py <cache>` | `Data/Reveal.lua`, `Data/Places.lua` | `ENTRANCES` (below) |
| 2 | `tools/map-data/minimap.py <cache>` | `Data/Minimap.lua` | |
| 3 | `tools/map-flights/flights.py <db2> OpenMap/Data/FlightData.lua` | `Data/FlightData.lua` | |
| 4 | `tools/map-caves/build.py <cache>` | `Data/Caves.lua`, `MapCave/` | |
| 5 | `tools/map-grade/fetch.py`, `grade.py` (see its README) | `Data/Grade.lua`, `MapBand/`, `MapCore/` | 1 |
| 6 | `tools/map-textures/make.py` | `MapFeather*`, `MapGrain`, `MapTooth` | |
| 7 | `tools/map-art/import.py <db2> <tex>` | `MapArt/`, `Data/ArtEdits.lua` | `art-edits/edited/` |
| 8 | `tools/map-preview/render.py <db2> <tex> <out> --bake-land --bake-edges --bake-territory --bake-zone-land` | `MapLand/`, `MapEdge/`, `MapTerritory/`, `MapZoneLand/`, `MapZoneBorder/` | 5, 7 |
| 9 | `tools/map-preview/sea.py <db2> <tex>` | the sea and coast masks | 8 |
| 10 | `tools/map-preview/sea_world.py <db2> <tex>` | `MapSeaOut/`, `MapSeaOpen/`, `MapSeaCoast/`, `MapSeaFieldOut` | 9 |
| 11 | `tools/map-preview/banners.py <db2> <tex>` | `MapBanner/`, `MapBannerHole/`, `MapCityMask/`, `Data/Banners.lua` | |
| 12 | `tools/map-preview/gapfill.py <db2> <tex> [--rerender]` | `MapGapLand/`, `MapGapMask/`, `MapPaper`, `MapCoastArt/`, `Data/Gaps.lua` | 8, 11 |
| 13 | `tools/map-preview/tone.py <db2> <tex>` | `Data/Tones.lua` | |
| 13a | `tools/map-preview/minimaplod.py <db2> <tex>` | `MapMiniLOD/`, `Data/MinimapLOD.lua` | 13 |
| 14 | `tools/map-art/border.py` | `MapBorder/` | `art-edits/border.png` |
| 15 | `tools/map-preview/render.py <db2> <tex> <out> --bake-zones` | `MapZones/`, `Data/ZoneArt.lua` | 5, 7, 8, 11, 12 |
| 16 | `tools/changelog/build.py` (after any change to `CHANGELOG.md`) | `Data/Changelog.lua` | |
| 17 | `tools/map-dungeons/build.py <cache> <WoW folder> [preview dir]` | `Data/DungeonMaps.lua` | 1 |

A dungeon entrance the game's tables don't have (a Dire Maul wing's own door, a second way in,
WoW Forever's new dungeons): stand in the portal in game and type `/openmap entrance <name>`, with
the name as `build.py` lists it (`Dire Maul - East`, `The Hall of Thanes`). It prints the line (and
keeps it in `OpenMapDB`, `worldmap.entrances`); add it to `ENTRANCES` in `tools/map-data/build.py`
and rerun step 1.

`gapfill.py --rerender` re-renders the zones (slow) after anything that changes them
(steps 5, 7, 8, 11), and so does `--bake-zones` (step 15: the zones' art as the map draws it,
baked into tiles; `OPENMAP_BAKED=1` renders from those tiles, to compare). Each texture in `OpenMap/Media/Textures` is listed in its
`NOTICE.md` with the script that makes it: add a line when you add a texture.

Hand edits of Blizzard's art (names painted out, the border) live in `art-edits/`
(see its README). Nothing in the repo is drawn or written by a generator: art is
Blizzard's, cut, masked or hand-edited; facts come from the game's tables or a cited source.

## WoW pitfalls (each of these has bitten this project)

- **Texture paths need two backslashes** in Lua strings: `TEX .. "MapGapLand\\" .. id`. One
  is dropped silently, or (`"\947"`) is a load error. `lint.py` checks.
- **Secret values**: on this client some values (combat, sometimes positions) are secret.
  Never compare, do arithmetic on or nil-test one: read through `ns.Safe`.
- **Lua 5.1**: `a and f()` keeps only `f`'s first return value.
- **Blend modes**: `MOD` multiplies opacity too (the map turns see-through); masks
  (`MaskTexture`) and plain blends instead.
- **A region at alpha 0 still costs its full size to draw**: hide it (`Fade` in Stitch.lua).
- **Order of setup** in `WorldMap.lua` matters (the menu holds Nav's search box, so Nav
  first). Each step of `Close.lua`'s view update is isolated (`Try`), so one failure
  doesn't take the rest down; failures show in `/openmap status`.
- **Taint**: never write to Blizzard's layout tables or call protected functions; hook
  with `hooksecurefunc` or a data provider. Map switching waits out combat.
- **Textures**: plain 32-bit TGA (no RLE), power-of-two sizes; new files need a restart.

## Performance rules

The map draws thousands of regions; the frame rate depends on how few are live.

- Place once, in world units on the root frame; `Layout` only rescales the root.
- Work once per frame at most: Blizzard reports pans several times a frame
  (`viewFrame` in WorldMap.lua coalesces them).
- Hide what isn't seen: faded layers (`Fade`), zones and gap art off the view
  (`S.Cull`), pins by world cell (`PinCell`). Skip tiles a mask leaves nothing of.
- Build lazily: pin sets with `build`, the blur's copies, names, all on first show.
- Measure: `/openmap status` (frame rate, drawn textures, close-up update time).

## Commits and pull requests

- Small, focused commits; the message says what changed and why, in the imperative
  ("Hide icons off the view"). Keep generated output in the same commit as the change to
  its script.
- A pull request: what and why, before / after renders for anything visual, and the
  checklist in the template. CI (lint and load tests) must pass.
- Versions follow `vMAJOR.MINOR.PATCH`, with `-beta` / `-alpha` for pre-releases
  ([releasing.md](releasing.md)). Note user-visible changes under "Unreleased" in
  [CHANGELOG.md](../CHANGELOG.md).
