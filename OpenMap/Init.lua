--------------------------------------------------------------------------------
-- Init: loaded last. Settings at ADDON_LOADED; the map, options and slash
-- commands at PLAYER_LOGIN.
--
--   /openmap (/omap)        options
--   /openmap status         what the map is doing
--   /openmap notes          map notes (paint areas, say what's there, export them)
--   /openmap debug          the debug overlay (frame rate, frame times, what OpenMap costs)
--   /openmap bench [zoom]   times the map at several zooms, each part off in turn (Bench.lua)
--   /openmap pins           the map pins (Pins.lua)
--   /openmap news           what's new in this version (News.lua)
--   /openmap draw           the quill: draw on the map (Sketch.lua)
--   /openmap dungeons       which map each dungeon entrance opens (Dungeons.lua)
--   /openmap entrance <name>  where you stand, as a dungeon entrance for tools/map-data (Dungeons.lua)
--------------------------------------------------------------------------------

local ADDON, ns = ...

local function Options()
	local mod = ns:GetModule("worldmap")
	local args = mod.Options and mod:Options() or {}
	args.enabled = { type = "toggle", name = "Enable OpenMap", order = 0, width = "full",
		desc = "Turning OpenMap off takes a reload.",
		get = function() return mod.db.enabled end,
		set = function(_, v) mod.db.enabled = v; ns:Print("Takes effect after a /reload.") end }
	return { type = "group", name = "|cff" .. ns.ACCENT .. "OpenMap|r " .. ns.version, args = args }
end

-- OpenMap's settings are the map's own menu (Panel.lua); with the map off (no menu), the options window,
-- which can turn it back on
local function OpenOptions()
	local mod = ns:GetModule("worldmap")
	if mod.enabled and mod.OpenMenu and mod:OpenMenu() then return end
	local ACD = LibStub("AceConfigDialog-3.0", true)
	if ACD then ACD:Open("OpenMap") end
end
ns.OpenOptions = OpenOptions

local function Slash(msg)
	local raw = (msg or ""):match("^%s*(.-)%s*$")
	msg = raw:lower()
	local mod = ns:GetModule("worldmap")
	local word, rest = msg:match("^(%S+)%s+(.+)$")
	local takes = { bench = true, entrance = true }  -- (/openmap bench 16: at that zoom; /openmap entrance Dire Maul - East)
	if takes[word] then msg, rest = word, raw:match("^%S+%s+(.+)$") end
	local run = {
		status = "Diag", paint = "TogglePaint", notes = "TogglePaint", debug = "ToggleDebugOverlay",
		bench = "Bench", pins = "TogglePins", news = "ToggleNews", entrance = "Entrance", draw = "ToggleSketch", dungeons = "DungeonDiag",
		welcome = "ShowWelcome",
	}
	if run[msg] then
		if mod.enabled and mod[run[msg]] then mod[run[msg]](mod, takes[msg] and rest or nil) else ns:Print("The map is off.") end
	else
		OpenOptions()
	end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, event, name)
	if event == "ADDON_LOADED" and name == ADDON then
		ns:InitDB()
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_LOGIN" then
		ns:EnableModules()
		local AC = LibStub("AceConfig-3.0", true)
		if AC then AC:RegisterOptionsTable("OpenMap", Options) end
		-- a page in Blizzard's settings that opens the options window
		if Settings and Settings.RegisterCanvasLayoutCategory then
			local panel = CreateFrame("Frame")
			local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
			title:SetPoint("TOPLEFT", 16, -16)
			title:SetText("|cff" .. ns.ACCENT .. "Open|rMap")
			local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
			button:SetSize(180, 26)
			button:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
			button:SetText("Open OpenMap's settings")
			button:SetScript("OnClick", function()
				if SettingsPanel then HideUIPanel(SettingsPanel) end
				OpenOptions()
			end)
			Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, "OpenMap"))
		end
		SLASH_OPENMAP1, SLASH_OPENMAP2 = "/openmap", "/omap"
		SlashCmdList.OPENMAP = Slash
		self:UnregisterEvent("PLAYER_LOGIN")
	end
end)

function ns.NotifyOptions()
	local ACR = LibStub("AceConfigRegistry-3.0", true)
	if ACR then ACR:NotifyChange("OpenMap") end
end
