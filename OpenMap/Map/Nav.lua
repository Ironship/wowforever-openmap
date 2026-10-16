--------------------------------------------------------------------------------
-- Getting around the map:
--   find me      a button that glides to where you are
--   reopen       choose player-centred, always remember, or remember
--                only while the player is still inside the previous view
--   waypoints    Ctrl-click the map to drop Blizzard's map pin there (and a
--                TomTom arrow, if TomTom is on); click the pin to clear it
--   search       type a zone, city, dungeon or flight master and glide to it
--   group        party and raid members as class-coloured dots, wherever they
--                are on the stitched map (Blizzard's own only show on the map
--                underneath)
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local mod = ns:GetModule("worldmap")
local Look, Safe, L = ns.Look, ns.Safe, ns.L

local d = mod.defaults
d.group = true

local map, sc


-- a unit's place on the world (normalized), or nil (secret, in an instance, unknown)
local function UnitWorld(unit)
	local best = Safe.Call(C_Map.GetBestMapForUnit, unit)
	if not best or not S.Rect(best) then return end
	local pos = Safe.Call(C_Map.GetPlayerMapPosition, best, unit)
	if not pos then return end
	local x, y = Safe.XY(pos)
	if Safe.IsSecret(x) or Safe.IsSecret(y) or not x or not y or (x == 0 and y == 0) then return end
	local u, v = mod.ToWorld(best, x, y)
	return u, v, best
end

--------------------------------------------------------------------------------
-- Find me, and reopening where you left off
--------------------------------------------------------------------------------

function mod:FindMe(keepZoom)
	if not mod.IsStitched() then return end
	local u, v, best = UnitWorld("player")
	if not u then
		-- the map underneath may still know (the zone you're in, shown)
		local host = mod.HostMap()
		local pos = host and Safe.Call(C_Map.GetPlayerMapPosition, host, "player")
		if pos then
			local x, y = Safe.XY(pos)
			if not Safe.IsSecret(x) and x and y and (x ~= 0 or y ~= 0) then u, v = mod.ToWorld(host, x, y) best = host end
		end
	end
	if not u then
		ns:Print(L["You aren't on the world map here (an instance or a place it doesn't cover)."])
		return
	end
	local _, _, zoom = mod.ViewNow()
	mod.Glide(u, v, keepZoom and zoom or math.max(zoom, mod.FitZoom(best)))
end

local saved                     -- { u, v, zoom, zone, host } when the map closed

function mod.GetReopenView()
	-- Preserve existing preferences, including the earlier two-checkbox setting.
	-- No default for reopenView: it would hide the old preference before migration.
	if not mod.db.reopenView then
		mod.db.reopenView = mod.db.rememberViewInView and "visible"
			or (mod.db.rememberView == false and "player" or "always")
	end
	if mod.db.reopenView == "zone" then mod.db.reopenView = "always" end
	mod.db.rememberView, mod.db.rememberViewInView = nil, nil
	return mod.db.reopenView
end

function mod:OnMapHidden()
	local u, v, zoom = mod.ViewNow()
	if u then saved = { u, v, zoom, Safe.Call(C_Map.GetBestMapForUnit, "player"), mod.HostMap() } end
end

-- the view to reopen on: restore the previous view when the selected condition holds,
-- otherwise centre on the player. Only for the map Blizzard opens on:
-- a map put up for something else (a quest's zone, from the quest log or the tracker) shows as
-- Blizzard shows it, or the view would move the map back and Blizzard would close the quest.
-- (No mapID: whether there's a view to reopen on at all)
function mod.SavedView(mapID)
	local mode = mod.GetReopenView()
	local zone = Safe.Call(C_Map.GetBestMapForUnit, "player")
	local restore = saved and mode == "always"
	if saved and mode == "visible" then
		local u, v = UnitWorld("player")
		if not u then return end
		local hu, hv = mod.ViewHalfExtents(saved[3])
		restore = math.abs(u - saved[1]) <= hu and math.abs(v - saved[2]) <= hv
	end
	local display = Safe.Call(MapUtil and MapUtil.GetDisplayableMapForPlayer)
	if restore then
		if mapID and mapID ~= saved[5] and mapID ~= zone and mapID ~= display then return end
		return saved[1], saved[2], saved[3]
	end
	if mapID and mapID ~= zone and mapID ~= display then return end
	local u, v, best = UnitWorld("player")
	if u then return u, v, mod.FitZoom(best) end
end

function mod:OnMapShown()
	if not mod.SavedView() then return end
	-- (Blizzard's zoom reset on opening goes straight there, WorldMap.lua; this is for when
	-- Blizzard puts up another map after it, on the next frame: only if it's not there yet)
	C_Timer.After(0, function()
		local u, v, zoom = mod.SavedView(mod.HostMap())
		if not u or not mod.IsStitched() then return end
		local nu, nv, nz = mod.ViewNow()
		if nu and math.abs(nu - u) < 1e-4 and math.abs(nv - v) < 1e-4 and math.abs(nz - zoom) < 1e-3 then return end
		mod.ShowNow(u, v, zoom)
	end)
end

--------------------------------------------------------------------------------
-- Waypoints
--------------------------------------------------------------------------------

local wpSet, RefreshWaypoint
local WAYPOINT = { atlas = "Waypoint-MapPin-Tracked", texture = "Interface\\Minimap\\Ping\\ping5", size = 30 }

-- Blizzard's user waypoint where the client has it (its pin, its arrow); else our own,
-- kept per character. Either shows on the whole stitched map.
local function BlizzardPin()
	if not (C_Map.HasUserWaypoint and C_Map.GetUserWaypoint) then return end
	local ok, has = pcall(C_Map.HasUserWaypoint)
	if not ok or not has then return end
	local point = C_Map.GetUserWaypoint()
	if point and point.position then
		local x, y = Safe.XY(point.position)
		return point.uiMapID, x, y
	end
end

local function ClearPin()
	if C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
	mod.char.pin = nil
	RefreshWaypoint()
end

-- our pin: a click removes it, a chat-link click (Shift) puts Blizzard's link to it in chat
local function PinClick()
	if IsModifiedClick and IsModifiedClick("CHATLINK") then
		local ok, link = pcall(C_Map.GetUserWaypointHyperlink or nop)
		if ok and link then
			local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
			if insert then insert(link) end
		end
		return
	end
	ClearPin()
end

-- On the stitched map the pin is always ours, never Blizzard's: a click on Blizzard's runs in
-- the map's code that OpenMap changes, and its Shift-click (copying a slash command to the
-- clipboard, which only Blizzard's UI may do) is then blocked, blaming OpenMap
local function HideBlizzardPin()
	if not (mod.IsStitched and mod.IsStitched()) or not map or not map.EnumeratePinsByTemplate then return end
	for pin in map:EnumeratePinsByTemplate("WaypointLocationPinTemplate") do pin:Hide() end
end

function RefreshWaypoint()
	if not wpSet then return end
	S.ClearPinSet(wpSet)
	local mapID, x, y = BlizzardPin()
	local own = not mapID
	if own and mod.char.pin then mapID, x, y = mod.char.pin[1], mod.char.pin[2], mod.char.pin[3] end
	HideBlizzardPin()
	if not mapID or not S.Rect(mapID) then return end
	local u, v = mod.ToWorld(mapID, x, y)
	local pin = S.AddPin(wpSet, u, v, WAYPOINT)
	pin:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local info = C_Map.GetMapInfo(mapID)
		GameTooltip:AddLine(L["Map pin"], 1, 0.82, 0)
		GameTooltip:AddLine(("%s  %.1f, %.1f"):format(info and info.name or "", x * 100, y * 100), 1, 1, 1)
		GameTooltip:AddLine(L["Click: remove"], 0.6, 0.6, 0.6)
		if not own then GameTooltip:AddLine(L["Shift-click: share in chat"], 0.6, 0.6, 0.6) end
		GameTooltip:Show()
	end)
	pin:SetScript("OnLeave", GameTooltip_Hide)
	pin.OnClick = PinClick
end

-- a pin at the world point (normalized): Blizzard's if it takes it, else ours; and TomTom's
function mod.DropWaypoint(u, v)
	local chain = S.ChainAt(u, v)
	local mapID = chain[#chain]
	if mapID == S.WORLD then return end
	local x, y = mod.FromWorld(mapID, u, v)
	local info = C_Map.GetMapInfo(mapID)
	local blizzard = false
	if C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates
		and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(mapID)) then
		blizzard = pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(mapID, x, y)) and BlizzardPin() ~= nil
		if blizzard and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true) end
	end
	mod.char.pin = not blizzard and { mapID, x, y } or nil
	local tomtom = _G.TomTom
	if tomtom and tomtom.AddWaypoint then
		pcall(tomtom.AddWaypoint, tomtom, mapID, x, y, { title = info and info.name or "OpenMap", from = "OpenMap" })
	end
	RefreshWaypoint()
end

-- the pin button: the next click on the map drops a pin there (Ctrl-click always does)
-- the menu's pin button: the next click on the map drops a pin there (Ctrl-click always does)
local pinArmed = false
function mod.PinMode() return pinArmed end
function mod.SetPinMode(on)
	pinArmed = on and true or false
	if mod.OnPinMode then mod.OnPinMode(pinArmed) end
end
function mod.ClearPin() ClearPin() end

--------------------------------------------------------------------------------
-- Search
--------------------------------------------------------------------------------

local places                    -- { name, lower, kind, u0, v0, u1, v1 } or a point (u0 == u1)
local box, list
local MAX_RESULTS = 8

local function Places()
	if places then return places end
	places = {}
	local seen = {}
	local function add(name, kind, u0, v0, u1, v1)
		if not name or name == "" or not u0 then return end
		local key = kind .. name
		if seen[key] then return end
		seen[key] = true
		places[#places + 1] = { name = name, lower = name:lower(), kind = kind, u0, v0, u1 or u0, v1 or v0 }
	end
	for _, kind in ipairs({ Enum.UIMapType.Continent, Enum.UIMapType.Zone }) do
		for _, info in ipairs(C_Map.GetMapChildrenInfo(S.WORLD, kind, true) or {}) do
			local l, r, t, b = S.Rect(info.mapID)
			if l then add(info.name, kind == Enum.UIMapType.Continent and L["Continent"] or L["Zone"], l, t, r, b) end
		end
	end
	for _, g in ipairs((ns.MapPlaces or {}).instances or {}) do
		local u, v = S.FromYards(g[1], g[2], g[3])
		for _, inst in ipairs(g[4]) do add(S.InstanceName(inst), inst[3] and L["Raid"] or L["Dungeon"], u, v) end
	end
	for _, node in pairs((ns.MapFlights or {}).nodes or {}) do
		local u, v = S.FromYards(node[2], node[3], node[4])
		add(node[1], L["Flight master"], u, v)
	end
	return places
end

-- a marker on what was found, for a few seconds
local pingSet, pingTimer
local PING = { atlas = "Waypoint-MapPin-Untracked", texture = "Interface\\Minimap\\Ping\\ping5", size = 30 }
local function Ping(u, v)
	if not pingSet then return end
	S.ClearPinSet(pingSet)
	local pin = S.AddPin(pingSet, u, v, PING)
	pin:EnableMouse(false)
	if pingTimer then pingTimer:Cancel() end
	pingTimer = C_Timer.NewTimer(5, function() S.ClearPinSet(pingSet) end)
end

local function Go(p)
	box:ClearFocus()
	list:Hide()
	if p[1] == p[3] then
		mod.Glide(p[1], p[2], math.max(14, select(3, mod.ViewNow()) or 1))
		Ping(p[1], p[2])
	else
		S.GlideToRect(p[1], p[2], p[3], p[4], 0.95)
	end
end

local function Results(text)
	text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local out = {}
	if #text < 2 then return out end
	for _, p in ipairs(Places()) do
		local at = p.lower:find(text, 1, true)
		if at then out[#out + 1] = { p, at == 1 and 0 or 1 } end
	end
	table.sort(out, function(a, b)
		if a[2] ~= b[2] then return a[2] < b[2] end
		return #a[1].name < #b[1].name
	end)
	return out
end

local function ShowResults()
	local found = Results(box:GetText())
	list.rows = list.rows or {}
	for _, row in ipairs(list.rows) do row:Hide() end
	if #found == 0 then list:Hide() return end
	for i = 1, math.min(#found, MAX_RESULTS) do
		local row = list.rows[i]
		if not row then
			row = CreateFrame("Button", nil, list)
			row:SetSize(220, 18)
			row:SetPoint("TOPLEFT", 6, -4 - (i - 1) * 18)
			row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
			row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.name:SetPoint("LEFT", 4, 0)
			row.kind = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			row.kind:SetPoint("RIGHT", -4, 0)
			row:SetScript("OnClick", function(self) Go(self.place) end)
			list.rows[i] = row
		end
		row.place = found[i][1]
		row.name:SetText(found[i][1].name)
		row.kind:SetText(found[i][1].kind)
		row:Show()
	end
	list:SetHeight(8 + math.min(#found, MAX_RESULTS) * 18)
	list:Show()
	list.first = found[1][1]
end

-- the search box, on `parent` (the map's menu), `width` wide; its results drop down below it
function mod.CreateSearch(parent, width)
	map = map or _G.WorldMapFrame
	box = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
	box:SetSize(width, 22)
	box:SetAutoFocus(false)
	if box.Instructions then box.Instructions:SetText(L["Find a place"]) end
	list = CreateFrame("Frame", nil, parent)
	list:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -2)
	list:SetWidth(232)
	list:SetFrameStrata("DIALOG")
	list:EnableMouse(true)
	Look:Panel(list, { inset = 0, alpha = 0.95 })
	list:Hide()
	box:HookScript("OnTextChanged", ShowResults)
	box:SetScript("OnEnterPressed", function() if list:IsShown() and list.first then Go(list.first) else box:ClearFocus() end end)
	box:HookScript("OnEscapePressed", function() list:Hide() end)
	box:HookScript("OnEditFocusLost", function() C_Timer.After(0.2, function() if not box:HasFocus() then list:Hide() end end) end)
	map:HookScript("OnHide", function() box:ClearFocus() list:Hide() end)
	return box
end

--------------------------------------------------------------------------------
-- Group members
--------------------------------------------------------------------------------

local groupSet, groupLooks = nil, {}
local DOT = { atlas = "WhiteCircle-RaidBlips", texture = "Interface\\Minimap\\PartyRaidBlips" }

local function GroupLook(unit)
	local _, class = UnitClass(unit)
	class = Safe.Value(class) or "PRIEST"
	local look = groupLooks[class]
	if not look then
		local c = (C_ClassColor and C_ClassColor.GetClassColor(class)) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class])
		look = { atlas = DOT.atlas, texture = DOT.texture, size = 12, color = c and { c.r, c.g, c.b, 1 } or { 1, 1, 1, 1 } }
		groupLooks[class] = look
	end
	return look
end

local function GroupEnter(pin)
	GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
	local name = Safe.Call(UnitName, pin.unit)
	GameTooltip:AddLine(name or "?", 1, 1, 1)
	GameTooltip:Show()
end

local function RefreshGroup()
	if not groupSet then return end
	S.ClearPinSet(groupSet)
	if not mod.db.group or not mod.IsStitched() or not IsInGroup() then return end
	local host = mod.HostMap()
	local raid = IsInRaid()
	for i = 1, raid and 40 or 4 do
		local unit = (raid and "raid" or "party") .. i
		if UnitExists(unit) and not UnitIsUnit(unit, "player") then
			-- Blizzard shows the ones on the map underneath; we show the rest
			local onHost = host and Safe.Call(C_Map.GetPlayerMapPosition, host, unit)
			if not onHost then
				local u, v = UnitWorld(unit)
				if u then
					local pin = S.AddPin(groupSet, u, v, GroupLook(unit))
					pin.unit = unit
					pin:SetScript("OnEnter", GroupEnter)
					pin:SetScript("OnLeave", GameTooltip_Hide)
				end
			end
		end
	end
end

--------------------------------------------------------------------------------

function mod:BuildNav()
	wpSet = S.PinSet("waypoint", 0, 5)
	pingSet = S.PinSet("ping", 0, 5)
	groupSet = S.PinSet("group", 0, 4)
	RefreshWaypoint()
end

function mod:SetupNav(worldMap)
	map, sc = worldMap, worldMap.ScrollContainer
	ns.RegisterEvent(mod, "USER_WAYPOINT_UPDATED", RefreshWaypoint)
	ns.RegisterEvent(mod, "SUPER_TRACKING_CHANGED", RefreshWaypoint)
	-- Blizzard's pin comes back each time its provider redraws (the waypoint set, the map changed)
	-- (found by a method only it has: asking each provider its pin template errors on some, the
	-- vignettes' takes an argument)
	for provider in pairs(map.dataProviders or {}) do
		if type(provider) == "table" and provider.OnWayPointLocationToggleUpdate and provider.RefreshAllData then
			hooksecurefunc(provider, "RefreshAllData", HideBlizzardPin)
		end
	end
	local wait = 0
	local ticker = CreateFrame("Frame", nil, map)
	ticker:SetScript("OnUpdate", function(_, elapsed)
		wait = wait - elapsed
		if wait > 0 then return end
		wait = 0.5
		RefreshGroup()
	end)
end

-- the map underneath changed: stitched or not, and the group's places on it
function mod:RefreshNav()
	RefreshWaypoint()
	RefreshGroup()
end

function mod:NavOptions(opts, get, set, off)
	opts.reopenView = { type = "select", name = L["When reopening the map"], order = 11,
		get = mod.GetReopenView, set = set, disabled = off,
		values = { player = L["Center on player"], always = L["Always remember"],
			visible = L["Remember while visible"] }, sorting = { "player", "always", "visible" },
		desc = L["Choose one behavior. Center on player: always open on you. Always remember: restore your previous position and zoom, even after changing zones. Remember while visible: restore only if your current location is inside the previous view, even across zone boundaries. Otherwise, open on you. Maps opened for a quest still show the quest's area."] }
	opts.group = { type = "toggle", name = L["Party and raid members"], order = 35, get = get, set = set, disabled = off,
		desc = L["Class-coloured dots for your group anywhere on the stitched map."] }
end
