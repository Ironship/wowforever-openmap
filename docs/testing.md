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
- [ ] Click a dungeon entrance icon: it glides down into its cave (or opens the dungeon map).

- [ ] The menu's "Minimap detail from" slider: lower, and the minimap's detail mixes in further out; higher, only right up close. At 1x it shows on the whole-world view, and zooming in from there it gets sharper with no pop or jump in strength. "Minimap opacity" caps it at every zoom. Both greyed out with Minimap detail off. Watch the frame rate (debug overlay) zoomed out with it at 1x.

## 4. Icons and routes (2 min)
- [ ] Dungeon, boat and zeppelin icons; the zeppelin is a red-ballooned airship. Click one: it glides to the other end.
- [ ] OpenMap menu → Boat and zeppelin routes: faint dotted routes, Alliance blue, others red. Hover near one: it lights up with a tooltip.
- [ ] Flight masters: click two, the route and time show.

## 5. Getting around (3 min)
- [ ] Search box: type "gadg", click Gadgetzan → glides there with a marker. Type "deadm" → the Deadmines entrance.
- [ ] Find me button: glides to you.
- [ ] "When reopening the map" is one dropdown: Center on player / Always remember / Remember while visible. Only one can be selected. Existing enabled/disabled preferences become always remember / center on player.
- [ ] Always remember: close and reopen for the same position and zoom, even after changing zones or moving outside the saved view. Remember while visible: cross a zone boundary while still inside the saved view and reopen for the same position and zoom; move outside that view (also within the same zone) and reopen for a view on you. Center on player: always open on you. Opening a quest's map still shows its zone.
- [ ] Pan away from the player, then middle-click the map: it centers on you at the same zoom. Left-click, right-click and Ctrl-click still work; dungeon maps behave as before.
- [ ] Ctrl-click the map: a map pin appears (and the navigation arrow). Click the pin: it's gone. With TomTom on, Ctrl-click also adds a TomTom arrow.
- [ ] In a group: party members show as class-coloured dots, also on zones the map isn't currently on.
- [ ] Drag the map's title bar: it moves. Drag the bottom-right corner, then the bottom-left one: it resizes, the other side staying put. `/reload`, reopen: same place and size. Maximize: the grips and drag bar go away; un-maximize: back where it was.

## 6. Settings and combat (2 min)
- [ ] Options → Look → Unexplored areas: Show / Darken / Hide each change the map at once. On Darken, unexplored land is much darker and greyer, a zone you haven't found at all is darkened whole from every zoom (no seam as you zoom into it), and the sea off its coasts is left alone. On Hide, unexplored parts of a zone are blank parchment; explore a new spot and it fills in without a reload.
- [ ] Open and close the map in combat, open the quest log from it, then leave combat: no "action blocked" message, and the action bars still work.
- [ ] The OpenMap menu's Quest log tile (and its favourite button): hides and shows the quest log beside the map; in combat it says it can't. Afterwards, open the map in combat: no "action blocked" message.
- [ ] The OpenMap button (its icon, no label) sits right in the map's bottom-left corner (above the coordinates when they show), its favourites in a row beside it, clear of the quest log button. Clicking it opens the menu; just outside the window's corner, the bottom-left resize grip still catches. The menu's frame matches the map window's; every row and tile has its icon (no green question marks).
- [ ] With Questie: quest icons on the stitched map, including in the neighbouring zones and once the map has switched to a zone; the menu's "Questie icons" turns them off and on.
- [ ] HandyNotes / GatherMate / TomTom (if you use them): their icons still show on the zone the map is on, and nothing errors.

- [ ] Full screen: the Quest log button and the arrow button in the corner show and hide the quest log over the map's right side; leaving full screen, the window is as it was (quest log beside the map if it was). Make the window tall: the quest log's background fills it, no line. Click a quest: its details reach the window's foot (the parchment behind the text, and the text, longer; Abandon / Share / Track at the bottom, no gap under them); at Blizzard's own size they look as before.
- [ ] Zoom in and out with the wheel, and drag the map, at the world and continent zooms: the
  continents' and seas' names keep their ink while the map moves, their soft light halo back a
  moment after it stops (no flicker when the map just opens).
- [ ] Zoom in and out over a quest's blue area (track a quest with one): the area stays on the map as it zooms.

- [ ] With a gamepad (Forever's gamepad mode on): open the map, move its cursor and zoom with the right stick, all the way in and out (a steady pace, about the cursor). The coordinates and the hover label follow the cursor. A over a zone zooms into it, X zooms out a map. Over the OpenMap button, a favourite or a dungeon icon its tooltip shows, and A presses it; open the menu, press a setting and the zoom slider.

## 7. Report a problem and map notes (2 min)
- [ ] Tools → Map notes: paint an area, type a note, Enter. Click on the map for a note at a point; Shift-drag adds to the last one; click a note to edit it. List: click a note, the map glides there. Export: the text copies with Ctrl-C. Done hides it all.
- [ ] Tools → Debug overlay: the frame rate and a moving graph in the map's top-right corner; zooming shows the costs change.
- [ ] The report button: circle something, type a note, copy the code. Paste it into `tools/map-preview/report.py`: the render shows your circle in the right place.
