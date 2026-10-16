# OpenMap

**OpenMap is an open-source, seamless world map addon for WoW Forever that keeps the original Vanilla art style.** Zoom and pan across the whole world map with a truly open-source, community-built map addon.

Help us build it as a community into the best world map, while staying true to the classic spirit.

There are already a bunch of map addons for Forever, and some of them are great. What I couldn't find was one that's seamless (lets you zoom and pan through the entire world), open source, and keeps the map looking like Blizzard's original map.

OpenMap stitches every zone map into one continuous map. Scroll out of Elwynn and you're looking at Westfall, Duskwood and Redridge, then the whole continent, then the world. No more clicking in and right-clicking out between zones. It lives inside the normal world map, so your quest log, the map's buttons, Questie and the rest of the standard map work as intended.

## What it does

- **One seamless map.** Zoom from the whole world down to street level, toward your cursor. It uses the map art from the game files, with the game's minimap blended in for extra detail at the closest zoom, without breaking the map's look.
- **Zone borders that blend.** Neighbouring zones fade into each other, and the border mountains are colour-matched.
- **The whole map made visible.** Land Forever has no zone map for (Gilneas, the ridges round Orgrimmar, the mountains west of Searing Gorge, the edges of Stonetalon, Feralas, Silithus and more) is drawn from Blizzard's own classic and pre-Cataclysm maps of it, which ship with the game but the game doesn't show. Land no map ever drew is left as clean parchment, like an unfinished map.
- **Ocean and continent names rebuilt** so they zoom properly, lettered in the game's own map font.
- **Dungeon and raid entrances** with level ranges, coloured for your level. Click one and Blizzard's own map of that dungeon opens right in the map, every floor of it, with its bosses and (with Questie) its quests beside it. For loot, OpenMap recommends [NeedRoll](https://www.curseforge.com/wow/addons/needroll): every boss's drops, what you've collected and a wishlist.
- **Boats and zeppelins**: click one to jump to the other end, and see their routes.
- **Underground.** Zoom into a cave or a dungeon's entrance area and Blizzard's map of it appears.
- **Flight paths.** Learned ones in colour, the rest greyed out. Click two flight masters to see the route you'd fly and roughly how long it takes.
- **Getting around.** Search for a zone, city, dungeon or flight master; a "Find me" button (or middle-click the map); choose how the map reopens; party and raid members are shown across the whole map.
- **Map pins and drawing.** Ctrl-click for as many pins as you like, each with a note and a colour, followed with Blizzard's waypoint (and TomTom's); share them with your group, guild or a friend. Draw on the map with a pen, lines, arrows, circles and raid marks, on its own or on a pin.
- **Vendors, spirit healers and rares** (needs Questie): repair, innkeepers, trainers, bankers, auctioneers, stable masters, spirit healers and rare mobs. Questie's quest icons can be switched on or off from OpenMap's menu too. (Still working on performance here.)
- **A map that fits your screen.** No more black bars at the sides: resize the window to any shape, or go full screen and the map fills it.

Everything is in the **OpenMap** menu on the map (or type `/openmap`). OpenMap works alongside other map addons: on its seamless map the map art and the zoom are OpenMap's, and the rest of theirs keeps working (their icons too, from every zone in view). If one of their options still fights OpenMap's window, OpenMap names it at login. Addon authors: [docs/api.md](docs/api.md) has OpenMap's API.

## Original game art

Every map and icon OpenMap uses is Blizzard's own art, loaded from the game. The few textures the addon ships are cut or masked from Blizzard's map art (the sea, blank parchment, coastlines, the border) or are plain paper grain made from noise. The zone data, dungeon entrances and levels, boat routes and flight network come from the game's data files; zone level ranges come from the Warcraft Wiki, and townsfolk and spirit healers from Questie.

## Help build it

I'd love help making this the best map addon for Forever. Bug reports, ideas, code and fixes are all welcome. The map is tricky to get looking right everywhere, so even a screenshot of a spot that looks off really helps. There's a "Report a problem" button right on the map: draw on the spot (a dungeon's map too), add a note, and paste the code into a GitHub issue.

- [CONTRIBUTING.md](CONTRIBUTING.md): how to help, and what makes a change easy to review
- [docs/development.md](docs/development.md): setting up, the check loop, regenerating data, pitfalls
- [ARCHITECTURE.md](ARCHITECTURE.md): how the map works
- [docs/testing.md](docs/testing.md): the in-game check before a release; [docs/releasing.md](docs/releasing.md): publishing one
- [docs/maintaining.md](docs/maintaining.md): triage, reviews, repository settings
- [SECURITY.md](SECURITY.md): reporting security problems privately; [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

OpenMap is free and always will be. If you'd like to support it, you can buy me a coffee on [Ko-fi](https://ko-fi.com/jiforever).

## About Claude

I'm using Claude (Anthropic's AI) as a coding partner: it helps write and review code and helps me run the open-source side (reviewing pull requests and so on). It doesn't make any of the art or content. Everything you see on the map comes from Blizzard's game files.

## Early days

This is a first release, so expect rough edges. If something looks wrong, let me know with an issue here or the "Report a problem" button.

## Install (development)

Link the `OpenMap` folder into the game's AddOns folder. In PowerShell (as admin or with developer mode on), from the repo root:

```powershell
New-Item -ItemType SymbolicLink -Path "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\OpenMap" -Target "$PWD\OpenMap"
```

Restart the game after adding new texture files; `/reload` is enough for Lua changes.

## Licence

The code, data tables and tools are MIT, see [LICENSE](LICENSE). Bundled libraries keep their own licences (`OpenMap/LICENSES`). The map itself is Blizzard's: the zone and continent art is loaded from the game at run time, and the few textures OpenMap ships that are cut from that art (the sea, the blank paper, coastlines, masks) remain Blizzard's and aren't covered by the MIT licence. [OpenMap/Media/Textures/NOTICE.md](OpenMap/Media/Textures/NOTICE.md) lists them and the scripts that make them.
