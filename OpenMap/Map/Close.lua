--------------------------------------------------------------------------------
-- The closest zoom levels: where Blizzard's art runs out of pixels.
--   minimap    the game's minimap tiles over the painted map (ns.MapMinimap): their own
--              colours, softened and warmed toward the parchment with a hint of the zone's
--              own (ns.MapTones), adding real tree cover, rocks and buildings.
--              A plain blend: it can't brighten past white (an additive one blew out pale
--              zones like Tanaris), and it leaves the map opaque (a multiply, in game,
--              also multiplies the map's opacity and the world shows through).
--   soft       the zone art blurred a little (S.SetBlur: a five-tap blur of the zones
--              in view) and parchment grain + paper tooth laid over, so stretched art
--              reads as close-up paper, not pixels
--   underground caves and pre-instance areas (ns.MapCaves, Blizzard's own micro maps,
--              frameless: MapCave masks). Zoom right in on one and the surface dims as
--              its map surfaces in at its real place; zoom back out and it sinks.
-- Everything here follows the view: S.SetView from WorldMap.lua on every pan / zoom.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local mod = ns:GetModule("worldmap")

local d = mod.defaults
d.minimap = true                -- the minimap's detail up close at all (off: the painted map alone, everywhere)
d.minimapMix = 0.45             -- how strong the minimap's detail is up close (0 = none)
d.minimapDeep = 0.85            -- the most it shows at any zoom (reached at the deepest, where the painted map has nothing left)
d.minimapFrom = 20              -- the zoom where it starts to mix in (MINI_FROM: what it can be set to)
d.soften = true                 -- soften + paper grain at the closest zoom
d.underground = true            -- caves and pre-instance areas
d.gapMinimap = false            -- the minimap in land no zone map covers (experimental: off, that land is left as
                                --  the zone maps' blank parchment, an unfinished map)

local MINI_FADE = { 20, 34 }    -- zoom where the minimap mixes in (at minimapFrom 20: both move with it)
local DEEP_FADE = { 30, 48 }    -- ... and where it takes over, toward minimapDeep
local MINI_FROM = { 1, 60, 1 }  -- minimapFrom's least (the whole world), most, step
mod.MINI_FROM = MINI_FROM
local miniFade, deepFade = { 20, 34 }, { 30, 48 }   -- (the fades as set: kept, not made each view)
local CITY_MINI = 0.5           -- the most the minimap shows over a city's own map
local CITY_MINI_OF = {          -- ... less over these: their own plan is detailed, and comes in from further out
	[1454] = 0.15,              --  (Orgrimmar)
	[1456] = 0.15,              --  (Thunder Bluff)
}
local GAP_FADE, GAP_MIX = { 4, 8 }, 0.6   -- ... and in the gaps between zones: where, and how strongly
local GAP_MAX = 220             -- tiles at most (it starts further out, so more are in view)
local SOFT_FADE = { 8, 18 }    -- ... the softening and grain
local UNDER_START, UNDER_FULL = 1.5, 1.05   -- view width / cave width where a cave starts / finishes surfacing
-- (some sooner: a landmark you look at from further out, Blackrock Mountain's inside)
local UNDER_START_OF = { [33] = 4 }
-- (and a mountain's deeper floors never surface by themselves: they lie under its main one,
-- Blackrock Caverns and the way down to the Depths under Blackrock Mountain)
local UNDER_SKIP = { [34] = true, [35] = true }
local TILE = 1600 / 3           -- yards per minimap tile
-- the overlay: painted * (1 - mix) + mix * tint * mini. The minimap keeps its own colours,
-- softened (MINI_DESAT) and warmed toward the map's parchment (PAPER), with only a hint of
-- the zone's own colour (TONE_SHARE), so it sits in the painted map's palette without
-- being recoloured
local MINI_DESAT = 0.35
local PAPER = { 1, 0.93, 0.80 }
local TONE_SHARE = 0.25
local DEFAULT_TONE = { 0.56, 0.45, 0.17 }    -- (the zone art's average, where a zone has no tone)

-- a tile's tint from a zone colour: the parchment warmth, a quarter of the way to the zone's
-- colour brought up to full brightness
local function Tint(tone)
	local top = math.max(tone[1], tone[2], tone[3], 1e-3)
	local r, g, b = tone[1] / top, tone[2] / top, tone[3] / top
	return PAPER[1] + (r - PAPER[1]) * TONE_SHARE, PAPER[2] + (g - PAPER[2]) * TONE_SHARE, PAPER[3] + (b - PAPER[3]) * TONE_SHARE
end

local function TileTone(u, v)
	local chain = S.ChainAt(u, v)
	return Tint(ns.MapTones and ns.MapTones[chain[#chain]] or DEFAULT_TONE)
end
local GRAIN = ns.Media.path .. "Textures\\MapGrain"
local TOOTH = ns.Media.path .. "Textures\\MapTooth"
local CONT_OF = { [1415] = 0, [1414] = 1 }
local CONT_MAP = { [0] = 1415, [1] = 1414 }

local function Smooth(x, r)
	local t = math.max(0, math.min(1, (x - r[1]) / (r[2] - r[1])))
	return t * t * (3 - 2 * t)
end

-- the continent (0 / 1) the view's centre is on: looked up again only once the centre has
-- moved a little (the game's lookup makes tables, and this runs every frame of a pan or zoom)
local lastCU, lastCV, lastCont
local function ContinentAt(u, v)
	if lastCU and math.abs(u - lastCU) < 0.002 and math.abs(v - lastCV) < 0.002 then return lastCont end
	lastCU, lastCV, lastCont = u, v, nil
	for _, id in ipairs(S.ChainAt(u, v)) do
		if CONT_OF[id] then lastCont = CONT_OF[id] break end
	end
	return lastCont
end

-- every continent (0 / 1) whose map the view overlaps (one list, reused)
local contsInView = {}
local function ContinentsInView(u, v, hu, hv)
	local out = contsInView
	wipe(out)
	for mapID, cont in pairs(CONT_OF) do
		local l, r, t, b = S.Rect(mapID)
		if l and r > u - hu and l < u + hu and b > v - hv and t < v + hv then out[#out + 1] = cont end
	end
	return out
end

--------------------------------------------------------------------------------
-- Minimap tiles
--------------------------------------------------------------------------------

local tiles, pool = {}, {}      -- cont * 4096 + index -> { texture }
local TileKey = function(cont, tx, ty) return cont * 4096 + tx * 64 + ty end   -- (a number: no string a tile a frame)
local wantedTiles, wantedGap = {}, {}   -- (reused each update)

-- a tile, through its continent's land (S.LandMask): the minimap's sea is left out
local function Tile(layer, fid, cont)
	local t = tremove(pool)
	if not t then
		t = { layer:CreateTexture(nil, "ARTWORK") }
		t[1]:SetDesaturation(MINI_DESAT)
	end
	local mask = CONT_MAP[cont] and S.LandMask and S.LandMask(layer, CONT_MAP[cont])
	if t.mask ~= mask then
		if t.mask then t[1]:RemoveMaskTexture(t.mask) end
		if mask then t[1]:AddMaskTexture(mask) end
		t.mask = mask
	end
	t[1]:SetTexture(fid, nil, nil, "LINEAR")
	return t
end

local function DropTile(key)
	local t = tiles[key]
	for _, tex in ipairs(t) do tex:Hide(); S.UnplaceWorld(tex) end
	tiles[key] = nil
	pool[#pool + 1] = t
end

-- The smaller copies of the minimap (ns.MapMinimapLOD, tools/map-preview/minimaplod.py): its detail
-- from further out than its own tiles can be drawn (at most 64 of them; a continent is over a
-- thousand). Each copy is cut into pieces of `per` tiles a side, tinted as the tiles are. Drawn
-- coarse under fine under the game's own tiles, their strengths set so the three add up to `mix`:
-- the finer takes over as fewer tiles are in view
local LOD = ns.Media.path .. "Textures\\MapMiniLOD\\"
local NATIVE_FROM = { 64, 36 }  -- tiles in view where the game's own tiles start / finish taking over
local FINE_FROM = { 40, 24 }    -- tiles across the view where the finer copy starts / finishes taking over
local lodPieces, lodPool, wantedLOD = {}, {}, {}   -- key -> texture; free textures; (reused each update)
local lodSets = {}              -- (continent * 2 + level) -> { [col * 64 + row] = true }

local function LODSet(cont, level, keys)
	local k = cont * 2 + level
	if not lodSets[k] then
		local set = {}
		for _, key in ipairs(keys) do set[key] = true end
		lodSets[k] = set
	end
	return lodSets[k]
end

local function LODPiece(layer, cont, sub)
	local t = tremove(lodPool) or layer:CreateTexture(nil, "ARTWORK")
	t:SetDrawLayer("ARTWORK", sub)
	t:SetDesaturation(MINI_DESAT)
	local mask = CONT_MAP[cont] and S.LandMask and S.LandMask(layer, CONT_MAP[cont])
	if t.omMask ~= mask then
		if t.omMask then t:RemoveMaskTexture(t.omMask) end
		if mask then t:AddMaskTexture(mask) end
		t.omMask = mask
	end
	return t
end

-- one copy's pieces over the tiles tx0 .. tx1, ty0 .. ty1, at `alpha`
local function ShowLOD(layer, cont, level, per, keys, tx0, tx1, ty0, ty1, alpha)
	local set = LODSet(cont, level, keys)
	for col = math.floor(tx0 / per), math.floor(tx1 / per) do
		for row = math.floor(ty0 / per), math.floor(ty1 / per) do
			if set[col * 64 + row] then
				local key = ((cont * 2 + level) * 64 + col) * 64 + row
				wantedLOD[key] = true
				local t = lodPieces[key]
				if not t then
					t = LODPiece(layer, cont, -level)
					t:SetTexture(LOD .. cont .. "_" .. per .. "_" .. col .. "_" .. row, nil, nil, "LINEAR")
					lodPieces[key] = t
					local u0, v0 = S.FromYards(cont, (32 - row * per) * TILE, (32 - col * per) * TILE)
					local u1, v1 = S.FromYards(cont, (32 - (row + 1) * per) * TILE, (32 - (col + 1) * per) * TILE)
					S.PlaceWorld(t, math.min(u0, u1), math.min(v0, v1), math.max(u0, u1), math.max(v0, v1))
					t:Show()
				end
				t:SetAlpha(alpha)
			end
		end
	end
end

local function UpdateMinimap(layer, conts, u, v, hu, hv, mix)
	local wanted = wantedTiles
	wipe(wanted)
	wipe(wantedLOD)
	for _, cont in ipairs(conts) do
		local list = ns.MapMinimap and ns.MapMinimap[cont]
		local xa, ya, xb, yb
		if list and mix > 0.01 then
			xa, ya = S.ToYards(cont, u - hu, v - hv)
			xb, yb = S.ToYards(cont, u + hu, v + hv)
		end
		if xa and xb then
			local tx0, tx1 = math.floor(32 - math.max(ya, yb) / TILE), math.floor(32 - math.min(ya, yb) / TILE)
			local ty0, ty1 = math.floor(32 - math.max(xa, xb) / TILE), math.floor(32 - math.min(xa, xb) / TILE)
			local count, across = (tx1 - tx0 + 1) * (ty1 - ty0 + 1), math.max(tx1 - tx0 + 1, ty1 - ty0 + 1)
			-- how much each shows: the game's tiles, the finer copy, the coarser
			local lods = ns.MapMinimapLOD and ns.MapMinimapLOD[cont]
			local wn = count <= 64 and (lods and Smooth(count, NATIVE_FROM) or 1) or 0
			local fine = Smooth(across, FINE_FROM)
			local a3 = mix * wn
			local a2 = a3 < 1 and mix * (1 - wn) * fine / (1 - a3) or 0
			local a1 = mix * (1 - wn) * (1 - fine) / math.max(1e-3, (1 - a2) * (1 - a3))
			if lods then
				for level, lv in ipairs(lods) do               -- (finest first)
					local a = level == 1 and a2 or a1
					if a > 0.005 then ShowLOD(layer, cont, level, lv[1], lv[2], tx0, tx1, ty0, ty1, math.min(1, a)) end
				end
			end
			if count <= 64 and a3 > 0.005 then
				for tx = tx0, tx1 do
					for ty = ty0, ty1 do
						local fid = list[tx * 64 + ty]
						if fid then
							local key = TileKey(cont, tx, ty)
							wanted[key] = true
							local t = tiles[key]
							if not t then
								t = Tile(layer, fid, cont)
								tiles[key] = t
								local u0, v0 = S.FromYards(cont, (32 - ty) * TILE, (32 - tx) * TILE)
								local u1, v1 = S.FromYards(cont, (31 - ty) * TILE, (31 - tx) * TILE)
								t[1]:SetVertexColor(TileTone((u0 + u1) / 2, (v0 + v1) / 2))
								for _, tex in ipairs(t) do
									S.PlaceWorld(tex, math.min(u0, u1), math.min(v0, v1), math.max(u0, u1), math.max(v0, v1))
									tex:Show()
								end
							end
							t[1]:SetAlpha(a3)
						end
					end
				end
			end
		end
	end
	for key in pairs(tiles) do
		if not wanted[key] then DropTile(key) end
	end
	for key, t in pairs(lodPieces) do
		if not wantedLOD[key] then
			t:Hide(); S.UnplaceWorld(t)
			lodPieces[key] = nil
			lodPool[#lodPool + 1] = t
		end
	end
end

--------------------------------------------------------------------------------
-- The minimap in the gaps (experimental): land no zone map covers (west of Searing Gorge,
-- Mount Hyjal ...) gets the game's minimap of it, from further out than the close-up
-- overlay. Drawn under every zone, through a soft mask of the gaps (MapGapMask), so it
-- fades out at their edges; void tiles past the world's edge are left out (gapfill.py);
-- tinted with the nearest zone's colour.
--------------------------------------------------------------------------------

local gapTiles, gapPools = {}, {}   -- key -> texture; continent -> its free textures (each masked by its land)
local gapSets                   -- continent mapID -> { [x * 64 + y] = true }: the tiles touching a gap

local function GapSet(mapID)
	gapSets = gapSets or {}
	if gapSets[mapID] == nil then
		local set = {}
		for _, key in ipairs(ns.MapGaps and ns.MapGaps.minimap and ns.MapGaps.minimap[mapID] or {}) do set[key] = true end
		gapSets[mapID] = set
	end
	return gapSets[mapID]
end

-- the nearest zone's colour, looking a little way round a point in a gap
local GAP_REACH = { 0, 0.004, 0.009, 0.016 }
local function GapTone(u, v)
	for _, reach in ipairs(GAP_REACH) do
		for k = 0, reach > 0 and 7 or 0 do
			local a = k * math.pi / 4
			local chain = S.ChainAt(u + math.cos(a) * reach, v + math.sin(a) * reach * 1.5)
			local tone = ns.MapTones and ns.MapTones[chain[#chain]]
			if tone then return tone end
		end
	end
	return DEFAULT_TONE
end

local function UpdateGapMinimap(conts, u, v, hu, hv, alpha)
	local wanted, n = wantedGap, 0
	wipe(wanted)
	local layer = S.GapLayer and S.GapLayer()
	for _, cont in ipairs(conts) do
		local list = ns.MapMinimap and ns.MapMinimap[cont]
		local mapID = CONT_MAP[cont]
		local landMask = mapID and S.GapMask and S.GapMask(mapID)
		local xa, ya, xb, yb
		if list and alpha > 0.01 and layer and landMask and ns.MapGaps then
			xa, ya = S.ToYards(cont, u - hu, v - hv)
			xb, yb = S.ToYards(cont, u + hu, v + hv)
		end
		if xa and xb then
			local set = GapSet(mapID)
			local pool = gapPools[cont] or {}
			gapPools[cont] = pool
			local tx0, tx1 = math.floor(32 - math.max(ya, yb) / TILE), math.floor(32 - math.min(ya, yb) / TILE)
			local ty0, ty1 = math.floor(32 - math.max(xa, xb) / TILE), math.floor(32 - math.min(xa, xb) / TILE)
			for tx = tx0, tx1 do
				for ty = ty0, ty1 do
					local fid = list[tx * 64 + ty]
					if fid and n < GAP_MAX and set[tx * 64 + ty] then
						local u0, v0 = S.FromYards(cont, (32 - ty) * TILE, (32 - tx) * TILE)
						local u1, v1 = S.FromYards(cont, (31 - ty) * TILE, (31 - tx) * TILE)
						local cu, cv = (u0 + u1) / 2, (v0 + v1) / 2
						do
							n = n + 1
							local key = TileKey(cont, tx, ty)
							wanted[key] = true
							local tex = gapTiles[key]
							if not tex then
								tex = tremove(pool)
								if not tex then
									tex = layer:CreateTexture(nil, "ARTWORK", nil, 5)
									tex:SetDesaturation(MINI_DESAT)
									tex:AddMaskTexture(landMask)
									tex.cont = cont
								end
								tex:SetTexture(fid, nil, nil, "LINEAR")
								tex:SetVertexColor(Tint(GapTone(cu, cv)))
								S.PlaceWorld(tex, math.min(u0, u1), math.min(v0, v1), math.max(u0, u1), math.max(v0, v1))
								tex:Show()
								gapTiles[key] = tex
							end
							tex:SetAlpha(alpha)
						end
					end
				end
			end
		end
	end
	for key, tex in pairs(gapTiles) do
		if not wanted[key] then
			tex:Hide()
			S.UnplaceWorld(tex)
			gapTiles[key] = nil
			local pool = gapPools[tex.cont] or {}
			gapPools[tex.cont] = pool
			pool[#pool + 1] = tex
		end
	end
	return n
end

--------------------------------------------------------------------------------
-- Paper grain: two octaves each of mottling and tooth, laid on the map (they move
-- with it) and crossfaded so the grain always looks the same size on screen
--------------------------------------------------------------------------------

local grain
-- (laid over a box well past the view, as the sea's: the grain is fixed on the world, so a pan
-- lays it again only near the box's edge; a zoom or a change of strength, every time)
local GRAIN_BOX = 1.8           -- the box's half extents, of the view's
local grainBox = {}             -- { u0, v0, u1, v1, hu =, amount = } as last laid

local function UpdateGrain(layer, u, v, hu, hv, amount)
	if not grain then
		grain = {}
		for i, spec in ipairs({ { GRAIN, 1 }, { GRAIN, 2 }, { TOOTH, 1 }, { TOOTH, 2 } }) do
			local tex = layer:CreateTexture(nil, "OVERLAY", nil, i)
			tex:SetTexture(spec[1], "REPEAT", "REPEAT")
			grain[i] = { tex = tex, octave = spec[2], tooth = spec[1] == TOOTH }
		end
	end
	local gb = grainBox
	if amount <= 0.01 then
		if gb.amount ~= 0 then
			for _, g in ipairs(grain) do g.tex:Hide() end
			gb.amount = 0
		end
		return
	end
	if gb.hu == hu and gb.amount == amount and u - hu * 1.2 > gb[1] and u + hu * 1.2 < gb[3]
		and v - hv * 1.2 > gb[2] and v + hv * 1.2 < gb[4] then return end
	local W, H = S.Size()
	local u0, u1, v0, v1 = u - hu * GRAIN_BOX, u + hu * GRAIN_BOX, v - hv * GRAIN_BOX, v + hv * GRAIN_BOX
	gb[1], gb[2], gb[3], gb[4], gb.hu, gb.amount = u0, v0, u1, v1, hu, amount
	local want = math.log(hu * 2 * W * 0.35) / math.log(2)      -- a mottle tile ~ a third of the view
	local n = math.floor(want)
	local f = want - n
	for _, g in ipairs(grain) do
		local size = 2 ^ (n + g.octave - 1) / (g.tooth and 6 or 1)          -- world units
		local a = (g.octave == 1 and (1 - f) or f) * amount * (g.tooth and 0.9 or 0.7)
		g.tex:SetTexCoord(u0 * W / size, u1 * W / size, v0 * H / size, v1 * H / size)
		S.PlaceWorld(g.tex, u0, v0, u1, v1)
		g.tex:SetAlpha(a)
		g.tex:Show()
	end
end

--------------------------------------------------------------------------------
-- Underground: caves and pre-instance areas
--------------------------------------------------------------------------------

local caves = {}                -- uiMapID -> { frame, tiles = {}, rect = { u0, v0, u1, v1 } }, or false
local dim

local function CaveRect(c)
	-- the art covers its world box (UiMin / UiMax are almost always 0..1)
	local u0, v0 = S.FromYards(c[2], c[5], c[6])       -- north-west: max X, max Y
	local u1, v1 = S.FromYards(c[2], c[3], c[4])
	if not u0 or not u1 then return end
	return math.min(u0, u1), math.min(v0, v1), math.max(u0, u1), math.max(v0, v1)
end

local function Cave(layer, id, c)
	local cave = caves[id]
	if cave then return cave end
	local u0, v0, u1, v1 = CaveRect(c)
	if not u0 then caves[id] = false return false end
	cave = { tiles = {}, rect = { u0, v0, u1, v1 } }
	local frame = CreateFrame("Frame", nil, layer)
	frame:SetAllPoints(layer)
	frame:SetFrameLevel(layer:GetFrameLevel() + 1)
	cave.frame = frame
	local mask = frame:CreateMaskTexture()
	mask:SetTexture(S.CaveMasks .. id, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	S.PlaceWorld(mask, u0, v0, u1, v1)
	local tw, th = (u1 - u0) / (1002 / 256), (v1 - v0) / (668 / 256)   -- one 256 px tile in world units
	for n, fid in ipairs(c[11]) do
		local col, row = (n - 1) % 4, math.floor((n - 1) / 4)
		local pw, ph = math.min(256, 1002 - col * 256), math.min(256, 668 - row * 256)
		local tex = frame:CreateTexture(nil, "ARTWORK")
		tex:SetTexture(fid, nil, nil, "TRILINEAR")
		tex:SetTexCoord(0, pw / 256, 0, ph / 256)
		local x0, y0 = u0 + col * tw, v0 + row * th
		S.PlaceWorld(tex, x0, y0, x0 + tw * pw / 256, y0 + th * ph / 256)
		tex:AddMaskTexture(mask)
		cave.tiles[#cave.tiles + 1] = tex
	end
	caves[id] = cave
	return cave
end

-- how far each cave near the view has surfaced (0..1); the deepest wins
-- one floor per place: a cave or dungeon entrance with several floors in one spot (Tiragarde
-- Keep ...) shows its first
local primary
local function Primary(id, c)
	if not primary then
		primary = {}
		for k, cc in pairs(ns.MapCaves or {}) do
			if not UNDER_SKIP[k] and (not primary[cc[1]] or k < primary[cc[1]]) then primary[cc[1]] = k end
		end
	end
	return primary[c[1]] == id
end

-- Every cave map in view surfaces by the zoom alone (UNDER_START .. UNDER_FULL of its width),
-- and stays while it's on screen. The surface above dims and softens for the one you're
-- centred on only, so panning about doesn't darken the whole map.
local underShown = {}           -- (reused each update)
local underRange = {}           -- cave id -> its { full, start } (made once: no table a cave a frame)
local FOCUS_RANGE = { 0.35, 0.8 }
local function UpdateUnderground(layer, cont, u, v, hu, hv)
	local shown, focus = underShown, 0
	wipe(shown)
	if mod.db.underground and cont and ns.MapCaves then
		for id, c in pairs(ns.MapCaves) do
			if c[2] == cont and not UNDER_SKIP[id] and Primary(id, c) then
				local u0, v0, u1, v1 = CaveRect(c)
				if u0 and u1 > u - hu and u0 < u + hu and v1 > v - hv and v0 < v + hv then
					local fill = (2 * hu) / (u1 - u0)          -- view width / cave width
					local range = underRange[id]
					if not range then range = { UNDER_FULL, UNDER_START_OF[id] or UNDER_START } underRange[id] = range end
					local tz = 1 - Smooth(fill, range)
					if tz > 0.01 then
						shown[id] = tz
						local cu, cv = (u0 + u1) / 2, (v0 + v1) / 2
						local off = math.max(math.abs(cu - u) / hu, math.abs(cv - v) / hv)
						focus = math.max(focus, tz * (1 - Smooth(off, FOCUS_RANGE)))
					end
				end
			end
		end
	end
	for id, cave in pairs(caves) do
		if cave and not shown[id] then cave.frame:Hide() end
	end
	for id, t in pairs(shown) do
		local cave = Cave(layer, id, ns.MapCaves[id])
		if cave then
			cave.frame:Show()
			cave.frame:SetAlpha(t)
		end
	end
	if not dim then
		dim = layer:CreateTexture(nil, "BACKGROUND")
		dim:SetColorTexture(0.05, 0.035, 0.02, 1)
	end
	if focus > 0.01 then
		S.PlaceWorld(dim, u - hu * 1.5, v - hv * 1.5, u + hu * 1.5, v + hv * 1.5)
		dim:SetAlpha(0.45 * focus)
		dim:Show()
	else
		dim:Hide()
	end
	S.SetUnderground(focus)
	return focus
end

-- the cave holding a world position (yards), for the entrance icons
function S.CaveAt(cont, x, y)
	for id, c in pairs(ns.MapCaves or {}) do
		if c[2] == cont and x >= c[3] and x <= c[5] and y >= c[4] and y <= c[6] then
			local u0, v0, u1, v1 = CaveRect(c)
			if u0 then return id, u0, v0, u1, v1 end
		end
	end
end

--------------------------------------------------------------------------------

-- each part runs on its own: one failing (a client difference) mustn't take the others
-- with it. Its error is reported once, and /openmap status lists it.
local failed = {}
S.closeFailed = failed
local stepMs = {}               -- each step's time (ms, smoothed) and its worst, for /openmap status
S.closeSteps = stepMs
local function Try(name, fn, ...)
	local start = debugprofilestop and debugprofilestop()
	local ok, a, b = pcall(fn, ...)
	if start then
		local ms = debugprofilestop() - start
		local s = stepMs[name] or { ms = ms, worst = 0 }
		s.ms, s.worst = s.ms * 0.9 + ms * 0.1, math.max(s.worst, ms)
		stepMs[name] = s
	end
	if ok then return a, b end
	if not failed[name] then
		failed[name] = tostring(a)
		geterrorhandler()(("OpenMap %s: %s"):format(name, tostring(a)))
	end
end

-- the view: centre (normalized), half extents (normalized), zoom (by the area in view: WorldMap.lua's
-- DetailK), and `steps`: the plain zoom, from the whole world fitting, as far as the wheel has gone.
-- The minimap's fades go by that: the same wheel turns in a small window or full screen (by the
-- area, the full screen's wide view took it in later)
S.closeView = {}
function S.SetView(u, v, hu, hv, zoom, steps)
	steps = steps or zoom
	local L = S.closeLayers
	if not L then return end
	local cv = S.closeView
	local start = debugprofilestop and debugprofilestop()
	cv.zoom, cv.time, cv.updates = zoom, GetTime(), (cv.updates or 0) + 1
	if S.Moved then S.Moved() end
	local cont = Try("continent", ContinentAt, u, v)
	Try("sea", S.SetSea, u, v, hu, hv)
	Try("culling", S.Cull, u - hu, v - hv, u + hu, v + hv)
	local soft = mod.db.soften and Smooth(zoom, SOFT_FADE) or 0
	cv.soft = soft
	Try("blur", S.SetBlur, soft, u - hu, v - hv, u + hu, v + hv)
	local base = mod.db.minimap and mod.db.minimapMix or 0
	local k = (mod.db.minimapFrom or MINI_FADE[1]) / MINI_FADE[1]          -- (sooner or later: the fades scale with it)
	-- (the take-over toward minimapDeep moves later with it, never sooner: it's where the painted
	-- map runs out of detail)
	miniFade[1], miniFade[2] = MINI_FADE[1] * k, MINI_FADE[2] * k
	deepFade[1], deepFade[2] = DEEP_FADE[1] * math.max(1, k), DEEP_FADE[2] * math.max(1, k)
	local most = mod.db.minimapDeep or 1                     -- (the most it ever shows)
	local from = mod.db.minimapFrom or MINI_FADE[1]
	local mix = math.min(base, most) * (from <= MINI_FROM[1] and 1 or Smooth(steps, miniFade))   -- (at the least: from the whole world)
	if base > 0 then mix = mix + (most - mix) * Smooth(steps, deepFade) end
	-- not over a city's own map (the minimap there is the surface, not the city)
	mix = mix * (1 - (Try("cities", S.CityCover, u, v) or 0))
	-- and over the cities on the surface no more than CITY_MINI (or the city's own): their own plan leads
	local city, cityID = Try("surface cities", S.SurfaceCityCover, u, v)
	local most = CITY_MINI_OF[cityID] or CITY_MINI
	if mix > most then mix = mix + (most - mix) * (city or 0) end
	cv.mix = mix
	local conts = Try("continents", ContinentsInView, u, v, hu, hv) or {}
	Try("minimap", UpdateMinimap, L.minimap, conts, u, v, hu, hv, mix)
	cv.gapTiles = Try("minimap in the gaps", UpdateGapMinimap, conts, u, v, hu, hv,
		mod.db.minimap and mod.db.gapMinimap and GAP_MIX * Smooth(steps, GAP_FADE) or 0)
	local under = Try("underground", UpdateUnderground, L.under, cont, u, v, hu, hv) or 0
	-- the out-of-focus world above a cave gets heavier grain
	Try("grain", UpdateGrain, L.grain, u, v, hu, hv, math.max(soft, math.min(1.4, under * 1.4)))
	for i, fn in ipairs(S.viewHooks) do Try("view hook " .. i, fn, u, v, hu, hv, zoom) end
	local n = 0
	for _ in pairs(tiles) do n = n + 1 end
	cv.tiles = n
	if start then
		local ms = debugprofilestop() - start
		cv.ms = (cv.ms or ms) * 0.9 + ms * 0.1
		cv.worst = math.max(cv.worst or 0, ms)
	end
end

function mod:CloseOptions(opts, get, set, off)
	local function noMinimap() return off() or not mod.db.minimap end
	opts.closeHeader = ns.Header("Up close", 50)
	opts.minimap = { type = "toggle", name = "Minimap detail", order = 50.5, width = "full", get = get, set = set, disabled = off,
		desc = "At the closest zoom, mix in the game's minimap for detail (tree cover, rocks, buildings). Off, the painted map is all you see, however far you zoom." }
	opts.minimapMix = { type = "range", name = "Minimap strength", order = 51, min = 0, max = 0.8, step = 0.05, isPercent = true,
		get = get, set = set, disabled = noMinimap,
		desc = "At the closest zoom, how much of the game's minimap is mixed in for detail. The painted map always leads." }
	opts.minimapFrom = { type = "range", name = "Minimap detail from zoom", order = 51.1, min = MINI_FROM[1], max = MINI_FROM[2], step = MINI_FROM[3],
		get = get, set = set, disabled = function() return noMinimap() or (mod.db.minimapMix or 0) == 0 end,
		desc = "How far in (in times the whole-world view) the minimap's detail starts to mix in: lower comes in sooner, higher later; at 1x it's there from the whole world. Further out than its own tiles can be drawn, smaller copies of it show." }
	opts.minimapDeep = { type = "range", name = "Minimap detail, most opacity", order = 51.2, min = 0, max = 1, step = 0.05, isPercent = true,
		get = get, set = set, disabled = function() return noMinimap() or (mod.db.minimapMix or 0) == 0 end,
		desc = "The most the minimap's detail ever shows, at any zoom: zooming in past where the painted map has any detail left, it takes over toward this." }
	opts.gapMinimap = { type = "toggle", name = "Minimap in the gaps (experimental)", order = 51.5, get = get, set = set, disabled = noMinimap,
		desc = "Land no zone map covers (west of Searing Gorge, Mount Hyjal ...) shows the game's minimap of it, tinted like the zones around it, instead of blank paper." }
	opts.soften = { type = "toggle", name = "Soften and add paper grain", order = 52, get = get, set = set, disabled = off,
		desc = "At the closest zoom the painted map runs out of pixels: soften it and lay paper grain over it." }
	opts.underground = { type = "toggle", name = "Caves and dungeon entrances", order = 53, get = get, set = set, disabled = off,
		desc = "Zoom right in on a cave or a dungeon's entrance area and its map surfaces from underground." }
end
