# OpenMap changelog

## Unreleased

- "When reopening the map" replaces "Reopen where you left off" with one choice:
  center on the player, always restore the previous view (even after changing zones), or restore
  it only while the player is still in view (including across zone boundaries).
  The previous same-zone setting becomes "Always remember"; disabled restoration
  stays player-centered. With "Remember while visible", leaving the saved view
  opens the map on the player.
- Middle-click the map to center on the player without changing the current zoom.

## v0.3.0-beta (2026-10-14)

- "Minimap detail from" (a slider in the menu, under Deepest zoom, and in Options' Up close) sets how
  far in the minimap's detail starts to mix in: lower comes in sooner, higher later (20x by default);
  at 1x it's there from the whole world. Further out than the game's own minimap tiles can be
  drawn, smaller copies of them show, crossfading to the tiles as you zoom in. (New textures:
  restart the game.)
- "Minimap opacity" (in the menu too, and Options' "Minimap detail, most opacity"): the most the
  minimap's detail ever shows, at any zoom.
- More coastal and border detail: each zone map now shows everything it paints
  round its own land (the sea off its coasts with its shallows, hatching and islets, the
  mountains and coasts beyond its border), shared out with its neighbours so each place shows
  one painting, handing over smoothly at the maps' frames. Land no map paints is plain
  parchment, which the art fades into, instead of the neighbours' edges blurred across it.
  The zone maps' sea names, their names for the neighbouring zones and their compass roses
  are left out. (Changed textures: restart the game.)
- Improved compatibility with other map addons: they work alongside OpenMap instead of fighting
  it. On the stitched map the art and the view are OpenMap's, and the rest of theirs keeps working;
  their map art shows on dungeon maps as before. At login OpenMap names only the options that
  still clash, not the whole addon.
- Gamepad: on the stitched map the right stick zooms at a steady pace all the way in and out
  (it crawled zoomed in), about the gamepad's cursor; A zooms into the zone under the cursor and
  X out a map, as clicks do, instead of changing the map underneath; the coordinates, the hover
  label, the zone highlight and the boat routes follow the gamepad's cursor. Its cursor shows
  the tooltips of OpenMap's buttons and map icons, and A presses them: the OpenMap button, the
  favourites, the menu (a slider goes to the value under the cursor), the dungeon, flight and
  other icons.
- "Fade unexplored areas" is now "Darken unexplored areas": the land you haven't explored is much
  darker and greyer, instead of faded toward the parchment, and a zone you haven't found at all is
  darkened whole from every zoom, the whole world's too, with the mountains and land round it, so a
  stretch you haven't been to is dark from one zone to the next. Only land is darkened, not the
  sea the zone maps paint round their coasts. (New textures: restart the game.)
- Panning and zooming make far less Lua garbage (OpenMap's view and zoom updates reuse their
  tables instead of making new ones every frame), so the game has less to clear up as you use the map.
- Clicking a quest in the quest log that's in another zone opens it again: the map goes to the
  quest's zone and stays there. It flickered and went back to the list, because the map was put
  back where you'd last closed it. Reopening where you left off now only applies when you open the
  map, not when Blizzard changes the map while it's open (the quest log, the zone dropdown), and
  not when the map opens on a quest's zone from the quest tracker.
- A quest's details in the quest log reach the foot of a window taller than Blizzard's, with more
  room for the quest's text, instead of stopping short with an empty strip under the buttons.
- The OpenMap button is its icon alone, right in the map's bottom-left corner.
- Zoomed in, only the tiles of each zone near the view are drawn and loaded, not every tile of
  every zone it touches, and panning works out what to show only now and then instead of every
  frame (the sea and the paper grain stay put as you pan, too). Less for the game to draw and lay
  out as you move about.
- The zones' art is baked into world tiles (made by a script from Blizzard's map art, as the map
  draws it), so from the continents' zoom in to a zone the map draws a few dozen tiles instead of
  hundreds of masked textures; closer in than the tiles' own pixels, the zones' art is drawn live
  as before. Changing the colour match, or hiding unexplored areas, uses the live art throughout.
  (New textures, 69 MB: restart the game.)
- The continents' and seas' names cost far less to pan and zoom: only those near the view are
  drawn, and their halo takes half as many font strings (each copy's shadow is the one opposite
  it), the same to look at. Panning over a continent with its names showing was a third of the
  map's frame time on a wide screen. While the map moves (zooming or panning) their halo rests
  (every letter is drawn again at its new size on each frame of a zoom, and laid out again on each
  of a pan, and the halo was eight of its nine), back as soon as the map stops.
- Questie's icons from the neighbouring zones are placed up to half the map's width round it,
  not a whole width: every icon on the map is laid out again on each frame of a pan or zoom (231
  of them cost 7 ms a frame on a wide screen). Those further off show once the map switches to
  their zone.
- Panning and zooming no longer lay out the thousands of zone textures that aren't showing (the
  live art the baked tiles stand in for, the tiles off the view): a hidden one lets go of its place
  on the map until it shows again. With vsync off on a wide screen, all of OpenMap's art cost 20 ms
  of a 41 ms panning frame, 8 of them in art nobody could see.
- Up close over Orgrimmar the minimap's detail is much fainter (15% at most, from 50%): the city's own
  plan, which comes in from further out than the other cities', leads there.
- OpenMap's icons (flight masters, dungeons, the player arrow ...) are on the map's view instead of
  its canvas: they keep their size on screen by themselves, instead of their layer being rescaled
  on every frame of a zoom (which laid every icon out again: 6.6 ms of a zooming frame).
- `/openmap bench` times the map where it's slow (still, panning and zooming, at several zooms, then
  with each part of it off in turn) and gives the results to copy into an issue.
- The OpenMap menu's close button is easier to hit, and Escape closes the menu.
- "Report a problem" isn't only about the map: circling a spot is optional (just click Next), it
  works on dungeon maps too, and the issue form says so.
- The debug overlay also shows what can pile up over a session: the UI's Lua memory and how fast it
  grows, the map's pins (every addon's, and the kind there's most of), how much zone art is loaded,
  how many regions are placed live, which parts make the most Lua garbage a second (rescaling
  every addon's pins, switching maps, OpenMap's own updates), and which addons hold the most
  memory and grow it fastest.

## v0.2.0-beta (2026-10-11)

- Map notes (Tools → Map notes, `/openmap notes`) replace the paint tool: paint an area (or
  click) and say what's there, as a "fix this", "look into this" or "idea"; a list of them all
  (click one to go there) and Export, which gives them all as text to paste where they're needed.
  `tools/map-preview/notes.py` renders them out of game. Older paint mark-up becomes notes.
- A debug overlay (Tools → Debug overlay, `/openmap debug`): the frame rate on the map, a graph of
  frame times, the worst frame, and what OpenMap's own updates cost.
- The quest log shows on the full-screen map too: the Quest log button (and the arrow button in
  the corner, as on the windowed map) puts it over the map's right side. Its background no longer
  ends in a line when the window is taller than Blizzard's.
- Blizzard's quest areas (the blue shapes) keep up with the map as it zooms, instead of a step behind.
- The OpenMap button and the favourites' row are in the map's bottom-left corner, along its
  foot (over the coordinates when they show); favourites are icon buttons in Blizzard's
  action-button frame, glowing while they're on.
- The OpenMap menu is laid out afresh in the map window's own frame: the actions as tiles with
  icons, an icon by each setting, bronze rules between the parts. Find me, Drop a pin,
  Report a problem, Options and a new Quest log button (hide or show the quest log beside the
  map, out of combat) can be starred onto the map too.
- "Minimap detail" (in the menu's Up close and in Options) turns the minimap's detail off at
  the closest zoom, so the painted map is all you see.
- The deepest zoom is a slider in the menu, and goes to 192x (it was 96x at most).
- The window resizes from its bottom-left corner as well as the bottom-right, and both grips
  are easier to catch.
- Favourite settings: the star by each setting in the OpenMap menu puts it on the map as a
  button of its own, beside the OpenMap button (lit while it's on; click to switch it,
  right-click to take it off).
- The parchment border's edges are laid as copies of their piece at its own length, every other
  one mirrored, instead of one piece stretched along the whole side; the corners are as they were.
- Orgrimmar and Undercity keep their own maps' name banners: up close that's the city's title,
  and their zone's big banner for them (Durotar's, Tirisfal's) gives way to it as you zoom in,
  instead of covering the city. (Changed textures: restart the game.)
- No more straight-edged patches over the zones zoomed out (east of the Barrens, Stranglethorn ...):
  the blank paper in the gaps between zones reaches only a little way under the zones, not to
  the edge of the square it's drawn in. (Changed textures: restart the game.)
- The ocean past the world map keeps the world sea's own colours, carried outward, instead of
  one flat grey-green. (New texture: restart the game.)
- The OpenMap button stays in the map's top-left corner (an addon's frame across the map
  could push it off the right edge).
- Going full screen and back (or resizing the window) keeps the view you were looking at,
  instead of jumping to where the map was last closed.
- Resizing the window keeps its top-left corner (and the OpenMap menu) in place with the map
  size option off 100%, so the corner stays under the cursor; the resize grip sits in the
  window's outer corner, clear of the quest log button, and is easier to catch.
- Reopening a moved or resized map shows it in its place at once (not Blizzard's first).
- The menu's pin button works wherever you click (on Blizzard's map icons too, where only
  Ctrl-click did), with the pin cursor while it's on.
- On the stitched map the waypoint is always OpenMap's pin: Shift-clicking Blizzard's there was
  blocked ("only available to the Blizzard UI"). Shift-click OpenMap's to share it in chat.
- No more square patches and straight bands in the sea off Stranglethorn and Wetlands: the
  gap fill's borrowed paintings of the land between zones stay on land, and a zone's painted
  sea fades out well inside its frame. (New textures: restart the game.)
- Zone art fades in as it loads (zooming or panning fast onto new zones), instead of popping in.
- Over the major cities' own maps the minimap shows at half strength at most, so the city plan leads.
- "Dim unexplored areas" is now "Fade unexplored areas": those areas fade 60% of the way to the
  zone's blank parchment (its unexplored look) instead of darkening.
- Faster panning and zooming: map icons off the view (townsfolk, flight masters ...) are
  hidden, and blank tiles of the filled-in land aren't drawn.
- Opening the map loads only the zone art in view (and none until zone detail shows), instead
  of the whole world's; `/openmap status` shows how long the last openings took.
- Questie's icons stay on the map when it switches to a zone: Questie's map library places
  them from world coordinates that are off on Forever's zone and continent maps, so there
  each icon is placed (or moved) from Forever's own map positions. They're also lifted above the stitched art:
  Questie fixes its icons' frame levels, which put them under the zone art up close. `/openmap status`
  shows how many Questie icons there are and who placed them.
- The parchment border frames the map only when zoomed right out, fading as you zoom in.
- Blizzard's glow on the zone under the cursor is off by default on the stitched map
  ("Zone highlight on hover" in the menu brings it back).
- The map window's portrait is OpenMap's icon while the map is stitched; the OpenMap button
  sits beside Blizzard's floor dropdown instead of under it.
- Opening the map sets its view once (straight to where you left off), or not at all if
  it's still there, instead of Blizzard's reset to the whole world and back; the
  close-up softening no longer recolours the whole map when it first builds a zone.
- Zone art coming into view loads over a few frames instead of stalling one; `/openmap status`
  names the slowest steps of the close-up update, and how much of opening the map is OpenMap's.
- Undercity: Tirisfal's "Undercity" banner sits over the city until close in, as Orgrimmar's
  does. You can zoom 1.5x further in cities, and the minimap mixes in over the cities in the
  open. Undercity's and Ironforge's own maps are drawn over the minimap, which shows the
  surface there, wherever they are in the view.
- Blackrock Mountain's inside (its main floor) surfaces from further out as you zoom in on it.
- Cave and dungeon-entrance maps stay while they're on screen (they no longer fade as you pan
  away from them); only the dimming of the surface follows the one you're centred on.
- Undercity's map is cut to the city's plan (its quarters, the Ruins, the Sewers), so Tirisfal's
  painting shows round it instead of the city map's own parchment.
- "Fade while moving" (0-90%, in Options; on / off in the map's menu) replaces "Don't fade while
  moving": the map fades smoothly while you move, never while the mouse is over it.

## v0.1.0-beta (2026-10-09)

First public beta. One seamless world map for WoW Forever: every zone stitched
together, Blizzard's own art, with dungeon entrances and caves, flight paths,
boat and zeppelin routes, townsfolk and rares (with Questie), search, map pins,
group members, a movable and resizable window, and a "Report a problem" button.
The continent and sea names are lettered live; land Forever has no zone map for is
drawn from Blizzard's classic and pre-Cataclysm maps of it, or left as blank parchment.
