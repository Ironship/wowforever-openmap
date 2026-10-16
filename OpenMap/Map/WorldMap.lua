--------------------------------------------------------------------------------
-- OpenMap: Blizzard's world map (quest log, controls, Questie) with every
-- zone stitched into one canvas (ns.MapStitch). More map helpers are in
-- Extras.lua, Flights.lua, Townsfolk.lua, Panel.lua, Paint.lua and Gamepad.lua.
--
-- On the world, continent and zone maps:
--   * the stitched art is a layer just above Blizzard's map art, under its pins
--   * zoom runs from the whole world down to street level, anchored at the cursor
--   * panning runs past the map's edge into its neighbours
--   * once the view settles, the map underneath quietly becomes the zone (or
--     continent) you're looking at, so quest areas, coordinates and the zone
--     name always match what's on screen
--   * left-click zooms into the place under the cursor, right-click out a level
-- Other maps (dungeons, battlegrounds) behave as Blizzard made them.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local WORLD = S.WORLD

local mod = ns:NewModule("worldmap", {
	defaults = {
		enabled = true,
		autoSwitch = true,      -- the map underneath follows what you're looking at
		hoverHighlight = false, -- Blizzard's glow on the zone under the cursor (on the stitched map)
		icons = true,
		flight = true,
		routes = false,         -- boat and zeppelin routes
		colorMatch = 1,         -- how far zone borders move to the shared palette
		desaturate = 0.1,
		unexplored = "show",    -- areas not explored yet: "show", "dim" or "hide"
		maxZoom = 48,           -- x the whole-world view (MAX_ZOOM: what it can be set to)
	},
})

local ZOOM_STEP = 1.25          -- each wheel notch
local MAX_ZOOM = { 16, 192, 8 } -- the deepest zoom's setting: least, most, step (the minimap's own detail runs out
                                --  near 48; past it the painted map and the minimap are only enlarged)
mod.MAX_ZOOM = MAX_ZOOM
local ENTER, LEAVE = 0.9, 0.7   -- switch into a map at this share of its fit zoom; leave it below that
local ART_RANGE = 80            -- frame levels the stitched art needs

local map, sc
local active = false            -- the current map is stitched
local switching = false         -- we're changing the map ourselves
local userMoved = false         -- the view moved since Blizzard last showed a map (only then do we follow it)
local wheelMode, scalingMode    -- Blizzard's, to put back on other maps
local levelCount                -- how many zoom levels are ours (other addons add steps past them: trimmed)

--------------------------------------------------------------------------------
-- Geometry: "zoom" 1 = the whole world fits the view
--------------------------------------------------------------------------------

local function Stitchable(mapID)
	if not mapID then return false end
	if mapID == WORLD then return true end
	local info = C_Map.GetMapInfo(mapID)
	if not info then return false end
	if info.mapType ~= Enum.UIMapType.Continent and info.mapType ~= Enum.UIMapType.Zone then return false end
	return S.Rect(mapID) ~= nil and S.ArtSize(mapID) ~= nil
end

-- view px per world unit when the whole world fits
local function FitPx()
	local W, H = S.Size()
	return math.min(sc:GetWidth() / W, sc:GetHeight() / H)
end

-- host canvas units per world unit
local function K(mapID)
	local W = S.Size()
	local l, r = S.Rect(mapID)
	return S.ArtSize(mapID) / ((r - l) * W)
end

local function ZoomFor(mapID, scale) return scale * K(mapID) / FitPx() end

-- the zoom the layers fade by (Stitch.lua's S.SetZoom, Close.lua's S.SetView): by how much of the
-- world is in view, its area, not how far it is from fitting it. A view the world map's shape (3:2)
-- is the same; a tall one (or a very wide one) fits the world across its narrow side and shows much
-- more of it the other way, so at the same zoom the zones would come in while it still shows a
-- continent's worth of map
local function DetailK()
	local W, H = S.Size()
	local w, h = sc:GetWidth(), sc:GetHeight()
	if not W or w <= 0 or h <= 0 then return 1 end
	return math.min(w / W, h / H) / math.sqrt(w * h / (W * H))
end
local function ScaleFor(mapID, zoom) return zoom * FitPx() / K(mapID) end

-- the zoom at which `mapID` just fits the view
local function FitZoom(mapID)
	local W, H = S.Size()
	local l, r, t, b = S.Rect(mapID)
	return math.min(sc:GetWidth() / ((r - l) * W), sc:GetHeight() / ((b - t) * H)) / FitPx()
end

-- world point (normalized) <-> the current map's normalized point
local function ToWorld(mapID, x, y)
	local l, r, t, b = S.Rect(mapID)
	return l + x * (r - l), t + y * (b - t)
end
local function FromWorld(mapID, u, v)
	local l, r, t, b = S.Rect(mapID)
	return (u - l) / (r - l), (v - t) / (b - t)
end

-- the view: world centre (normalized) and zoom
local function View()
	local mapID = map:GetMapID()
	local u, v = ToWorld(mapID, sc:GetCurrentScrollX() or 0.5, sc:GetCurrentScrollY() or 0.5)
	return u, v, ZoomFor(mapID, sc:GetCanvasScale())
end

-- puts the view at once (Blizzard's InstantPanAndZoom drifts the pan toward the old one)
local openStart, Part             -- (timing an opening: below)

-- the Lua garbage each part makes (KB, added up), for the debug overlay (Debug.lua): counted
-- only while it's on. (A collection during a part makes it read low, never high)
local garbage = {}
mod.garbage = garbage
local function Before() return mod.db.debugOverlay and collectgarbage("count") or nil end
local function After(name, before)
	if not before then return end
	local d = collectgarbage("count") - before
	if d > 0 then garbage[name] = (garbage[name] or 0) + d end
end
local BLOB_PINS = { "QuestBlobPinTemplate", "ScenarioBlobPinTemplate", "BonusObjectiveBlobPinTemplate" }
-- /openmap bench (Bench.lua): each part's time, added up while it runs (S.bench, ms)
local function Clock() return S.bench and debugprofilestop and debugprofilestop() end
local function Clocked(name, t0)
	if t0 and S.bench then S.bench[name] = (S.bench[name] or 0) + debugprofilestop() - t0 end
end

local function SetView(scale, x, y)
	sc.currentScale, sc.targetScale, sc.zoomTarget = scale, scale, scale
	sc.Child:SetScale(scale)
	sc:CalculateScrollExtents()
	x = Clamp(x, sc.scrollXExtentsMin, sc.scrollXExtentsMax)
	y = Clamp(y, sc.scrollYExtentsMin, sc.scrollYExtentsMax)
	sc.targetScrollX, sc.targetScrollY, sc.currentScrollX, sc.currentScrollY = x, y, x, y
	sc:SetNormalizedHorizontalScroll(x)
	sc:SetNormalizedVerticalScroll(y)
	local start = openStart and debugprofilestop and debugprofilestop()
	local g, t0 = Before(), Clock()
	map:OnCanvasScaleChanged()
	After("pins (all addons)", g)
	Clocked("every addon's pins rescaled", t0)
	if start then Part("icons rescaled (all addons)", debugprofilestop() - start) end
	-- Blizzard's quest areas (blobs) redraw for a new scale in their own next OnUpdate, which can
	-- come before this in the next frame: a frame behind all through a zoom. Redrawn now
	g, t0 = Before(), Clock()
	for _, template in ipairs(BLOB_PINS) do
		for pin in map:EnumeratePinsByTemplate(template) do
			if pin:IsShown() and pin.Refresh then pin:Refresh() end
		end
	end
	After("quest areas", g)
	Clocked("quest areas", t0)
	sc:MarkAreaTriggersDirty()
	sc:MarkViewRectDirty()
end

-- the view centred on a world point (normalized) at `zoom`, at once
local function ShowWorld(u, v, zoom)
	local mapID = map:GetMapID()
	local x, y = FromWorld(mapID, u, v)
	SetView(ScaleFor(mapID, zoom), x, y)
end

--------------------------------------------------------------------------------
-- Zoom animation. Ours, not Blizzard's: Blizzard eases zoom and pan separately
-- (the point under the cursor zigzags) and won't pan while zooming out. Each
-- frame we work out the view exactly, so the point under the cursor stays put,
-- and a drag mid-zoom just carries that point with the cursor.
--   anchor: wheel zoom about a world point held at a view offset
--   glide:  click zoom from one view to another, as one zoom about a fixed point
--------------------------------------------------------------------------------

local ZOOM_RATE = 14            -- the wheel zoom's approach, per second (in log zoom)
local GLIDE_TIME = 0.4
local anim                      -- the running animation, or nil

-- the gamepad's cursor on the map (Blizzard's SoftCursor, in gamepad mode), in screen px as
-- GetCursorPosition: while it's what's in use. That's from when it shows or moves until the
-- mouse moves over the map (as Blizzard's own map labels judge it); nil otherwise
local padX, padY                -- the mouse when the pad's cursor showed or last moved
local function PadFocus()
	local soft = _G.SoftCursor
	return soft and soft:IsShown() and InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled()
end
local function PadCursor()
	if not PadFocus() then padX = nil return end
	local soft = _G.SoftCursor
	local mx, my = GetCursorPosition()
	if not padX or soft:IsMoving() or (sc.gamepadZoom or 0) ~= 0 then
		padX, padY = mx, my
	elseif (mx ~= padX or my ~= padY) and sc:IsMouseOver() then
		return
	end
	local l, b, w, h = soft:GetRect()
	if not l then return end
	local es = soft:GetEffectiveScale()
	return (l + w / 2) * es, (b + h / 2) * es
end

-- the cursor in view px from the view's centre (y down)
local function CursorOffset()
	local x, y = PadCursor()
	if not x then x, y = GetCursorPosition() end
	local es = sc:GetEffectiveScale()
	return x / es - (sc:GetLeft() + sc:GetWidth() / 2), (sc:GetTop() - sc:GetHeight() / 2) - y / es
end

-- world units (normalized) per view px at `zoom`
local function PerPx(zoom)
	local W, H = S.Size()
	local px = FitPx() * zoom
	return 1 / (W * px), 1 / (H * px)
end

-- the deepest zoom at (u, v): further in a city, whose map is small (its own map, and outdoors
-- the minimap, carry the detail there)
local CITY_ZOOM = 1.5
local function MaxZoomAt(u, v)
	return mod.db.maxZoom * ((u and S.InCity and S.InCity(u, v)) and CITY_ZOOM or 1)
end

-- wheel: zoom about the point under the cursor
local function ZoomAtCursor(factor)
	local u, v, zoom = View()
	local sx, sy = CursorOffset()
	local pu, pv = PerPx(zoom)
	local target = Clamp((anim and anim.mode == "anchor" and anim.target or zoom) * factor, 1, MaxZoomAt(u + sx * pu, v + sy * pv))
	anim = { mode = "anchor", u = u + sx * pu, v = v + sy * pv, sx = sx, sy = sy, target = target }
	userMoved = true
end

-- glides the view to a world point (normalized) at `zoom`
local function GlideTo(u, v, zoom)
	local u0, v0, z0 = View()
	anim = { mode = "glide", u0 = u0, v0 = v0, z0 = z0, u1 = u, v1 = v,
		z1 = Clamp(zoom, 1, MaxZoomAt(u, v)), t = 0 }
	userMoved = true
end

-- the gamepad's zoom stick: a steady rate in log zoom, about its cursor (Blizzard's adds a fixed
-- scale a second, which at the stitched map's depths is too slow zoomed in, too fast out)
local PAD_ZOOM_RATE = 1.8       -- per second at full tilt (in log zoom: 6x a second)
local function PadZoom(elapsed)
	local speed = sc.gamepadZoomSpeed
	local tilt = Clamp(sc.gamepadZoom / ((speed and speed > 0) and speed or 1), -1, 1)   -- (Blizzard's curve applied)
	local u, v, zoom = View()
	local sx, sy = CursorOffset()
	local pu, pv = PerPx(zoom)
	local cu, cv = u + sx * pu, v + sy * pv
	anim = nil
	userMoved = true
	local to = Clamp(zoom * math.exp(tilt * PAD_ZOOM_RATE * elapsed), 1, MaxZoomAt(cu, cv))
	if math.abs(to - zoom) < 1e-6 then return end
	pu, pv = PerPx(to)
	ShowWorld(cu - sx * pu, cv - sy * pv, to)
end

-- after Blizzard's own OnUpdate, so its panning never adds to ours
local function Animate(_, elapsed)
	if active and (sc.gamepadZoom or 0) ~= 0 then return PadZoom(elapsed) end
	-- the gamepad's cursor at the view's edge pans it (Blizzard's): a move of the user's
	if active and sc.HasGamepadScrollSpeed and sc:HasGamepadScrollSpeed() then userMoved = true end
	if not anim then return end
	if not active then anim = nil return end
	local a = anim
	if a.mode == "anchor" then
		local _, _, z = View()
		local zoom = math.exp(math.log(z) + (math.log(a.target) - math.log(z)) * (1 - math.exp(-elapsed * ZOOM_RATE)))
		local done = math.abs(math.log(a.target / zoom)) < 0.003
		if done then zoom = a.target end
		local down = sc.mouseButtonInfo.LeftButton.down
		if down and not a.down then
			-- grabbed mid-zoom: what's under the cursor now is what the cursor carries
			local u, v = View()
			local sx, sy = CursorOffset()
			local pu, pv = PerPx(z)
			a.u, a.v, a.sx, a.sy = u + sx * pu, v + sy * pv, sx, sy
		elseif down then
			a.sx, a.sy = CursorOffset()
		end
		a.down = down
		local pu, pv = PerPx(zoom)
		ShowWorld(a.u - a.sx * pu, a.v - a.sy * pv, zoom)
		if done then anim = nil end
	else
		a.t = math.min(1, a.t + elapsed / GLIDE_TIME)
		local e = a.t * a.t * (3 - 2 * a.t)
		local zoom = math.exp(math.log(a.z0) + (math.log(a.z1) - math.log(a.z0)) * e)
		-- the centre moves with 1/zoom, which is what zooming about one fixed point looks like
		local w = math.abs(a.z1 - a.z0) < 1e-6 and e or (1 / a.z0 - 1 / zoom) / (1 / a.z0 - 1 / a.z1)
		ShowWorld(a.u0 + (a.u1 - a.u0) * w, a.v0 + (a.v1 - a.v0) * w, zoom)
		if a.t >= 1 then anim = nil end
	end
end

--------------------------------------------------------------------------------
-- Following the view: which map should be underneath
--------------------------------------------------------------------------------

local function PickMap(u, v, zoom, current)
	local chain = S.ChainAt(u, v)
	local pick = WORLD
	for _, mapID in ipairs(chain) do
		local need = (mapID == current) and LEAVE or ENTER
		if mapID ~= WORLD and Stitchable(mapID) and zoom >= FitZoom(mapID) * need then pick = mapID end
	end
	return pick
end

local function Switch(target)
	local u, v, zoom = View()
	switching = true
	local g = Before()
	local ok, err = pcall(map.SetMapID, map, target)
	After("map switch (all addons)", g)
	switching = false
	if not ok then geterrorhandler()(err) return end
	if active then
		local x, y = FromWorld(target, u, v)
		SetView(ScaleFor(target, zoom), x, y)
	end
end

local function Settled()
	return not anim and not sc.mouseButtonInfo.LeftButton.down
		and sc.currentScale == sc.targetScale
		and sc.currentScrollX == sc.targetScrollX and sc.currentScrollY == sc.targetScrollY
end

local ticker = CreateFrame("Frame")
ticker:Hide()
local elapsedSum = 0
-- a switch has Blizzard refresh every map data provider (every Questie pin with them): a
-- hitch, so it waits until the view has been still this long, not the moment it stops
local SWITCH_AFTER = 0.6
local stillFor = 0
ticker:SetScript("OnUpdate", function(_, elapsed)
	elapsedSum = elapsedSum + elapsed
	if elapsedSum < 0.1 then return end
	elapsedSum = 0
	if not active then return end
	-- another addon's zoom steps past ours (BetterMaps', High Fidelity World Map's): the deepest
	-- zoom is OpenMap's, and Blizzard's icons size themselves from the last step
	local zl = sc.zoomLevels
	if levelCount and zl and #zl > levelCount then
		for i = #zl, levelCount + 1, -1 do zl[i] = nil end
	end
	local mapID = map:GetMapID()

	-- the player, when the map underneath can't show them
	local pos = C_Map.GetPlayerMapPosition(mapID, "player")
	if pos then
		S.SetPlayer(nil)
	else
		local best = C_Map.GetBestMapForUnit("player")
		local p = best and S.Rect(best) and C_Map.GetPlayerMapPosition(best, "player")
		local x, y
		if p then x, y = ns.Safe.XY(p) end
		if not ns.Safe.IsSecret(x) and not ns.Safe.IsSecret(y) and x and y then
			local u, v = ToWorld(best, x, y)
			S.SetPlayer(u, v, ns.Safe.Call(GetPlayerFacing))
		else
			S.SetPlayer(nil)
		end
	end

	stillFor = Settled() and stillFor + 0.1 or 0
	if mod.db.autoSwitch and userMoved and stillFor >= SWITCH_AFTER and not InCombatLockdown() and not mod.benching then
		local u, v, zoom = View()
		local target = PickMap(u, v, zoom, mapID)
		if target ~= mapID then Switch(target) end
	end
end)

--------------------------------------------------------------------------------
-- Hooks into Blizzard's map
--------------------------------------------------------------------------------

-- how long opening the map takes, to the next frame drawn (/openmap status): the game's
-- work, Questie's and ours (the first opening also builds the map); and OpenMap's own part,
-- its handlers' time from the open until the second frame after it
local openTimes, openOurs, openFrames = {}, 0, 0
local openParts, openLast = {}, {}
local openTimer = CreateFrame("Frame")
openTimer:Hide()
openTimer:SetScript("OnUpdate", function(self)
	openFrames = openFrames + 1
	if openFrames == 1 and openStart then
		table.insert(openTimes, 1, { debugprofilestop() - openStart, 0 })
		openTimes[4] = nil
	elseif openFrames >= 2 then
		if openTimes[1] then openTimes[1][2] = openOurs end
		openLast, openParts = openParts, {}
		openStart = nil
		self:Hide()
	end
end)
-- `fn`, with its time counted as OpenMap's part of an opening (while one is being timed),
-- by part. "icons rescaled" (Blizzard telling every addon's map icons the new scale, from
-- SetView) is timed apart: it runs inside our handlers but is mostly other addons' work.
Part = function(name, ms)
	openParts[name] = (openParts[name] or 0) + ms
end
local function Ours(name, fn)
	return function(...)
		if not openStart or not debugprofilestop then return fn(...) end
		local start = debugprofilestop()
		fn(...)
		local ms = debugprofilestop() - start
		openOurs = openOurs + ms
		Part(name, ms)
	end
end

-- the view for Close.lua (minimap, grain, caves): centre, half extents (normalized), zoom
-- (Blizzard reports a pan several times a frame: the work is done once, on the next frame)
local live                      -- { u, v, zoom, width, height }: the view on screen, and the view's size then
local viewFrame = CreateFrame("Frame")
viewFrame:Hide()
viewFrame:SetScript("OnUpdate", Ours("view update", function(self)
	self:Hide()
	if not active or not S.SetView then return end
	local u, v, zoom = View()
	live = live or {}                             -- (kept: the view updates every frame of a pan)
	live[1], live[2], live[3], live[4], live[5] = u, v, zoom, sc:GetWidth(), sc:GetHeight()
	local pu, pv = PerPx(zoom)
	local g, t0 = Before(), Clock()
	S.SetView(u, v, sc:GetWidth() / 2 * pu, sc:GetHeight() / 2 * pv, zoom * DetailK(), zoom)
	After("close-up", g)
	Clocked("OpenMap's view update", t0)
	if mod.OnViewMoved then mod.OnViewMoved() end   -- (API.lua: other addons told, a few times a second at most)
end))
local function ApplyView()
	if active then viewFrame:Show() end
end

local function ApplyZoom()
	if not active then return end
	local g, t0 = Before(), Clock()
	S.SetZoom(ZoomFor(map:GetMapID(), sc:GetCanvasScale()) * DetailK(), sc:GetCanvasScale())
	After("zoom", g)
	Clocked("OpenMap's zoom update", t0)
	ApplyView()
end

-- a map is about to show: decide whether it's stitched, then lay the art out for it
-- Blizzard's own art for the host map (its tiles, and the explored-area pin, which also
-- runs every frame): all under ours, so off while the stitched map shows
local function BlizzardArt()
	local show = not active
	if map.detailLayerPool then
		for layer in map.detailLayerPool:EnumerateActive() do layer:SetShown(show) end
	end
	for pin in map:EnumeratePinsByTemplate("MapExplorationPinTemplate") do pin:SetShown(show) end
end

local function Attach(mapID)
	active = mod.enabled and Stitchable(mapID) and S.IsBuilt() and S.Layout(mapID) or false
	S.SetShown(active)
	BlizzardArt()
	if active then
		sc:SetMouseWheelZoomMode(MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_NONE)
		sc:SetScalingMode("SCALING_MODE_LINEAR")
		if map:IsShown() then ticker:Show() end
	else
		sc:SetMouseWheelZoomMode(wheelMode)
		sc:SetScalingMode(scalingMode)
		S.SetPlayer(nil)
		ticker:Hide()
		anim = nil
		if mod.IsPainting and mod:IsPainting() then mod:TogglePaint(false) end
		if mod.IsSketching and mod:IsSketching() then mod:ToggleSketch(false) end
	end
	if mod.OnStitchedChanged then mod.OnStitchedChanged(active) end
end

-- zoom levels from the whole world to street level, in this map's scale
local function OnCreateZoomLevels(self)
	if not S.IsBuilt() then
		local fl = map:GetPinFrameLevelsManager()
		S.Build(map:GetCanvas(), fl:GetValidFrameLevel("PIN_FRAME_LEVEL_OPENMAP_STITCH"), ART_RANGE,
			fl:GetValidFrameLevel("PIN_FRAME_LEVEL_OPENMAP_ICONS"))
		if mod.BuildFlights then mod:BuildFlights() end
		if mod.BuildPaint then mod:BuildPaint() end
		if mod.BuildSketch then mod:BuildSketch() end
		if mod.BuildNav then mod:BuildNav() end
		if mod.BuildMapPins then mod:BuildMapPins() end
		mod:Refresh()
	end
	Attach(self.mapID)
	if not active then return end
	local levels = {}
	local zoom = 1
	local deepest = mod.db.maxZoom * CITY_ZOOM               -- (the deepest anywhere: a city's)
	while zoom < deepest * ZOOM_STEP do
		levels[#levels + 1] = { scale = ScaleFor(self.mapID, math.min(zoom, deepest)), layerIndex = 1 }
		zoom = zoom * ZOOM_STEP
	end
	self.zoomLevels = levels
	self.baseScale = levels[1].scale    -- panning allowed above the whole-world view
	levelCount = #levels
end

-- Blizzard showed a map (opening, the quest log, the dropdown): show it as it would
-- Blizzard's zoom reset (each time the map opens, after re-adding every addon's icons), done
-- our way while the map is stitched: straight to where you left off, in one step (not the
-- whole world and then there: every addon's icons rescaled twice); and if the map is still
-- there (closed and reopened without moving), nothing at all. The window resized while open
-- (full screen and back, or dragged): where you were looking, at the same framing. Another
-- map put up while it's open (the quest log's, the dropdown's) shows whole, as Blizzard's does
local beforeReset                 -- the view on screen when Blizzard last put up a map: { u, v, zoom, at = GetTime() }
local function ResetView(self)
	userMoved = false
	anim = nil
	if live and map:IsShown() then beforeReset = { live[1], live[2], live[3], at = GetTime() } end
	local u, v, zoom
	if live and map:IsShown() and (math.abs(sc:GetWidth() - live[4]) > 0.5 or math.abs(sc:GetHeight() - live[5]) > 0.5) then
		u, v, zoom = live[1], live[2], live[3]
	elseif not live and mod.SavedView then          -- (no view drawn yet: the map is opening)
		u, v, zoom = mod.SavedView(self.mapID)
	end
	if not u and mod.ReturnView then u, v, zoom = mod.ReturnView(self.mapID) end   -- (out of a dungeon's map: Dungeons.lua)
	if u then
		zoom = Clamp(zoom, 1, MaxZoomAt(u, v))
		local nu, nv, nz = View()
		if not (nu and math.abs(nu - u) < 1e-4 and math.abs(nv - v) < 1e-4 and math.abs(nz - zoom) < 1e-3) then
			ShowWorld(u, v, zoom)
		end
		userMoved = true
		return
	end
	local aw, ah = S.ArtSize(self.mapID)
	SetView(math.min(self:GetWidth() / aw, self:GetHeight() / ah), 0.5, 0.5)
end

-- pan anywhere on the world, not just this map. Zoomed right out the world is centred;
-- zooming in, the view gains room to go past its edges (EDGE_SLACK, in by CENTRE_UNTIL), so
-- the wheel zooms about the point under the cursor from the first step
local EDGE_SLACK = 0.2          -- world widths / heights
local CENTRE_UNTIL = 1.6        -- zoom by which the view has all that room
local function Range(a0, a1, half, slack, t)
	local lo, hi = a0 + half, a1 - half
	local c = (a0 + a1) / 2
	local plainLo, plainHi = lo, hi         -- on the world, or (the view wider than it) centred
	if lo > hi then plainLo, plainHi = c, c end
	-- with room: the whole world kept in view (if wider), and EDGE_SLACK past it
	local fullLo, fullHi = math.min(lo, hi) - slack, math.max(lo, hi) + slack
	return plainLo + (fullLo - plainLo) * t, plainHi + (fullHi - plainHi) * t
end
local function Extents(origExtents)
	return function(self, scale)
		if not active then return origExtents(self, scale) end
		local mapID = map:GetMapID()
		local x0, y0 = FromWorld(mapID, 0, 0)
		local x1, y1 = FromWorld(mapID, 1, 1)
		local hw = self:NormalizeHorizontalSize(self:GetWidth() * 0.5 / scale)
		local hh = self:NormalizeVerticalSize(self:GetHeight() * 0.5 / scale)
		local t = Clamp((ZoomFor(mapID, scale) - 1) / (CENTRE_UNTIL - 1), 0, 1)
		local minX, maxX = Range(x0, x1, hw, (x1 - x0) * EDGE_SLACK, t)
		local minY, maxY = Range(y0, y1, hh, (y1 - y0) * EDGE_SLACK, t)
		return minX, maxX, minY, maxY
	end
end

-- the hover highlight. Blizzard's shows the host map's children: on the world, whole
-- continents. Once the continents' art (and its zone outlines) is in, it's the zone under
-- the cursor instead: the continent's own highlight for it, placed on the world
local ZONE_HIGHLIGHT = 1.5      -- zoom from which the world highlights zones (Stitch.lua's continents half in)
local lastHU, lastHV, lastHK      -- (the highlight's cursor: it's redone only when that moves a pixel)
local function HighlightZone(pin)
	local tex = pin.HighlightTexture
	local u, v, pu = mod.CursorWorld()
	local key = sc:GetCanvasScale()
	if u and lastHU and lastHK == key and math.abs(u - lastHU) < pu and math.abs(v - lastHV) < pu then return end
	lastHU, lastHV, lastHK = u, v, key
	local cont
	for _, id in ipairs(u and S.ChainAt(u, v) or {}) do
		local info = C_Map.GetMapInfo(id)
		if info and info.mapType == Enum.UIMapType.Continent then cont = id end
	end
	local l, r, t, b = S.Rect(cont or WORLD)
	if not cont or not l then tex:Hide() return end
	local x, y = FromWorld(cont, u, v)
	local fid, atlas, tx, ty, w, h, left, top = C_Map.GetMapHighlightInfoAtPosition(cont, x, y)
	if not ((fid and fid > 0) or atlas) or not w or w <= 0 or h <= 0 then tex:Hide() return end
	if atlas then
		tex:SetAtlas(atlas, false, "TRILINEAR")
	else
		tex:SetTexture(fid, nil, nil, "TRILINEAR")
		tex:SetTexCoord(0, tx, 0, ty)
	end
	-- from the continent's normalized space to the world's (this map's)
	local pw, ph = pin:GetWidth(), pin:GetHeight()
	tex:ClearAllPoints()
	tex:SetSize(w * (r - l) * pw, h * (b - t) * ph)
	tex:SetPoint("TOPLEFT", (l + left * (r - l)) * pw, -(t + top * (b - t)) * ph)
	tex:Show()
end
local function HookHighlight()
	for pin in map:EnumeratePinsByTemplate("MapHighlightPinTemplate") do
		if not pin.omRefresh and pin.Refresh and pin.HighlightTexture then
			pin.omRefresh = pin.Refresh
			pin.Refresh = function(self)
				if active and not mod.db.hoverHighlight then return self.HighlightTexture:Hide() end
				if active and map:GetMapID() == WORLD and select(3, View()) >= ZONE_HIGHLIGHT then
					return HighlightZone(self)
				end
				return self:omRefresh()
			end
		end
	end
end

-- wheel: a step, about the point under the cursor
local function OnMouseWheel(_, delta)
	if not active then return end
	ZoomAtCursor(delta > 0 and ZOOM_STEP or 1 / ZOOM_STEP)
end

-- a left click drops a pin under the cursor when the menu's pin button is on, or with Ctrl
local function Dropping(button)
	return active and button == "LeftButton" and mod.DropWaypoint and (IsControlKeyDown() or (mod.PinMode and mod.PinMode()))
end

local function DropAtCursor()
	if mod.SetPinMode then mod.SetPinMode(false) end
	mod.DropWaypoint(mod.CursorWorld())     -- (not the click position Blizzard passes: that's clamped to this map's rectangle)
end

-- clicks: in = the next map down under the cursor, out = the map above
local function OnCanvasClick(_, button)
	if not active then return false end
	if Dropping(button) then
		DropAtCursor()
		return true
	end
	local u, v = mod.CursorWorld()
	local _, _, zoom = View()
	local chain = S.ChainAt(u, v)
	if button == "LeftButton" then
		for _, id in ipairs(chain) do
			if id ~= WORLD and Stitchable(id) and FitZoom(id) > zoom * 1.05 then
				local l, r, t, b = S.Rect(id)
				GlideTo((l + r) / 2, (t + b) / 2, FitZoom(id))
				break
			end
		end
	elseif button == "RightButton" then
		if mod.ClearFlightRoute then mod:ClearFlightRoute() end
		local target = WORLD
		for _, id in ipairs(chain) do
			if id ~= WORLD and Stitchable(id) and FitZoom(id) < zoom * 0.95 then target = id end
		end
		local l, r, t, b = S.Rect(target)
		GlideTo((l + r) / 2, (t + b) / 2, FitZoom(target))
	end
	return true
end

-- our icons: a press still drags the map, a click is the icon's
-- the map was grabbed (on it or on one of our icons)
local function OnGrab()
	userMoved = true
	if anim and anim.mode == "glide" then anim = nil end   -- a grab stops a glide where it is
end

local function OnPinMouseDown(_, button)
	sc:OnMouseDown(button)
	OnGrab()
end

local function OnPinMouseUp(pin, button)
	local x, y = sc:GetCursorPosition()
	if button ~= "LeftButton" or not sc:WouldCursorPositionBeClick(button, x, y) then
		sc:OnMouseUp(button)
		return
	end
	sc.mouseButtonInfo.LeftButton.down = false
	if Dropping(button) then DropAtCursor() return end
	if pin.OnClick then pin:OnClick() end
end

-- a click on one of Blizzard's map icons goes to its pin handlers, not the canvas's: dropping a
-- pin works there too (Blizzard's own only took Ctrl-clicks, never the menu's pin button)
local function OnBlizzardPinAction(_, action, button)
	if not Dropping(button) then return false end
	if action == MapCanvasMixin.MouseAction.Click then DropAtCursor() end
	return action ~= MapCanvasMixin.MouseAction.Up
end

local function Setup()
	map = _G.WorldMapFrame
	sc = map and map.ScrollContainer
	if not sc or not sc.CreateZoomLevels or not map.GetPinFrameLevelsManager or not map:GetPinFrameLevelsManager() then
		ns:Print("World map: Blizzard's map isn't the expected kind; the seamless map is off.")
		return
	end
	wheelMode = sc.mouseWheelZoomMode or MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_FULL
	scalingMode = sc.scalingMode or "SCALING_MODE_TRANSLATE_FASTER_THAN_SCALE"

	-- our art sits just above Blizzard's exploration overlays, our icons above the highlight
	local fl = map:GetPinFrameLevelsManager()
	if not fl:InsertFrameLevelAbove("PIN_FRAME_LEVEL_OPENMAP_STITCH", "PIN_FRAME_LEVEL_MAP_EXPLORATION", ART_RANGE)
		or not fl:InsertFrameLevelAbove("PIN_FRAME_LEVEL_OPENMAP_ICONS", "PIN_FRAME_LEVEL_MAP_HIGHLIGHT", 6) then
		ns:Print("World map: Blizzard's map layers aren't the expected ones; the stitched art may cover some map icons.")
	end

	S.OnPinMouseDown, S.OnPinMouseUp = OnPinMouseDown, OnPinMouseUp
	S.GlideToWorld = function(u, v, zoom) GlideTo(u, v, math.max(zoom or 1, select(3, View()))) end
	-- glides until a world rectangle (normalized) just fills the view
	S.GlideToRect = function(u0, v0, u1, v1, fill)
		local W, H = S.Size()
		local z = math.min(sc:GetWidth() / ((u1 - u0) * W), sc:GetHeight() / ((v1 - v0) * H)) / FitPx()
		GlideTo((u0 + u1) / 2, (v0 + v1) / 2, z * (fill or 1))
	end
	S.OpenMap = function(mapID) map:SetMapID(mapID) end
	S.Switching = function() return switching end   -- (the map underneath following the view, not another map put up)
	hooksecurefunc(sc, "CreateZoomLevels", Ours("zoom levels", OnCreateZoomLevels))
	local blizzardReset, ourReset = sc.ResetZoom, Ours("reset zoom", ResetView)
	sc.ResetZoom = function(self, ...)
		if active and not switching then return ourReset(self) end
		return blizzardReset(self, ...)
	end
	if map.RefreshDetailLayers then hooksecurefunc(map, "RefreshDetailLayers", BlizzardArt) end
	sc.CalculateScrollExtentsAtScale = Extents(sc.CalculateScrollExtentsAtScale)
	sc:HookScript("OnMouseWheel", OnMouseWheel)
	sc:HookScript("OnMouseDown", OnGrab)
	-- Listen directly: Blizzard's canvas click dispatcher only tracks left/right buttons.
	sc:HookScript("OnMouseUp", function(_, button)
		if active and button == "MiddleButton" then mod:FindMe(true) end
	end)
	sc:HookScript("OnUpdate", Animate)
	-- the gamepad (Forever's gamepad mode): its zoom stick is ours on the stitched map (PadZoom);
	-- its A (Blizzard's icons under the cursor, then this) presses OpenMap's control or icon under
	-- the cursor (Gamepad.lua), or else zooms in as a click does; its X, with no icon under the
	-- cursor, zooms out a map as a right-click does (Blizzard's would change the map underneath)
	if sc.IsGamepadZooming then
		local zooming = sc.IsGamepadZooming
		sc.IsGamepadZooming = function(self, ...)
			if active then return false end
			return zooming(self, ...)
		end
	end
	-- other addons' view changes (zoom remembered per map, keep centred, a jump into a cave) don't
	-- apply on the stitched map: its view is OpenMap's. Blizzard's own calls go through
	if sc.InstantPanAndZoom and debugstack then
		local pan = sc.InstantPanAndZoom
		sc.InstantPanAndZoom = function(self, ...)
			if active then
				local caller = (debugstack(2, 1, 0) or ""):match("AddOns[\\/]([^\\/]+)[\\/]")
				if caller and caller ~= "OpenMap" and not caller:find("^Blizzard_") then return end
			end
			return pan(self, ...)
		end
	end
	if map.NavigateToGamepadCursor then
		local navigate = map.NavigateToGamepadCursor
		map.NavigateToGamepadCursor = function(self, ...)
			local x, y = PadCursor()
			if x and mod.PadPress and mod.PadPress(x, y) then return true end
			if not active then return navigate(self, ...) end
			if self.GetHoveredPin and self:GetHoveredPin() then return true end   -- (Blizzard clicked it)
			return OnCanvasClick(nil, "LeftButton")
		end
	end
	if map.NavigateToParentMap then
		local up = map.NavigateToParentMap
		map.NavigateToParentMap = function(self, ...)
			if active and PadFocus() then return OnCanvasClick(nil, "RightButton") end
			return up(self, ...)
		end
	end
	map:AddCanvasClickHandler(OnCanvasClick, 1000)
	if map.AddGlobalPinMouseActionHandler and MapCanvasMixin and MapCanvasMixin.MouseAction then
		map:AddGlobalPinMouseActionHandler(OnBlizzardPinAction, 1000)
	end
	-- Blizzard's pin cursor while the menu's pin button is on
	if map.AddCursorHandler then
		map:AddCursorHandler(function() if active and mod.PinMode and mod.PinMode() then return "MAP_PIN_CURSOR" end end, 1000)
	end
	HookHighlight()
	-- a quest's details, Back: the map stays where you're looking (most likely at the quest's place,
	-- to pick another nearby). Blizzard puts back the map it was on when they opened, and a map Blizzard
	-- puts up shows whole: the view from just before that comes back
	if QuestMapFrame_ReturnFromQuestDetails then
		hooksecurefunc("QuestMapFrame_ReturnFromQuestDetails", function()
			local b = beforeReset
			if b and b.at == GetTime() and active and map:IsShown() then mod.ShowNow(b[1], b[2], b[3]) end
		end)
	end

	local dp = CreateFromMixins(MapCanvasDataProviderMixin)
	dp.OnCanvasScaleChanged = Ours("scale changed", ApplyZoom)
	dp.OnCanvasPanChanged = ApplyView
	dp.OnMapChanged = function()
		ApplyZoom()
		if mod.OnHostMapChanged then mod.OnHostMapChanged() end
		if mod.RefreshPortrait then pcall(mod.RefreshPortrait) end   -- (OpenMap's icon only while stitching)
		-- (inside Blizzard's map change: a failure here is reported, never left to break it)
		if mod.RefreshNav then
			local ok, err = pcall(mod.RefreshNav, mod)
			if not ok then geterrorhandler()(err) end
		end
	end
	dp.OnHide = function()
		live = nil
		if mod.OnMapHidden then mod:OnMapHidden() end
		ticker:Hide()
	end
	local shown = Ours("map shown", function()
		if not S.IsBuilt() and map:GetMapID() then sc:OnCanvasSizeChanged() end   -- built on first showing
		if active then ticker:Show() end
		if mod.OnMapShown then mod:OnMapShown() end
	end)
	dp.OnShow = function()
		if debugprofilestop then openStart, openOurs, openFrames, openParts = debugprofilestop(), 0, 0, {} openTimer:Show() end
		shown()
	end
	map:AddDataProvider(dp)

	if mod.SetupExtras then mod:SetupExtras(map) end
	if mod.SetupFlights then mod:SetupFlights() end
	ns.RegisterEvent(mod, "MAP_EXPLORATION_UPDATED", function() if S.IsBuilt() then S.RefreshExplored() end end)
	if mod.SetupNav then mod:SetupNav(map) end          -- (before the menu: it holds Nav's search box)
	if mod.SetupPins then mod:SetupPins(map) end
	if mod.SetupDungeons then mod:SetupDungeons(map) end
	if mod.SetupCombat then mod:SetupCombat(map) end
	if mod.SetupNews then mod:SetupNews() end
	if mod.SetupPanel then mod:SetupPanel(map) end
	if mod.SetupPaint then mod:SetupPaint(map) end
	if mod.SetupSketch then mod:SetupSketch(map) end
	if mod.SetupDebug then mod:SetupDebug(map) end
	if mod.SetupBench then mod:SetupBench(map) end
	if mod.SetupGamepad then mod:SetupGamepad(map) end
	if mod.SetupReport then mod:SetupReport(map) end
	if mod.SetupWindow then mod:SetupWindow(map) end
	if mod.SetupCompat then mod:SetupCompat(map) end

	-- the map may already be showing something
	if map:IsShown() and map:GetMapID() then sc:OnCanvasSizeChanged() end
end

-- for Extras / Flights / Townsfolk / Panel / Paint
function mod.IsStitched() return active end
function mod.WheelZoom(delta) if active then ZoomAtCursor(delta > 0 and ZOOM_STEP or 1 / ZOOM_STEP) end end
-- the world point (normalized) under the cursor, and world units per view px
function mod.CursorWorld()
	if not active then return end
	local u, v, zoom = View()
	local sx, sy = CursorOffset()
	local pu, pv = PerPx(zoom)
	return u + sx * pu, v + sy * pv, pu, pv
end
-- the gamepad's cursor (screen px) while it's the one in use on the map, else nil
function mod.PadCursor() if sc then return PadCursor() end end
mod.ToWorld = function(mapID, x, y) return ToWorld(mapID, x, y) end
function mod.ViewHalfExtents(zoom)
	local pu, pv = PerPx(zoom)
	return sc:GetWidth() / 2 * pu, sc:GetHeight() / 2 * pv
end
-- for Nav.lua: glide / jump to a world point (normalized) at a zoom; the zoom where a map fits
function mod.Glide(u, v, zoom) if active then GlideTo(u, v, zoom) end end
function mod.ShowNow(u, v, zoom) if active then anim = nil ShowWorld(u, v, Clamp(zoom, 1, MaxZoomAt(u, v))) userMoved = true end end
-- for Bench.lua: the view heads for a world point (normalized) the way a drag moves it, Blizzard's
-- scroll easing there over the next frames; and whether a zoom or glide of ours is running
function mod.PanTo(u, v)
	if not active then return end
	local x, y = FromWorld(map:GetMapID(), u, v)
	sc.targetScrollX = Clamp(x, sc.scrollXExtentsMin, sc.scrollXExtentsMax)
	sc.targetScrollY = Clamp(y, sc.scrollYExtentsMin, sc.scrollYExtentsMax)
end
function mod.Animating() return anim ~= nil end
function mod.FitZoom(mapID) return FitZoom(mapID) end
-- the deepest zoom (the menu's slider and the options): the zoom levels are rebuilt for it
function mod.SetMaxZoom(v)
	mod.db.maxZoom = math.max(MAX_ZOOM[1], math.min(MAX_ZOOM[2], v))
	if map and active then sc:OnCanvasSizeChanged() end
end
function mod.HostMap() return active and map:GetMapID() or nil end
-- the close-up layers again, for the view as it is (a setting changed)
function mod.RefreshView() ApplyView() end
mod.FromWorld = function(mapID, u, v) return FromWorld(mapID, u, v) end
-- the view now: centre (normalized), zoom; nil when the map isn't stitched
function mod.ViewNow() if active then return View() end end

function mod:OnEnable()
	if _G.WorldMapFrame then
		Setup()
	elseif EventUtil and EventUtil.ContinueOnAddOnLoaded then
		EventUtil.ContinueOnAddOnLoaded("Blizzard_WorldMap", Setup)
	end
end

-- which pin sets each option shows
local SET_OPTION = { dungeons = "icons", travel = "icons", flight = "flight", routes = "routes" }

function mod:Refresh()
	for key, opt in pairs(SET_OPTION) do
		local set = S.GetPinSet(key)
		if set then S.SetPinSetOn(set, self.db[opt]) end
	end
	S.ApplyGrade(self.db.colorMatch, self.db.desaturate, self.db.unexplored)
	ApplyZoom()
	if self.RefreshExtras then self.RefreshExtras() end
	if self.RefreshTownsfolk then self:RefreshTownsfolk() end
	if self.RefreshDungeonCard then self.RefreshDungeonCard() end
	if self.RefreshSketch then self.RefreshSketch() end
	if self.RefreshPanel then self:RefreshPanel() end
end

-- /openmap status: what the map is doing
function mod:Diag()
	if not map or not sc or not S.IsBuilt() then
		ns:Print("World map: not built yet (it's built the first time the map opens).")
		return
	end
	local mapID = map:GetMapID()
	local info = C_Map.GetMapInfo(mapID)
	ns:Print("World map: %s (%d), %s, zoom %.2f, scale %.3f, %d zones / %d base tiles / %d overlay tiles / %d icons.",
		info and info.name or "?", mapID or 0, active and "stitched" or "Blizzard's",
		active and select(3, View()) or 0, sc:GetCanvasScale(),
		S.stats.zones, S.stats.tiles, S.stats.overlays, S.stats.pins)
	local fixed, live = S.RegionCount()
	local kb
	if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
		UpdateAddOnMemoryUsage()
		kb = GetAddOnMemoryUsage(ns.name)
	end
	ns:Print("World map: %d art regions, %d live ones; addon memory %s.", fixed, live, kb and ("%.1f MB"):format(kb / 1024) or "?")
	if map:IsVisible() then
		ns:Print("Drawing %d of the art's textures now; %.0f frames a second.", S.DrawnCount(), GetFramerate())
	else
		ns:Print("The map is closed: open it and run this again for what it's drawing.")
	end
	if #openTimes > 0 then
		local list = {}
		for i, t in ipairs(openTimes) do list[i] = ("%.0f (OpenMap %.0f)"):format(t[1], t[2]) end
		ns:Print("Opening the map took %s ms, latest first; the rest is the game and other addons.", table.concat(list, ", "))
		local parts = {}
		for name, ms in pairs(openLast) do parts[#parts + 1] = { name, ms } end
		table.sort(parts, function(a, b) return a[2] > b[2] end)
		for i, p in ipairs(parts) do parts[i] = ("%s %.0f"):format(p[1], p[2]) end
		if #parts > 0 then ns:Print("  the latest, by part (ms; parts can run inside each other): %s.", table.concat(parts, ", ")) end
	end
	local registered, shown, placed, ours, moved
	if mod.QuestieStatus then registered, shown, placed, ours, moved = mod.QuestieStatus() end
	if registered then
		ns:Print("Questie: %d map icons, %d on this map (%d placed by Questie, %d of those moved to Forever's positions, %d placed by OpenMap), map %d.",
			registered, shown, placed, moved, ours, map:GetMapID() or 0)
	end
	local cv = S.closeView or {}
	ns:Print("Up close: zoom %.1f, softening %.0f%%, minimap %.0f%% (%d tiles, %d in the gaps); %d view updates, the last %.1fs ago; %.2f ms each (worst %.1f).",
		cv.zoom or 0, (cv.soft or 0) * 100, (cv.mix or 0) * 100, cv.tiles or 0, cv.gapTiles or 0,
		cv.updates or 0, cv.time and (GetTime() - cv.time) or -1, cv.ms or 0, cv.worst or 0)
	cv.worst = 0
	-- its slowest steps (by their worst), so a slow update says where the time went
	local steps = {}
	for name, s in pairs(S.closeSteps or {}) do steps[#steps + 1] = { name, s } end
	table.sort(steps, function(a, b) return a[2].worst > b[2].worst end)
	local list = {}
	for i = 1, math.min(3, #steps) do
		list[i] = ("%s %.1f (worst %.1f)"):format(steps[i][1], steps[i][2].ms, steps[i][2].worst)
		steps[i][2].worst = 0
	end
	if #list > 0 then ns:Print("Slowest steps, ms: %s.", table.concat(list, "; ")) end
	-- and the zoom update's (S.SetZoom, "scale changed" when the map opens)
	steps = {}
	for name, st in pairs(S.zoomSteps or {}) do steps[#steps + 1] = { name, st } end
	table.sort(steps, function(a, b) return a[2].worst > b[2].worst end)
	list = {}
	for i = 1, math.min(4, #steps) do
		list[i] = ("%s %.1f (worst %.1f)"):format(steps[i][1], steps[i][2].ms, steps[i][2].worst)
		steps[i][2].worst = 0
	end
	if #list > 0 then ns:Print("Zoom update, slowest parts, ms: %s.", table.concat(list, "; ")) end
	for name, err in pairs(S.closeFailed or {}) do ns:Print("|cffff6060%s failed:|r %s", name, err) end
end


function mod:Options()
	local get, set = ns.Bind(function() return mod.db end, function() mod:Refresh() end)
	local function off() return not mod.db.enabled end
	local opts = {
		intro = ns.Desc("Blizzard's world map with every zone stitched together: scroll out of a zone into the next, drag across the whole world. The quest log, the map's controls and Questie all keep working.\n\n|cffffd100Wheel|r zooms at the cursor, |cffffd100drag|r pans, |cffffd100left-click|r zooms into the place under the cursor, |cffffd100right-click|r zooms out a level.\n\nIf you use Leatrix Maps or another world map addon, turn it off.", 1),
		autoSwitch = { type = "toggle", name = "Follow the view", order = 10, width = "full", get = get, set = set, disabled = off,
			desc = "Once the map stops moving, the map underneath becomes the zone or continent you're looking at, so quest areas, coordinates and the zone name match what's on screen." },
		hoverHighlight = { type = "toggle", name = "Highlight the zone under the cursor", order = 11, width = "full", get = get, set = set, disabled = off,
			desc = "Blizzard's glow on the zone you're pointing at." },
		lookHeader = ns.Header("Look", 20),
		colorMatch = { type = "range", name = "Colour matching", order = 21, min = 0, max = 1, step = 0.05, isPercent = true,
			get = get, set = set, disabled = off,
			desc = "How far each zone's borders move toward a shared palette, so mountains and borders hand over smoothly between zones. Zone interiors keep their own colours." },
		desaturate = { type = "range", name = "Take colour out", order = 22, min = 0, max = 0.6, step = 0.05, isPercent = true,
			get = get, set = set, disabled = off },
		unexplored = { type = "select", name = "Unexplored areas", order = 23, get = get, set = set, disabled = off,
			values = { show = "Show", dim = "Darken", hide = "Hide" }, sorting = { "show", "dim", "hide" },
			desc = "Areas you haven't explored yet: shown as they are, darkened and cooled (and a zone you haven't found at all darkened from every zoom, the continents' too), or hidden like Blizzard's own map (blank parchment until you get there)." },
		maxZoom = { type = "range", name = "Deepest zoom", order = 24, min = MAX_ZOOM[1], max = MAX_ZOOM[2], step = MAX_ZOOM[3],
			get = get, set = function(_, v) mod.SetMaxZoom(v) if mod.RefreshPanel then mod:RefreshPanel() end end, disabled = off,
			desc = "How far in the map zooms, in times the whole-world view (cities go half as far again). Past about 48 the art is only enlarged." },
		iconHeader = ns.Header("Icons", 30),
		routes = { type = "toggle", name = "Boat and zeppelin routes", order = 34, get = get, set = set, disabled = off },
		icons = { type = "toggle", name = "Dungeons, travel and more", order = 31, get = get, set = set, disabled = off,
			desc = "Dungeon and raid entrances, with their levels (click one: its map), boats and zeppelins (click: the other end)." },
		flight = { type = "toggle", name = "Flight masters", order = 32, get = get, set = set,
			disabled = off },
	}
	if mod.ExtraOptions then mod:ExtraOptions(opts, get, set, off) end
	if mod.NavOptions then mod:NavOptions(opts, get, set, off) end
	if mod.PinOptions then mod:PinOptions(opts, get, set, off) end
	if mod.DungeonOptions then mod:DungeonOptions(opts, get, set, off) end
	if mod.SketchOptions then mod:SketchOptions(opts, get, set, off) end
	if mod.WindowOptions then mod:WindowOptions(opts, get, set, off) end
	if mod.CloseOptions then mod:CloseOptions(opts, get, set, off) end
	opts.news = { type = "execute", name = "What's new", order = 1.5, func = function() mod:ToggleNews(true) end,
		desc = "This version's changes, and the versions before." }
	opts.resetSliders = { type = "execute", name = "Reset sliders to defaults", order = 2, disabled = off,
		desc = "Every slider here (and the OpenMap menu's) back to how OpenMap comes.",
		confirm = true, confirmText = "Put every slider back to its default?",
		func = function() mod:ResetSliders() end }
	return opts
end

-- every slider back to its default (Options' Reset sliders, the menu's Defaults): each through its own
-- setter, so what it changes follows as if it had been dragged there
function mod:ResetSliders()
	for key, opt in pairs(mod:Options()) do
		local default = mod.defaults[key]
		if type(opt) == "table" and opt.type == "range" and opt.set and default ~= nil and mod.db[key] ~= default then
			opt.set({ key }, default)
		end
	end
	if mod.RefreshPanel then mod:RefreshPanel() end
	if ns.NotifyOptions then ns.NotifyOptions() end
end
