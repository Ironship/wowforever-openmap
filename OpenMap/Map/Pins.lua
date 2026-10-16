--------------------------------------------------------------------------------
-- Map pins: as many as you like, each with a note and a colour, kept for every character
-- (OpenMapDB: worldmap -> pins). Ctrl-click the map, or the menu's Drop a pin, adds one (followed:
-- Blizzard's waypoint and its arrow, and TomTom's; Nav.lua) and opens its note; click a pin to
-- change its note or colour, follow it, share it or delete it. The menu's Pins (/openmap pins)
-- lists them all.
-- Sharing: with your group or guild, or whispered to your target, as addon messages only OpenMap
-- reads (whoever gets them is asked first; a note arrives as plain text, cut short); or as a code
-- to copy and paste anywhere, which the list's Import adds.
-- A pin: { id, map (uiMapID), x, y (on that map, 0..1), note, color (COLORS), from (who shared
-- it), at (time()) }
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local mod = ns:GetModule("worldmap")
local Look, Safe, L = ns.Look, ns.Safe, ns.L

mod.defaults.pins = { list = {}, nextId = 1 }
mod.defaults.pinsShared = true  -- pins others share reach you (you're asked first)

local PREFIX = "OpenMap"        -- (its addon messages)
local CODE = "OMPINS1:"         -- (a code of pins, to paste)
local NOTE_MAX = 160            -- characters of a note
local SHARE_MAX = 100           -- pins from one share, at most
local SEND_GAP = 0.3            -- seconds between messages sent (the game holds back a burst)
local ASK_AFTER = 1.5           -- seconds after someone's last pin before asking (a share of several)
local NEAR = 5e-4               -- (two points this close on a map are one)
local COLORS = {                -- { name, r, g, b }: the first leaves the pin as it is
	{ L["Gold"] },
	{ L["Red"], 1, 0.38, 0.32 },
	{ L["Green"], 0.5, 0.95, 0.4 },
	{ L["Blue"], 0.45, 0.72, 1 },
	{ L["Purple"], 0.82, 0.55, 1 },
}
local MARK = { atlas = "Waypoint-MapPin-Untracked", texture = "Interface\\Minimap\\Ping\\ping5", size = 24 }
local FOLLOWED = { atlas = "Waypoint-MapPin-Tracked", texture = "Interface\\Minimap\\Ping\\ping5", size = 30 }
local ROWS = 12

local map, sc, set, editor, list, codeFrame
local looks = {}                -- (each colour's look, followed or not: made once)
local RefreshList, Edit, ShowDrawing   -- (below)

local function DB() return mod.db.pins end

local function ZoneName(id)
	local info = id and C_Map.GetMapInfo(id)
	return info and info.name or "?"
end

local function Round(v) return math.floor(v * 1e4 + 0.5) / 1e4 end

-- a note as plain text: no control characters, no escape codes ("|": links, colours), cut short
-- (not mid-character)
local function Clean(text)
	text = tostring(text or ""):gsub("%c", " "):gsub("|", "/")
	text = strtrim(text)
	if #text > NOTE_MAX then text = text:sub(1, NOTE_MAX):gsub("[\192-\255][\128-\191]*$", "") end
	return text
end

local function Same(p, mapID, x, y)
	return p.map == mapID and math.abs(p.x - x) < NEAR and math.abs(p.y - y) < NEAR
end

-- the pin at a point on a map (the waypoint's: Nav.lua shows that as this pin, followed)
function mod.PinAt(mapID, x, y)
	if not mapID or not x then return end
	for _, p in ipairs(DB().list) do
		if Same(p, mapID, x, y) then return p end
	end
end

local function Followed(p)
	if not mod.WaypointPoint then return false end
	local mapID, x, y = mod.WaypointPoint()
	return mapID and x and Same(p, mapID, x, y) or false
end

local function Add(mapID, x, y, note, color, from)
	local db = DB()
	local p = { id = db.nextId, map = mapID, x = Round(x), y = Round(y), note = Clean(note),
		color = COLORS[color or 1] and color or 1, from = from, at = time() }
	db.nextId = db.nextId + 1
	tinsert(db.list, p)
	return p
end

local function Remove(p)
	for i, q in ipairs(DB().list) do
		if q == p then tremove(DB().list, i) return end
	end
end

local function Follow(p)
	if mod.TrackPoint then mod.TrackPoint(p.map, p.x, p.y, p.note ~= "" and p.note or nil) end
end

--------------------------------------------------------------------------------
-- On the map
--------------------------------------------------------------------------------

local function PinLook(p, followed)
	local key = (p.color or 1) .. (followed and "f" or "")
	if not looks[key] then
		local base, c = followed and FOLLOWED or MARK, COLORS[p.color] or COLORS[1]
		looks[key] = { atlas = base.atlas, texture = base.texture, size = base.size, color = c[2] and { c[2], c[3], c[4] } or nil }
	end
	return looks[key]
end

local function PinEnter(self)
	local p = self.data
	if not p then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(p.note ~= "" and p.note or L["Map pin"], 1, 0.82, 0, true)
	GameTooltip:AddLine(("%s  %.1f, %.1f"):format(ZoneName(p.map), p.x * 100, p.y * 100), 1, 1, 1)
	if p.from then GameTooltip:AddLine(L["Shared by %s"]:format(p.from), 0.6, 0.8, 1) end
	if Followed(p) then GameTooltip:AddLine(L["Followed (the waypoint)"], 0.5, 0.95, 0.4) end
	GameTooltip:AddLine(L["Click to edit its note, follow, share or delete it"], 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

local function PinClick(self) if self.data then Edit(self.data) end end

function mod.RefreshPins()
	if not set then return end
	S.ClearPinSet(set)
	for _, p in ipairs(DB().list) do
		if S.Rect(p.map) then
			local u, v = mod.ToWorld(p.map, p.x, p.y)
			local pin = S.AddPin(set, u, v, PinLook(p, Followed(p)), p)
			pin:SetScript("OnEnter", PinEnter)
			pin:SetScript("OnLeave", GameTooltip_Hide)
			pin.OnClick = PinClick
		end
	end
	if list and list:IsShown() then RefreshList() end
	if editor and editor:IsShown() and editor.pin then
		editor.follow:SetText(Followed(editor.pin) and L["Stop following"] or L["Follow"])
		ShowDrawing()
	end
end

--------------------------------------------------------------------------------
-- Sharing: addon messages ("P1", map, x, y, colour, note: tab-separated, at most 255 bytes),
-- sent a few a second; and a code of pins (CODE, then each pin's map,x,y,colour,note, the note's
-- "%", "," and ";" written %XX, the pins joined by ";")
--------------------------------------------------------------------------------

local queue = {}                -- { message, channel, target }
local sender = CreateFrame("Frame")
sender:Hide()
local wait = 0
sender:SetScript("OnUpdate", function(self, elapsed)
	wait = wait - elapsed
	if wait > 0 then return end
	local m = tremove(queue, 1)
	if not m then self:Hide() return end
	wait = SEND_GAP
	pcall(C_ChatInfo.SendAddonMessage, PREFIX, m[1], m[2], m[3])
end)

local function Message(p)
	local head = ("P1\t%d\t%.4f\t%.4f\t%d\t"):format(p.map, p.x, p.y, p.color or 1)
	local note = p.note or ""
	if #head + #note > 255 then note = note:sub(1, 255 - #head):gsub("[\192-\255][\128-\191]*$", "") end
	return head .. note
end

-- where a share can go now: "group", "guild", "target"; channel and whisper target, or nil
local function Channel(to)
	if to == "group" then
		if IsInRaid() then return "RAID" end
		if IsInGroup() then return "PARTY" end
	elseif to == "guild" then
		if IsInGuild() then return "GUILD" end
	elseif to == "target" then
		if UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
			return "WHISPER", GetUnitName("target", true)
		end
	end
end

local SHARE_TO = { group = L["your group"], guild = L["your guild"] }

local function Share(pins, to)
	local channel, target = Channel(to)
	if not channel or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) or #pins == 0 then return end
	for _, p in ipairs(pins) do queue[#queue + 1] = { Message(p), channel, target } end
	sender:Show()
	ns:Print(L["Sharing %d map pin(s) with %s (players with OpenMap are asked whether to add them)."], #pins,
		target or SHARE_TO[to] or "?")
end

local function Escape(note) return (note:gsub("[%%,;]", function(c) return ("%%%02X"):format(c:byte()) end)) end
local function Unescape(note) return (note:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local function CodeOf(pins)
	local parts = {}
	for _, p in ipairs(pins) do
		parts[#parts + 1] = ("%d,%.4f,%.4f,%d,%s"):format(p.map, p.x, p.y, p.color or 1, Escape(p.note or ""))
	end
	return CODE .. table.concat(parts, ";")
end

-- a pin's fields from a message or a code, checked: a map on the stitched world, a point on it
local function Valid(m, x, y, color, note)
	m, x, y, color = tonumber(m), tonumber(x), tonumber(y), tonumber(color)
	if not (m and x and y) or x < 0 or x > 1 or y < 0 or y > 1 or not S.Rect(m) then return end
	return { map = m, x = Round(x), y = Round(y), color = COLORS[color or 1] and color or 1, note = Clean(note) }
end

-- pins not already here (the same place and note): added; how many
local function AddAll(pins, from)
	local n = 0
	for _, q in ipairs(pins) do
		local dup = false
		for _, p in ipairs(DB().list) do
			if Same(p, q.map, q.x, q.y) and p.note == q.note then dup = true break end
		end
		if not dup then Add(q.map, q.x, q.y, q.note, q.color, from) n = n + 1 end
	end
	mod.RefreshPins()
	return n
end

local function FromCode(text)
	local body = tostring(text or ""):match(CODE:gsub("%p", "%%%0") .. "(%S+)")
	if not body then return end
	local pins = {}
	for part in body:gmatch("[^;]+") do
		local m, x, y, color, note = strsplit(",", part, 5)
		local q = Valid(m, x, y, color, Unescape(note or ""))
		if q then pins[#pins + 1] = q end
		if #pins >= SHARE_MAX * 5 then break end
	end
	return pins
end

-- pins someone shares: gathered for a moment after their last, then you're asked about them all
local incoming = {}             -- sender -> { from, pins, at }
local asking = false
StaticPopupDialogs.OPENMAP_PINS_SHARED = {
	text = "%s",
	button1 = L["Add them"],
	button2 = L["Ignore"],
	OnAccept = function(_, batch)
		local n = AddAll(batch.pins, batch.from)
		ns:Print(L["Added %d map pin(s) from %s."], n, batch.from)
	end,
	OnHide = function() asking = false end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}

local function Ask(batch)
	local lines = {}
	for i = 1, math.min(3, #batch.pins) do
		local q = batch.pins[i]
		lines[i] = ("%s%s"):format(ZoneName(q.map), q.note ~= "" and (": " .. q.note) or "")
	end
	if #batch.pins > 3 then lines[#lines + 1] = L["... and %d more"]:format(#batch.pins - 3) end
	asking = true
	StaticPopup_Show("OPENMAP_PINS_SHARED", L["%s shared %d map pin(s) with you:"]:format(batch.from, #batch.pins)
		.. "\n|cffffffff" .. table.concat(lines, "\n") .. "|r", nil, batch)
end

local waiter = CreateFrame("Frame")
waiter:Hide()
waiter:SetScript("OnUpdate", function(self)
	if asking then return end
	local now = GetTime()
	for from, batch in pairs(incoming) do
		if now - batch.at > ASK_AFTER then
			incoming[from] = nil
			Ask(batch)
			return
		end
	end
	if not next(incoming) then self:Hide() end
end)

local function OnAddonMessage(_, _, prefix, text, _, from)
	if prefix ~= PREFIX or not mod.db.pinsShared then return end
	if Safe.IsSecret(text) or Safe.IsSecret(from) or type(text) ~= "string" or type(from) ~= "string" then return end
	local name = Ambiguate(from, "none")
	if name == UnitName("player") then return end   -- (your own, sent to your group or guild)
	local kind, m, x, y, color, note = strsplit("\t", text, 6)
	if kind ~= "P1" then return end
	local q = Valid(m, x, y, color, note or "")
	if not q then return end
	local batch = incoming[name] or { from = name, pins = {} }
	incoming[name] = batch
	if #batch.pins >= SHARE_MAX then return end
	batch.pins[#batch.pins + 1] = q
	batch.at = GetTime()
	waiter:Show()
end

-- a code to copy (Ctrl-C), or a box to paste one into (Import)
local function CodeBox(text)
	if not codeFrame then
		codeFrame = CreateFrame("Frame", "OpenMapPinsCode", UIParent)
		codeFrame:SetPoint("CENTER")
		codeFrame:SetFrameStrata("DIALOG")
		codeFrame:EnableMouse(true)
		local top, title = Look:Window(codeFrame, "")   -- (the map window's own frame, its title bar and X)
		codeFrame:SetSize(560, 150 + top)
		tinsert(UISpecialFrames, "OpenMapPinsCode")
		codeFrame.title = title
		local scroll = CreateFrame("ScrollFrame", nil, codeFrame, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 16, -10 - top)
		scroll:SetPoint("BOTTOMRIGHT", -32, 40)
		local box = CreateFrame("EditBox", nil, scroll)
		box:SetMultiLine(true)
		box:SetMaxLetters(0)
		box:SetAutoFocus(false)
		box:SetFontObject(ChatFontNormal)
		box:SetWidth(510)
		box:SetScript("OnEscapePressed", function() codeFrame:Hide() end)
		box:SetScript("OnTextChanged", function(self, user)
			if user and codeFrame.text then self:SetText(codeFrame.text) self:HighlightText() end   -- (a code to copy: as it is)
		end)
		scroll:SetScrollChild(box)
		codeFrame.box = box
		codeFrame.import = CreateFrame("Button", nil, codeFrame, "UIPanelButtonTemplate")
		codeFrame.import:SetSize(110, 22)
		codeFrame.import:SetPoint("BOTTOMRIGHT", -12, 10)
		codeFrame.import:SetText(L["Add the pins"])
		codeFrame.import:SetScript("OnClick", function()
			local pins = FromCode(codeFrame.box:GetText())
			if not pins or #pins == 0 then ns:Print(L["That isn't a code of map pins (it starts %s)."], CODE) return end
			ns:Print(L["Added %d map pin(s) from the code."], AddAll(pins))
			codeFrame:Hide()
		end)
	end
	codeFrame.text = text
	if text then
		codeFrame.title:SetText(L["Map pins: Ctrl-C to copy, then paste them anywhere (another player's OpenMap: Pins, Import)."])
		codeFrame.box:SetText(text)
	else
		codeFrame.title:SetText(L["Paste a code of map pins here (Ctrl-V), then Add the pins."])
		codeFrame.box:SetText("")
	end
	codeFrame.import:SetShown(not text)
	codeFrame:Show()
	codeFrame.box:SetFocus()
	if text then codeFrame.box:HighlightText() end
end

--------------------------------------------------------------------------------
-- A pin's card: its note, colour, follow, share, delete
--------------------------------------------------------------------------------

local function Button(parent, width, text, fn, tip)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", fn)
	if tip then
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
			GameTooltip:AddLine(tip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
	end
	return b
end

local function Close(save)
	local p = editor.pin
	editor.pin = nil
	-- (its drawing is done with it)
	if p and mod.SketchPin and mod.SketchPin() == p then mod:ToggleSketch(false) end
	editor:Hide()
	if p and save then
		p.note = Clean(editor.box:GetText())
		p.color = editor.color
		if Followed(p) then Follow(p) end          -- (TomTom's title follows the note)
	end
	mod.RefreshPins()
end
-- the drawing tray's Done, drawing on a pin: the pin's done too (Sketch.lua)
function mod.FinishPin() if editor and editor.pin then Close(true) else mod:ToggleSketch(false) end end

local function ShowColors()
	for i, b in ipairs(editor.colors) do
		local on = i == editor.color
		b.ring:SetShown(on)
		b.icon:SetAlpha(on and 1 or 0.75)
	end
end

-- the card's drawing line: drawing now or not, and how much is drawn on it
ShowDrawing = function()
	if not editor or not editor.pin then return end
	local now = mod.SketchPin and mod.SketchPin() == editor.pin
	local n = mod.SketchCount and mod.SketchCount(editor.pin.id) or 0
	editor.draw:SetText(now and L["Stop drawing"] or (n > 0 and L["Draw more"] or L["Draw on the map"]))
	editor.drawn:SetText(now and L["Drawing: the tray is below"] or (n > 0 and L["%d drawn"]:format(n) or L["Nothing drawn on it yet"]))
end
mod.OnSketchChanged = function() ShowDrawing() end

local function Editor()
	if editor then return editor end
	editor = CreateFrame("Frame", "OpenMapPinEditor", UIParent)
	editor:SetFrameStrata("DIALOG")
	editor:EnableMouse(true)
	-- the map window's own frame, its title bar and X (closing keeps the note, as Enter does)
	local top, title = Look:Window(editor, L["Map pin"], function() Close(true) end)
	editor:SetSize(480, 150 + top)
	editor.title = title
	editor.box = CreateFrame("EditBox", nil, editor, "InputBoxTemplate")
	editor.box:SetSize(436, 22)
	editor.box:SetPoint("TOPLEFT", 22, -12 - top)
	editor.box:SetAutoFocus(false)
	editor.box:SetMaxLetters(NOTE_MAX)
	editor.box:SetScript("OnEnterPressed", function() Close(true) end)
	editor.box:SetScript("OnEscapePressed", function() Close(false) end)
	-- the colours: the pin itself in each
	local colour = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	colour:SetPoint("TOPLEFT", 18, -52 - top)
	colour:SetText(L["Colour"])
	editor.colors = {}
	for i, c in ipairs(COLORS) do
		local b = CreateFrame("Button", nil, editor)
		b:SetSize(28, 28)
		b:SetPoint("TOPLEFT", 70 + (i - 1) * 32, -44 - top)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		S.Look(b.icon, { atlas = MARK.atlas, texture = MARK.texture, color = c[2] and { c[2], c[3], c[4] } or nil })
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		S.Look(hl, { atlas = MARK.atlas, texture = MARK.texture })
		hl:SetBlendMode("ADD")
		hl:SetAlpha(0.35)
		b.ring = b:CreateTexture(nil, "BACKGROUND")
		b.ring:SetPoint("TOPLEFT", -4, 4)
		b.ring:SetPoint("BOTTOMRIGHT", 4, -4)
		b.ring:SetTexture("Interface\\Buttons\\CheckButtonHilight")
		b.ring:SetBlendMode("ADD")
		b:SetScript("OnClick", function()
			editor.color = i
			ShowColors()
			if editor.pin then editor.pin.color = i mod.RefreshPins() end   -- (seen on the map at once)
		end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
			GameTooltip:AddLine(c[1], 1, 1, 1)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		editor.colors[i] = b
	end
	editor.follow = Button(editor, 120, L["Follow"], function()
		local p = editor.pin
		if not p then return end
		if Followed(p) then mod.ClearPin() else
			p.note = Clean(editor.box:GetText())
			Follow(p)
		end
		mod.RefreshPins()
	end, L["Blizzard's waypoint and its arrow on it (and TomTom's, if you use it)."])
	editor.follow:SetPoint("TOPRIGHT", -16, -46 - top)
	-- drawing on this pin (Sketch.lua): the tray opens under this card, and what's drawn goes with it
	local drawLabel = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	drawLabel:SetPoint("TOPLEFT", 18, -92 - top)
	drawLabel:SetText(L["Drawing"])
	editor.draw = Button(editor, 130, L["Draw on the map"], function()
		local p = editor.pin
		if not p or not mod.ToggleSketch then return end
		if mod.SketchPin and mod.SketchPin() == p then mod:ToggleSketch(false)
		else
			p.note = Clean(editor.box:GetText())
			p.color = editor.color
			editor.box:ClearFocus()
			mod:ToggleSketch(true, p, editor)
		end
		ShowDrawing()
	end, L["Draw on the map with the pen, attached to this pin: deleting the pin takes its drawing too."])
	editor.draw:SetPoint("TOPLEFT", 70, -86 - top)
	editor.drawn = editor:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	editor.drawn:SetPoint("LEFT", editor.draw, "RIGHT", 10, 0)
	-- share: your group, your guild, your target, a code
	local share = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	share:SetPoint("BOTTOMLEFT", 18, 18)
	share:SetText(L["Share:"])
	local x = 60
	for _, s in ipairs({
		{ "group", L["Group"], L["Your party or raid (those with OpenMap are asked whether to add it)."] },
		{ "guild", L["Guild"], L["Your guild (those with OpenMap are asked whether to add it)."] },
		{ "target", L["Target"], L["Whispered to your target (if they have OpenMap, they're asked whether to add it)."] },
	}) do
		local b = Button(editor, 62, s[2], function()
			local p = editor.pin
			if not p then return end
			p.note = Clean(editor.box:GetText())
			Share({ p }, s[1])
		end, s[3])
		b:SetPoint("BOTTOMLEFT", x, 12)
		b.to = s[1]
		editor["share_" .. s[1]] = b
		x = x + 64
	end
	local code = Button(editor, 62, L["Code"], function()
		local p = editor.pin
		if not p then return end
		p.note = Clean(editor.box:GetText())
		CodeBox(CodeOf({ p }))
	end, L["A code to copy and paste anywhere: another player adds it with their OpenMap (Pins, Import)."])
	code:SetPoint("BOTTOMLEFT", x, 12)
	-- done: the note and colour kept, the drawing finished
	local done = Button(editor, 80, L["Done"], function() Close(true) end, L["Keep the pin as it is (Enter, or the X, too)"])
	done:SetPoint("BOTTOMRIGHT", -16, 12)
	Button(editor, 70, L["Delete"], function()
		local p = editor.pin
		editor.pin = nil
		editor:Hide()
		if p then
			if Followed(p) then mod.ClearPin() end
			Remove(p)
			if mod.DropSketches then mod.DropSketches(p.id) end
		end
		mod.RefreshPins()
	end):SetPoint("TOPRIGHT", -16, -86 - top)
	editor:SetScript("OnHide", function() if editor.pin then Close(true) end end)
	editor:Hide()
	mod.padRoots[#mod.padRoots + 1] = editor     -- (the gamepad's cursor presses its buttons: Gamepad.lua)
	return editor
end

Edit = function(p)
	Editor()
	if editor.pin and editor.pin ~= p then Close(true) end   -- (one at a time: the open one is kept)
	editor.pin = p
	editor.color = p.color or 1
	editor.title:SetText(("%s · %s  %.1f, %.1f%s"):format(L["Map pin"], ZoneName(p.map), p.x * 100, p.y * 100,
		p.from and ("  |cff99ccff" .. L["Shared by %s"]:format(p.from) .. "|r") or ""))
	editor.box:SetText(p.note or "")
	editor.follow:SetText(Followed(p) and L["Stop following"] or L["Follow"])
	for _, to in ipairs({ "group", "guild", "target" }) do editor["share_" .. to]:SetEnabled(Channel(to) ~= nil) end
	ShowColors()
	ShowDrawing()
	editor:ClearAllPoints()
	editor:SetPoint("TOP", sc, "TOP", 0, -40)
	editor:Show()
	editor.box:SetFocus()
	editor.box:HighlightText()
end

-- a new pin where the map was clicked: followed, and its card open for a note
function mod.AddPin(mapID, x, y)
	local p = Add(mapID, x, y, "")
	Follow(p)
	mod.RefreshPins()
	Edit(p)
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

RefreshList = function()
	local pins = DB().list
	list.head:SetFormattedText(L["Map pins (%d)"], #pins)
	list.empty:SetShown(#pins == 0)
	list.offset = math.max(0, math.min(list.offset or 0, #pins - ROWS))
	for i, row in ipairs(list.rows) do
		local p = pins[(list.offset or 0) + i]
		row.pin = p
		if p then
			local c = COLORS[p.color] or COLORS[1]
			row.dot:SetColorTexture(c[2] or 1, c[3] or 0.82, c[4] or 0.25)
			local drawn = mod.SketchCount and mod.SketchCount(p.id) > 0
			row.text:SetText(("%s%s%s%s"):format(ZoneName(p.map), p.note ~= "" and (" · |cffffffff" .. p.note .. "|r") or "",
				drawn and (" |cffe6c27a(" .. L["drawing"] .. ")|r") or "", Followed(p) and (" |cff80f070(" .. L["followed"] .. ")|r") or ""))
		end
		row:SetShown(p ~= nil)
	end
end

local function BuildList()
	list = CreateFrame("Frame", "OpenMapPins", map)
	mod.padRoots[#mod.padRoots + 1] = list
	list:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -8, -66)
	list:SetFrameStrata("DIALOG")
	list:EnableMouse(true)
	list:EnableMouseWheel(true)
	local top, head = Look:Window(list, L["Map pins"])    -- (the map window's own frame, its title bar and X)
	list:SetSize(352, ROWS * 18 + 62 + top)
	list.head = head
	list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	list.empty:SetPoint("TOPLEFT", 16, -12 - top)
	list.empty:SetWidth(320)
	list.empty:SetJustifyH("LEFT")
	list.empty:SetText(L["No pins yet: Ctrl-click the map, or the menu's Drop a pin."])
	list.rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, list)
		row:SetSize(320, 18)
		row:SetPoint("TOPLEFT", 16, -10 - top - (i - 1) * 18)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.dot = row:CreateTexture(nil, "ARTWORK")
		row.dot:SetSize(8, 8)
		row.dot:SetPoint("LEFT", 2, 0)
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", 14, 0)
		row.text:SetPoint("RIGHT")
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row:SetScript("OnClick", function(self, button)
			local p = self.pin
			if not p then return end
			if button == "RightButton" then Edit(p) return end
			if S.Rect(p.map) then
				local u, v = mod.ToWorld(p.map, p.x, p.y)
				mod.Glide(u, v, math.max(select(3, mod.ViewNow()) or 1, mod.FitZoom(p.map) * 1.5))
			end
		end)
		row:SetScript("OnEnter", function(self)
			local p = self.pin
			if not p then return end
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:AddLine(p.note ~= "" and p.note or L["Map pin"], 1, 0.82, 0, true)
			GameTooltip:AddLine(("%s  %.1f, %.1f"):format(ZoneName(p.map), p.x * 100, p.y * 100), 1, 1, 1)
			if p.from then GameTooltip:AddLine(L["Shared by %s"]:format(p.from), 0.6, 0.8, 1) end
			GameTooltip:AddLine(L["Click to go there, right-click to open its card"], 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", GameTooltip_Hide)
		list.rows[i] = row
	end
	list:SetScript("OnMouseWheel", function(self, delta)
		self.offset = (self.offset or 0) - delta * 3
		RefreshList()
	end)
	-- every pin: a code, your group, your guild; a code to add
	local x = 16
	for _, b in ipairs({
		{ L["Import"], 64, function() CodeBox(nil) end, L["Paste a code of map pins someone gave you."] },
		{ L["Code"], 56, function() CodeBox(CodeOf(DB().list)) end, L["Every pin as a code to copy and paste anywhere."] },
		{ L["Group"], 60, function() Share(DB().list, "group") end, L["Every pin to your party or raid (those with OpenMap are asked whether to add them)."] },
		{ L["Guild"], 56, function() Share(DB().list, "guild") end, L["Every pin to your guild (those with OpenMap are asked whether to add them)."] },
	}) do
		local btn = Button(list, b[2], b[1], b[3], b[4])
		btn:SetPoint("BOTTOMLEFT", x, 12)
		x = x + b[2] + 4
	end
	list:Hide()
end

function mod:TogglePins(on)
	if not list then return end
	if on == nil then on = not list:IsShown() end
	if on then
		if not map:IsShown() then ToggleWorldMap() end
		RefreshList()
	end
	list:SetShown(on)
end
function mod.PinsShown() return list and list:IsShown() or false end

--------------------------------------------------------------------------------

function mod:BuildMapPins()
	set = S.PinSet("userpins", 0, 5)
	-- (the single pin of before: the waypoint, if one's set, becomes the first map pin)
	local db = DB()
	if not db.migrated then
		db.migrated = true
		local mapID, x, y
		if mod.WaypointPoint then mapID, x, y = mod.WaypointPoint() end
		if mapID and x and S.Rect(mapID) and not mod.PinAt(mapID, x, y) then Add(mapID, x, y, "") end
	end
	mod.RefreshPins()
end

function mod:SetupPins(worldMap)
	map, sc = worldMap, worldMap.ScrollContainer
	BuildList()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX) end
	ns.RegisterEvent(mod, "CHAT_MSG_ADDON", OnAddonMessage)
	map:HookScript("OnHide", function() if editor and editor:IsShown() then Close(true) end end)
end

function mod:PinOptions(opts, get, set_, off)
	opts.pinsShared = { type = "toggle", name = L["Pins others share with you"], order = 36, width = "full", get = get, set = set_, disabled = off,
		desc = L["Map pins your group, guild or a player shares with you: you're asked whether to add them. Off, they're ignored."] }
end
