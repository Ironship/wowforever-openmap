--------------------------------------------------------------------------------
-- OpenMap's core: saved settings, events, chat output, options plumbing and
-- the few look helpers the map uses. Loaded first; the map files (Map/*.lua)
-- add a module with ns:NewModule and Init.lua starts it at login.
--
-- Settings: OpenMapDB (account), OpenMapCharDB (per character), filled from
-- the module's defaults (missing keys only, so new defaults reach old saves).
--------------------------------------------------------------------------------

local ADDON, ns = ...
_G.OpenMap = ns

ns.name = ADDON
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "dev"
if ns.version:find("^@") then ns.version = "dev" end   -- (a checkout: the packager fills it in for releases)
ns.ACCENT = "e6b85c"
-- where players send reports (the "Report a problem" button shows it to copy)
ns.ISSUES_URL = "https://github.com/jiforever/wowforever-openmap/issues/new?template=map-problem.yml"
ns.Media = { path = "Interface\\AddOns\\" .. ADDON .. "\\Media\\" }

-- Translations: ns.L["English text"] gives the text for the player's language once a
-- translation fills it in (none yet), else the English. Place names come from the game.
ns.L = setmetatable({}, { __index = function(_, k) return k end })

function ns:Print(fmt, ...)
	local msg = select("#", ...) > 0 and fmt:format(...) or tostring(fmt)
	DEFAULT_CHAT_FRAME:AddMessage("|cff" .. ns.ACCENT .. "OpenMap|r: " .. msg)
end

--------------------------------------------------------------------------------
-- Secret-safe reads (clients with secret values, e.g. WoW Forever)
--------------------------------------------------------------------------------

local Safe = {}
ns.Safe = Safe

function Safe.IsSecret(v)
	return issecretvalue ~= nil and issecretvalue(v) or false
end

function Safe.Value(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

-- a position's x, y: Blizzard's vectors have GetXY, but some APIs on this client hand back
-- a plain { x, y } table
function Safe.XY(vec)
	if type(vec) ~= "table" then return end
	if vec.GetXY then return vec:GetXY() end
	return vec.x, vec.y
end

-- calls fn(...) and returns its first result when it is plain, else nil
function Safe.Call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if not ok then return nil end
	return Safe.Value(v)
end

--------------------------------------------------------------------------------
-- Events: any number of handlers per event, keyed by owner
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local handlers = {}
eventFrame:SetScript("OnEvent", function(_, event, ...)
	for owner, fn in pairs(handlers[event] or {}) do
		local ok, err = pcall(fn, owner, event, ...)
		if not ok then geterrorhandler()(err) end
	end
end)

function ns.RegisterEvent(owner, event, fn)
	if not handlers[event] then
		if not pcall(eventFrame.RegisterEvent, eventFrame, event) then return false end
		handlers[event] = {}
	end
	handlers[event][owner] = fn or owner[event]
	return true
end

function ns.UnregisterEvent(owner, event)
	local list = handlers[event]
	if not list then return end
	list[owner] = nil
	if next(list) == nil then
		handlers[event] = nil
		eventFrame:UnregisterEvent(event)
	end
end

--------------------------------------------------------------------------------
-- Modules (OpenMap has one, "worldmap")
--------------------------------------------------------------------------------

ns.modules = {}

function ns:NewModule(key, spec)
	local mod = spec or {}
	mod.key = key
	mod.defaults = mod.defaults or {}
	if mod.defaults.enabled == nil then mod.defaults.enabled = true end
	ns.modules[key] = mod
	return mod
end

function ns:GetModule(key)
	return ns.modules[key]
end

-- missing keys from defaults, recursively
local function Fill(t, defaults)
	for k, v in pairs(defaults) do
		if t[k] == nil then
			t[k] = type(v) == "table" and Fill({}, v) or v
		elseif type(v) == "table" and type(t[k]) == "table" then
			Fill(t[k], v)
		end
	end
	return t
end

function ns:InitDB()
	OpenMapDB = OpenMapDB or {}
	OpenMapCharDB = OpenMapCharDB or {}
	for key, mod in pairs(ns.modules) do
		mod.fresh = OpenMapDB[key] == nil       -- (no saved settings yet: a new install)
		OpenMapDB[key] = Fill(OpenMapDB[key] or {}, mod.defaults)
		OpenMapCharDB[key] = OpenMapCharDB[key] or {}
		mod.db, mod.char = OpenMapDB[key], OpenMapCharDB[key]
	end
end

function ns:EnableModules()
	for _, mod in pairs(ns.modules) do
		if mod.db.enabled and not mod.enabled then
			mod.enabled = true
			if mod.OnEnable then
				local ok, err = pcall(mod.OnEnable, mod)
				if not ok then
					mod.enabled = false
					ns:Print("|cffff6060failed to start|r: %s", tostring(err):sub(1, 300))
					geterrorhandler()(err)
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Options (AceConfig tables)
--------------------------------------------------------------------------------

-- get / set for options stored in getTable(info)[key]; refresh() after a change
function ns.Bind(getTable, refresh)
	local function get(info)
		local v = getTable(info)[info[#info]]
		if info.type == "color" then
			v = v or { 1, 1, 1, 1 }
			return v[1], v[2], v[3], v[4] or 1
		end
		return v
	end
	local function set(info, a, b, c, d)
		local t = getTable(info)
		if info.type == "color" then
			t[info[#info]] = { a, b, c, d or 1 }
		else
			t[info[#info]] = a
		end
		if refresh then refresh(info) end
	end
	return get, set
end

function ns.Header(name, order)
	return { type = "header", name = name, order = order }
end

function ns.Desc(text, order)
	return { type = "description", name = text, order = order, fontSize = "medium" }
end

--------------------------------------------------------------------------------
-- Look: fonts and a plain dark panel (other addons may restyle these: every
-- panel is frame.omBackdrop, every font goes through ns.Look:Font)
--------------------------------------------------------------------------------

local Look = {}
ns.Look = Look

function Look:Font(fs, size, flags)
	if not fs:SetFont(STANDARD_TEXT_FONT, size or 12, flags or "") then
		fs:SetFontObject(GameFontHighlight)
	end
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetShadowOffset(1, -1)
	return fs
end

-- a dark backdrop with a thin border behind `frame`; opts: inset, alpha
function Look:Panel(frame, opts)
	opts = opts or {}
	local bd = frame.omBackdrop
	if not bd then
		bd = CreateFrame("Frame", nil, frame, "BackdropTemplate")
		bd:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
		frame.omBackdrop = bd
	end
	local inset = opts.inset or 0
	bd:ClearAllPoints()
	bd:SetPoint("TOPLEFT", -inset, inset)
	bd:SetPoint("BOTTOMRIGHT", inset, -inset)
	bd:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	bd:SetBackdropColor(0.06, 0.06, 0.07, opts.alpha or 0.9)
	bd:SetBackdropBorderColor(0, 0, 0, 1)
	return bd
end

-- a dropdown list in the game's own menus' look (its dark rounded panel, which WoW Forever edges in
-- bronze: Blizzard_Menu's MenuStyle1, the same offsets), else the plain panel with a bronze edge.
-- Returns the room to leave inside it: left, top, right, bottom
function Look:Dropdown(frame)
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("common-dropdown-bg") then
		local bg = frame:CreateTexture(nil, "BACKGROUND")
		bg:SetAtlas("common-dropdown-bg")
		bg:SetPoint("TOPLEFT", -10, 3)
		bg:SetPoint("BOTTOMRIGHT", 10, -3)
		bg:SetAlpha(0.925)
		return 8, 8, 8, 15
	end
	local bd = Look:Panel(frame, { alpha = 0.97 })
	bd:SetBackdropBorderColor(0.66, 0.49, 0.28, 1)
	return 6, 6, 6, 6
end

-- a window in the game's own frame: the map window's metal border (Blizzard's nine-slice without the
-- portrait, which WoW Forever draws in bronze) over its dark rock, a title in its title bar and its
-- close button; else (a client without that layout) the plain panel with a title and a close button.
-- Returns the title bar's height (content starts below it), the title and the close button.
function Look:Window(frame, title, onClose)
	local util = _G.NineSliceUtil
	local top = 0
	local layout = util and util.GetLayout and util.GetLayout("ButtonFrameTemplateNoPortrait") and "ButtonFrameTemplateNoPortrait"
	local ok, nine = false, nil
	if layout then ok, nine = pcall(CreateFrame, "Frame", nil, frame, "NineSlicePanelTemplate") end
	if ok and nine and pcall(util.ApplyLayoutByName, nine, layout) then
		nine:SetAllPoints()
		nine:SetFrameLevel(frame:GetFrameLevel())
		local bg = frame:CreateTexture(nil, "BACKGROUND")
		bg:SetPoint("TOPLEFT", 6, -21)
		bg:SetPoint("BOTTOMRIGHT", -2, 3)
		if bg:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT") == false then
			bg:SetColorTexture(0.1, 0.09, 0.08, 1)
		end
		bg:SetHorizTile(true)
		bg:SetVertTile(true)
		local shade = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
		shade:SetAllPoints(bg)
		shade:SetColorTexture(0, 0, 0, 0.45)       -- (the rock darkened, so the small print reads)
		top = 21
	else
		Look:Panel(frame, { alpha = 0.96 })
	end
	local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	text:SetPoint("TOPLEFT", top > 0 and 30 or 12, top > 0 and -4 or -10)
	text:SetPoint("TOPRIGHT", -30, top > 0 and -4 or -10)
	text:SetJustifyH(top > 0 and "CENTER" or "LEFT")
	text:SetWordWrap(false)
	text:SetText(title or "")
	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetFrameLevel(frame:GetFrameLevel() + 20)
	close:SetHitRectInsets(-4, -4, -4, -4)
	if top > 0 then close:SetPoint("TOPRIGHT", 1, 0) else close:SetPoint("TOPRIGHT", 2, 2) end
	close:SetScript("OnClick", onClose or function() frame:Hide() end)
	return top, text, close
end
