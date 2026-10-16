# Map preview

Renders OpenMap's stitched world map out of game: the same maps, placements,
masks, fades and colour matching as `OpenMap/Map/Stitch.lua`, from the
client's own map tables and textures. Use it to check blending without logging in.

Needs Python with Pillow, numpy and scipy, and the Forever build's map tables
(`UiMap`, `UiMapAssignment`, `UiMapArt`, `UiMapArtTile`, `UiMapXMapArt` as CSV
from wago.tools for build 1.60.1.70245) in one folder. Textures are downloaded by
file ID into the cache folder on first use (about 1,600 files). With the game installed, set
`OPENMAP_WOW` to its folder (the one holding `Data` and `_classic_beta_`) and they're read from
the install instead (`tools/casc`), with wago.tools only for anything it doesn't have.

```bash
python -P tools/map-preview/render.py <db2 dir> <texture cache> <out dir> "world=0.5,0.5,1" "barrens=@Mulgore+The Barrens,8"
```

A view is `name=u,v,zoom` (centre on Azeroth's map, zoom 1 = the whole world) or
`name=@Zone Name,zoom` (`@A+B` centres between two zones). `--bake-territory`
first rewrites `Media/Textures/MapTerritory` (where each zone's base art shows:
its own land and a little past it, its painted sea off its coasts, the cities in
it, never past its own frame). Re-run `gapfill.py` after it: the gaps are what
the territories leave. `--bake-zone-land` (after it) rewrites
`Media/Textures/MapZoneLand`: each zone's territory without the sea its own art
paints, for darkening unexplored land and not the sea; and `MapZoneBorder`: each
zone's share of the land round it that's no zone's (border mountains, land between
zones), so a stretch of unexplored zones darkens as one.

`OPENMAP_UNEXPLORED="Westfall=all;Duskwood=half"` previews "Darken unexplored
areas": out of game nothing's known about what a player has explored, so it says
which zones to treat as never found (`all`) or half explored (`half`, every other
overlay piece).

`--bake-zones` rewrites `Media/Textures/MapZones` and `Data/ZoneArt.lua`: every zone's art as
`Stitch.lua` draws it at full detail (its layers, in its order, through its masks, at the default
colour settings), on the world in 512-px tiles (BLP, DXT5, mipmapped: `tools/map-textures/blp.py`),
which the map draws instead of the zones' hundreds of textures until the view passes the tiles'
own pixels. Re-run it after anything that changes the zones (the grade, the art edits, the
territories and edges, the banners, the gaps). `OPENMAP_BAKED=1` renders the zones from those
tiles, as the game draws them, to compare with a render of the live layers.

`--bake-land` rewrites `Media/Textures/MapLand/<continent>.tga` (the continents'
land masks). The edge fades and the parchment grain come from
`tools/map-textures/make.py`.

The other bakes, each a script here (run with the same `<db2 dir> <texture cache>`):

| Script | Writes |
| --- | --- |
| `sea.py` | the sea's paper and wave strokes, the coastal bands, the backdrop's land / sea masks |
| `sea_world.py` (after `sea.py`) | the continents' sea past the world map's edges, the sea's colour out there (the world sea's own, carried outward), and the world map's coastal hatching apart from its open sea |
| `gapfill.py` | the gaps: blank parchment where no zone paints, and Blizzard's classic maps of that land |
| `banners.py` | city banners cut from their zone's art (Orgrimmar on Durotar's) |
| `tone.py` | each zone's colour, for the close-up minimap's tint |
| `minimaplod.py` (after `tone.py`) | smaller copies of the minimap, for its detail from further out |

Two read what players and contributors send from the game:

| Script | Renders |
| --- | --- |
| `report.py <db2> <tex> <out.png> "OM1\|..."` | a "Report a problem" code: the view and what was drawn (a dungeon map's: its floors) |
| `notes.py <db2> <tex> <out dir> <notes.txt> [#id ...]` | the Map notes tool's export: each note at its place, its painted area and text, and an index (`notes.md`) |

