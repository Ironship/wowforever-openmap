--------------------------------------------------------------------------------
-- World map extras:
--   coordinates   two labels in the bottom-right corner: your position,
--                 and the zone and position under the cursor (any zone, not just the one shown)
--   zone levels   the hover label adds a zone's level range (coloured by your
--                 level; Data/Levels.lua)
--   moving fade   how far the map fades while you move (0: not at all); ours, not the
--                 game's (its mapFade CVar is held off): smooth, never under the mouse
-- And other addons' pins through HereBeDragons (Questie's, TomTom's, gatherers' ...): on a zone
-- map they only show that zone's own; the stitched map shows the neighbours too, so theirs come along.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local mod = ns:GetModule("worldmap")

local d = mod.defaults
d.coords = true
d.zoneLevels = true
d.moveFade = 0                  -- how much the map fades while you move (0 to 0.9)

local map, sc, bar
local labelProvider, labelOnUpdate      -- Blizzard's area label, and its own OnUpdate

local function SetCVarSafe(name, value)
	if C_CVar and C_CVar.SetCVar then pcall(C_CVar.SetCVar, name, value) elseif SetCVar then pcall(SetCVar, name, value) end
end

-- Game settings OpenMap holds while it runs: Blizzard's map coordinates while OpenMap's own show (they'd
-- double them), and the game's map fade (OpenMap's is the one that runs). The player's own values are
-- kept (mod.char.cvars: name -> value) and put back when OpenMap lets go, and at logout, so the game
-- saves the player's values (OpenMap takes the settings again at the next login)
local COORDS = { "worldMapShowPlayerCoords", "worldMapShowCursorCoords" }
local loggingOut = false
local cvarOwner = {}            -- (the logout handler's key)

local function DefaultCVar(name)
	local get = C_CVar and C_CVar.GetCVarDefault or _G.GetCVarDefault
	local ok, v = pcall(get or nop, name)
	return ok and v or "1"
end

local function Kept()
	if not mod.char.cvars then
		local kept = {}
		-- (from before they were kept: the fade was kept on its own; the coordinates were turned off
		-- unkept, so they go back to the game's default)
		if mod.char.mapFade ~= nil then
			kept.mapFade = mod.char.mapFade
			if mod.db.coords then
				for _, name in ipairs(COORDS) do
					if GetCVar(name) == "0" then kept[name] = DefaultCVar(name) end
				end
			end
		end
		mod.char.mapFade = nil
		mod.char.cvars = kept
	end
	return mod.char.cvars
end

local function HoldCVar(name, value)
	local kept = Kept()
	if kept[name] == nil then
		local ok, was = pcall(GetCVar, name)
		if ok and was and was ~= value then kept[name] = was end
	end
	SetCVarSafe(name, value)
end

local function LetGoCVar(name)
	local kept = Kept()
	local was = kept[name]
	if was == nil then return end
	kept[name] = nil
	SetCVarSafe(name, was)
end

-- the zone (or continent) under the cursor, the cursor's point in it, and its
-- point in the map shown. Stitched, from the cursor itself: Blizzard's cursor
-- position is clamped to the shown map's rectangle.
local lastU, lastV, lastId
local function PlaceAt()
	local mapID = map:GetMapID()
	if mod.IsStitched() then
		local u, v, pu = mod.CursorWorld()
		local id = lastId
		if not lastU or math.abs(u - lastU) > (pu or 0) * 2 or math.abs(v - lastV) > (pu or 0) * 2 then
			local chain = S.ChainAt(u, v)
			id, lastU, lastV, lastId = chain[#chain], u, v, chain[#chain]
		end
		local l, r, t, b = S.Rect(id)
		local hx, hy = mod.FromWorld(mapID, u, v)
		return id, (u - l) / (r - l), (v - t) / (b - t), hx, hy
	end
	local x, y
	if mod.PadCursor() and map.GetNormalizedGamepadCursorPosition then x, y = map:GetNormalizedGamepadCursorPosition()
	else x, y = map:GetNormalizedCursorPosition() end
	local info = C_Map.GetMapInfoAtPosition(mapID, x, y)
	if info and info.mapID ~= mapID then
		local l, r, t, b = C_Map.GetMapRectOnMap(info.mapID, mapID)
		if l and r > l and b > t then return info.mapID, (x - l) / (r - l), (y - t) / (b - t), x, y end
	end
	return mapID, x, y, x, y
end

local function MapName(mapID)
	local info = mapID and C_Map.GetMapInfo(mapID)
	return info and info.name
end

--------------------------------------------------------------------------------
-- Coordinates
--------------------------------------------------------------------------------

local NUMBERS = 74              -- px: the numbers' own box, right-aligned (wide enough for "100.0, 100.0")
local function Coord(x, y)
	if not x or x < 0 or x > 1 or y < 0 or y > 1 then return "|cff808080--|r" end
	return ("%.1f, %.1f"):format(x * 100, y * 100)
end

local throttle = 0
local function UpdateCoords(_, elapsed)
	throttle = throttle + elapsed
	if throttle < 0.05 then return end
	throttle = 0

	local best = C_Map.GetBestMapForUnit("player")
	local pos = best and C_Map.GetPlayerMapPosition(best, "player")
	local px, py
	if pos then px, py = ns.Safe.XY(pos) end
	if ns.Safe.IsSecret(px) or ns.Safe.IsSecret(py) then px, py = nil, nil end
	bar.player.at:SetText(Coord(px, py))

	if sc:IsMouseOver() or mod.PadCursor() then
		local id, zx, zy = PlaceAt()
		local name = MapName(id)
		bar.cursor:SetText(name or "")
		bar.cursor.at:SetText(Coord(zx, zy))
		bar.cursor:GetParent():Show()
	else
		bar.cursor:GetParent():Hide()
	end
	-- a pill's width changes with its name only, never with the numbers (they sit in a box of their own)
	for _, fs in ipairs({ bar.player, bar.cursor }) do
		local w = math.floor(fs:GetStringWidth() + NUMBERS + 30.5)
		local pill = fs:GetParent()
		if pill.omWidth ~= w then pill.omWidth = w pill:SetWidth(w) end
	end
end

-- a label: black, a thin bronze edge; its name in gold, then its numbers in a box of their own
-- (right-aligned, a fixed width: moving the mouse changes the numbers, never the pill's size)
local function Pill(parent, label)
	local pill = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	pill:SetHeight(24)
	pill:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	pill:SetBackdropColor(0, 0, 0, 0.78)
	pill:SetBackdropBorderColor(0.55, 0.42, 0.25, 0.8)
	local fs = pill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("LEFT", 10, 0)
	ns.Look:Font(fs, 12)
	fs:SetTextColor(1, 0.82, 0)
	fs:SetText(label or "")
	fs.at = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs.at:SetPoint("RIGHT", -10, 0)
	fs.at:SetWidth(NUMBERS)
	fs.at:SetJustifyH("RIGHT")
	ns.Look:Font(fs.at, 12)
	return pill, fs
end

-- the labels' place: the bottom-right corner, left of whatever Blizzard keeps there (the quest log's
-- button; Window.lua's, full screen)
local function PlaceCoords()
	if not bar then return end
	local right, bottom = sc:GetRight(), sc:GetBottom()
	local x = 8
	local frames = { mod.maxLogToggle }
	for _, f in ipairs(map.overlayFrames or {}) do frames[#frames + 1] = f end
	for _, f in ipairs(frames) do
		local fl, fb, fr = f:IsShown() and f:GetLeft(), f:GetBottom(), f:GetRight()
		if fl and right and fb and fr and bottom and right - fr < 40 and fb - bottom < 40 and fr - fl < 220 then
			x = math.max(x, right - fl + 6)
		end
	end
	bar:ClearAllPoints()
	bar:SetPoint("BOTTOMRIGHT", sc, "BOTTOMRIGHT", -x, 8)
end
mod.PlaceCoords = PlaceCoords

-- the labels' left edge (Panel.lua's favourites stop short of it), nil while they're hidden
function mod.CoordsLeft()
	if not bar or not bar:IsShown() then return end
	local left
	for _, pill in ipairs({ bar:GetChildren() }) do
		if pill:IsShown() and pill:GetLeft() then left = math.min(left or math.huge, pill:GetLeft()) end
	end
	return left
end

local function SetUpCoords()
	if not bar then
		bar = CreateFrame("Frame", nil, sc)
		bar:SetSize(1, 22)
		bar:SetFrameLevel(math.min(sc:GetFrameLevel() + 9000, 9900))   -- above every map pin
		-- (yours at the right, steady; the cursor's comes in to its left while over the map)
		local playerPill, cursorPill
		playerPill, bar.player = Pill(bar, PLAYER)
		playerPill:SetPoint("RIGHT")
		cursorPill, bar.cursor = Pill(bar)
		cursorPill:SetPoint("RIGHT", playerPill, "LEFT", -6, 0)
		bar:SetScript("OnUpdate", UpdateCoords)
		PlaceCoords()
		map:HookScript("OnShow", function() PlaceCoords() C_Timer.After(0, PlaceCoords) end)
		sc:HookScript("OnSizeChanged", PlaceCoords)
		if map.RefreshOverlayFrames then hooksecurefunc(map, "RefreshOverlayFrames", PlaceCoords) end
	end
	bar:SetShown(mod.db.coords)
	-- Blizzard's own coordinates (another addon may have turned them on) would double ours; ours off,
	-- the player's own setting for them comes back
	for _, name in ipairs(COORDS) do
		if mod.db.coords then HoldCVar(name, "0") else LetGoCVar(name) end
	end
end

--------------------------------------------------------------------------------
-- Zone levels on the hover label
--------------------------------------------------------------------------------

-- a level range in the game's quest colours for you: above you red / orange, yours orange, below you
-- green, grey (zones, dungeons: Dungeons.lua); as a colour code and the range
function mod.LevelColor(lo, hi)
	local level = ns.Safe.Value(UnitLevel("player")) or 1
	local color
	if level < lo then
		color = GetQuestDifficultyColor(lo)
	elseif level > hi then
		color = GetQuestDifficultyColor(hi - 2)   -- wholly below you goes grey/green, not yellow
	end
	color = color or QuestDifficultyColors and QuestDifficultyColors.difficult or { r = 1, g = 0.5, b = 0.25 }
	return ("|cff%02x%02x%02x"):format(color.r * 255, color.g * 255, color.b * 255), lo == hi and tostring(hi) or (lo .. "-" .. hi)
end

local function LevelText(mapID)
	local lv = ns.MapLevels and ns.MapLevels[mapID]
	if not lv or not lv[1] or not lv[2] then return "" end
	local code, range = mod.LevelColor(lv[1], lv[2])
	return (" %s(%s)|r"):format(code, range)
end

-- replaces AreaLabelFrameMixin's OnUpdate: the place under the cursor, with its levels
local function AreaLabelOnUpdate(self)
	self:ClearLabel(MAP_AREA_LABEL_TYPE.AREA_NAME)
	local m = self.dataProvider:GetMap()
	if m:IsCanvasMouseFocus() or mod.PadCursor() then
		local mapID = m:GetMapID()
		local id, _, _, x, y = PlaceAt()
		local name
		if id ~= mapID and id ~= S.WORLD then
			name = MapName(id)
			if name then name = name .. LevelText(id) end
		elseif x >= 0 and x <= 1 and y >= 0 and y <= 1 then
			name = MapUtil.FindBestAreaNameAtMouse(mapID, x, y)
		end
		if name then self:SetLabel(MAP_AREA_LABEL_TYPE.AREA_NAME, name) end
	end
	self:EvaluateLabels()
end

local function SetUpZoneLevels()
	if not labelProvider then
		for provider in pairs(map.dataProviders or {}) do
			if provider.Label and provider.Label.SetLabel then labelProvider = provider break end
		end
		if not labelProvider then return end
		labelOnUpdate = labelProvider.Label:GetScript("OnUpdate")
	end
	labelProvider.Label:SetScript("OnUpdate", mod.db.zoneLevels and AreaLabelOnUpdate or labelOnUpdate)
end

--------------------------------------------------------------------------------
-- Fading
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Questie's pins on the stitched map. HereBeDragons (Questie's copy) places a pin from
-- its world coordinates; on Forever that's only right on the world map, where Questie
-- converts it through the client's own map rectangles. On a zone or continent map (the
-- stitched map switches to the one you're looking at) it either drops the pin or puts it
-- in the wrong place, and it never shows a neighbouring zone's pins on a zone. So there,
-- every pin is placed (or moved) here, from the map it belongs to (`uiMapID`, `mapX`,
-- `mapY`) through the same rectangles, following Questie's own rules for where it may show.
--------------------------------------------------------------------------------

local SHOW_CURRENT = 0                  -- HBD_PINS_WORLDMAP_SHOW_CURRENT: only on its own map
local QUESTIE_BASE = 2015               -- the fixed frame level Questie's map icons and lines start from

-- Questie fixes its icons' frame levels from QUESTIE_BASE up (it expects Blizzard's map canvas
-- near 2000), which is under the stitched map's upper art layers: lift them above the art,
-- keeping their order among themselves (quest finishers in front ...)
local function Lift(icon)
	local top = S.artTop
	if not top or not icon.GetFrameLevel or not icon.SetFixedFrameLevel then return end
	local level = icon:GetFrameLevel()
	if level > top then return end
	icon:SetFixedFrameLevel(false)
	icon:SetFrameLevel(level - QUESTIE_BASE + top + 1)
	icon:SetFixedFrameLevel(true)
end
local NEAR = 0.5                        -- how far round the map underneath (its widths) pins are placed (each pin
                                        --  on the map is laid out again on every frame of a pan or zoom: /openmap bench)

local questie = { placed = 0, ours = 0, moved = 0 }   -- for /openmap status: since the map last changed

-- The same for every addon's copy of HereBeDragons' pins (TomTom, gatherers, notes ... each may bring
-- its own): a pin placed from a map point (`uiMapID`, `mapX`, `mapY`: AddWorldMapIconMap) goes where it
-- belongs on the stitched map, a neighbouring zone's too. Questie's copy has its own pin template and
-- frame levels; the others use HereBeDragons' own template.
local PIN_LIBS = {
	["HereBeDragonsQuestie-Pins-2.0"] = { template = "HereBeDragonsPinsTemplateQuestie", questie = true },
}
local DEFAULT_TEMPLATE = "HereBeDragonsPinsTemplate"

local function SetUpPins(name, pins)
	local spec = PIN_LIBS[name] or { template = DEFAULT_TEMPLATE }
	local provider = pins and pins.worldmapProvider
	if not provider or not provider.HandlePin or provider.openmapPins then return end
	if not (map.pinPools and map.pinPools[spec.template]) then return end   -- (a copy this doesn't know the pins of)
	provider.openmapPins = true
	local count = spec.questie and questie or { placed = 0, ours = 0, moved = 0 }
	if spec.questie then questie.pins = pins end
	-- each icon's map point as it was added (the library keeps only its world position and uiMapID;
	-- Questie's copy also keeps mapX, mapY)
	local at = setmetatable({}, { __mode = "k" })
	-- (noted before the library places it: it may place the icon straight away)
	local add = pins.AddWorldMapIconMap
	if type(add) == "function" then
		pins.AddWorldMapIconMap = function(lib, ref, icon, uiMapID, x, y, ...)
			if icon and type(uiMapID) == "number" and type(x) == "number" and type(y) == "number" then at[icon] = { uiMapID, x, y } end
			return add(lib, ref, icon, uiMapID, x, y, ...)
		end
	end
	local HandlePin = provider.HandlePin
	provider.HandlePin = function(self, icon, data, ...)
		HandlePin(self, icon, data, ...)
		local holder = icon:GetParent()
		local placed = holder and holder.icon == icon and holder.SetPosition and holder
		if placed then count.placed = count.placed + 1 end
		if placed and spec.questie and mod.IsStitched() then Lift(icon) end
		if not mod.IsStitched() then return end
		local uiMapID, mx, my = data.uiMapID, data.mapX, data.mapY
		if not (mx and my) and at[icon] and at[icon][1] == uiMapID then uiMapID, mx, my = at[icon][1], at[icon][2], at[icon][3] end
		if not uiMapID or not mx or not my then return end
		local mapID = self:GetMap():GetMapID()
		if mapID == S.WORLD and spec.questie then return end   -- (Questie's own Forever path: right there)
		local l, r, t, b = S.Rect(uiMapID)
		if not l then return end
		local x, y = mod.FromWorld(mapID, l + mx * (r - l), t + my * (b - t))
		if placed then                                      -- placed, but from coordinates that are off here
			placed:SetPosition(x, y)
			count.moved = count.moved + 1
			return
		end
		if mapID == S.WORLD then return end                -- (on the whole world, only what the library itself shows)
		if (data.worldMapShowFlag or SHOW_CURRENT) == SHOW_CURRENT and uiMapID ~= mapID then return end
		local info = C_Map.GetMapInfo(mapID)
		if not info then return end
		local profile = spec.questie and _G.Questie and Questie.db and Questie.db.profile
		if profile and profile.hideIconsOnContinents and info.mapType == Enum.UIMapType.Continent then return end
		if x < -NEAR or x > 1 + NEAR or y < -NEAR or y > 1 + NEAR then return end
		self:GetMap():AcquirePin(spec.template, icon, x, y, data.frameLevelType)
		if spec.questie then Lift(icon) end
		count.ours = count.ours + 1
	end
	-- (counted afresh each time the map changes: HereBeDragons rebuilds its pins then)
	local Refresh = provider.RefreshAllData
	provider.RefreshAllData = function(self, ...)
		local before = self:GetMap() and self:GetMap():GetMapID()
		if before ~= count.mapID then count.placed, count.ours, count.moved, count.mapID = 0, 0, 0, before end
		return Refresh(self, ...)
	end
end

-- every copy of the pins library loaded so far (an addon loaded later: next time the map opens)
local function SetUpAllPins()
	if not LibStub or not LibStub.IterateLibraries then return end
	for name, lib in LibStub:IterateLibraries() do
		if type(name) == "string" and name:match("^HereBeDragons.*%-Pins%-2%.0$") then SetUpPins(name, lib) end
	end
end

-- for /openmap status: Questie's pins, and how many are on the map now
function mod.QuestieStatus()
	if not questie.pins then return nil end
	local registered, shown = 0, 0
	for _ in pairs(questie.pins.worldmapPins or {}) do registered = registered + 1 end
	for _ in map:EnumeratePinsByTemplate("HereBeDragonsPinsTemplateQuestie") do shown = shown + 1 end
	return registered, shown, questie.placed, questie.ours, questie.moved
end

--------------------------------------------------------------------------------
-- Fading while you move
--------------------------------------------------------------------------------

local FADE_RATE = 6             -- the fade's approach, per second
local fader = CreateFrame("Frame")
fader:Hide()
local faded = 1
fader:SetScript("OnUpdate", function(_, elapsed)
	local moving = false
	if GetUnitSpeed then
		local speed = GetUnitSpeed("player")
		moving = not ns.Safe.IsSecret(speed) and (speed or 0) > 0
	end
	local want = (moving and not (map:IsMouseOver() or mod.PadCursor())) and 1 - (mod.db.moveFade or 0) or 1
	if math.abs(faded - want) < 0.005 then
		if faded ~= want then faded = want map:SetAlpha(want) end
		return
	end
	faded = faded + (want - faded) * math.min(1, elapsed * FADE_RATE)
	map:SetAlpha(faded)
end)

local function ApplyExtras()
	if not map or loggingOut then return end
	SetUpCoords()
	SetUpZoneLevels()
	-- (from the old on / off setting: fading back on was the game's half-fade)
	if mod.db.noFade ~= nil then
		if mod.db.noFade == false and (mod.db.moveFade or 0) == 0 then mod.db.moveFade = 0.5 end
		mod.db.noFade = nil
	end
	-- the game's own fade off while ours runs (the player's setting kept, and put back at logout)
	HoldCVar("mapFade", "0")
	fader:SetShown(map:IsShown() and (mod.db.moveFade or 0) > 0)
	if (mod.db.moveFade or 0) == 0 then map:SetAlpha(1) end
end

function mod:SetupExtras(worldMap)
	map, sc = worldMap, worldMap.ScrollContainer
	map:HookScript("OnShow", function() fader:SetShown((mod.db.moveFade or 0) > 0) end)
	map:HookScript("OnHide", function() fader:Hide() faded = 1 map:SetAlpha(1) end)
	SetUpAllPins()
	map:HookScript("OnShow", SetUpAllPins)            -- (a copy an addon loaded since brought)
	ApplyExtras()
	-- (before the game saves its settings: the player's own back; Compat.lua's reassertion stands down)
	ns.RegisterEvent(cvarOwner, "PLAYER_LOGOUT", function()
		loggingOut = true
		for name in pairs(Kept()) do LetGoCVar(name) end
	end)
end

mod.RefreshExtras = ApplyExtras

function mod:ExtraOptions(opts, get, set, off)
	local function setApply(info, v) set(info, v) ApplyExtras() end
	opts.extrasHeader = ns.Header("On the map", 40)
	opts.coords = { type = "toggle", name = "Coordinates", order = 41, get = get, set = setApply, disabled = off,
		desc = "A bar along the map's foot: your position, and the zone and position under the cursor." }
	opts.zoneLevels = { type = "toggle", name = "Zone levels", order = 42, get = get, set = setApply, disabled = off,
		desc = "Hovering a zone shows its level range, coloured for your level." }
	opts.moveFade = { type = "range", name = "Fade while moving", order = 44, min = 0, max = 0.9, step = 0.05, isPercent = true,
		get = get, set = setApply, disabled = off,
		desc = "How much the map fades while you walk or ride, so you can see where you're going. 0% keeps it solid. It never fades while the mouse is over it." }
end
