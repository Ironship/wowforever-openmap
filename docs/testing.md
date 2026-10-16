# In-game check (about 15 minutes)

Everything in OpenMap is first checked out of game with the preview renderer
(`tools/map-preview`), but some things only the game can show. Run through this before
a release, and after any change to `Map/Stitch.lua`, `Map/Close.lua` or the textures.

**Setup.** Link the `OpenMap` folder into `_classic_beta_\Interface\AddOns` (see the
README), turn off other world map addons, and **restart the game** (new or changed
textures aren't picked up by `/reload`). Turn on Lua errors: `/console scriptErrors 1`.

Write down anything odd, with `/openmap status` output, or use the map's own
"Report a problem" button.

## 1. It loads (1 min)
- [ ] No Lua error at login. With Leatrix Maps' "Unlock map frame", "Scale the map", "Use simple map frame" or "Show coordinates" on, one chat line names them; with Mapster or Magnify, one line says so.
- [ ] With other map addons on (Leatrix Maps, BetterMaps, High Fidelity World Map, HiddenMaps): on the stitched map only OpenMap's art shows (no satellite tiles, terrain, approach maps or their icons over or under it), opening the map and zooming aren't pulled elsewhere, the hover label shows OpenMap's zone levels, and there's one coordinates bar. On a dungeon map their maps show as usual.
- [ ] `/openmap status` after opening the map: a zone count around 40+, "stitched", and a memory figure.

## 2. The whole world (3 min)
- [ ] Open the map, scroll out to the whole world: one picture, no missing zones, no black or white blocks.
- [ ] The continent and sea names: sharp, in the map's font with a soft glow, staying put as you zoom; never two of one. Scroll in on the Great Sea: the whirlpool stays a while, then the sea keeps a soft paper texture and brown wave strokes along the coasts, with no giant blurred stripes.
- [ ] Drag across from Kalimdor to the Eastern Kingdoms: no stutter you'd notice. Note `/openmap status` memory before and after.
- [ ] Gilneas, round Orgrimmar, the rims of Stonetalon, Feralas and Silithus: Blizzard's own lighter terrain, no stray names, no hard edges. Southern Mount Hyjal and the rest: blank map paper, crisp coastlines, no repeating marks.
- [ ] Orgrimmar: from zoom ~3 the city fills in under Durotar's banner; zoomed in, the banner goes and the whole city shows, soft-edged.
- [ ] Elwynn into Redridge, Elwynn into Westfall: the zones meet through a soft strip, no doubled outlines.

## 3. Up close (3 min)
- [ ] Zoom all the way into Goldshire: the map softens with paper grain, and the minimap's buildings and ground show faintly. The map stays fully opaque: the game world must never show through it.
- [ ] Zoom into Blackrock Mountain or the Wailing Caverns entrance: the world blurs and the cave map surfaces, soft-edged, no stray strips or banner pieces.
- [ ] Dungeon entrances show their level range under the icon, coloured for your level (red/orange above you, green/grey below).
- [ ] Click the Wailing Caverns entrance: its dungeon map opens at once in the same window (hover the entrance first: no pause, no picture coming in late), with its bosses and, with Questie, its quests in the side panel. Scroll all the way out: the picture gets smaller, past its fit, and the map stays open. Right-click the map: back on the world exactly where you were. Back and Escape do the same.
- [ ] A dungeon of several floors (Shadowfang Keep, Scarlet Monastery): the side panel opens on its Floors tab (the first), showing each floor as a small picture with its name, the one shown edged in gold; click one: that floor (the arrows and the floor list agree). One-floor dungeons have no Floors tab.
- [ ] Click Blackrock Mountain's and Dire Maul's entrances: a list to pick from; Dire Maul - East opens on Warpwood Quarter, North on Gordok Commons, West on Capital Gardens. Scarlet Monastery's: its four wings to pick from, each opening on its own floor (Graveyard, Library, Armory, Cathedral).
- [ ] A WoW Forever dungeon with no map in the client (City of Dalaran, The Drowned City ...): its entrance opens the same view on a blank parchment page saying there's no map of it yet, with its side panel (bosses, quests, loot) as any other's.
- [ ] Forever's dungeons: City of Dalaran (Alterac Mountains), The Drowned City (Stranglethorn), Excavation Site: Wetlands, The Hall of Thanes (Ironforge), Ruins of Lordaeron (Undercity map) have an entrance icon where the portal is; click: their map if the client has one.
- [ ] `/openmap entrance Test` standing anywhere outdoors: a line like `"Test": [(0, -8840.6, 489.7)],` in chat.

- [ ] The menu's "Minimap detail from" slider: lower, and the minimap's detail mixes in further out; higher, only right up close. At 1x it shows on the whole-world view, and zooming in from there it gets sharper with no pop or jump in strength. "Minimap opacity" caps it at every zoom. Both greyed out with Minimap detail off. Watch the frame rate (debug overlay) zoomed out with it at 1x.

## 4. Icons and routes (2 min)
- [ ] Dungeon, boat and zeppelin icons; the zeppelin is a red-ballooned airship. Click one: it glides to the other end.
- [ ] OpenMap menu → Boat and zeppelin routes: faint dotted routes, Alliance blue, others red. Hover near one: it lights up with a tooltip.
- [ ] Flight masters: click two, the route and time show.

## 5. Getting around (3 min)
- [ ] Search box: type "gadg", click Gadgetzan → glides there with a marker. Type "deadm" → the Deadmines entrance.
- [ ] Find me button: glides to you.
- [ ] The menu's More tab, "Reopen map (choose one)": Center on player / Always remember / Remember while visible, only one ticked at a time (Options' "When reopening the map" is the same choice). A fresh install starts on Center on player; an existing "Reopen where you left off" on / off becomes Always remember / Center on player.
- [ ] Always remember: close and reopen for the same position and zoom, even after changing zones or moving outside the saved view. Remember while visible: cross a zone boundary while still inside the saved view and reopen for the same position and zoom; move outside that view (also within the same zone) and reopen for a view on you. Center on player: always open on you. Opening a quest's map still shows its zone.
- [ ] Pan away from the player, then middle-click the map: it centers on you at the same zoom. Left-click, right-click and Ctrl-click still work; dungeon maps behave as before.
- [ ] Ctrl-click the map: a map pin appears, followed (the navigation arrow), and its card opens: type a note, pick a colour, Enter. Ctrl-click somewhere else: a second pin, now the followed one; the first stays. Hover a pin: its note. Click it: Follow / Stop following, Delete. With TomTom on, the followed pin has a TomTom arrow, gone when you follow another or delete it.
- [ ] Menu → Pins: every pin; click one to go there, right-click for its card. Code: copy it, Import it on another character (or after deleting the pins): they're back. In a group with another OpenMap player: Share → Group on a pin; they're asked, and Add puts it on their map.
- [ ] In a group: party members show as class-coloured dots, also on zones the map isn't currently on.
- [ ] Drag the map's title bar: it moves. Drag the bottom-right corner, then the bottom-left one: it resizes, the other side staying put. `/reload`, reopen: same place and size. Maximize: the grips and drag bar go away; un-maximize: back where it was.

## 6. Settings and combat (2 min)
- [ ] Options → Look → Unexplored areas: Show / Darken / Hide each change the map at once. On Darken, unexplored land is much darker and greyer, a zone you haven't found at all is darkened whole from every zoom (no seam as you zoom into it), and the sea off its coasts is left alone. On Hide, unexplored parts of a zone are blank parchment; explore a new spot and it fills in without a reload.
- [ ] Open and close the map in combat, open the quest log from it, then leave combat: no "action blocked" message, and the action bars still work.
- [ ] The OpenMap menu's Quest log tile (and its favourite button): hides and shows the quest log beside the map; in combat it says it can't. Afterwards, open the map in combat: no "action blocked" message.
- [ ] The OpenMap button (its icon, no label) sits in the map's bottom-left corner in an action button's slot frame, its favourites (framed the same) folding out to its right and the menu opening above it; the coordinates are parchment labels in the bottom-right corner, left of the quest log button. `/openmap` opens the menu (and the map, if it's closed); the AddOns settings page's button too. Clicking it opens the menu; just outside the window's corner, the bottom-left resize grip still catches. The menu's frame matches the map window's; every row and tile has its icon (no green question marks).
- [ ] With "Buttons as edge tabs" on (the look tab): no button in the bottom-left corner; instead tabs inside the map's right edge (the quest log's left while it's open), low down, flat to it: the OpenMap tab (its logo filling it; lit while the menu's open, pulsing with news), an arrow over it, the favourites as smaller tabs above (lit while on). The arrow folds them and back; right-click one takes it off. A short window shows only as many as fit. Drag the OpenMap tab round the map's edge: it follows along the nearest edge, the tabs turned flat to it (top and bottom too), the favourites going the way with more room; `/reload`: it stays there. A click after a drag doesn't open the menu. On a dungeon's map its two tabs are on the right edge, past the rail when it's there too. The menu opens beside the OpenMap tab, toward the map's middle.
- [ ] With Questie: quest icons on the stitched map, including in the neighbouring zones and once the map has switched to a zone; the menu's "Questie icons" turns them off and on.
- [ ] HandyNotes / GatherMate / TomTom (if you use them): their icons show on the stitched map, neighbouring zones' too, and nothing errors.

- [ ] Full screen: the Quest log button and the arrow button in the corner show and hide the quest log over the map's right side; leaving full screen, the window is as it was (quest log beside the map if it was). Make the window tall: the quest log's background fills it, no line. Click a quest: its details reach the window's foot (the parchment behind the text, and the text, longer; Abandon / Share / Track at the bottom, no gap under them); at Blizzard's own size they look as before.
- [ ] Zoom in and out with the wheel, and drag the map, at the world and continent zooms: the
  continents' and seas' names keep their ink while the map moves, their soft light halo back a
  moment after it stops (no flicker when the map just opens).
- [ ] Zoom in and out over a quest's blue area (track a quest with one): the area stays on the map as it zooms.

- [ ] With a gamepad (Forever's gamepad mode on): open the map, move its cursor and zoom with the right stick, all the way in and out (a steady pace, about the cursor). The coordinates and the hover label follow the cursor. A over a zone zooms into it, X zooms out a map. Over the OpenMap button, a favourite or a dungeon icon its tooltip shows, and A presses it; open the menu, press a setting and the zoom slider.

## 7. The quill, the menu and the tray (3 min)
- [ ] The OpenMap menu: three tabs (On the map, Look, More) in the game's own tab art; the checkboxes and sliders look like the game's options panel's; the second column fits inside the frame. The Look tab has the sliders and Defaults; the menu remembers the tab.
- [ ] Menu → Quill (or `/openmap draw`): the tray at the top. Draw with the quill, a line, an arrow, a ring; set down a raid mark (right-click its button for another); each ink and nib. Ctrl-Z undoes, the eraser takes a drawing off, Clear (twice) takes all. Right-drag pans, the wheel zooms, Escape puts it down. The drawings stay through zoom and pan and after `/reload`.
- [ ] A map pin's card → Draw: what's drawn now is the pin's; the Pins list says "(drawing)"; delete the pin: its drawing goes too.
- [ ] Beside the OpenMap button: an arrow that folds the favourites away and back (the coordinates' pills follow). A character with no favourites before starts with Find me, Drop a pin and the Quill.
- [ ] What's new: laid out like the quest log: the versions on the left (each with its date and how many changes, the newest picked, a gold bar), the picked one's notes on a quest's parchment on the right, in dark ink that reads easily, no boxes where an arrow was. Click a version: its notes; Newer and Older step through them (greyed at the ends). The credit line and the GitHub link at the foot; click the link box, Ctrl-C copies it. On a small screen it shrinks to fit.

## 8. Report a problem and map notes (2 min)
- [ ] Tools → Map notes: paint an area, type a note, Enter. Click on the map for a note at a point; Shift-drag adds to the last one; click a note to edit it. List: click a note, the map glides there. Export: the text copies with Ctrl-C. Done hides it all.
- [ ] Tools → Debug overlay: the frame rate and a moving graph in the map's top-right corner; zooming shows the costs change.
- [ ] The report button: the quill's tray opens titled Report a problem, in red ink; draw something (pen, an arrow, a circle), Next, type a note, copy the code. Your own drawings stay as they were (the report's aren't kept). Paste the code into `tools/map-preview/report.py`: the render shows what you drew in the right place. On a dungeon's map: its bar over the picture, a left-drag draws red lines, a right-drag pans (a right-click doesn't leave); change floors and draw there too; Next: the render shows each floor's picture with its lines. Escape or Cancel: no report.
