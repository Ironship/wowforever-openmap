--------------------------------------------------------------------------------
-- Other world map addons, side by side with OpenMap. On the stitched map the map art and the
-- view are OpenMap's; everything else of theirs keeps working.
--   * their map art there is hidden while the stitched map shows, and back on other maps
--     (dungeons, battlegrounds): High Fidelity World Map's minimap tiles and its blend button,
--     BetterMaps' terrain and caves (under the stitched art: drawn for nothing), HiddenMaps'
--     approach and dungeon maps (over it, catching clicks)
--   * Leatrix Maps' icons (its points of interest: dungeons, flight points, boats, portals ...) are
--     lifted above the stitched art (they're made at a fixed low frame level on the canvas, under it)
--   * their view changes (zoom remembered per map, keep centred, a jump into a cave) and their
--     zoom steps past OpenMap's deepest don't apply there (WorldMap.lua)
--   * the zone label, the coordinates CVars and the game's map fade are set again after theirs:
--     Leatrix Maps and OpenMap both replace the label's script at login (theirs reads the map
--     underneath, not the view), and either may turn Blizzard's coordinates or fade back on
--   * Move Any: the map window is its to move and size; OpenMap's title bar, grips and saved
--     place stand down (Window.lua)
--   * what still clashes, their window options, is named once at login, in their own words
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local mod = ns:GetModule("worldmap")
local L = ns.L

local map
local owner = {}                -- (our event handlers' key)
local held = {}                 -- frame -> shown again when the stitched map goes
-- their art frames, by name, and whether to show them again ourselves (HiddenMaps shows its own on
-- its next refresh: shown by us, a dungeon overlay could linger on a map it's not for)
local FRAMES = {
	HFWMForeverOverlay = true, HFWMForeverToggleButton = true,                 -- High Fidelity World Map
	BetterMapsTerrain = true, BetterMapsCaves = true,                          -- BetterMaps
	HiddenMapsFullCanvasBackground = false, HiddenMapsWorldMapHost = false,    -- HiddenMaps
	HiddenMapsAdaptivePresentationHost = false, HiddenMapsMapInteractionLayer = false,
}

local function Stitched() return mod.IsStitched() and map and map:IsShown() end

local function Hold(f, reshow)
	if not f.omHeld then
		f.omHeld = true
		f:HookScript("OnShow", function(self)
			if Stitched() then held[self] = reshow self:Hide() end
		end)
	end
	if f:IsShown() then held[f] = reshow f:Hide() end
end

-- Leatrix Maps' icons: plain frames on the canvas, marked by it, made at frame level 100 (under the
-- stitched art's): lifted above the art, as Questie's are (Extras.lua). Leatrix finds the one under
-- the cursor itself, from where it placed it, so its tooltips go with them
local function LeatrixPins()
	local top = S.artTop
	if not top then return end
	local kids = { map:GetCanvas():GetChildren() }     -- (once a map change: every pin is a child)
	for _, f in ipairs(kids) do
		if f.isLeaMapsPin and f:GetFrameLevel() <= top then f:SetFrameLevel(top + 2) end
	end
end

local function HoldAll()
	if not Stitched() then return end
	for name, reshow in pairs(FRAMES) do
		local f = _G[name]
		if type(f) == "table" and f.HookScript then Hold(f, reshow) end
	end
	if _G.LeaMapsDB then LeatrixPins() end
end

local function Release()
	for f, reshow in pairs(held) do
		held[f] = nil
		if reshow then f:Show() end
	end
end

function mod.OnStitchedChanged(on)
	if not map then return end
	if on then HoldAll() else Release() end
end

-- (their art comes back as the map changes underneath, from their own map-change hooks: once
-- theirs have run)
function mod.OnHostMapChanged()
	if map and mod.IsStitched() then C_Timer.After(0, HoldAll) end
end

-- the label script, the coordinates and the fade again, after theirs
local function Reassert()
	if mod.RefreshExtras then mod.RefreshExtras() end
end

local function OnCVar(_, _, name, value)
	if type(name) ~= "string" then return end
	name = name:lower()
	if name == "mapfade" and value ~= "0" then Reassert()
	elseif (name == "worldmapshowplayercoords" or name == "worldmapshowcursorcoords") and value ~= "0" and mod.db.coords then Reassert() end
end

-- once, at login: the options of theirs that still fight OpenMap's window or coordinates
local function Warn()
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if not loaded then return end
	local lea = loaded("Leatrix_Maps") and _G.LeaMapsDB
	if type(lea) == "table" then
		local names = {}
		for _, o in ipairs({ { "UnlockMap", "Unlock map frame" }, { "ScaleWorldMap", "Scale the map" }, { "SimpleMapFrame", "Use simple map frame" } }) do
			if lea[o[1]] == "On" then names[#names + 1] = o[2] end
		end
		if lea.ShowCoords == "On" and mod.db.coords then names[#names + 1] = "Show coordinates" end
		if #names > 0 then
			ns:Print(L["Leatrix Maps: turn off %s there; OpenMap does the same for its map."]:format(table.concat(names, ", ")))
		end
	end
	-- (not checked against OpenMap yet: both change the map's zoom)
	for addon, title in pairs({ Mapster = "Mapster", Magnify = "Magnify" }) do
		if loaded(addon) then
			ns:Print(L["%s is also changing the world map. Turn off its world map options (or the addon) so the two don't fight."]:format(title))
		end
	end
end

function mod:SetupCompat(worldMap)
	map = worldMap
	map:HookScript("OnShow", function() HoldAll() end)
	-- (after every addon's own login setup: they replace the label and set the CVars then)
	local first = true
	map:HookScript("OnShow", function() if first then first = false Reassert() end end)
	C_Timer.After(1, Reassert)
	ns.RegisterEvent(owner, "CVAR_UPDATE", OnCVar)
	C_Timer.After(3, Warn)
end
