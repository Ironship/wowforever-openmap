# OpenMap

**OpenMap is an open-source, seamless world map addon for WoW Forever that keeps the original Vanilla art style.** Zoom and pan across the whole world map with a truly open-source, community-built map addon.

The project is fully open source on [GitHub](https://github.com/jiforever/wowforever-openmap). Help us build it as a community into the best world map, while staying true to the classic spirit.

There are already a bunch of map addons for Forever, and some of them are great. What I couldn't find was one that's seamless (lets you zoom and pan through the entire world), open source, and keeps the map looking like Blizzard's original map.

OpenMap stitches every zone map into one continuous map. Scroll out of Elwynn and you're looking at Westfall, Duskwood and Redridge, then the whole continent, then the world. No more clicking in and right-clicking out between zones. It lives inside the normal world map, so your quest log, the map's buttons, Questie and the rest of the standard map work as intended.

## What it does

- **One seamless map.** Zoom from the whole world down to street level, toward your cursor. It uses the map art from the game files, with the game's minimap blended in for extra detail at the closest zoom, without breaking the map's look.
- **Zone borders that blend.** Neighbouring zones fade into each other, and the border mountains are colour-matched.
- **The whole map made visible.** Land Forever has no zone map for (Gilneas, the ridges round Orgrimmar, the mountains west of Searing Gorge, the edges of Stonetalon, Feralas, Silithus and more) is drawn from Blizzard's own classic and pre-Cataclysm maps of it, which ship with the game but the game doesn't show. Land no map ever drew is left as clean parchment, like an unfinished map.
- **Ocean and continent names rebuilt** so they zoom properly, lettered in the game's own map font.
- **Dungeon and raid entrances** with level ranges. **Boats and zeppelins**: click one to jump to the other end, and see their routes.
- **Underground.** Zoom into a cave or a dungeon's entrance area and Blizzard's map of it appears.
- **Flight paths.** Learned ones in colour, the rest greyed out. Click two flight masters to see the route you'd fly and roughly how long it takes.
- **Getting around.** Search for a zone, city, dungeon or flight master; a "Find me" button; Ctrl-click to drop a map pin (and a TomTom arrow, if you use it); the map reopens where you left it; party and raid members are shown across the whole map.
- **Vendors, spirit healers and rares** (needs Questie): repair, innkeepers, trainers, bankers, auctioneers, stable masters, spirit healers and rare mobs. Questie's quest icons can be switched on or off from OpenMap's menu too. (Still working on performance here.)
- **A map that fits your screen.** No more black bars at the sides: resize the window to any shape, or go full screen and the map fills it.

Everything is in the **OpenMap** menu on the map (or type `/openmap`). OpenMap works alongside other map addons: on its seamless map the map art and the zoom are OpenMap's, and the rest of theirs keeps working. If one of their options still fights OpenMap's window, OpenMap names it at login.

## Original game art

Every map and icon OpenMap uses is Blizzard's own art, loaded from the game. The few textures the addon ships are cut or masked from Blizzard's map art (the sea, blank parchment, coastlines, the border) or are plain paper grain made from noise. The zone data, dungeon entrances and levels, boat routes and flight network come from the game's data files; zone level ranges come from the Warcraft Wiki, and townsfolk and spirit healers from Questie.

## It's open source

The code lives on GitHub: **[jiforever/wowforever-openmap](https://github.com/jiforever/wowforever-openmap)**

I'd love help making this the best map addon for Forever. Bug reports, ideas, code and fixes are all welcome. The map is tricky to get looking right everywhere, so even a screenshot of a spot that looks off really helps. There's a "Report a problem" button right on the map: draw on the spot (a dungeon's map too), add a note, and paste the code into a GitHub issue.

## About Claude

I'm using Claude (Anthropic's AI) as a coding partner: it helps write and review code and helps me run the open-source side (reviewing pull requests and so on). It doesn't make any of the art or content. Everything you see on the map comes from Blizzard's game files.

## Early days

This is a first release, so expect rough edges. If something looks wrong, let me know on GitHub or with the "Report a problem" button.
