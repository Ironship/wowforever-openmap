--------------------------------------------------------------------------------
-- What's new: the latest versions' notes (Data/Changelog.lua, made from CHANGELOG.md) in a window
-- laid out like the quest log: the versions listed on the log's dark page (each with how many
-- changes it brought), the one picked set out on a quest's parchment, Newer and Older to step
-- through them. From the OpenMap menu, Options or /openmap news. After an update the OpenMap button
-- and the menu's What's new glow, and a line in chat says so, until the window has been opened once.
--------------------------------------------------------------------------------

local _, ns = ...
local mod = ns:GetModule("worldmap")
local Look, L = ns.Look, ns.L

mod.defaults.newsSeen = false   -- the newest notes' version the window has shown (false: a fresh install)

local frame
local W, H = 900, 620
local LIST_W = 300              -- the versions' list
local FOOT = 80                 -- under the two: the buttons, who makes it
local ROW_H = 26
local INK = { 0.2, 0.12, 0.05 }       -- (the quest text's)
local TITLE = { 0.24, 0.13, 0.04 }
local GOLD = { 1, 0.82, 0 }
local TITLE_FONT = "Fonts\\MORPHEUS.TTF"
local URL = "https://github.com/jiforever/wowforever-openmap"
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
	"October", "November", "December" }

local function Newest()
	local log = ns.MapChangelog
	return log and log[1] and log[1].version
end

-- notes newer than the player has seen (after an update)
function mod.NewsUnseen()
	local newest = Newest()
	return newest ~= nil and mod.db.newsSeen ~= false and mod.db.newsSeen ~= newest
end

local function Font(fs, face, size)
	if not fs:SetFont(face, size, "") then fs:SetFontObject(GameFontNormal) end
	fs:SetShadowOffset(0, 0)
	return fs
end

-- "2026-10-16" as "16 October 2026"
local function Day(date)
	local y, m, d = (date or ""):match("^(%d+)-(%d+)-(%d+)$")
	if not y then return date or "" end
	local names = _G.CALENDAR_FULLDATE_MONTH_NAMES
	return ("%d %s %s"):format(tonumber(d), names and names[tonumber(m)] or MONTHS[tonumber(m)] or m, y)
end

-- a version's short name for the list: "v0.4.0-beta" as "0.4.0"
local function Short(sec)
	if sec.version == "Unreleased" then return L["Next"] end
	return (sec.version:gsub("^v", ""):gsub("%-.*$", ""))
end

local function Clean(text) return (text:gsub("`", "")) end

-- the page: one version's notes, its name and when, each change a paragraph by a bullet
local function ShowPage(n)
	local log = ns.MapChangelog or {}
	n = math.max(1, math.min(#log, n))
	local sec = log[n]
	if not sec then return end
	frame.at = n
	local page, child = frame.page, frame.child
	local width = page.scroll:GetWidth() - 8
	child:SetWidth(width)
	page.title:SetText(sec.version == "Unreleased" and L["Unreleased"] or sec.version)
	page.sub:SetText(sec.version == "Unreleased" and L["Coming in the next version."]
		or (sec.date ~= "" and L["Released %s."]:format(Day(sec.date)) or ""))
	local y = (page.title:GetStringHeight() or 28) + (page.sub:GetStringHeight() or 14) + 26
	for _, p in ipairs(page.items) do p.dot:Hide() p.text:Hide() end
	for _, h in ipairs(page.heads) do h:Hide() h.rule:Hide() end
	local nh = 0
	for i, item in ipairs(sec.items) do
		-- (a heading before this one: the kind of change, New, Improved, Fixed)
		local head = sec.heads and sec.heads[i]
		if head then
			nh = nh + 1
			local h = page.heads[nh]
			if not h then
				h = Font(child:CreateFontString(nil, "OVERLAY"), TITLE_FONT, 20)
				h:SetTextColor(TITLE[1], TITLE[2], TITLE[3])
				h.rule = child:CreateTexture(nil, "ARTWORK")
				h.rule:SetColorTexture(TITLE[1], TITLE[2], TITLE[3], 0.35)
				h.rule:SetHeight(1)
				page.heads[nh] = h
			end
			if i > 1 then y = y + 8 end
			h:ClearAllPoints()
			h:SetPoint("TOPLEFT", 0, -y)
			h:SetText(head)
			h.rule:ClearAllPoints()
			h.rule:SetPoint("LEFT", h, "RIGHT", 10, 0)
			h.rule:SetPoint("RIGHT", child, "RIGHT", -6, 0)
			h:Show()
			h.rule:Show()
			y = y + (h:GetStringHeight() or 22) + 12
		end
		local p = page.items[i]
		if not p then
			p = {}
			p.dot = child:CreateTexture(nil, "ARTWORK")
			p.dot:SetSize(8, 8)
			p.dot:SetTexture("Interface\\COMMON\\Indicator-Yellow")
			if not p.dot:GetTexture() then p.dot:SetColorTexture(0.6, 0.45, 0.15, 1) end
			p.text = Font(child:CreateFontString(nil, "OVERLAY"), STANDARD_TEXT_FONT, 15)
			p.text:SetJustifyH("LEFT")
			p.text:SetSpacing(4)
			p.text:SetTextColor(INK[1], INK[2], INK[3])
			page.items[i] = p
		end
		p.text:ClearAllPoints()
		p.text:SetPoint("TOPLEFT", 26, -y)
		p.text:SetWidth(width - 34)
		p.text:SetText(Clean(item))
		p.dot:ClearAllPoints()
		p.dot:SetPoint("TOPLEFT", 6, -y - 4)
		p.dot:Show()
		p.text:Show()
		y = y + (p.text:GetStringHeight() or 16) + 14
	end
	child:SetHeight(y + 16)
	page.scroll:SetVerticalScroll(0)
	-- the list: this one lit; Newer and Older as far as there are
	for _, row in ipairs(frame.rows) do
		local on = row.n == n
		row.lit:SetShown(on)
		row.label:SetTextColor(on and 1 or GOLD[1], on and 1 or GOLD[2], on and 1 or GOLD[3])
		row.count:SetTextColor(on and 1 or GOLD[1], on and 1 or GOLD[2], on and 1 or GOLD[3])
	end
	frame.newer:SetEnabled(n > 1)
	frame.older:SetEnabled(n < #log)
end

local function Button(text, fn, w)
	local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	b:SetSize(w or 100, 24)
	b:SetText(text)
	b:SetScript("OnClick", fn)
	return b
end

local function Build()
	local log = ns.MapChangelog or {}
	frame = CreateFrame("Frame", "OpenMapNews", UIParent)
	frame:SetSize(W, H)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	-- (smaller on a small screen: all of it on it)
	local fit = math.min(1, (UIParent:GetHeight() - 60) / H, (UIParent:GetWidth() - 60) / W)
	frame:SetScale(fit)
	-- (the map window's own frame, its title bar and X)
	local top = Look:Window(frame, L["What's new in OpenMap"] .. "  |cff998866" .. ns.version .. "|r")
	tinsert(UISpecialFrames, "OpenMapNews")

	-- along the top, as the quest log's count: how many versions, how many changes
	local changes = 0
	for _, sec in ipairs(log) do changes = changes + #sec.items end
	local count = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	count:SetPoint("TOPLEFT", 16, -top - 10)
	count:SetSize(110, 24)
	count:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	count:SetBackdropColor(0, 0, 0, 0.6)
	count:SetBackdropBorderColor(0.66, 0.49, 0.28, 0.9)
	local countText = Font(count:CreateFontString(nil, "OVERLAY"), STANDARD_TEXT_FONT, 13)
	countText:SetPoint("CENTER")
	countText:SetText(L["Versions: |cffffffff%d|r"]:format(#log))
	countText:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
	local summary = Font(frame:CreateFontString(nil, "OVERLAY"), STANDARD_TEXT_FONT, 13)
	summary:SetPoint("LEFT", count, "RIGHT", 14, 0)
	summary:SetTextColor(0.85, 0.8, 0.7)
	summary:SetText(L["%d changes, newest first."]:format(changes))

	-- the versions: the quest log's dark page, a heading, a row each (lit: the one on the page)
	local list = CreateFrame("Frame", nil, frame)
	list:SetPoint("TOPLEFT", 14, -top - 44)
	list:SetPoint("BOTTOMLEFT", 14, FOOT)
	list:SetWidth(LIST_W)
	local dark = list:CreateTexture(nil, "BACKGROUND")
	dark:SetAllPoints()
	if not (C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("QuestLog-main-background")) then
		dark:SetColorTexture(0.08, 0.06, 0.05, 1)
	else
		dark:SetAtlas("QuestLog-main-background")
	end
	local rim = CreateFrame("Frame", nil, list, "BackdropTemplate")
	rim:SetPoint("TOPLEFT", -1, 1)
	rim:SetPoint("BOTTOMRIGHT", 1, -1)
	rim:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	rim:SetBackdropBorderColor(0.4, 0.3, 0.18, 1)
	local head = Font(list:CreateFontString(nil, "OVERLAY"), TITLE_FONT, 18)
	head:SetPoint("TOPLEFT", 14, -14)
	head:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
	head:SetText("OpenMap")
	local headCount = Font(list:CreateFontString(nil, "OVERLAY"), STANDARD_TEXT_FONT, 12)
	headCount:SetPoint("RIGHT", list, "TOPRIGHT", -14, -24)
	headCount:SetTextColor(0.7, 0.62, 0.5)
	headCount:SetText(L["%d versions"]:format(#log))
	frame.rows = {}
	for n, sec in ipairs(log) do
		local row = CreateFrame("Button", nil, list)
		row:SetHeight(ROW_H)
		row:SetPoint("TOPLEFT", 8, -44 - (n - 1) * (ROW_H + 2))
		row:SetPoint("TOPRIGHT", -8, -44 - (n - 1) * (ROW_H + 2))
		row.n = n
		row.lit = row:CreateTexture(nil, "BACKGROUND")
		row.lit:SetAllPoints()
		row.lit:SetColorTexture(0.75, 0.55, 0.1, 0.85)   -- (the quest log's picked title: a gold bar)
		row.lit:Hide()
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 0.82, 0.3, 0.15)
		row.label = Font(row:CreateFontString(nil, "OVERLAY"), STANDARD_TEXT_FONT, 14)
		row.label:SetPoint("LEFT", 10, 0)
		row.label:SetText(("[%s]  %s"):format(Short(sec), sec.version == "Unreleased" and L["Unreleased"] or Day(sec.date)))
		row.count = Font(row:CreateFontString(nil, "OVERLAY"), STANDARD_TEXT_FONT, 14)
		row.count:SetPoint("RIGHT", -10, 0)
		row.count:SetText(("(%d)"):format(#sec.items))
		row:SetScript("OnClick", function(self)
			PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_SELECT or 857)
			ShowPage(self.n)
		end)
		frame.rows[n] = row
	end

	-- the page: a quest's parchment, the notes on it, scrolling
	local page = CreateFrame("Frame", nil, frame)
	frame.page = page
	page:SetPoint("TOPLEFT", list, "TOPRIGHT", 12, 0)
	page:SetPoint("BOTTOMRIGHT", -14, FOOT)
	local paper = page:CreateTexture(nil, "BACKGROUND")
	paper:SetAllPoints()
	local atlas
	for _, name in ipairs({ "questbg-parchment", "QuestDetailsBackgrounds" }) do
		if not atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) then atlas = name end
	end
	if atlas then paper:SetAtlas(atlas)
	elseif paper:SetTexture(ns.Media.path .. "Textures\\MapPaper", "REPEAT", "REPEAT") == false then
		paper:SetColorTexture(0.86, 0.78, 0.6, 1)
	end
	page.scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
	page.scroll:SetPoint("TOPLEFT", 40, -34)
	page.scroll:SetPoint("BOTTOMRIGHT", -52, 30)
	local child = CreateFrame("Frame", nil, page.scroll)
	child:SetSize(1, 1)
	page.scroll:SetScrollChild(child)
	frame.child = child
	page.title = Font(child:CreateFontString(nil, "OVERLAY"), TITLE_FONT, 28)
	page.title:SetPoint("TOPLEFT", 0, 0)
	page.title:SetTextColor(TITLE[1], TITLE[2], TITLE[3])
	page.sub = Font(child:CreateFontString(nil, "OVERLAY"), STANDARD_TEXT_FONT, 15)
	page.sub:SetPoint("TOPLEFT", page.title, "BOTTOMLEFT", 0, -8)
	page.sub:SetTextColor(0.36, 0.25, 0.14)
	page.items, page.heads = {}, {}

	-- at the foot: Newer, Older; Close; who makes it, and that it's open source (the link to copy:
	-- the game opens none)
	frame.newer = Button(L["Newer"], function() ShowPage(frame.at - 1) end)
	frame.newer:SetPoint("BOTTOMLEFT", 14, FOOT - 34)
	frame.older = Button(L["Older"], function() ShowPage(frame.at + 1) end)
	frame.older:SetPoint("LEFT", frame.newer, "RIGHT", 8, 0)
	local close = Button(CLOSE or L["Close"], function() frame:Hide() end)
	close:SetPoint("BOTTOMRIGHT", -14, FOOT - 34)
	local credit = Look:Font(frame:CreateFontString(nil, "OVERLAY"), 13)
	credit:SetPoint("BOTTOMLEFT", 16, 16)
	credit:SetText(L["OpenMap is made by |cffe6b85cJi|r, and it's open source: join in on GitHub"])
	local link = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	link:SetSize(300, 22)
	link:SetPoint("LEFT", credit, "RIGHT", 14, 0)
	link:SetAutoFocus(false)
	link:SetText(URL)
	link:SetCursorPosition(0)
	link:SetScript("OnTextChanged", function(self, user) if user then self:SetText(URL) self:HighlightText() end end)
	link:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	link:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	local copy = Look:Font(frame:CreateFontString(nil, "OVERLAY"), 11)
	copy:SetPoint("LEFT", link, "RIGHT", 10, 0)
	copy:SetTextColor(0.6, 0.53, 0.4)
	copy:SetText(L["click, then Ctrl-C"])

	frame:SetScript("OnShow", function()
		-- (laid out once it shows: text measures its height only then); the newest first
		C_Timer.After(0, function() if frame:IsShown() then ShowPage(frame.at or 1) end end)
		ShowPage(frame.at or 1)
		mod.db.newsSeen = Newest() or false
		if mod.RefreshPanel then mod:RefreshPanel() end
	end)
	frame:Hide()
end

function mod:ToggleNews(on)
	if not frame then Build() end
	if on == nil then on = not frame:IsShown() end
	frame:SetShown(on)
end
function mod.NewsShown() return frame and frame:IsShown() or false end

function mod:SetupNews()
	local newest = Newest()
	if not newest then return end
	if mod.db.newsSeen == false then
		mod.db.newsSeen = newest                    -- (a fresh install: nothing to tell)
	elseif mod.NewsUnseen() then
		C_Timer.After(6, function()
			if mod.NewsUnseen() then ns:Print(L["Updated to %s: see What's new in the OpenMap menu."], ns.version) end
		end)
	end
end
