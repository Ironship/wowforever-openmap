--------------------------------------------------------------------------------
-- World map art, stitched: every zone map on one canvas, so the map zooms out
-- of one zone into the next instead of switching maps.
--
-- Coordinates are "world units": the art pixels of Azeroth's map (947). Every
-- map is placed by C_Map.GetMapRectOnMap(map, 947). The art is built once;
-- Layout(host) re-places it in a host map's canvas units, so it can sit inside
-- Blizzard's map canvas whichever map that is showing.
--
-- Layers, bottom to top, and the zoom where each fades in (zoom 1 = the whole
-- world fits the view):
--   world art          always
--   continent art      CONT_FADE     (wide feathered edges hide its frame)
--   zone base art      DETAIL_FADE   (mostly blank parchment in this client; it
--                                     shows on its territory, MapTerritory: its
--                                     land and just past it, plus any land in its
--                                     rectangle, never sea; fills gaps between zones)
--   zone overlays      DETAIL_FADE   (exploration pieces cut to the zone's shape:
--                                     explored ones from the client, the rest from
--                                     ns.MapReveal; thin feather at the art edge)
--   zone interiors     DETAIL_FADE   (the overlays again through MapCore, from just
--                                     inside each outline: every zone's land sits
--                                     over its neighbours' parchment halos)
--   cities             CITY_FADE x the zoom where the city fills the view (no
--                                     overlays of their own: base art, round
--                                     feather, so its dull surroundings drop away)
--   icons              per kind      (ns.MapPlaces, flights, townsfolk ...)
-- World / continent art mutes once zones cover it, fading to a hint over a sea
-- in the map art's own water colour, so gaps read as sea, not as blurry letters.
-- The sea keeps Blizzard's texture (S.SetSea): the open sea's mottled paper
-- (MapSea) and the coastal wave strokes (MapHatch, on each continent's coastal
-- band, MapCoast), both cut from the continent art and tiled at its own scale,
-- then in finer octaves as you close in, so more strokes come in with the zoom.
-- Its land stays land (PlaceLand: MapLand mask, parchment tint and grain), so
-- regions with no zone map (Quel'Thalas, Gilneas ...) meet the zones as land.
-- Each zone's art reaches as far as Blizzard painted it (MapTerritory): its own land, the
-- sea off its coasts (Blizzard's hatching and islets there, not ours), and the land round
-- it no zone owns, shared with the neighbours that paint it too. Land no zone paints
-- (ns.MapGaps) is the zone maps' own blank paper (MapPaper through MapGapLand), which
-- their art fades into at its frame; it fades in with the zones.
-- Colour matching: each zone's art is drawn a second time, tinted toward a
-- shared palette (ns.MapGrade), through a mask of its border band
-- (Media/Textures/MapBand/<uiMapID>): full strength at the zone's outline,
-- fading inward, so borders and mountains hand over smoothly while the zone's
-- own colours stay inside it.
--------------------------------------------------------------------------------

local _, ns = ...

local S = {}
ns.MapStitch = S

local WORLD = 947
S.WORLD = WORLD

local CONT_FADE = { 1.3, 2.2 }  -- zoom where each layer starts / finishes fading in
local CONT_IN, WORLD_OUT = { 1.3, 1.7 }, { 1.7, 2.2 }   -- (the continents come in fully, then the world art's land under them goes)
local LABELS_OUT = { 3, 4 }     -- the continents' names go as the zones (with their own names) come in
local SEA_LABELS_OUT = { 3.5, 5 } -- ... and the seas' a little after (nothing comes in over them)
local WORLD_SEA_OUT = { 4, 7 }  -- the world art's sea (the whirlpool, the ship ...) stays the ocean until well in (its
                                --  lettering is hand-cleaned: tools/map-art); the sea texture takes over after
local WORLD_COAST_OUT = { 3, 5 } -- ... but off the coasts, where its hatching would grow huge, much sooner
local DETAIL_FADE = { 3, 4.5 } -- (late: the continent art, all of a piece, carries the mid zooms)
local DETAIL_HINT = { 1.8, 3, 0.3 }   -- ... after a hint of it from further out: where, and how strong
local CITY_FADE = { 0.2, 0.4 }  -- (cities: share of the zoom where they fill the view: their own map takes over
                                --  from the zone's painting of them once they fill a fifth to two fifths of it,
                                --  big enough for its labels to read)
local CITY_FADE_OF = {          -- ... sooner where the zone paints it as no more than a blur
	[1454] = { 0.08, 0.25 },    --  (Orgrimmar, on Durotar's: a long fade, over its zone's painting of it)
	[1456] = { 0.08, 0.25 },    --  (Thunder Bluff, on Mulgore's: in before its zone's banner for it goes)
}
local BANNER_OUT = { 0.25, 0.4 } -- ... and where the zone's banner for a city that keeps its own (ns.MapCityTitles)
                                --  gives way to it: once that reads (tools/map-preview/render.py mirrors it)
local UNDERGROUND_CITIES ={ [1458] = true, [1455] = true }   -- Undercity, Ironforge: the minimap there
                                -- shows the surface, so their own map is drawn above it (and it's kept off them)
local MUTE_FADE = { 4, 7 }      -- ... and where the world / continent art mutes
local SEA_FADE = { 1.2, 1.9 }   -- ... and where it goes from over the sea (its big sea lettering), the sea's own texture taking over
local UNDISCOVERED = { 0.05, 0.06, 0.08, 0.62 }   -- unexplored land, shaded ("dim"): darker and greyer, over the
                                --  zones' art and the close-up minimap (a plain blend: the map stays opaque)
local SEA = { 0.50, 0.49, 0.41 } -- the sea's colour where no map paints one (MapSeaField covers the rest)
local LAND_TINT, LAND_DESAT = { 0.96, 0.92, 0.84 }, 0.25   -- unmapped land, toward the zone art's parchment
local GRAIN_TILE = 14           -- world units per parchment grain tile
local GRAIN_OCTAVES = { { 1, 0, 0.55 }, { 2.618, 0.37, 0.5 } }   -- { size x, offset (tiles), strength }
local BACK_MUTE = 0.92          -- how far the world / continent art fades as it mutes
local SEA_REACH = 1.5            -- how far past the world art the sea runs (world widths, each side)
local SEA_TILE = 128            -- the sea paper's tile, in continent-art pixels (tools/map-preview/sea.py)
local HATCH_W, HATCH_H = 34, 84 -- ... the wave strokes' tile
local SEA_OCTAVE, HATCH_OCTAVE = 4, 7     -- zoom where each starts halving, to keep its size on screen
local HATCH_ALPHA = 0.6

local TEX = ns.Media.path .. "Textures\\"
local FEATHER, FEATHER_THIN, FEATHER_WIDE = TEX .. "MapFeather", TEX .. "MapFeatherThin", TEX .. "MapFeatherWide"
local FEATHER_ROUND = TEX .. "MapFeatherRound"
local LAND, GRAIN = TEX .. "MapLand\\", TEX .. "MapGrain"
local BAND, TERRITORY, CORE = TEX .. "MapBand\\", TEX .. "MapTerritory\\", TEX .. "MapCore\\"
local ZONELAND = TEX .. "MapZoneLand\\"   -- (each zone's land without its painted sea: render.py --bake-zone-land)
local EDGE = TEX .. "MapEdge\\"     -- each zone's own frame, measured (tools/map-preview/render.py --bake-edges)
local SEA_DARK, SEA_LIGHT, SEA_FIELD = TEX .. "MapSeaDark", TEX .. "MapSeaLight", TEX .. "MapSeaField\\"
local SEA_FIELD_OUT = TEX .. "MapSeaFieldOut"   -- (the world's sea colour carried out past it: sea_world.py)
local HATCH, COAST = TEX .. "MapHatch", TEX .. "MapCoast\\"
local PAPER_LAYERS = { { 1, 0, 1 }, { 2.618, 0.41, 0.5 } }   -- the gap paper: { size x, offset (tiles), alpha }
local SEA_MASK = TEX .. "MapSeaMask\\"
local SEA_OUT = TEX .. "MapSeaOut\\"   -- (each continent's open sea past the world art's edges: tools/map-preview/sea_world.py)
local SEA_OPEN, SEA_COAST = TEX .. "MapSeaOpen\\947", TEX .. "MapSeaCoast\\947"   -- (the world art's sea, apart from / off its coasts: the same)
local GAP_LAND, PAPER = TEX .. "MapGapLand\\", TEX .. "MapPaper"
local W, H                      -- the world map's art size (world units)
local namesFrame                -- (the names' lettering: Letter, below)
local labelsRoot, names = nil, {}   -- the lettered names (ns.MapLabels): { frame, label }, built when first shown
local root, contRoot, tilesRoot, overlayRoot, coreRoot, blurRoot, citiesRoot, shadeRoot, pinRoot, arrow
local placed = {}               -- every region: { region, x, y, w, h } in world units
local graded = {}               -- zone art: { tex, mapID, piece } (piece: its overlay piece, or false for base art)
local twins = {}                -- its colour-matched copies, same shape
local zoneTex = {}              -- mapID -> its graded and twin entries (shown / hidden with the zone)
local inView = {}               -- mapID -> whether the zone is near the view (S.Cull)
local detailLive = false        -- whether the zone detail is drawn at all (zoomed in far enough)
local ShowZone, GradeEntry      -- (below)
local gradeNow = { 1, 0, "show" }   -- ApplyGrade's settings
local culled = {}               -- other regions shown only near the view: { region, l, t, r, b } (normalized)
local backdrop = {}             -- world / continent art textures (over land)
local backdropSea = {}          -- ... the same art over the sea (MapSeaMask), gone sooner
local worldArt = {}             -- which of those are the world map's (it hands over to the continents')
local worldCoast = {}           -- the world art's sea off the coasts (its hatching): gone before its open sea
local landFill = {}             -- the continents' land kept as land (art copy + grain), shown as the backdrop mutes
local gapFill = {}              -- the gap-fill tiles (they fade in with the zone detail)
local seaPaper = {}             -- the sea paper's mottling: two octaves, dark and light each
local hatches = {}              -- per continent: { l, r, t, b, k (world units per art px), tex = { two octaves } }
local pins = {}
local cities = {}               -- { frame, zoom where it fills the view (roughly) }
local rects = {}                -- mapID -> { l, r, t, b } on the world, or false
local host = { l = 0, t = 0, k = 1 }   -- the host map: its corner (world units) and units per world unit
local zoomNow, scaleNow, muted, seaNow, worldOut, worldSea, worldCoastOut = 1, 1, -1, -1, -1, -1, -1
local detailNow, softNow = 1, 0   -- the zone detail's zoom fade; the blur's amount
local underNow = 0              -- how far a cave has surfaced (Close.lua)

-- a region faded to `a`, and hidden once it's gone (drawn at alpha 0, a layer still costs
-- its full size in fill; most of these are the size of the world, many masked)
-- (only when it changes: these layers hold thousands of textures, and S.SetZoom runs several
-- times as the map opens)
local function Fade(region, a)
	if region.omFade == a then return end
	region.omFade = a
	region:SetAlpha(a)
	region:SetShown(a > 0.003)
end

-- The zones' art baked into world tiles (ns.MapZoneArt, render.py --bake-zones): at the settings it
-- was baked at, drawn in place of the live zone layers (tilesRoot, overlayRoot, coreRoot: hundreds of
-- masked textures in view) until the view is past the tiles' own pixels, then handing over to them
-- (FADE: screen px per tile px). `live`: the live layers' share now (0: the tiles alone, 1: live alone).
-- (One table: the file is near Lua's limit of 200 locals)
-- The handover is the same art over the same art: the live layers come on (at full) under the tiles a
-- little before it (WARM, of FADE's start: their files load meanwhile) and the tiles fade off them; and
-- while their files are still coming in (busy) the tiles stay (holding), or the zones' plain parchment,
-- the first of their files to arrive, showed for a moment between the two
local Baked = { FADE = { 1.2, 1.6 }, WARM = 0.85, tiles = {}, use = false, live = 1, warm = false, busy = false, holding = false,
	path = TEX .. "MapZones\\" }

-- The live zone layers' regions (tilesRoot, overlayRoot, coreRoot: thousands of textures and their
-- masks) are anchored only while they can show. Every region is placed on root, and each frame of a
-- pan or zoom the game lays out again everything anchored to it, hidden or not: thousands of hidden
-- textures cost as much as the art on screen. masks: mapID -> its masks' records in those layers;
-- placed: mapID -> whether they're anchored now; seen: whether the zone detail shows at all
local Live = { masks = {}, placed = {}, seen = false }
function Live.Under(f)
	while f do
		if f == tilesRoot or f == overlayRoot or f == coreRoot then return true end
		f = f:GetParent()
	end
	return false
end

-- the zone detail layers' alpha: the zoom fade, less the softening and underground
local appliedDetail, appliedSoft
local function ApplyDetail()
	local d = detailNow * (1 - 0.75 * underNow)
	if blurRoot and softNow ~= appliedSoft then
		appliedSoft = softNow
		Fade(blurRoot, d * softNow)
	end
	local live = Baked.use and Baked.live or 1
	local warm = Baked.use and Baked.warm or false
	local key = live + (warm and 2 or 0) + (Baked.holding and 4 or 0)
	if d == appliedDetail and key == Baked.applied then return end
	appliedDetail, Baked.applied = d, key
	-- (the live layers at full under the tiles, from just before the handover: Baked, above)
	local on, seen = d > 0.001 and (live > 0 or warm), d > 0.001
	local dl = on and d or 0
	if on ~= detailLive or seen ~= Live.seen then   -- (zones' files load once their detail first shows; the live
		detailLive, Live.seen = on, seen             --  layers' regions are anchored while they show, ShowZone)
		for mapID in pairs(zoneTex) do
			if inView[mapID] == true then ShowZone(mapID) end
		end
		Baked.holding = on and Baked.use and Baked.busy or false
	end
	tilesRoot:SetShown(on)
	overlayRoot:SetShown(on)
	tilesRoot:SetAlpha(dl)
	for _, tex in ipairs(gapFill) do tex:SetAlpha(d) end
	overlayRoot:SetAlpha(dl)
	-- the interiors (a second copy of every zone's overlays) only with the zones proper:
	-- under the faint hint from further out they'd hardly show, over both continents at once
	Fade(coreRoot, on and math.max(0, (d - DETAIL_HINT[3]) / (1 - DETAIL_HINT[3])) or 0)
	if blurRoot then Fade(blurRoot, d * softNow) end
	if Baked.frame then
		-- (the live layers stack: a zone's base art and its overlays, each at d, cover 1 - (1 - d)^2 of
		-- what's under them; the tiles are all of them in one, so they're drawn that strong)
		local gone = Baked.holding and 0 or live
		Fade(Baked.frame, math.floor((1 - (1 - d) ^ 2) * (1 - gone) * 100 + 0.5) / 100)
		Baked.Cull()
	end
end
S.stats = { zones = 0, tiles = 0, overlays = 0, pins = 0, cities = {} }
S.viewHooks = {}                -- fn(u, v, hu, hv, zoom) on every pan / zoom (Close.lua's S.SetView calls them)

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

-- a map's rectangle on the world (normalized), cached; nil when it isn't on it
function S.Rect(mapID)
	local r = rects[mapID]
	if r == nil then
		if mapID == WORLD then
			r = { 0, 1, 0, 1 }
		else
			local ok, l, rr, t, b = pcall(C_Map.GetMapRectOnMap, mapID, WORLD)
			r = (ok and l and rr > l and b > t) and { l, rr, t, b } or false
		end
		rects[mapID] = r
	end
	if r then return r[1], r[2], r[3], r[4] end
end

function S.Size() return W, H end

-- the map's art size (its canvas units)
local function ArtSize(mapID)
	local layers = C_Map.GetMapArtLayers(mapID)
	local layer = layers and layers[1]
	if layer then return layer.layerWidth, layer.layerHeight, layer end
end
S.ArtSize = ArtSize

-- deepest zone / continent under a world point (normalized), with the chain
-- from the world down: { 947, continent, zone }
function S.ChainAt(u, v)
	local chain = { WORLD }
	local mapID, x, y = WORLD, u, v
	for _ = 1, 4 do
		local info = C_Map.GetMapInfoAtPosition(mapID, x, y)
		if not info or info.mapID == mapID then break end
		if info.mapType ~= Enum.UIMapType.Continent and info.mapType ~= Enum.UIMapType.Zone then break end
		local l, r, t, b = C_Map.GetMapRectOnMap(info.mapID, mapID)
		if not l or r <= l or b <= t then break end
		mapID, x, y = info.mapID, (x - l) / (r - l), (y - t) / (b - t)
		tinsert(chain, mapID)
	end
	return chain
end

--------------------------------------------------------------------------------
-- Placing art (in world units; Layout anchors it)
--------------------------------------------------------------------------------

local function Pow2(n)
	local p = 16
	while p < n do p = p * 2 end
	return p
end

-- a map's art tiles (file IDs, row-major): the client's, with any hand-cleaned tiles
-- (ns.MapArtEdits, tools/map-art) in their place
local function ArtFiles(mapID)
	local files = C_Map.GetMapArtLayerTextures(mapID, 1)
	local edits = ns.MapArtEdits and ns.MapArtEdits[mapID]
	if not files or not edits then return files end
	local out = {}
	for i, f in ipairs(files) do out[i] = f end
	for _, i in ipairs(edits) do out[i] = TEX .. "MapArt\\" .. mapID .. "_" .. i end
	return out
end

local PlaceRecord, ForEachPiece
local function Record(region, x, y, w, h)
	-- a region in a shifted frame (the blur's copies) hangs from that frame
	local parent = region:GetParent()
	local rec = { region, x, y, w, h, rel = parent and parent.omShift and parent or nil }
	placed[#placed + 1] = rec
	region.omRec = rec
	PlaceRecord(rec)
end

-- A map's art rectangle in world units: left, top, x scale, y scale
local function Place(mapID)
	local aw, ah, layer = ArtSize(mapID)
	local l, r, t, b = S.Rect(mapID)
	if not aw or not l then return end
	return { left = l * W, top = t * H, sx = (r - l) * W / aw, sy = (b - t) * H / ah, layer = layer, mapID = mapID }
end

-- a mask over a map's whole art (edges faded, or a zone's border band)
local function Feather(parent, p, file)
	local mask = parent:CreateMaskTexture()
	mask:SetTexture(file, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	Record(mask, p.left, p.top, p.layer.layerWidth * p.sx, p.layer.layerHeight * p.sy)
	if p.mapID and Live.Under(parent) then         -- (a live layer's: anchored while the zone's art can show)
		local list = Live.masks[p.mapID] or {}
		Live.masks[p.mapID] = list
		list[#list + 1] = mask.omRec
	end
	return mask
end

-- An image w x h at (x, y) in a map's art, cut into tiles (row-major file IDs).
-- Base tiles are full tw x th files cropped at the art's edge; overlay edge
-- tiles are the next power of two. `mask2`: a second mask on the tiles;
-- `band`: also draw a colour-matched copy through this mask.
-- a zone's overlay art is drawn without its banner for a city (ns.MapBannerHoles): Stitch's
-- copy of the banner shows instead, and goes once you're close (S.SetZoom)
local holeMasks = {}
local function BannerHole(parent, p)
	if not (p.mapID and ns.MapBannerHoles and ns.MapBannerHoles[p.mapID]) then return end
	local key = tostring(parent) .. p.mapID
	holeMasks[key] = holeMasks[key] or Feather(parent, p, TEX .. "MapBannerHole\\" .. p.mapID)
	return holeMasks[key]
end

local function PlaceTiles(parent, p, files, x, y, w, h, drawLayer, sub, overlay, mask, list, piece, band, mask2)
	local tw, th = p.layer.tileWidth, p.layer.tileHeight
	local cols, rows = math.ceil(w / tw), math.ceil(h / th)
	local n = 0
	local layer = Live.Under(parent)               -- (a live zone layer's: shown only while the layers are)
	for j = 1, rows do
		local ph = (j < rows) and th or (h - (rows - 1) * th)
		local fh = (j < rows or not overlay) and th or Pow2(ph)
		for k = 1, cols do
			local f = files[(j - 1) * cols + k]
			local file = tonumber(f) or f              -- (a file ID, or a hand-edited tile's path)
			local pw = (k < cols) and tw or (w - (cols - 1) * tw)
			local fw = (k < cols or not overlay) and tw or Pow2(pw)
			if file and pw > 0 and ph > 0 then
				local tx, ty = p.left + (x + (k - 1) * tw) * p.sx, p.top + (y + (j - 1) * th) * p.sy
				-- a zone's textures get their file once the zone is in view (ShowZone): opening the
				-- map loads what's there, not the whole world
				local lazy = band or list == graded              -- (ShowZone queues them)
				for copy = 1, band and 2 or 1 do
					local tex = parent:CreateTexture(nil, drawLayer, nil, sub + (copy - 1) * 2)
					if lazy then tex.omFile = file else tex:SetTexture(file, nil, nil, "TRILINEAR") end
					tex:SetTexCoord(0, pw / fw, 0, ph / fh)
					Record(tex, tx, ty, pw * p.sx, ph * p.sy)
					if mask then tex:AddMaskTexture(mask) end
					local hole = overlay and BannerHole(parent, p)
					if hole then tex:AddMaskTexture(hole) end
					-- (a zone's texture keeps its rectangle on the world, normalized: ShowZone shows only
					-- those near the view)
					local u0, v0, u1, v1 = tx / W, ty / H, (tx + pw * p.sx) / W, (ty + ph * p.sy) / H
					if copy == 2 then
						tex:AddMaskTexture(band)
						local e = { tex, p.mapID, piece, twin = true, layer = layer, u0 = u0, v0 = v0, u1 = u1, v1 = v1 }
						twins[#twins + 1] = e
						local list = zoneTex[p.mapID] or {}
						zoneTex[p.mapID] = list
						list[#list + 1] = e
					else
						if mask2 then tex:AddMaskTexture(mask2) end
						if list == graded then
							local e = { tex, p.mapID, piece, layer = layer, u0 = u0, v0 = v0, u1 = u1, v1 = v1 }
							graded[#graded + 1] = e
							local list = zoneTex[p.mapID] or {}
							zoneTex[p.mapID] = list
							list[#list + 1] = e
						elseif list then
							list[#list + 1] = tex
						end
					end
				end
				n = n + 1
			end
		end
	end
	return n
end

-- the zone's generated masks (MapBand, MapTerritory, MapCore) on `parent`; only
-- colour-matched zones have them
local function ZoneMask(parent, p, folder)
	if ns.MapGrade and ns.MapGrade[p.mapID] then return Feather(parent, p, folder .. p.mapID) end
end

-- A map's own base art (its whole layer), edges faded by `feather` when given;
-- a zone's shows only on its territory
local function PlaceBase(parent, mapID, drawLayer, list, feather)
	local p = Place(mapID)
	if not p then return 0 end
	local files = ArtFiles(mapID)
	if not files or #files == 0 then return 0 end
	local mask = feather and Feather(parent, p, feather)
	local band = list == graded and ZoneMask(parent, p, BAND)
	local territory = list == graded and ZoneMask(parent, p, TERRITORY)
	return PlaceTiles(parent, p, files, 0, 0, p.layer.layerWidth, p.layer.layerHeight, drawLayer, 0, false, mask, list, false, band, territory)
end

-- World / continent art as the backdrop, twice: over its land and coastal band (backdrop,
-- MapBackLand: Blizzard's shallow-water halo and hatching stay with the land) and over its
-- open sea (backdropSea, MapSeaMask), so the sea's lettering can go before the land does
local function PlaceBackdrop(parent, mapID, drawLayer, feather)
	local p = Place(mapID)
	if not p then return end
	local files = ArtFiles(mapID)
	if not files or #files == 0 then return end
	local mask = feather and Feather(parent, p, feather)
	local sea = Feather(parent, p, mapID == WORLD and SEA_OPEN or SEA_MASK .. mapID)
	local land = Feather(parent, p, TEX .. "MapBackLand\\" .. mapID)   -- (its land and coastal band: they stay)
	PlaceTiles(parent, p, files, 0, 0, p.layer.layerWidth, p.layer.layerHeight, drawLayer, 0, false, mask, backdrop, false, nil, land)
	PlaceTiles(parent, p, files, 0, 0, p.layer.layerWidth, p.layer.layerHeight, drawLayer, 0, false, mask, backdropSea, false, nil, sea)   -- (same sublevel: the masks don't overlap)
	if mapID == WORLD then
		PlaceTiles(parent, p, files, 0, 0, p.layer.layerWidth, p.layer.layerHeight, drawLayer, 0, false, mask, worldCoast, false, nil,
			Feather(parent, p, SEA_COAST))
	end
end

-- A continent's land kept as land once the backdrop mutes to sea (regions with no
-- zone map, like Quel'Thalas north of the Plaguelands): MapLand, a smooth colour field
-- of the continent art's land (its ink strokes and baked-in names left out), warmed
-- toward the zone art's parchment, with parchment grain at the zone art's scale
local function PlaceLand(mapID)
	local p = Place(mapID)
	if not p then return end
	local w, h = p.layer.layerWidth * p.sx, p.layer.layerHeight * p.sy
	local mask, land = Feather(contRoot, p, FEATHER_WIDE), Feather(contRoot, p, LAND .. mapID)
	local field = contRoot:CreateTexture(nil, "ARTWORK", nil, 2)
	field:SetTexture(LAND .. mapID, nil, nil, "LINEAR")
	field:SetVertexColor(LAND_TINT[1], LAND_TINT[2], LAND_TINT[3])
	field:SetDesaturation(LAND_DESAT)
	Record(field, p.left, p.top, w, h)
	field:AddMaskTexture(mask)
	landFill[#landFill + 1] = field
	-- the grain twice, at sizes and offsets that don't line up, so over a wide stretch
	-- of plain land it never shows a repeat
	for _, o in ipairs(GRAIN_OCTAVES) do
		local grain = contRoot:CreateTexture(nil, "ARTWORK", nil, 6)
		local size = GRAIN_TILE * o[1]
		grain:SetTexture(GRAIN, "REPEAT", "REPEAT")
		grain:SetTexCoord(o[2], o[2] + w / size, o[2] * 1.7, o[2] * 1.7 + h / size)
		grain:SetVertexColor(1, 1, 1, o[3])
		Record(grain, p.left, p.top, w, h)
		grain:AddMaskTexture(mask)
		grain:AddMaskTexture(land)
		landFill[#landFill + 1] = grain
	end

	-- the gaps between and around its zones (ns.MapGaps, tools/map-preview/gapfill.py): blank
	-- map paper through a mask of where the land is (the zones' own art fades into it)
	local gaps = ns.MapGaps and ns.MapGaps[mapID]
	if gaps then
		local size, paper = ns.MapGaps.tile, ns.MapGaps.paper
		for k = 1, #gaps - 2, 3 do
			local i, j = gaps[k], gaps[k + 1]
			local name = mapID .. "_" .. i .. "_" .. j
			local x, y = p.left + i * size, p.top + j * size
			if paper then
				local land = contRoot:CreateMaskTexture()
				land:SetTexture(GAP_LAND .. name, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
				Record(land, x, y, size, size)
				-- twice, at sizes and offsets that never line up, so it doesn't read as tiled
				for n, o in ipairs(PAPER_LAYERS) do
					local tex = contRoot:CreateTexture(nil, "ARTWORK", nil, 2 + n)
					local s_ = paper * o[1]
					tex:SetTexture(PAPER, "REPEAT", "REPEAT")
					tex:SetTexCoord(x / s_ + o[2], (x + size) / s_ + o[2], y / s_ + o[2] * 1.7, (y + size) / s_ + o[2] * 1.7)
					tex:SetVertexColor(1, 1, 1, o[3])
					Record(tex, x, y, size, size)
					tex:AddMaskTexture(land)
					tex:AddMaskTexture(mask)
					gapFill[#gapFill + 1] = tex
					culled[#culled + 1] = { tex, x / W, y / H, (x + size) / W, (y + size) / H }
				end
			end
		end
	end

	-- its coastal wave strokes: two octaves through the coastal band, between the
	-- continent art and the land (placed by S.SetSea)
	local coast = Feather(contRoot, p, COAST .. mapID)
	local l, r, t, b = S.Rect(mapID)
	local h = { l, r, t, b, k = (r - l) * W / p.layer.layerWidth, mapID = mapID, tex = {} }
	for i = 1, 2 do
		local tex = contRoot:CreateTexture(nil, "ARTWORK", nil, 1)
		tex:SetTexture(HATCH, "REPEAT", "REPEAT")
		tex:AddMaskTexture(coast)
		tex:Hide()
		h.tex[i] = tex
	end
	hatches[#hatches + 1] = h
end

-- every overlay piece of a zone: fn(files, x, y, w, h, sublevel, piece). A piece is
-- { key, unexplored }, one table per piece shared by all its copies (overlay, interior,
-- blur), so S.RefreshExplored can flip it when the player explores it.
local overlayZones = {}         -- the zones that have overlays
local pieces = {}               -- mapID -> key -> piece
local function Piece(mapID, key, unexplored)
	local list = pieces[mapID] or {}
	pieces[mapID] = list
	local piece = list[key] or { key = key }
	list[key] = piece
	piece.unexplored = unexplored
	return piece
end
ForEachPiece = function(mapID, fn)
	local explored = C_MapExplorationInfo.GetExploredMapTextures(mapID) or {}
	local reveal = ns.MapReveal and ns.MapReveal[C_Map.GetMapArtID(mapID) or 0]
	local seen = {}
	for _, info in ipairs(explored) do
		local key = info.textureWidth .. ":" .. info.textureHeight .. ":" .. info.offsetX .. ":" .. info.offsetY
		seen[key] = true
		if not info.isShownByMouseOver then
			fn(info.fileDataIDs, info.offsetX, info.offsetY, info.textureWidth, info.textureHeight, 1, Piece(mapID, key, false))
		end
	end
	for key, ids in pairs(reveal or {}) do
		if not seen[key] then
			local w, h, x, y = strsplit(":", key)
			fn({ strsplit(",", ids) }, tonumber(x), tonumber(y), tonumber(w), tonumber(h), 0, Piece(mapID, key, true))
		end
	end
end

-- A zone's overlays: explored ones from the client, the rest from the reveal data.
-- Drawn twice: whole (with their parchment halos) on overlayRoot, and their
-- interior (MapCore) on coreRoot, above every zone's halo.
local function PlaceOverlays(mapID)
	local p = Place(mapID)
	if not p then return 0 end
	local explored = C_MapExplorationInfo.GetExploredMapTextures(mapID) or {}
	local reveal = ns.MapReveal and ns.MapReveal[C_Map.GetMapArtID(mapID) or 0]
	if #explored == 0 and not reveal then return 0 end
	-- inside the zone's own frame (measured per zone: what it paints right up to it shows)
	local mask = ZoneMask(overlayRoot, p, EDGE) or Feather(overlayRoot, p, FEATHER_THIN)
	local band = ZoneMask(overlayRoot, p, BAND)
	local coreThin, core = ZoneMask(coreRoot, p, EDGE) or Feather(coreRoot, p, FEATHER_THIN), ZoneMask(coreRoot, p, CORE)
	local n = 0
	ForEachPiece(mapID, function(files, x, y, w, h, sub, piece)
		n = n + PlaceTiles(overlayRoot, p, files, x, y, w, h, "ARTWORK", sub, true, mask, graded, piece, band)
		if core then
			PlaceTiles(coreRoot, p, files, x, y, w, h, "ARTWORK", sub, true, coreThin, graded, piece, nil, core)
		end
	end)
	overlayZones[#overlayZones + 1] = mapID
	return n
end

--------------------------------------------------------------------------------
-- Icons
--------------------------------------------------------------------------------

-- dungeon name -> its uiMapID (first map of that name), built on first use
local instanceMaps
-- an instance's map, by its name: a dungeon map before a micro map of the same name, and never an
-- entrance cave's (Data/Caves.lua: Wailing Caverns' cave shares the dungeon's name); names matched
-- without "The", case or punctuation (the game's "Deadmines" is its map's "The Deadmines")
function S.InstanceMap(name)
	if type(name) ~= "string" or name == "" then return end
	local function NameKey(n) return (n:lower():gsub("^the ", ""):gsub("[^%w]", "")) end
	if not instanceMaps then
		instanceMaps = {}
		local caves = ns.MapCaves or {}
		for id = 1, 5000 do
			local info = C_Map.GetMapInfo(id)
			local kind = info and info.mapType
			if (kind == Enum.UIMapType.Dungeon or kind == Enum.UIMapType.Micro) and info.name and not caves[id] then
				local key = NameKey(info.name)
				local had = instanceMaps[key]
				if not had or (kind == Enum.UIMapType.Dungeon and had.kind ~= Enum.UIMapType.Dungeon) then
					instanceMaps[key] = { id = id, kind = kind }
				end
			end
		end
	end
	local e = instanceMaps[NameKey(name)] or instanceMaps[NameKey((name:gsub("%s*%b()", "")))]
	return e and e.id
end

--------------------------------------------------------------------------------
-- Pin sets: groups of icons (and lines) that keep their size on screen.
-- Each pin hangs from an invisible anchor placed in the art (re-placed by
-- Layout), and pinRoot is on the map's view, not its canvas: it never scales, so
-- the pins keep their size on screen and a zoom only moves them (a layer rescaled
-- on each frame of a zoom lays out every pin in it again). A set shows when it's on
-- and the zoom has reached its minimum. Pins can be any frame with a texture; lines
-- join two anchors.
--------------------------------------------------------------------------------

local sets = {}                 -- key -> { frame, on, minZoom, pins = {}, lines = {}, anchors = {}, pinPool, linePool }
local anchorPool = {}
local dynamic = {}              -- region -> record: anchors and paint marks (added and dropped often)

-- places a record's region, once, in world units: root's own units (Layout scales root
-- to the host map, so nothing is re-placed when the host changes)
PlaceRecord = function(rec)
	local region = rec[1]
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", rec.rel or root, "TOPLEFT", rec[2], -rec[3])
	region:SetSize(rec[4], rec[5])
end

local function Anchor(u, v)
	local a = tremove(anchorPool) or root:CreateTexture(nil, "BACKGROUND")
	a:SetAlpha(0)
	local rec = { a, u, v, 0.01, 0.01 }
	dynamic[a] = rec
	PlaceRecord(rec)
	return a
end

local function DropAnchor(a)
	dynamic[a] = nil
	a:ClearAllPoints()
	anchorPool[#anchorPool + 1] = a
end

function S.PinSet(key, minZoom, level)
	local set = sets[key]
	if not set then
		set = { frame = CreateFrame("Frame", nil, pinRoot), on = true, minZoom = minZoom or 1,
			pins = {}, lines = {}, anchors = {}, pinPool = {}, linePool = {} }
		set.frame:SetAllPoints(pinRoot)
		sets[key] = set
	end
	if level then set.frame:SetFrameLevel(pinRoot:GetFrameLevel() + level) end
	return set
end

-- sets a texture from a look: { atlas = } or { texture =, coords = }; an atlas this
-- client lacks falls back to the texture, a missing texture to `fallback`
local function Look(tex, look)
	tex:SetTexCoord(0, 1, 0, 1)
	tex:SetVertexColor(1, 1, 1, 1)
	if look.atlas and (not C_Texture or not C_Texture.GetAtlasInfo or C_Texture.GetAtlasInfo(look.atlas)) then
		tex:SetAtlas(look.atlas)
	else
		local ok = tex:SetTexture(look.texture or look.fallback or "Interface\\Minimap\\ObjectIcons")
		if ok == false and look.fallback then tex:SetTexture(look.fallback) end
		if look.coords then tex:SetTexCoord(unpack(look.coords)) end
	end
	if look.color then tex:SetVertexColor(unpack(look.color)) end
	tex:SetRotation(look.rotation or 0)
end
S.Look = Look

-- a pin at a world point (normalized); look: atlas / texture / coords / size / color.
-- Pins are pooled per set: a reused pin keeps the fields its set's code gave it.
-- Pins are kept in cells of the world, PIN_CELL wide: S.Cull hides the cells off the
-- view, so a pan or zoom doesn't move (and draw) every pin on the world, only those near it
local PIN_CELL = 0.04           -- world (normalized)
local cullBox                   -- the last view S.Cull saw, with its margin: { u0, v0, u1, v1 }
local NONE = {}                 -- (an empty list to loop over, kept: not a new one a frame)
local function PinCell(set, u, v)
	local i, j = math.floor(u / PIN_CELL), math.floor(v / PIN_CELL)
	set.cells = set.cells or {}
	local key = i * 4096 + j
	local cell = set.cells[key]
	if not cell then
		cell = CreateFrame("Frame", nil, set.frame)
		cell:SetAllPoints(set.frame)
		cell:SetFrameLevel(set.frame:GetFrameLevel())
		cell.u0, cell.v0 = i * PIN_CELL, j * PIN_CELL
		set.cells[key] = cell
		if cullBox then                         -- (until the next view change: judged against the last)
			cell.here = cell.u0 + PIN_CELL > cullBox[1] and cell.u0 < cullBox[3] and cell.v0 + PIN_CELL > cullBox[2] and cell.v0 < cullBox[4]
			cell:SetShown(cell.here)
		end
	end
	return cell
end

function S.AddPin(set, u, v, look, data)
	local pin = tremove(set.pinPool)
	if not pin then
		pin = CreateFrame("Button", nil, set.frame)
		pin.Icon = pin:CreateTexture(nil, "ARTWORK")
		pin.Icon:SetAllPoints()
		pin.Highlight = pin:CreateTexture(nil, "HIGHLIGHT")
		pin.Highlight:SetAllPoints()
		pin.Highlight:SetBlendMode("ADD")
		pin.Highlight:SetAlpha(0.3)               -- (a lift, not a flare)
		pin:SetScript("OnMouseDown", function(self, button) if S.OnPinMouseDown then S.OnPinMouseDown(self, button) end end)
		pin:SetScript("OnMouseUp", function(self, button) if S.OnPinMouseUp then S.OnPinMouseUp(self, button) end end)
	end
	local size = look.size or 16
	pin:SetParent(PinCell(set, u, v))
	pin:SetSize(size, size)
	pin:SetFrameLevel(set.frame:GetFrameLevel())
	pin.anchor = Anchor(u * W, v * H)
	pin:ClearAllPoints()
	pin:SetPoint("CENTER", pin.anchor, "TOPLEFT")
	pin.u, pin.v, pin.data, pin.look = u, v, data, look
	Look(pin.Icon, look)
	Look(pin.Highlight, look)
	pin.Icon:SetDesaturated(false)
	pin.Icon:SetAlpha(1)
	pin:SetScript("OnEnter", nil)
	pin:SetScript("OnLeave", nil)
	pin.OnClick = nil
	pin:EnableMouse(true)
	pin:Show()
	set.pins[#set.pins + 1] = pin
	return pin
end

-- a line between two world points (normalized), `thickness` px on screen
function S.AddLine(set, u1, v1, u2, v2, thickness, r, g, b, a, texture)
	local line = tremove(set.linePool) or set.frame:CreateLine(nil, "ARTWORK")
	local a1, a2 = Anchor(u1 * W, v1 * H), Anchor(u2 * W, v2 * H)
	line:ClearAllPoints()
	line:SetStartPoint("TOPLEFT", a1)
	line:SetEndPoint("TOPLEFT", a2)
	line:SetThickness(thickness or 3)
	if texture then line:SetTexture(texture, "REPEAT", "CLAMP") else line:SetColorTexture(1, 1, 1, 1) end
	line:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
	line:Show()
	set.lines[#set.lines + 1] = line
	set.anchors[#set.anchors + 1] = a1
	set.anchors[#set.anchors + 1] = a2
	return line
end

-- a path through world points (normalized: { u1, v1, u2, v2, ... }), `thickness` px on screen: a
-- line between each two, sharing their anchors (a drawing's stroke: Sketch.lua); `sub`: its draw
-- sublevel, so one path can lie over another
function S.AddPath(set, pts, thickness, r, g, b, a, sub)
	local prev
	for i = 1, #pts - 1, 2 do
		local anchor = Anchor(pts[i] * W, pts[i + 1] * H)
		set.anchors[#set.anchors + 1] = anchor
		if prev then
			local line = tremove(set.linePool) or set.frame:CreateLine(nil, "ARTWORK")
			line:SetDrawLayer("ARTWORK", sub or 0)
			line:ClearAllPoints()
			line:SetStartPoint("TOPLEFT", prev)
			line:SetEndPoint("TOPLEFT", anchor)
			line:SetThickness(thickness or 3)
			line:SetColorTexture(1, 1, 1, 1)
			line:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
			line:Show()
			set.lines[#set.lines + 1] = line
		end
		prev = anchor
	end
end

-- a plain dot (a texture, not a button: routes have hundreds) at a world point (normalized),
-- on the set's frame or `parent` (a frame in it)
function S.AddDot(set, u, v, size, look, r, g, b, a, parent)
	local dot = (parent or set.frame):CreateTexture(nil, "ARTWORK")
	S.Look(dot, look)
	dot:SetVertexColor(r, g, b, a)
	dot:SetSize(size, size)
	local anchor = Anchor(u * W, v * H)
	dot:SetPoint("CENTER", anchor, "TOPLEFT")
	set.anchors[#set.anchors + 1] = anchor
	return dot
end

function S.ClearPinSet(set)
	for _, pin in ipairs(set.pins) do
		pin:Hide()
		pin:ClearAllPoints()
		DropAnchor(pin.anchor)
		set.pinPool[#set.pinPool + 1] = pin
	end
	for _, line in ipairs(set.lines) do
		line:Hide()
		set.linePool[#set.linePool + 1] = line
	end
	for _, a in ipairs(set.anchors) do DropAnchor(a) end
	wipe(set.pins) wipe(set.lines) wipe(set.anchors)
end

-- a set with `build` makes its pins the first time it shows
local function ShowSets()
	for _, set in pairs(sets) do
		local shown = set.on and zoomNow >= set.minZoom and (not set.maxZoom or zoomNow < set.maxZoom)
		if shown and set.build then
			local build = set.build
			set.build = nil
			build(set)
		end
		if set.shownNow ~= shown then set.shownNow = shown set.frame:SetShown(shown) end
	end
end

function S.GetPinSet(key) return sets[key] end

-- the shown pin nearest a screen point (px, as GetCursorPosition) within `reach` px: for the
-- gamepad's cursor, which has no mouse-over of its own
function S.PinAt(x, y, reach)
	local best, bestD = nil, reach * reach
	for _, set in pairs(sets) do
		if set.frame:IsVisible() then
			for _, pin in ipairs(set.pins) do
				if pin:IsVisible() and pin:IsMouseEnabled() then
					local cx, cy = pin:GetCenter()
					if cx then
						local es = pin:GetEffectiveScale()
						local dx, dy = cx * es - x, cy * es - y
						local d = dx * dx + dy * dy
						if d < bestD then best, bestD = pin, d end
					end
				end
			end
		end
	end
	return best
end

-- paint marks (the map paint tool's preview): soft dabs in world units, so they
-- grow and shrink with the map; above the art, under the icons
local marksRoot
local marks, markPool = {}, {}

function S.AddMark(u, v, radius, r, g, b, a)
	local tex = tremove(markPool) or marksRoot:CreateTexture(nil, "OVERLAY")
	tex:SetTexture(FEATHER_ROUND)
	tex:SetVertexColor(r, g, b, a)
	local rw = radius * W
	local rec = { tex, u * W - rw, v * H - rw, 2 * rw, 2 * rw }
	dynamic[tex] = rec
	PlaceRecord(rec)
	tex:Show()
	marks[#marks + 1] = tex
	return tex
end

function S.ClearMarks()
	for _, tex in ipairs(marks) do
		dynamic[tex] = nil
		tex:Hide()
		markPool[#markPool + 1] = tex
	end
	wipe(marks)
end

function S.SetMarksShown(shown)
	if marksRoot then marksRoot:SetShown(shown) end
end

function S.SetPinSetOn(set, on)
	set.on = on and true or false
	ShowSets()
end

--------------------------------------------------------------------------------
-- World yards -> the world map (normalized), through each continent's corners
--------------------------------------------------------------------------------

local CONTINENT_MAP = { [0] = 1415, [1] = 1414 }
local corners = {}              -- continent -> { x0, y0, x1, y1, mapID } or false

local function Corners(cont)
	local c = corners[cont]
	if c ~= nil then return c end
	c = false
	local mapID = CONTINENT_MAP[cont]
	local ok0, _, p0 = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(0, 0))
	local ok1, _, p1 = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(1, 1))
	if mapID and ok0 and ok1 and p0 and p1 then
		local x0, y0 = ns.Safe.XY(p0)
		local x1, y1 = ns.Safe.XY(p1)
		c = { x0, y0, x1, y1, mapID }
	end
	corners[cont] = c
	return c
end

-- the two ways the corners' vector and world X / Y can line up with the map's x / y;
-- `swap` picks one. (Usually the vector is (world X, world Y) and the map's x runs
-- along world Y: HereBeDragons reads it as top, left.)
local function Project(c, wx, wy, swap)
	local mx, my
	if swap then
		mx, my = (wx - c[1]) / (c[3] - c[1]), (wy - c[2]) / (c[4] - c[2])
	else
		mx, my = (wy - c[2]) / (c[4] - c[2]), (wx - c[1]) / (c[3] - c[1])
	end
	local l, r, t, b = S.Rect(c[5])
	if not l then return end
	return l + mx * (r - l), t + my * (b - t)
end

local swap
-- a world position (yards on continent 0 / 1) on Azeroth's map (normalized)
function S.FromYards(cont, wx, wy)
	local c = Corners(cont)
	if not c then return end
	if swap == nil then
		-- settle the axis order once: Stormwind's flight master (-8840.6, 489.7) is in Elwynn / Stormwind
		local wc = Corners(0)
		swap = false
		if wc then
			for _, try in ipairs({ false, true }) do
				local u, v = Project(wc, -8840.6, 489.7, try)
				for _, zone in ipairs({ 1429, 1453 }) do
					local l, r, t, b = S.Rect(zone)
					if u and l and u >= l and u <= r and v >= t and v <= b then swap = try end
				end
			end
		end
	end
	return Project(c, wx, wy, swap)
end

--------------------------------------------------------------------------------
-- Places (ns.MapPlaces, from the game's tables): instance entrances, boats, zeppelins
--------------------------------------------------------------------------------

-- Blizzard's own icons (atlases and textures in the client); dungeons' are Dungeons.lua's
local LOOK = {
	boat     = { atlas = "Ships_CargoShip-Map", texture = "Interface\\Minimap\\ObjectIcons", size = 30 },
	-- Blizzard's Horde airship (the battleground maps' flying-vehicle icon); the old seat
	-- indicator outline where a client lacks it
	zeppelin = { atlas = "vehicle-air-horde", texture = "Interface\\Vehicles\\SeatIndicator\\Vehicle-HordeZeppelin", size = 30 },
}

-- an instance's name in the player's language (the game's own), else the data's English. A wing
-- (the group finder's name for part of a dungeon, "Dire Maul - East") keeps its own name in English,
-- and in another language is the dungeon's name with the wing's after it
function S.InstanceName(inst)
	local name = GetRealZoneText and inst[1] > 0 and ns.Safe.Call(GetRealZoneText, inst[1])   -- (0: not in the tables)
	if not name or name == "" then return inst[2] end
	if inst.wing == nil then
		local en = GetLocale and GetLocale():sub(1, 2) == "en"
		inst.wing = false
		for _, g in ipairs((ns.MapPlaces or {}).instances or {}) do
			for _, other in ipairs(g[4]) do
				if other ~= inst and other[1] == inst[1] and other[2] ~= inst[2] then inst.wing = en and inst[2] or (name .. " (" .. inst[2] .. ")") end
			end
		end
	end
	return inst.wing or name
end
local L = ns.L

local function DockEnter(pin)
	GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
	GameTooltip:AddLine(pin.kind == "zeppelin" and L["Zeppelin"] or L["Boat"], 1, 0.82, 0)
	if pin.to then
		-- where it goes: the zone at the other end, in the player's language
		local chain = S.ChainAt(pin.to[1], pin.to[2])
		local info = C_Map.GetMapInfo(chain[#chain])
		if info and info.name then GameTooltip:AddLine(L["To"] .. " " .. info.name, 1, 1, 1) end
		GameTooltip:AddLine(L["Click to go to the other end"], 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

local function DockClick(pin)
	if pin.to and S.GlideToWorld then S.GlideToWorld(pin.to[1], pin.to[2], 6) end
end

local function BuildPins()
	local P = ns.MapPlaces or {}
	local dungeons, travel = S.PinSet("dungeons", 1.5), S.PinSet("travel", 2.5)
	if S.BuildDungeonPins then
		for _, pin in ipairs(S.BuildDungeonPins(dungeons)) do pins[#pins + 1] = pin end   -- (Dungeons.lua)
	end
	local horde = UnitFactionGroup("player") == "Horde"
	for _, d in ipairs(P.transports or {}) do
		local u, v = S.FromYards(d[3], d[4], d[5])
		if u and (d[1] ~= "zeppelin" or horde) then
			local pin = S.AddPin(travel, u, v, LOOK[d[1]])
			pin.kind = d[1]
			if d[6] then
				local tu, tv = S.FromYards(d[6], d[7], d[8])
				if tu then pin.to = { tu, tv } end
			end
			pin:SetScript("OnEnter", DockEnter)
			pin:SetScript("OnLeave", GameTooltip_Hide)
			pin.OnClick = DockClick
			pins[#pins + 1] = pin
		end
	end
	S.stats.pins = #pins

	if S.BuildRoutes then S.BuildRoutes() end     -- Routes.lua
end

--------------------------------------------------------------------------------
-- Build, layout, zoom
--------------------------------------------------------------------------------

-- Builds everything on `parent` (Blizzard's canvas): art frames from `artLevel`
-- (needs `range` levels), icons at `iconLevel`.
function S.Build(parent, artLevel, range, iconLevel)
	if root then return end
	S.artTop = artLevel + range             -- (the top of the art: Extras.lua lifts Questie's icons above it)
	W, H = ArtSize(WORLD)
	if not W then return end
	local function Layer(level)
		local fr = CreateFrame("Frame", nil, root)
		fr:SetAllPoints(root)
		fr:SetFrameLevel(level)
		return fr
	end
	root = CreateFrame("Frame", nil, parent)
	root:SetPoint("TOPLEFT", parent, "TOPLEFT")
	root:SetSize(1, 1)
	root:SetFrameLevel(artLevel)
	contRoot = Layer(artLevel + 1)
	tilesRoot = Layer(artLevel + 2)
	overlayRoot = Layer(artLevel + range - 16)
	coreRoot = Layer(artLevel + range - 15)
	blurRoot = Layer(artLevel + range - 14)   -- (its copies take the next 4 levels)
	citiesRoot = Layer(artLevel + range - 9)
	shadeRoot = Layer(artLevel + range - 7)   -- (unexplored land, darkened: over the art and the minimap)
	S.closeLayers = {                       -- for Close.lua: the closest zoom's layers
		minimap = Layer(artLevel + range - 8),
		grain = Layer(artLevel + range - 1),   -- (over everything; range - 5 is the underground cities')
		under = Layer(artLevel + range - 4),
	}
	labelsRoot = Layer(artLevel + range - 3)
	marksRoot = Layer(artLevel + range - 2)
	marksRoot:Hide()
	-- (on the map's view, which clips them as the canvas does, not on the canvas: see Pin sets)
	local view = parent:GetParent() or parent
	pinRoot = CreateFrame("Frame", nil, view)
	pinRoot:SetAllPoints(view)
	pinRoot:SetFrameLevel(iconLevel)
	if pinRoot.SetClipsChildren then pinRoot:SetClipsChildren(true) end
	arrow = pinRoot:CreateTexture(nil, "OVERLAY", nil, 7)
	arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
	arrow:SetSize(28, 28)
	arrow:Hide()

	-- the sea runs on well past the world art, so a wide (or tall) view shows more ocean,
	-- not the edge of the paper: its colour (the world's sea colours carried outward, keeping
	-- the tints of the sea near its edges), and its mottling at the continents' scale (the
	-- world art and its sea colour fade out into it at their edges)
	local sea = root:CreateTexture(nil, "BACKGROUND", nil, -8)
	sea:SetTexture(SEA_FIELD_OUT, nil, nil, "LINEAR")
	Record(sea, -SEA_REACH * W, -SEA_REACH * H, (1 + 2 * SEA_REACH) * W, (1 + 2 * SEA_REACH) * H)
	local outer = {}
	for i, file in ipairs({ SEA_DARK, SEA_LIGHT }) do
		local tex = root:CreateTexture(nil, "BACKGROUND", nil, -7)
		tex:SetTexture(file, "REPEAT", "REPEAT")
		Record(tex, -SEA_REACH * W, -SEA_REACH * H, (1 + 2 * SEA_REACH) * W, (1 + 2 * SEA_REACH) * H)
		outer[i] = tex
	end
	-- the sea's colour as the world and continent maps paint it (MapSeaField), so zooming
	-- in keeps the colour the map had from afar; the continents' fade into the world's
	for _, mapID in ipairs({ WORLD, 1414, 1415 }) do
		local p = Place(mapID)
		if p then
			local w, h = p.layer.layerWidth * p.sx, p.layer.layerHeight * p.sy
			local field = root:CreateTexture(nil, "BACKGROUND", nil, mapID == WORLD and -6 or -5)
			field:SetTexture(SEA_FIELD .. mapID, nil, nil, "LINEAR")
			Record(field, p.left, p.top, w, h)
			field:AddMaskTexture(Feather(root, p, FEATHER_WIDE))
		end
	end
	-- and its mottling over that, dark and light, in two octaves
	for i = 1, 4 do
		local tex = root:CreateTexture(nil, "BACKGROUND", nil, -5 + i)
		tex:SetTexture(i % 2 == 1 and SEA_DARK or SEA_LIGHT, "REPEAT", "REPEAT")
		tex:Hide()
		seaPaper[i] = tex
	end
	local nb, ns_ = #backdrop, #backdropSea
	PlaceBackdrop(root, WORLD, "BACKGROUND", FEATHER_WIDE)
	-- past its edges, the continents' own sea (their compass roses, ship and sea serpent)
	-- carries it on, as part of the world's sea
	for _, info in ipairs(C_Map.GetMapChildrenInfo(WORLD, Enum.UIMapType.Continent, true) or {}) do
		local p, files = Place(info.mapID), ArtFiles(info.mapID)
		if p and files and #files > 0 then
			PlaceTiles(root, p, files, 0, 0, p.layer.layerWidth, p.layer.layerHeight, "BACKGROUND", 0, false,
				Feather(root, p, SEA_OUT .. info.mapID), backdropSea, false)
		end
	end
	for i = nb + 1, #backdrop do worldArt[backdrop[i]] = true end
	for i = ns_ + 1, #backdropSea do worldArt[backdropSea[i]] = true end
	for _, info in ipairs(C_Map.GetMapChildrenInfo(WORLD, Enum.UIMapType.Continent, true) or {}) do
		PlaceBackdrop(contRoot, info.mapID, "ARTWORK", FEATHER_WIDE)
		PlaceLand(info.mapID)
	end
	-- the outer sea's mottling, at the same scale as the sea paper's first octave
	local size = SEA_TILE * 0.4
	for _, h in ipairs(hatches) do
		if h.mapID == 1415 then size = SEA_TILE * h.k end
	end
	for _, tex in ipairs(outer) do
		local x0, y0 = -SEA_REACH * W, -SEA_REACH * H
		local x1, y1 = (1 + SEA_REACH) * W, (1 + SEA_REACH) * H
		tex:SetTexCoord(x0 / size, x1 / size, y0 / size, y1 / size)
	end

	-- the continents' and seas' names (S.SetZoom letters each when it first shows)
	namesFrame = CreateFrame("Frame", nil, labelsRoot)
	namesFrame:SetSize(1, 1)
	-- while the map moves, the names' halos rest: every font string is drawn again at its new size on
	-- each frame of a zoom, and laid out again on each of a pan, and the halo is eight of a letter's
	-- nine. Back once the map has stopped. (On `names`, not locals of their own: the file is near
	-- Lua's limit of 200)
	names.Hush = function(on)
		names.hushed = on
		for _, n in ipairs(names) do
			for _, copy in ipairs(n[1].halos or NONE) do copy:SetShown(not on) end
		end
		names.watch:SetShown(on)
	end
	names.watch = CreateFrame("Frame")
	names.watch:Hide()
	names.watch:SetScript("OnUpdate", function()
		if GetTime() - (names.movedAt or 0) > 0.15 then names.Hush(false) end
	end)
	for _, label in ipairs(ns.MapLabels or {}) do
		local f = CreateFrame("Frame", nil, namesFrame)
		f:SetPoint("TOPLEFT")
		f:SetSize(1, 1)
		f:Hide()
		-- its box on the world (normalized), for S.Cull: its lines, with room for a name set wider
		-- than the art's line (another language's) and for its halo
		local n, p = { f, label }, Place(label.map)
		for _, line in ipairs(p and label.lines or NONE) do
			local x0, x1 = p.left + line[1] * p.sx, p.left + line[2] * p.sx
			local y1 = p.top + line[3] * p.sy
			local y0 = y1 - line[4] * p.sy
			n.l, n.r = math.min(n.l or x0, x0), math.max(n.r or x1, x1)
			n.t, n.b = math.min(n.t or y0, y0), math.max(n.b or y1, y1)
		end
		if n.l then
			local mx, my = (n.r - n.l) * 0.5, (n.b - n.t)
			n.l, n.r, n.t, n.b = (n.l - mx) / W, (n.r + mx) / W, (n.t - my) / H, (n.b + my) / H
		end
		names[#names + 1] = n
	end

	-- zones, biggest first so small zones land on top; cities go above everything
	local zones = C_Map.GetMapChildrenInfo(WORLD, Enum.UIMapType.Zone, true) or {}
	local area = {}
	for _, info in ipairs(zones) do
		local l, r, t, b = S.Rect(info.mapID)
		area[info.mapID] = l and (r - l) * (b - t) or 0
	end
	table.sort(zones, function(a, b) return area[a.mapID] > area[b.mapID] end)
	local level = artLevel + 2
	for _, info in ipairs(zones) do
		if area[info.mapID] > 0 then
			local n = PlaceOverlays(info.mapID)
			if n > 0 then
				level = math.min(level + 1, artLevel + range - 17)
				local zf = CreateFrame("Frame", nil, tilesRoot)
				zf:SetAllPoints(root)
				zf:SetFrameLevel(level)
				S.stats.tiles = S.stats.tiles + PlaceBase(zf, info.mapID, "ARTWORK", graded, FEATHER)
				S.stats.overlays = S.stats.overlays + n
			else
				tinsert(S.stats.cities, info.mapID)
				local cf = CreateFrame("Frame", nil, citiesRoot)
				cf:SetAllPoints(root)
				-- (an underground city above the minimap layer, which shows the surface over it)
				cf:SetFrameLevel(UNDERGROUND_CITIES[info.mapID] and artLevel + range - 5 or citiesRoot:GetFrameLevel())
				local l, r, t, b = S.Rect(info.mapID)
				cities[#cities + 1] = { cf, 1 / (r - l), mapID = info.mapID }
				culled[#culled + 1] = { cf, l, t, r, b }
				-- (a city that comes in early is cut down to the city: ns.MapCityCuts, banners.py)
				local cut = ns.MapCityCuts and ns.MapCityCuts[info.mapID] and TEX .. "MapCityMask\\" .. info.mapID
				PlaceBase(cf, info.mapID, "ARTWORK", graded, cut or FEATHER_ROUND)
			end
			S.stats.zones = S.stats.zones + 1
		end
	end

	-- finer maps the client has of land no zone covers (ns.MapGaps.art, gapfill.py: Blizzard's
	-- unexplored map of Gilneas): its own tiles, at their own resolution, through MapCoastArt
	-- (its land and shallows, where no zone paints), under every zone, over the gaps' paper
	for _, x in ipairs(ns.MapGaps and ns.MapGaps.art or {}) do
		local name, _, r, list = unpack(x)
		local files = {}                -- (0: a tile its mask leaves nothing of; not drawn)
		for i, f in ipairs(list) do files[i] = f ~= 0 and f or nil end
		local p = { left = r[1] * W, top = r[3] * H, sx = (r[2] - r[1]) * W / 1002, sy = (r[4] - r[3]) * H / 668,
			layer = { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } }
		local f = CreateFrame("Frame", nil, tilesRoot)
		f:SetAllPoints(root)
		f:SetFrameLevel(tilesRoot:GetFrameLevel())
		PlaceTiles(f, p, files, 0, 0, 1002, 668, "ARTWORK", 0, false, Feather(f, p, TEX .. "MapCoastArt\\" .. name))
		culled[#culled + 1] = { f, r[1], r[3], r[2], r[4] }
	end

	-- a zone's name banner for a city (ns.MapBanners, tools/map-preview/banners.py), cut from
	-- the zone's art: the city's title at every zoom (its own map is cut down to its plan, without
	-- its banner), over the city and the close-up layers (the minimap, the caves), with the labels
	for _, c in ipairs(cities) do
		local b = ns.MapBanners and ns.MapBanners[c.mapID]
		local p = b and Place(b[1])
		if p then
			local f = CreateFrame("Frame", nil, citiesRoot)
			f:SetAllPoints(root)
			f:SetFrameLevel(artLevel + range - 3)
			local tex = f:CreateTexture(nil, "ARTWORK")
			tex:SetTexture(TEX .. "MapBanner\\" .. c.mapID, nil, nil, "LINEAR")
			Record(tex, p.left + b[2] * p.sx, p.top + b[3] * p.sy, b[4] * p.sx, b[5] * p.sy)
			f:Hide()
			c.banner, c.bannerTex = f, tex
		end
	end

	cities.Build()
	Baked.Build()
	BuildPins()
	return true
end

function S.IsBuilt() return root ~= nil end

-- how much an underground city's own map covers the point (u, v) (0..1): Close.lua keeps
-- the minimap off it, as the minimap there shows the surface (the ruins above the Undercity,
-- Ironforge's mountain). Over the cities in the open the minimap is the city, and mixes in.

-- whether (u, v) is in a city's own map (WorldMap.lua lets you zoom further there)
function S.InCity(u, v)
	for _, c in ipairs(cities) do
		local l, r, t, b = S.Rect(c.mapID)
		if l and u > l and u < r and v > t and v < b then return true end
	end
	return false
end
-- how much the cities' own maps cover (u, v): full in the middle, easing off toward the edge of
-- each one's rectangle. `underground`: the cities under the surface (their minimap is the
-- surface's), else the others
local function Cover(u, v, underground)
	local cover, most = 0, nil
	for _, c in ipairs(cities) do
		local l, r, t, b
		if (UNDERGROUND_CITIES[c.mapID] and true or false) == underground then l, r, t, b = S.Rect(c.mapID) end
		if l and u > l and u < r and v > t and v < b then
			local e = math.min(u - l, r - u) / (r - l) * 2
			e = math.min(e, math.min(v - t, b - v) / (b - t) * 2)
			local here = c[1]:GetAlpha() * math.min(1, e * 2.5)
			if here > cover then cover, most = here, c.mapID end
		end
	end
	return cover, most                             -- (and the city covering it most)
end
function S.CityCover(u, v) return Cover(u, v, true) end
function S.SurfaceCityCover(u, v) return Cover(u, v, false) end

-- for Close.lua's minimap in the gaps: the continent layer (under every zone, so what's
-- drawn there shows only where no zone covers), and each continent's gaps as a soft mask
local landMasks = {}
function S.GapLayer() return contRoot end
function S.GapMask(mapID)
	if landMasks[mapID] == nil then
		local p = Place(mapID)
		landMasks[mapID] = p and Feather(contRoot, p, TEX .. "MapGapMask\\" .. mapID) or false
	end
	return landMasks[mapID] or nil
end

-- for Close.lua's close-up minimap: each continent's land (a touch past its coast) as a
-- soft mask on `layer`, so the minimap never draws the open sea (dark, in square tiles)
local minimapMasks = {}
function S.LandMask(layer, mapID)
	if minimapMasks[mapID] == nil then
		local p = Place(mapID)
		minimapMasks[mapID] = p and Feather(layer, p, LAND .. mapID) or false
	end
	return minimapMasks[mapID] or nil
end

-- for /openmap status: regions placed (art, masks) and placed since (icons, close-up layers)
function S.RegionCount()
	local n = 0
	for _ in pairs(dynamic) do n = n + 1 end
	return #placed, n
end

-- for /openmap status: how many of the art's regions are being drawn now
function S.DrawnCount()
	local n = 0
	for _, rec in ipairs(placed) do
		if rec[1]:IsVisible() and rec[1]:GetObjectType() == "Texture" then n = n + 1 end
	end
	return n
end

-- the view moved (a pan or zoom: Close.lua's S.SetView): a third frame running is the map moving, and
-- the names' halos rest until it stops (the map opening, or a setting changed, is one or two)
function S.Moved()
	if not names.Hush then return end
	local now = GetTime()
	if now == names.movedAt then return end      -- (one a frame)
	names.moves = names.movedAt and now - names.movedAt < 0.1 and (names.moves or 0) + 1 or 1
	names.movedAt = now
	if not names.hushed and names.moves >= 3 then names.Hush(true) end
end

function S.SetShown(shown)
	if root and root:IsShown() ~= (shown and true or false) then root:SetShown(shown) end
	if pinRoot and pinRoot:IsShown() ~= (shown and true or false) then pinRoot:SetShown(shown) end
end

-- for /openmap bench (Bench.lua): the art's parts, each { name, regions } it hides for a moment
-- to see what that part costs. (Textures straight on root: the sea and the world map's art)
function S.Parts()
	if not root then return {} end
	local own, copies = {}, {}
	for _, r in ipairs({ root:GetRegions() }) do
		if r:GetObjectType() == "Texture" then own[#own + 1] = r end
	end
	for _, e in ipairs(twins) do copies[#copies + 1] = e[1] end
	local L = S.closeLayers or {}
	return {
		{ "all OpenMap art and icons", { root, pinRoot } },
		{ "sea and world art", own },
		{ "continents, land, gap paper", { contRoot } },
		{ "zone base art", { tilesRoot } },
		{ "zone overlays", { overlayRoot } },
		{ "zone interiors", { coreRoot } },
		{ "baked zone art", { Baked.frame } },
		{ "colour-match copies", copies },
		{ "blur", { blurRoot } },
		{ "cities", { citiesRoot } },
		{ "unexplored shade", { shadeRoot } },
		{ "minimap detail", { L.minimap } },
		{ "grain", { L.grain } },
		{ "caves", { L.under } },
		{ "names", { labelsRoot } },
		{ "OpenMap icons", { pinRoot } },
	}
end

-- after the bench: the next S.Cull shows or hides every zone's textures and every culled region
-- afresh, as they should be
function S.ResetShown()
	if not root then return end
	wipe(inView)
	wipe(Live.placed)
	cullBox = nil
	for _, list in pairs(zoneTex) do
		for _, e in ipairs(list) do e.shown = nil end
	end
	for _, c in ipairs(culled) do c.here = nil end
	for _, n in ipairs(names) do n.near = nil end
	for _, set in pairs(sets) do
		for _, cell in pairs(set.cells or NONE) do cell.here = nil end
	end
end

-- the blur's copies (see S.SetBlur): offset diagonally each way by a fraction of an art pixel
local BLUR_TAPS = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
local BLUR_PX = 0.6             -- art pixels per tap
local blurZones = {}            -- mapID -> its four copy frames
local lastGrade                 -- ApplyGrade's settings, for copies built later

local function PlaceShift(f)
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", root, "TOPLEFT", f.dx, -f.dy)
	f:SetSize(1, 1)
end

--------------------------------------------------------------------------------
-- Names: the continents' and seas' names, lettered live in the client's
-- font as Blizzard's map art letters them (ns.MapLabels; the art is hand-cleaned of
-- its own): dark ink, small capitals under a capital initial, set wide, in a soft
-- light halo. In world units x NAME_UNITS on namesFrame, which Layout scales to the
-- host, so font sizes stay the same whichever map hosts the canvas.
--------------------------------------------------------------------------------

local NAME_UNITS = 4            -- font units per world unit
local NAME_CAP = 0.69           -- Friz Quadrata's capital height, in font sizes
local NAME_MIDDLE = 0.36        -- ... and the middle of its letters' box, above the baseline
local NAME_SMALL = 0.78         -- small capitals, to the capitals (as measured on the art)
local NAME_TRACK = 0.1          -- the least letter spacing, in cap heights (a longer name in another language)
local NAME_SPACE = 0.4          -- a word space, in cap heights (a name that doesn't fit the art's lines)
local HALO = { { 0.07, 1 }, { 0.15, 0.45 } }   -- copies behind the ink: { ring radius (cap heights), strength }
local HALO_TAPS = 8
local INK_ALPHA = 0.9           -- (the art's ink lets a little of the paper through)

-- the client's name for a label (localized), else its own
local function NameOf(label)
	local n, text = label.name, nil
	if n.map then
		local info = C_Map.GetMapInfo(n.map)
		text = info and info.name
	elseif n.area then
		text = C_Map.GetAreaInfo(n.area)
	end
	return (text and text ~= "") and text or n.text
end

-- the name's words onto the art's lines: one each, as the art sets them, or (another
-- language's name, with more or fewer words) all on its widest
local function SetLines(label, text)
	local words = {}
	for word in text:gmatch("%S+") do words[#words + 1] = word end
	local lines = label.lines
	if #words == #lines then
		local out = {}
		for i, line in ipairs(lines) do out[i] = { line, words[i] } end
		return out
	end
	local widest = lines[1]
	for _, line in ipairs(lines) do
		if line[2] - line[1] > widest[2] - widest[1] then widest = line end
	end
	return { { widest, text } }
end

local function Letter(f, label)
	local p = Place(label.map)
	if not p then return end
	local ink, glow = label.ink, label.glow
	local font = STANDARD_TEXT_FONT                -- (Friz Quadrata; the client's own in other alphabets)
	for _, set in ipairs(SetLines(label, NameOf(label))) do
		local line, text = set[1], set[2]
		local u = NAME_UNITS
		local left, right = (p.left + line[1] * p.sx) * u, (p.left + line[2] * p.sx) * u
		local base, cap = (p.top + line[3] * p.sy) * u, line[4] * p.sy * u
		-- the letters: a capital starting each word, small capitals after (a line set all
		-- small is already measured at their size)
		local glyphs, width, wordStart = {}, 0, true
		for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			if ch == " " then
				glyphs[#glyphs + 1] = { w = NAME_SPACE * cap }
				width = width + NAME_SPACE * cap
				wordStart = true
			else
				local size = cap / NAME_CAP * ((wordStart or line[5]) and 1 or NAME_SMALL)
				local fs = f:CreateFontString(nil, "OVERLAY")
				fs:SetFont(font, size, "")
				fs:SetText(#ch == 1 and ch:upper() or ch)
				fs:SetTextColor(ink[1] / 255, ink[2] / 255, ink[3] / 255, INK_ALPHA)
				fs:SetShadowOffset(0, 0)
				local w = fs:GetStringWidth()
				glyphs[#glyphs + 1] = { fs = fs, size = size, w = w }
				width = width + w
				wordStart = false
			end
		end
		-- set wide across the art's line, centred on it
		local gaps = #glyphs - 1
		local track = gaps > 0 and math.max(NAME_TRACK * cap, (right - left - width) / gaps) or 0
		local x = (left + right) / 2 - (width + track * gaps) / 2
		for _, g in ipairs(glyphs) do
			if g.fs then
				local y = -base + NAME_MIDDLE * g.size
				g.fs:SetPoint("LEFT", f, "TOPLEFT", x, y)
				-- the halo: copies in a ring round it, in the glow's colour. Each copy's shadow is the
				-- tap opposite it in the ring, so a ring is half as many font strings (every one is
				-- moved on each frame of a pan, and redrawn on each frame of a zoom)
				for _, ring in ipairs(HALO) do
					local r, a = ring[1] * cap, math.min(1, ring[2] * label.glowA / HALO_TAPS * 2)
					for i = 1, HALO_TAPS / 2 do
						local angle = (i - 1) / HALO_TAPS * 2 * math.pi
						local dx, dy = r * math.cos(angle), r * math.sin(angle)
						local copy = f:CreateFontString(nil, "ARTWORK")
						copy:SetFont(font, g.size, "")
						copy:SetText(g.fs:GetText())
						copy:SetTextColor(glow[1] / 255, glow[2] / 255, glow[3] / 255, a)
						copy:SetShadowColor(glow[1] / 255, glow[2] / 255, glow[3] / 255, a)
						copy:SetShadowOffset(-2 * dx, -2 * dy)
						copy:SetPoint("LEFT", f, "TOPLEFT", x + dx, y + dy)
						f.halos = f.halos or {}
						f.halos[#f.halos + 1] = copy
						if names.hushed then copy:Hide() end
					end
				end
			end
			x = x + g.w + track
		end
	end
end

-- lays the art out in `mapID`'s canvas units (it must be on the world). Everything is
-- placed in world units on root, so this is root's scale and corner: one change, however
-- much is built (offsets are in root's own, scaled, units)
function S.Layout(mapID)
	local aw = ArtSize(mapID)
	local l, r, t = S.Rect(mapID)
	if not root or not aw or not l then return false end
	local k = aw / ((r - l) * W)
	scaleNow = -1
	-- the same map again (each time the map opens): nothing to move, and moving the root
	-- would have the game lay out every texture under it again
	if host.mapID == mapID and host.k == k then return true end
	host.l, host.t, host.k, host.mapID = l * W, t * H, k, mapID
	root:SetScale(k)
	root:ClearAllPoints()
	root:SetPoint("TOPLEFT", root:GetParent(), "TOPLEFT", -host.l, host.t)
	namesFrame:SetScale(1 / NAME_UNITS)
	namesFrame:ClearAllPoints()
	namesFrame:SetPoint("TOPLEFT", labelsRoot, "TOPLEFT")
	return true
end

-- zoom: 1 = the world fits the view; scale: the host canvas's scale (host units -> view px)
-- for /openmap status: each part of S.SetZoom's time (ms, smoothed) and its worst
local zoomSteps = {}
S.zoomSteps = zoomSteps
local stepAt
local function Step(name)
	if not debugprofilestop then return end
	local now = debugprofilestop()
	if name and stepAt then
		local ms = now - stepAt
		local st = zoomSteps[name] or { ms = ms, worst = 0 }
		st.ms, st.worst = st.ms * 0.9 + ms * 0.1, math.max(st.worst, ms)
		zoomSteps[name] = st
	end
	stepAt = now
end

-- SetZoom's fades: 0..1 across `range` ({ from, to }, or from, to) of the zoom now. (Out here,
-- and the names' fades a table kept, so a zoom step makes no garbage: it runs every frame of one)
local function Smooth(range, to)
	local from = range
	if to == nil then from, to = range[1], range[2] end
	local t = math.max(0, math.min(1, (zoomNow - from) / (to - from)))
	return t * t * (3 - 2 * t)
end
local fades = {}

function S.SetZoom(zoom, scale)
	if not root then return end
	Step()
	zoomNow = zoom
	Fade(contRoot, Smooth(CONT_IN))
	fades.land = 1 - Smooth(LABELS_OUT)          -- the names (one of each, fixed on the world)
	fades.sea = 1 - Smooth(SEA_LABELS_OUT)
	for _, n in ipairs(names) do
		local a = math.floor((fades[n[2].fade] or 0) * 100 + 0.5) / 100
		Fade(n[1], a)
		if n.near == false and n[1]:IsShown() then n[1]:Hide() end   -- (off the view: S.Cull)
		if a > 0.01 and not n.built then Letter(n[1], n[2]); n.built = true end
	end
	Step("names")
	detailNow = DETAIL_HINT[3] * Smooth(DETAIL_HINT) + (1 - DETAIL_HINT[3]) * Smooth(DETAIL_FADE)
	if Baked.frame then                         -- (screen px per baked px: the live layers take over past them)
		local _, ph = GetPhysicalScreenSize()
		local r = root:GetEffectiveScale() * (ph or 768) / 768 / ns.MapZoneArt.px
		local t = math.max(0, math.min(1, (r - Baked.FADE[1]) / (Baked.FADE[2] - Baked.FADE[1])))
		Baked.live = math.floor(t * t * (3 - 2 * t) * 50 + 0.5) / 50
		Baked.warm = r >= Baked.FADE[1] * Baked.WARM
	end
	ApplyDetail()
	Step("zone detail")
	for _, c in ipairs(cities) do
		local fade = CITY_FADE_OF[c.mapID] or CITY_FADE
		local a = Smooth(fade[1] * c[2], fade[2] * c[2])
		if c.alpha ~= a then c.alpha = a c[1]:SetAlpha(a) end   -- (shown / hidden by S.Cull)
	end
	-- (the zone's banner for each city: the zone's art is drawn without it, so this is the banner, with
	-- the zone's detail; the city's title once you're in it, unless the city's own map keeps its own)
	cities.Banners()
	Step("cities")
	local m = math.floor(Smooth(MUTE_FADE) * 20) / 20
	local sm = math.floor(Smooth(SEA_FADE) * 20) / 20
	-- the world map gives way to the continents' as they come in (else each name and sea
	-- label shows twice, a little apart); the sea's own texture takes over around them
	local wo = math.floor(Smooth(WORLD_OUT) * 20) / 20
	local ws = math.floor(Smooth(WORLD_SEA_OUT) * 20) / 20
	local wc = math.floor(Smooth(WORLD_COAST_OUT) * 20) / 20
	if m ~= muted or sm ~= seaNow or wo ~= worldOut or ws ~= worldSea or wc ~= worldCoastOut then
		muted, seaNow, worldOut, worldSea, worldCoastOut = m, sm, wo, ws, wc
		for _, tex in ipairs(worldCoast) do Fade(tex, 1 - wc) end
		local c = 1 - 0.45 * m
		for _, tex in ipairs(backdrop) do
			tex:SetDesaturation(0.8 * m)
			tex:SetVertexColor(c, c * 0.97, c * 0.92)
			Fade(tex, (1 - BACK_MUTE * m) * (worldArt[tex] and (1 - wo) or 1))
		end
		for _, tex in ipairs(backdropSea) do
			if worldArt[tex] then                      -- the world's sea: the ocean, as Blizzard painted it
				tex:SetDesaturation(0)
				tex:SetVertexColor(1, 1, 1)
				Fade(tex, 1 - ws)
			else                                       -- a continent's open sea: the world's is under it
				tex:SetDesaturation(0.8 * m)
				tex:SetVertexColor(c, c * 0.97, c * 0.92)
				Fade(tex, (1 - BACK_MUTE * m) * (1 - sm))
			end
		end
		if S.SetSea then S.SetSea() end
	end
	Step("world / continent art")
	for _, tex in ipairs(landFill) do Fade(tex, math.max(m, underNow)) end
	Step("land")

	-- (the icons keep their size on screen by themselves: pinRoot is on the view, PlacePlayer's units)
	scaleNow = scale
	ShowSets()
	Step("icon sets")
	S.PlacePlayer()
	Step("player")
end

--------------------------------------------------------------------------------
-- For Close.lua: regions placed in world units (normalized), and yards <-> world
--------------------------------------------------------------------------------

-- the blur at the closest zoom (Close.lua), where the art is stretched past its pixels.
-- Each zone in view gets four copies of its interior (BLUR_TAPS, declared with Layout,
-- which re-places them), drawn at 1/2, 1/3, 1/4, 1/5 over it: an even five-tap
-- average, i.e. a small real blur. Built the first time a zone needs it.
local function BuildBlur(mapID)
	local p = Place(mapID)
	if not p or not (ns.MapGrade and ns.MapGrade[mapID]) then blurZones[mapID] = false return end
	local frames, from = {}, #graded + 1
	for i, tap in ipairs(BLUR_TAPS) do
		local f = CreateFrame("Frame", nil, blurRoot)
		f.omShift = true
		f.dx, f.dy = tap[1] * BLUR_PX * p.sx, tap[2] * BLUR_PX * p.sy
		f:SetFrameLevel(blurRoot:GetFrameLevel() + i)
		f:SetAlpha(1 / (i + 1))
		PlaceShift(f)
		local thin, core = ZoneMask(f, p, EDGE) or Feather(f, p, FEATHER_THIN), ZoneMask(f, p, CORE)
		ForEachPiece(mapID, function(files, x, y, w, h, sub, piece)
			PlaceTiles(f, p, files, x, y, w, h, "ARTWORK", sub, true, thin, graded, piece, nil, core)
		end)
		frames[i] = f
	end
	blurZones[mapID] = frames
	-- (its own new copies graded and queued to load, not every zone's)
	if lastGrade then
		for i = from, #graded do GradeEntry(graded[i], lastGrade[2]) end
	end
	ShowZone(mapID)
end

-- amount 0..1; the view's world rectangle (normalized): zones in it get their copies
function S.SetBlur(amount, u0, v0, u1, v1)
	if not root then return end
	softNow = amount
	for _, mapID in ipairs(overlayZones) do
		local l, r, t, b = S.Rect(mapID)
		local inView = amount > 0.01 and l and r > u0 and l < u1 and b > v0 and t < v1
		if inView and blurZones[mapID] == nil then BuildBlur(mapID) end
		local frames = blurZones[mapID]
		local shown = inView and true or false
		if frames and frames.shown ~= shown then
			frames.shown = shown
			for _, f in ipairs(frames) do f:SetShown(shown) end
		end
	end
	ApplyDetail()
end

-- underground (Close.lua): as a cave surfaces, the world above goes out of focus. The
-- zone detail fades back to the continent's smooth land colours (MapLand), which reads
-- as a blur; Close.lua adds heavier grain and a dim on top.
function S.SetUnderground(t)
	if not root or t == underNow then return end
	underNow = t
	ApplyDetail()
	for _, tex in ipairs(landFill) do Fade(tex, math.max(muted, t)) end
end

-- the sea's texture over the view (Close.lua's S.SetView passes it; the mute calls it
-- again with the last view). Both tile at the continent art's scale, then halve each time
-- the zoom doubles past SEA_OCTAVE / HATCH_OCTAVE, crossfading octave to octave, so the
-- paper and strokes keep their size on screen and finer ones come in as you close in.
local seaView = {}
-- (laid over a box well past the view: the pattern is fixed on the world, so a pan only lays it
-- again once the view nears the box's edge; a zoom or the mute changing, every time)
local seaBox = { k = 1.8 }      -- { u0, v0, u1, v1, zoom =, m = } as last laid; k: its half extents, of the view's
local function shift(k) return (k * 0.37) % 1 end   -- (an octave's own offset: below)
local function Octaves(from)
	local o = math.max(0, math.log(zoomNow / from) / math.log(2))
	local n = math.floor(o)
	return 2 ^ n, o - n
end

local function Tile(tex, u0, v0, u1, v1, sx, sy, alpha, shift)
	if alpha <= 0.01 or u1 <= u0 or v1 <= v0 then tex:Hide() return end
	local o = shift or 0
	tex:SetTexCoord(u0 * W / sx + o, u1 * W / sx + o, v0 * H / sy + o * 1.6, v1 * H / sy + o * 1.6)
	S.PlaceWorld(tex, u0, v0, u1, v1)
	tex:SetAlpha(alpha)
	tex:Show()
end

function S.SetSea(u, v, hu, hv)
	if not root then return end
	if u then seaView[1], seaView[2], seaView[3], seaView[4] = u, v, hu, hv end
	u, v, hu, hv = seaView[1], seaView[2], seaView[3], seaView[4]
	if not u then return end
	local m = math.max(0, worldSea, worldCoastOut)   -- (under the world art's sea: it shows as that goes, off the coasts first)
	local sb = seaBox
	if sb.zoom == zoomNow and sb.m == m and u - hu * 1.2 > sb[1] and u + hu * 1.2 < sb[3]
		and v - hv * 1.2 > sb[2] and v + hv * 1.2 < sb[4] then return end
	local u0, u1, v0, v1 = u - hu * sb.k, u + hu * sb.k, v - hv * sb.k, v + hv * sb.k
	sb[1], sb[2], sb[3], sb[4], sb.zoom, sb.m = u0, v0, u1, v1, zoomNow, m
	local ek = hatches[1] and hatches[1].k or 0.4
	for _, h in ipairs(hatches) do
		if h.mapID == 1415 then ek = h.k end
	end
	local div, f = Octaves(SEA_OCTAVE)
	local size = SEA_TILE * ek
	-- each size keeps its own offset (the octave's number), so when the finer copy takes
	-- over as the zoom doubles, it's the same pattern in the same place: no jump
	local n = math.floor(math.log(div) / math.log(2) + 0.5)
	for i = 1, 2 do
		Tile(seaPaper[i], u0, v0, u1, v1, size / div, size / div, m * (1 - f), shift(n))
		Tile(seaPaper[i + 2], u0, v0, u1, v1, size / div / 2, size / div / 2, m * f, shift(n + 1))
	end
	div, f = Octaves(HATCH_OCTAVE)
	for _, h in ipairs(hatches) do
		local a0, a1 = math.max(u0, h[1]), math.min(u1, h[2])
		local b0, b1 = math.max(v0, h[3]), math.min(v1, h[4])
		local a = m * HATCH_ALPHA
		local sx, sy = HATCH_W * h.k / div, HATCH_H * h.k / div
		Tile(h.tex[1], a0, b0, a1, b1, sx, sy, a * math.sqrt(1 - f))
		Tile(h.tex[2], a0, b0, a1, b1, sx / 2, sy / 2, a * math.sqrt(f))
	end
end

-- places `region` over the world rectangle u0..u1, v0..v1 (normalized), following Layout
function S.PlaceWorld(region, u0, v0, u1, v1)
	local rec = dynamic[region] or { region }
	rec[2], rec[3], rec[4], rec[5] = u0 * W, v0 * H, (u1 - u0) * W, (v1 - v0) * H
	dynamic[region] = rec
	PlaceRecord(rec)
end

function S.UnplaceWorld(region)
	dynamic[region] = nil
end

-- a world point (normalized) in yards on continent 0 / 1 (the inverse of FromYards)
function S.ToYards(cont, u, v)
	local x0, y0 = S.FromYards(cont, 0, 0)
	local x1, y1 = S.FromYards(cont, 1000, 0)
	local x2, y2 = S.FromYards(cont, 0, 1000)
	if not x0 or not x1 or not x2 then return end
	-- the projection is linear: solve u, v = origin + wx * a + wy * b
	local ax, ay, bx, by = (x1 - x0) / 1000, (y1 - y0) / 1000, (x2 - x0) / 1000, (y2 - y0) / 1000
	local det = ax * by - bx * ay
	if det == 0 then return end
	local du, dv = u - x0, v - y0
	return (du * by - bx * dv) / det, (ax * dv - du * ay) / det
end

S.CaveMasks = ns.Media.path .. "Textures\\MapCave\\"

-- our own player arrow, for when the host map can't show the player
local player = {}
function S.SetPlayer(u, v, facing)
	player.u, player.v, player.facing = u, v, facing
	S.PlacePlayer()
end

function S.PlacePlayer()
	if not root then return end
	if not player.u or scaleNow <= 0 then arrow:Hide() return end
	local s = scaleNow * host.k                 -- (world units -> the arrow's, pinRoot's, units)
	arrow:ClearAllPoints()
	arrow:SetPoint("CENTER", root, "TOPLEFT", player.u * W * s, -player.v * H * s)
	if player.facing then arrow:SetRotation(player.facing) end
	arrow:Show()
end

-- colour matching: the border copies move `strength` of the way to the shared
-- palette (ns.MapGrade); `desat` takes some colour out of every zone. `unexplored`:
-- "show" the areas the player hasn't explored yet as they are, "dim" them (darkened and cooled;
-- a zone not found at all is shaded on the continent's art too, so it shows from every zoom), or
-- "hide" them (the zone's blank parchment shows there, as on Blizzard's own map)
-- a zone's textures shown or hidden: near the view, and not an unexplored piece being hidden
-- zones' files waiting to be set, a few each frame (LOAD_PER_FRAME), so a zone coming into
-- view (or the map opening on one) doesn't stall a frame setting them all at once
-- Each fades in as it gets its file (LOAD_FADE), not popping in (the file itself streams in
-- over a few frames)
local LOAD_PER_FRAME = 40
local LOAD_FADE = 0.3           -- seconds
local loadQueue, loadAt = {}, 1
local fading, fadingN = {}, 0   -- texture -> when it got its file
local loader = CreateFrame("Frame")
loader:Hide()
loader:SetScript("OnUpdate", function(self)
	local n, now = 0, GetTime()
	while loadAt <= #loadQueue and n < LOAD_PER_FRAME do
		local tex = loadQueue[loadAt]
		loadAt = loadAt + 1
		if tex.omFile then
			tex:SetTexture(tex.omFile, nil, nil, "TRILINEAR")
			tex.omFile = nil
			tex:SetAlpha(0)
			fading[tex] = now
			fadingN = fadingN + 1
			n = n + 1
		end
	end
	if loadAt > #loadQueue then wipe(loadQueue) loadAt = 1 end
	for tex, t0 in pairs(fading) do
		local t = (now - t0) / LOAD_FADE
		if t >= 1 then
			tex:SetAlpha(1)
			fading[tex] = nil
			fadingN = fadingN - 1
		else
			tex:SetAlpha(t * t * (3 - 2 * t))
		end
	end
	if loadAt == 1 and #loadQueue == 0 and fadingN == 0 then
		self:Hide()
		Baked.busy = false
		if Baked.holding then                   -- (all in: the baked tiles can go)
			Baked.holding = false
			ApplyDetail()
		end
	end
end)

--------------------------------------------------------------------------------
-- Unexplored land, darkened ("dim"). A zone you haven't found any of: a shade over its art and the
-- close-up minimap, through its land without the sea its art paints (MapZoneLand, so the sea is left
-- alone), from every zoom. A zone you've been to: each piece's art again over the zone's (the baked
-- tiles' or the live layers'), the unexplored pieces darkened and the explored over them as they are.
-- (Blizzard's pieces are opaque rectangles, over half of a zone's art under two or more: a shade per
-- piece stacked darker where they overlap and showed every piece's tiles as lines; copies of the art
-- over the same art don't stack, and their edges are the pieces' own.) Built the first time it's
-- wanted, a zone's pieces when it's first in view; hidden with the zone off the view.
--------------------------------------------------------------------------------

-- (one table: the file is near Lua's limit of 200 locals)
-- zones: mapID -> { frame, land, p, all = texture, rim = texture, dim = frame, pieces = { piece -> { copies } } },
-- or false. REACH: world units round a zone its border share covers (render.py's BORDER_REACH).
-- DIM: an unexplored piece's colour, { r, g, b (multipliers), desaturation }: near the shade's (UNDISCOVERED
-- at its alpha over the art), as a texture can only multiply (render.py's DIM)
local Shade = { zones = {}, on = false, REACH = 12, DIM = { 0.38, 0.39, 0.43, 0.25 } }

function Shade.Texture(z, x, y, w, h)
	local tex = z.frame:CreateTexture(nil, "ARTWORK")
	tex:SetColorTexture(UNDISCOVERED[1], UNDISCOVERED[2], UNDISCOVERED[3], UNDISCOVERED[4])
	Record(tex, x, y, w, h)
	tex:AddMaskTexture(z.land)
	return tex
end

function Shade.Zone(mapID)
	local z = Shade.zones[mapID]
	if z ~= nil then return z end
	z = false
	local p = Place(mapID)
	if p and shadeRoot then
		local frame = CreateFrame("Frame", nil, shadeRoot)
		frame:SetAllPoints(root)
		local land = ZoneMask(frame, p, ZONELAND)
		if land then
			z = { frame = frame, land = land, p = p }
			z.all = Shade.Texture(z, p.left, p.top, p.layer.layerWidth * p.sx, p.layer.layerHeight * p.sy)
			-- ... and its share of the land round it that's no zone's (border mountains, blank land
			-- between zones: MapZoneBorder, over its art rectangle and REACH round it), so a stretch
			-- of zones you haven't found is dark from one to the next
			local R = Shade.REACH
			local x, y = p.left - R, p.top - R
			local w, h = p.layer.layerWidth * p.sx + 2 * R, p.layer.layerHeight * p.sy + 2 * R
			local share = frame:CreateMaskTexture()
			share:SetTexture(TEX .. "MapZoneBorder\\" .. mapID, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			Record(share, x, y, w, h)
			z.rim = frame:CreateTexture(nil, "ARTWORK")
			z.rim:SetColorTexture(UNDISCOVERED[1], UNDISCOVERED[2], UNDISCOVERED[3], UNDISCOVERED[4])
			Record(z.rim, x, y, w, h)
			z.rim:AddMaskTexture(share)
		else
			frame:Hide()
		end
	end
	Shade.zones[mapID] = z
	return z
end

-- a zone you've been to: every piece's art again, as the overlays are drawn (the zone's frame, its
-- banner hole, its colour-match copy through the border band), on a layer over the zones' art and the
-- baked tiles and under the blur's copies, the cities and the minimap. Shade.Colour darkens them
function Shade.Pieces(mapID, z)
	z.pieces = {}
	local p = z.p
	if not Shade.root then
		Shade.root = CreateFrame("Frame", nil, root)
		Shade.root:SetAllPoints(root)
		Shade.root:SetFrameLevel(blurRoot:GetFrameLevel())   -- (blurRoot holds no art of its own: its copies are a level up)
	end
	local f = CreateFrame("Frame", nil, Shade.root)
	f:SetAllPoints(root)
	z.dim = f
	local edge = ZoneMask(f, p, EDGE) or Feather(f, p, FEATHER_THIN)
	local band, hole = ZoneMask(f, p, BAND), BannerHole(f, p)
	z.dimLand = ZoneMask(f, p, ZONELAND)          -- (a darkened piece: its land only, the sea it paints left alone)
	local tw, th = p.layer.tileWidth, p.layer.tileHeight
	ForEachPiece(mapID, function(files, x, y, w, h, _, piece)
		local list = {}
		local cols, rows = math.ceil(w / tw), math.ceil(h / th)
		for j = 1, rows do
			local ph = (j < rows) and th or (h - (rows - 1) * th)
			for k = 1, cols do
				local file = files[(j - 1) * cols + k]
				file = tonumber(file) or file
				local pw = (k < cols) and tw or (w - (cols - 1) * tw)
				if file and pw > 0 and ph > 0 then
					local fw, fh = (k < cols) and tw or Pow2(pw), (j < rows) and th or Pow2(ph)
					local tx, ty = p.left + (x + (k - 1) * tw) * p.sx, p.top + (y + (j - 1) * th) * p.sy
					for copy = 1, band and 2 or 1 do
						local tex = f:CreateTexture(nil, "ARTWORK")
						tex:SetTexture(file, nil, nil, "TRILINEAR")
						tex:SetTexCoord(0, pw / fw, 0, ph / fh)
						Record(tex, tx, ty, pw * p.sx, ph * p.sy)
						tex:AddMaskTexture(edge)
						if hole then tex:AddMaskTexture(hole) end
						if copy == 2 then tex:AddMaskTexture(band) end
						list[#list + 1] = { tex, twin = copy == 2 }
					end
				end
			end
		end
		z.pieces[piece] = list
	end)
end

-- the copies coloured for whether their piece is explored, at the colour settings now: the explored
-- as the overlays are, over the unexplored, which are darkened (DIM) on the zone's land alone (the sea
-- it paints left as it is) and without their colour-match copy (a texture takes three masks)
function Shade.Colour(mapID, z)
	local strength, desat = gradeNow[1], gradeNow[2]
	-- (only when the settings or the pieces explored have changed: this runs with each cull)
	local un = 0
	for piece in pairs(z.pieces) do if piece.unexplored then un = un + 1 end end
	local done = strength .. ":" .. desat .. ":" .. un
	if z.coloured == done then return end
	z.coloured = done
	local m = ns.MapGrade and ns.MapGrade[mapID]
	local D = Shade.DIM
	for piece, list in pairs(z.pieces) do
		local dark = piece.unexplored and true or false
		for _, e in ipairs(list) do
			local r, g, b = 1, 1, 1
			if e.twin and m then r, g, b = 1 + (m[1] - 1) * strength, 1 + (m[2] - 1) * strength, 1 + (m[3] - 1) * strength end
			if dark then r, g, b = D[1], D[2], D[3] end
			local tex = e[1]
			if z.dimLand and not e.twin and e.landed ~= dark then
				e.landed = dark
				if dark then tex:AddMaskTexture(z.dimLand) else tex:RemoveMaskTexture(z.dimLand) end
			end
			tex:SetVertexColor(r, g, b, 1)
			tex:SetDesaturation(dark and math.max(desat, D[4]) or desat)
			tex:SetDrawLayer("ARTWORK", (dark and 0 or 2) + (e.twin and 1 or 0))
			tex:SetShown(not (e.twin and (dark or strength <= 0)))
		end
	end
end

-- how much of a zone is unexplored: "all", "some", or nil (none, or no pieces)
function Shade.Unexplored(mapID)
	local list = pieces[mapID]
	if not list or next(list) == nil then return nil end
	local any, all = false, true
	for _, piece in pairs(list) do
		if piece.unexplored then any = true else all = false end
	end
	return all and "all" or (any and "some" or nil)
end

-- near the view: its art rectangle and REACH round it (its border share), against S.Cull's box
function Shade.Near(mapID)
	local box = cullBox
	if not box then return true end
	local l, r, t, b = S.Rect(mapID)
	if not l then return false end
	local du, dv = Shade.REACH / W, Shade.REACH / H
	return r + du > box[1] and l - du < box[3] and b + dv > box[2] and t - dv < box[4]
end

-- a zone not found at all: its shade (and its share of the border land); one you've been to: its
-- pieces' copies; near the view only
function Shade.Show(mapID)
	local z = Shade.zones[mapID]
	local state = Shade.on and Shade.Unexplored(mapID)
	if not state then
		if z then
			z.frame:Hide()
			if z.dim then z.dim:Hide() end
		end
		return
	end
	if z == nil then z = Shade.Zone(mapID) end
	if not z then return end
	local here = Shade.Near(mapID)
	z.near = here
	z.frame:SetShown(here and state == "all")
	local some = here and state == "some"
	if some and not z.pieces then Shade.Pieces(mapID, z) end
	if z.dim then
		z.dim:SetShown(some)
		if some then Shade.Colour(mapID, z) end
	end
end

-- a zone's textures: those near the view (S.Cull's box), tile by tile, so zoomed in only the part
-- of a zone on screen is drawn (and has its files loaded), not all of every zone touching the view
-- A hidden one lets go of its anchor (and a zone's live-layer masks do while none of its live art can
-- show), so a pan or zoom doesn't lay out thousands of textures nobody sees: see Live, above
ShowZone = function(mapID)
	local here = inView[mapID] ~= false
	local inside = inView[mapID] == true          -- (in view and drawn: its files are wanted)
	local hide, strength = gradeNow[3] == "hide", gradeNow[1]
	local box = cullBox
	for _, e in ipairs(zoneTex[mapID] or NONE) do
		local tex = e[1]
		local near = here and (not box or not e.u0 or (e.u1 > box[1] and e.u0 < box[3] and e.v1 > box[2] and e.v0 < box[4]))
		local drawn = not e.layer or detailLive       -- (the live layers: only while they show; the cities: always)
		local un = e[3] and e[3].unexplored
		if near and drawn and inside and (detailLive or Live.seen) and tex.omFile and not tex.omQueued then
			tex.omQueued = true
			loadQueue[#loadQueue + 1] = tex
			loader:Show()
			Baked.busy = true
		end
		local show = near and drawn and not (un and hide) and (not e.twin or strength > 0)
		if e.shown ~= show then
			e.shown = show
			if show then
				if not tex:GetPoint() then PlaceRecord(tex.omRec) end
				tex:Show()
			else
				tex:Hide()
				tex:ClearAllPoints()
			end
		end
	end
	local want = (here and detailLive) and true or false
	if Live.placed[mapID] ~= want then
		Live.placed[mapID] = want
		for _, rec in ipairs(Live.masks[mapID] or NONE) do
			if want then PlaceRecord(rec) else rec[1]:ClearAllPoints() end
		end
	end
	Shade.Show(mapID)
end

-- for the debug overlay (Debug.lua): how much of the zone art has its files loaded, of all of
-- it; regions placed since the build (pins' anchors, close-up layers, marks); the load queue
function S.ArtStats()
	local loaded, total = 0, 0
	for _, list in pairs(zoneTex) do
		for _, e in ipairs(list) do
			total = total + 1
			if not e[1].omFile then loaded = loaded + 1 end
		end
	end
	local live = 0
	for _ in pairs(dynamic) do live = live + 1 end
	return loaded, total, live, #loadQueue - loadAt + 1
end

-- a zone texture's colour: some colour taken out. (The texture's own alpha is its load fade-in;
-- unexplored areas are darkened by the shades over them, Shade.Show)
GradeEntry = function(g, desat)
	g[1]:SetVertexColor(1, 1, 1, 1)
	g[1]:SetDesaturation(desat)
end

function S.ApplyGrade(strength, desat, unexplored)
	lastGrade = { strength, desat, unexplored }
	gradeNow = { strength, desat, unexplored }
	local grade = ns.MapGrade or {}
	Shade.on = unexplored == "dim"
	for _, g in ipairs(graded) do GradeEntry(g, desat) end
	for _, g in ipairs(twins) do
		local tex, m = g[1], grade[g[2]]
		tex:SetVertexColor(1 + (m[1] - 1) * strength, 1 + (m[2] - 1) * strength, 1 + (m[3] - 1) * strength, 1)
		tex:SetDesaturation(desat)
	end
	for mapID in pairs(zoneTex) do ShowZone(mapID) end
	if root then
		for _, c in ipairs(cities) do c.dark = nil end   -- (the grade above set their colours afresh)
		cities.Dim()
		cities.Banners()
	end
	-- the baked art only at the settings it was baked at (unexplored areas hidden: live, piece by piece)
	local art = ns.MapZoneArt
	Baked.use = (art and Baked.frame and strength == art.colorMatch and math.abs(desat - art.desaturate) < 0.001
		and unexplored ~= "hide") and true or false
	if root then
		appliedDetail = nil
		ApplyDetail()
	end
end

-- only what's near the view is drawn: each zone's art (tile by tile), the cities, the gap fill.
-- (Hidden regions cost nothing; at the closest zoom most of the world is off screen.) The box is
-- kept while the view stays well inside it, so a pan redoes it now and then, not every frame
-- margin: of the view's size, on every side; redone once the view comes `keep` near its edge (of
-- the view's size), or has zoomed in `zoom` times since (the box would be much too big).
-- (One table: the file is near Lua's limit of 200 locals)
local CULL = { margin = 0.35, keep = 0.1, zoom = 1.6 }
function S.Cull(u0, v0, u1, v1)
	if not root then return end
	local w, h = u1 - u0, v1 - v0
	local box = cullBox
	local keep = CULL.keep
	if box and w * CULL.zoom > box.w and u0 - w * keep > box[1] and u1 + w * keep < box[3]
		and v0 - h * keep > box[2] and v1 + h * keep < box[4] then return end
	local mu, mv = w * CULL.margin, h * CULL.margin
	u0, v0, u1, v1 = u0 - mu, v0 - mv, u1 + mu, v1 + mv
	cullBox = box or {}
	cullBox[1], cullBox[2], cullBox[3], cullBox[4], cullBox.w = u0, v0, u1, v1, w
	for mapID in pairs(zoneTex) do
		local l, r, t, b = S.Rect(mapID)
		local here = (l and r > u0 and l < u1 and b > v0 and t < v1) and true or false
		if here or inView[mapID] ~= here then        -- (one in view: its tiles near the new box)
			inView[mapID] = here
			ShowZone(mapID)
		end
	end
	for _, c in ipairs(culled) do
		local here = c[4] > u0 and c[2] < u1 and c[5] > v0 and c[3] < v1
		if c.here ~= here then
			c.here = here
			local r = c[1]
			if r.omRec then                          -- (a texture of its own, the gap paper: its anchor too, Live)
				if here then
					if not r:GetPoint() then PlaceRecord(r.omRec) end
				else
					r:ClearAllPoints()
				end
			end
			r:SetShown(here)
		end
	end
	Baked.Cull()
	-- the names: each letter is many font strings (its halo), all moved on every frame of a pan
	for _, n in ipairs(names) do
		local near = not n.l or (n.r > u0 and n.l < u1 and n.b > v0 and n.t < v1)
		if n.near ~= near then
			n.near = near
			n[1]:SetShown(near and (n[1].omFade or 0) > 0.003)
		end
	end
	if Shade.on then
		for mapID, z in pairs(Shade.zones) do
			if z and z.near ~= Shade.Near(mapID) then Shade.Show(mapID) end
		end
	end
	-- the pins' cells (S.AddPin)
	for _, set in pairs(sets) do
		for _, cell in pairs(set.cells or NONE) do
			local here = cell.u0 + PIN_CELL > u0 and cell.u0 < u1 and cell.v0 + PIN_CELL > v0 and cell.v0 < v1
			if cell.here ~= here then
				cell.here = here
				cell:SetShown(here)
			end
		end
	end
end

-- the baked tiles (Baked, above): each placed the first time it's near the view (its file set then),
-- and shown near the view (S.Cull's box) while the baked art shows
function Baked.Build()
	local art = ns.MapZoneArt
	if not art or not root then return end
	local f = CreateFrame("Frame", nil, root)
	f:SetAllPoints(root)
	f:SetFrameLevel(coreRoot:GetFrameLevel())   -- (in place of the live layers, under the blur and the cities)
	f:Hide()
	Baked.frame = f
	local size = art.step / art.px            -- world units a tile covers
	Baked.inset = (art.size - art.step) / 2 / art.size
	for _, key in ipairs(art.tiles) do
		local i, j = math.floor(key / 256), key % 256
		local x, y = i * size, j * size
		Baked.tiles[#Baked.tiles + 1] = { name = i .. "_" .. j, x = x, y = y, size = size,
			u0 = x / W, v0 = y / H, u1 = (x + size) / W, v1 = (y + size) / H }
	end
end

function Baked.Cull()
	local f, box = Baked.frame, cullBox
	if not f or not f:IsShown() then return end
	for _, t in ipairs(Baked.tiles) do
		local near = not box or (t.u1 > box[1] and t.u0 < box[3] and t.v1 > box[2] and t.v0 < box[4])
		if near and not t.tex then
			t.tex = f:CreateTexture(nil, "ARTWORK")
			t.tex:SetTexture(Baked.path .. t.name, nil, nil, "TRILINEAR")
			t.tex:SetTexCoord(Baked.inset, 1 - Baked.inset, Baked.inset, 1 - Baked.inset)
			Record(t.tex, t.x, t.y, t.size, t.size)
			t.shown = true
		end
		if t.tex and t.shown ~= near then
			t.shown = near
			t.tex:SetShown(near)
		end
	end
end

-- Whether each city has been found: its own map has no pieces to explore, so the pieces of the zone
-- maps under its centre (Orgrimmar's: Durotar's) say; with none there, it's found. A city's textures
-- share one stand-in piece, so hidden unexplored areas hide an unfound city as they do a piece, and the
-- zone's banner for it with it. (On `cities`: the file is near Lua's limit of 200 locals)
cities.Build = function()
	for _, c in ipairs(cities) do
		local l, r, t, b = S.Rect(c.mapID)
		local cx, cy = (l + r) / 2 * W, (t + b) / 2 * H
		c.covers, c.piece = {}, { key = "city" }
		for zoneID, list in pairs(pieces) do
			local p = Place(zoneID)
			if p then
				local x, y = (cx - p.left) / p.sx, (cy - p.top) / p.sy
				for key, piece in pairs(list) do
					local w, h, px, py = strsplit(":", key)
					w, h, px, py = tonumber(w), tonumber(h), tonumber(px), tonumber(py)
					if w and x >= px and x <= px + w and y >= py and y <= py + h then c.covers[#c.covers + 1] = piece end
				end
			end
		end
		for _, e in ipairs(zoneTex[c.mapID] or NONE) do e[3] = c.piece end
	end
	cities.Refresh()
end

cities.Refresh = function()
	for _, c in ipairs(cities) do
		local found = #c.covers == 0
		for _, piece in ipairs(c.covers) do
			if not piece.unexplored then found = true break end
		end
		c.piece.unexplored = not found
	end
end

-- the zones' banners for their cities: with the zone detail, giving way to the city's own (BANNER_OUT),
-- and gone with an unfound city while unexplored areas are hidden
cities.Banners = function()
	for _, c in ipairs(cities) do
		if c.banner then
			local out = ns.MapCityTitles and ns.MapCityTitles[c.mapID] and Smooth(BANNER_OUT[1] * c[2], BANNER_OUT[2] * c[2]) or 0
			local lost = gradeNow[3] == "hide" and c.piece and c.piece.unexplored
			Fade(c.banner, lost and 0 or math.floor(detailNow * (1 - out) * 50 + 0.5) / 50)
		end
	end
end

-- an unfound city while unexplored areas are darkened: its own map and the zone's banner for it
-- darkened as the zone's unexplored art is (Shade.DIM). Both are drawn over the darkening (the banner
-- over everything, the city over a visited zone's darkened pieces), so it doesn't reach them
cities.Dim = function()
	local D = Shade.DIM
	local strength, desat = gradeNow[1], gradeNow[2]
	for _, c in ipairs(cities) do
		local dark = Shade.on and c.piece and c.piece.unexplored and true or false
		if c.dark ~= dark then
			c.dark = dark
			local m = ns.MapGrade and ns.MapGrade[c.mapID]
			for _, e in ipairs(zoneTex[c.mapID] or NONE) do
				local r, g, b = 1, 1, 1
				if e.twin and m then r, g, b = 1 + (m[1] - 1) * strength, 1 + (m[2] - 1) * strength, 1 + (m[3] - 1) * strength end
				if dark then r, g, b = r * D[1], g * D[2], b * D[3] end
				e[1]:SetVertexColor(r, g, b, 1)
				e[1]:SetDesaturation(dark and math.max(desat, D[4]) or desat)
			end
			if c.bannerTex then
				c.bannerTex:SetVertexColor(dark and D[1] or 1, dark and D[2] or 1, dark and D[3] or 1, 1)
				c.bannerTex:SetDesaturation(dark and D[4] or 0)
			end
		end
	end
end

-- the player explored somewhere: its pieces stop being unexplored (MAP_EXPLORATION_UPDATED)
function S.RefreshExplored()
	local changed = false
	for mapID, list in pairs(pieces) do
		local now = {}
		for _, info in ipairs(C_MapExplorationInfo.GetExploredMapTextures(mapID) or {}) do
			now[info.textureWidth .. ":" .. info.textureHeight .. ":" .. info.offsetX .. ":" .. info.offsetY] = true
		end
		for key, piece in pairs(list) do
			local un = not now[key]
			if piece.unexplored ~= un then piece.unexplored, changed = un, true end
		end
	end
	if changed then cities.Refresh() end
	if changed and lastGrade then S.ApplyGrade(unpack(lastGrade)) end
end
