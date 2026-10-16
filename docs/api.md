# OpenMap for other addons

OpenMap works with most map addons without anything from them: icons other addons put on the
world map through HereBeDragons (Questie, TomTom, gatherers, notes addons) show on the stitched map
from every zone in view, not just the one the map is on, and Blizzard's own map icons keep working.

For more than that there is `OpenMapAPI`, a global table. Check it's there before using it:

```lua
local OM = OpenMapAPI
if OM and OM.major == 1 then
	-- ...
end
```

`OM.version` goes up when something is added. Nothing is changed or taken away without a new
`OM.major`. Everything is read-only or "add your own": nothing lets another addon change OpenMap's
settings. Functions return `nil` (or `false`) when the map hasn't been opened yet or the stitched
map isn't showing.

## Positions

- `u, v`: a point on OpenMap's stitched Azeroth, 0 to 1 across and down. (The same space as the
  in-game Report codes, `OM1|...`.)
- `x, y`: a point on a uiMap, 0 to 1, as Blizzard's map APIs use.

| Function | Returns |
| --- | --- |
| `OM.IsStitched()` | whether the world map shows OpenMap's stitched map now |
| `OM.WorldFromMap(uiMapID, x, y)` | `u, v`, or nil if that map isn't part of the stitched world |
| `OM.MapFromWorld(uiMapID, u, v)` | `x, y` on that map (outside 0..1 when the point is off it) |
| `OM.MapAt(u, v)` | the uiMapID of the zone (or city) at that point |
| `OM.GetView()` | the view's centre `u, v` and its zoom (1: the whole world fits) |
| `OM.ShowWorld(u, v [, zoom])` | glides the stitched map there; false if it isn't showing |

## Callbacks

CallbackHandler-1.0: `OM.RegisterCallback(self, event, method)`, `OM.UnregisterCallback(self, event)`,
`OM.UnregisterAllCallbacks(self)`.

| Event | Arguments |
| --- | --- |
| `OpenMap_StitchedChanged` | `stitched`: the map switched between OpenMap's and Blizzard's own |
| `OpenMap_ViewChanged` | `u, v, zoom`: the stitched view moved (a few times a second at most, and the last always) |
| `OpenMap_DungeonMapShown` | `info`: a dungeon's map is up (below) |
| `OpenMap_DungeonMapHidden` | none |

`info` is `{ mapID = uiMapID, instances = { { name, minLevel, maxLevel, raid, bosses = { name, ... } }, ... } }`
(`mapID` is nil when the client has no map of the dungeon: WoW Forever has none, so its card shows over
the world map when its entrance is clicked, and `OpenMap_DungeonMapShown` doesn't fire for it):
more than one instance when the map is shared (Dire Maul's wings). Bosses are the game's own list, in
its order.

## Adding your own

### A switch in OpenMap's menu

```lua
OM.RegisterMenuToggle("MyAddon", {
	id = "herbs",                       -- yours, stable (a starred switch is saved by it)
	label = "Herbs",
	get = function() return MyAddonDB.showHerbs end,
	set = function(on) MyAddonDB.showHerbs = on; MyAddon:Refresh() end,
	icon = "Interface\\Icons\\INV_Misc_Herb_07",   -- optional
	tab = "show",                       -- "show" (On the map), "look" or "more"; default "show"
	section = "My Addon",               -- the heading it sits under; default "Other addons"
})
```

It shows in that tab of the OpenMap menu and can be starred onto the map's button tray like
OpenMap's own. Registering the same `id` again replaces it.

### A section on a dungeon's map

```lua
OM.RegisterDungeonSection("MyLootAddon", function(info)
	local lines = {}
	for _, inst in ipairs(info.instances) do
		for _, boss in ipairs(inst.bosses) do lines[#lines + 1] = boss .. ": " .. MyLoot:Summary(boss) end
	end
	return "Loot", lines                -- a title and up to 40 lines; nil for nothing
end)
```

It's shown on the card OpenMap puts on a dungeon's map, after OpenMap's own bosses and quests,
whenever the card is filled. Keep it quick: it runs on the map's change. Pass `nil` as the function
to take it off.

Errors in your functions are reported (the game's error handler) and don't break the map.
