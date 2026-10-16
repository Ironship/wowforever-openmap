--------------------------------------------------------------------------------
-- The first time the map opens on a new install: how it starts out. "Classic" is closer to
-- Blizzard's map: unexplored areas hidden, none of OpenMap's own icons or zone levels, the
-- favourites folded away. "OpenMap" keeps OpenMap's defaults. Settings saved before this are
-- never asked about, or changed. /openmap welcome asks again.
--------------------------------------------------------------------------------

local _, ns = ...
local mod = ns:GetModule("worldmap")
local L = ns.L

-- (presetAsked isn't in the defaults, where old saves would get it too: nil until the first login
-- with this version, then false on a new install, asked when the map opens, and true on one that
-- had settings)
local CLASSIC = { unexplored = "hide", icons = false, flight = false, routes = false, zoneLevels = false,
	dungeonLevels = false, trayOpen = false }

local frame

local function Choose(classic)
	mod.db.presetAsked = true
	if classic then
		for k, v in pairs(CLASSIC) do mod.db[k] = v end
		mod:Refresh()
		if ns.NotifyOptions then ns.NotifyOptions() end
	end
	frame:Hide()
end

local function Build(map)
	frame = CreateFrame("Frame", nil, map, "BackdropTemplate")
	frame:SetSize(460, 190)
	frame:SetPoint("CENTER", map.ScrollContainer or map, "CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)         -- (clicks don't reach the map under it)
	frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	frame:SetBackdropColor(0, 0, 0, 0.85)
	frame:SetBackdropBorderColor(0.55, 0.42, 0.25, 0.9)
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText(L["How should the map start out?"])
	local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("TOP", title, "BOTTOM", 0, -8)
	text:SetWidth(420)
	text:SetText(L["You can change any of it later in OpenMap's menu (its button on the map, or /openmap)."])
	local function Choice(x, label, desc, classic)
		local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		b:SetSize(180, 28)
		b:SetPoint("TOP", frame, "TOP", x, -74)
		b:SetText(label)
		b:SetScript("OnClick", function() Choose(classic) end)
		local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("TOP", b, "BOTTOM", 0, -8)
		fs:SetWidth(200)
		fs:SetText(desc)
	end
	Choice(-106, L["Classic"], L["Unexplored areas hidden. No dungeon or flight master icons and no zone levels; the favourite buttons folded away."], true)
	Choice(106, L["OpenMap"], L["The whole map shown, with dungeon entrances, flight masters, zone levels and favourite buttons."], false)
	frame:Hide()
end

function mod:ShowWelcome()
	local map = WorldMapFrame
	if not map then return end
	if not frame then Build(map) end
	if map:IsShown() then frame:Show() return end
	ToggleWorldMap()
	C_Timer.After(0, function() if map:IsShown() then frame:Show() end end)
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_LOGIN")
	if mod.db.presetAsked == nil then mod.db.presetAsked = not mod.fresh end
	if mod.db.presetAsked then return end
	EventUtil.ContinueOnAddOnLoaded("Blizzard_WorldMap", function()
		WorldMapFrame:HookScript("OnShow", function()
			if mod.enabled and mod.db.presetAsked == false and not (frame and frame:IsShown()) then mod:ShowWelcome() end
		end)
	end)
end)
