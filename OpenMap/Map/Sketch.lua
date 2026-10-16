--------------------------------------------------------------------------------
-- The quill: draw on the map in ink, for yourself (OpenMapDB: worldmap -> sketch, every character's).
-- The menu's Quill (or /openmap draw) opens its tray: a quill, a straight line, an arrow, a ring and
-- the raid marks, six inks and three nibs, an eraser, Undo and Clear. Left-drag draws, right-drag
-- pans, the wheel zooms; Ctrl-Z undoes, Escape puts the quill down. From a map pin's card, Draw
-- attaches what you draw to that pin: it goes when the pin does.
-- A stroke: { id, tool, ink, size, pts = { u, v, u, v, ... } (Azeroth's map, normalized), mark (a raid
-- mark's number), pin (the map pin's id) }
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local mod = ns:GetModule("worldmap")
local Look, L = ns.Look, ns.L

mod.defaults.sketch = { strokes = {}, nextId = 1, tool = "quill", ink = 1, size = 2, mark = 8 }
mod.defaults.sketchShown = true

-- inks: clear colours that read on the parchment and on the minimap's darker ground
local INKS = {
	{ L["Black"], 0.1, 0.08, 0.06 },
	{ L["Red"], 0.92, 0.18, 0.14 },
	{ L["Blue"], 0.22, 0.5, 1 },
	{ L["Green"], 0.24, 0.82, 0.32 },
	{ L["Gold"], 1, 0.8, 0.16 },
	{ L["White"], 1, 1, 1 },
}
local NIBS = { 2, 3.5, 6 }      -- px on screen
-- the tools, each button showing what it draws (glyph: lines in a 32 x 20 box, from its top left)
local function Circle(cx, cy, r, n)
	local out = {}
	for k = 0, n do
		local a = k / n * 2 * math.pi
		out[#out + 1] = { cx + math.cos(a) * r, cy + math.sin(a) * r }
	end
	return out
end
local TOOLS = {
	{ key = "quill", name = L["Pen"], tip = L["Draw freely."],
		glyph = { { { 3, 15 }, { 8, 7 }, { 13, 13 }, { 19, 5 }, { 24, 12 }, { 29, 6 } } } },
	{ key = "line", name = L["Line"], tip = L["A straight line: drag from one end to the other."],
		glyph = { { { 4, 17 }, { 28, 3 } } } },
	{ key = "arrow", name = L["Arrow"], tip = L["An arrow: drag from its tail to where it points."],
		glyph = { { { 4, 17 }, { 28, 3 } }, { { 19, 3 }, { 28, 3 }, { 24, 11 } } } },
	{ key = "ring", name = L["Circle"], tip = L["A circle: drag from its middle out."],
		glyph = { Circle(16, 10, 8, 16) } },
	{ key = "mark", name = L["Mark"], tip = L["A raid mark: click to set it down. Right-click this button for another mark."] },
	{ key = "erase", name = L["Erase"], tip = L["Click a drawing to take it off."],
		glyph = { { { 6, 13 }, { 16, 3 }, { 27, 11 }, { 17, 21 }, { 6, 13 } }, { { 11, 8 }, { 22, 16 } } } },
}
local STEP = 3                  -- px the cursor moves before the quill adds a point
local NEAR = 8                  -- px: an eraser's click this close to a drawing takes it
local MAX_POINTS = 600          -- in one stroke
local MARK = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"

local map, sc, set, liveSet, catcher, tray   -- (liveSet: the stroke being drawn, redrawn alone as it grows)
local drawing = false
local forPin                    -- the map pin what's drawn is attached to (Pins.lua's Draw)
local stroke                    -- the stroke being drawn: { record, x, y (where it began, px) }
local panning
local Redraw, RefreshTray
-- a drawing for something else (Report.lua's): its own strokes, shown with yours but never kept;
-- the tools, inks and nibs yours (its ink starts red)
local session
local held                      -- a finished session's strokes, still shown till its owner's done with them (HoldSketch)

local function DB() return session and session.db or mod.db.sketch end
local function Round(x) return math.floor(x * 1e5 + 0.5) / 1e5 end

--------------------------------------------------------------------------------
-- Drawing the strokes: each line with a faint halo under it, so ink reads on dark land and light
--------------------------------------------------------------------------------

-- a stroke's points: the quill's as drawn; a line, an arrow (its head a share of its length) and a
-- ring (round on the screen: the world's sides aren't equal) worked out from its two
local function Points(st)
	local p = st.pts
	if st.tool == "quill" or #p < 4 then return p end
	local u0, v0, u1, v1 = p[1], p[2], p[#p - 1], p[#p]
	local W, H = S.Size()
	if st.tool == "ring" then
		local r = math.sqrt(((u1 - u0) * W) ^ 2 + ((v1 - v0) * H) ^ 2)
		local out = {}
		for k = 0, 40 do
			local a = k / 40 * 2 * math.pi
			out[#out + 1], out[#out + 2] = u0 + math.cos(a) * r / W, v0 + math.sin(a) * r / H
		end
		return out
	end
	if st.tool == "arrow" then
		local dx, dy = (u1 - u0) * W, (v1 - v0) * H
		local len = math.sqrt(dx * dx + dy * dy)
		if len == 0 then return { u0, v0, u1, v1 } end
		local head = math.min(len * 0.3, len * 0.12 + 0.002 * W)
		local ux, uy = dx / len, dy / len
		local function at(angle)
			local c, s = math.cos(angle), math.sin(angle)
			return u1 - (ux * c - uy * s) * head / W, v1 - (ux * s + uy * c) * head / H
		end
		local lu, lv = at(0.45)
		local ru, rv = at(-0.45)
		return { u0, v0, u1, v1, lu, lv, u1, v1, ru, rv }
	end
	return { u0, v0, u1, v1 }
end

local function Halo(ink)
	local dark = ink[2] + ink[3] + ink[4] < 1.5
	if dark then return 0.93, 0.86, 0.7, 0.45 end
	return 0.1, 0.07, 0.04, 0.5
end

local function Ink(st, into, pts)
	local ink = INKS[st.ink] or INKS[1]
	local nib = NIBS[st.size] or NIBS[2]
	local hr, hg, hb, ha = Halo(ink)
	S.AddPath(into, pts, nib + 2, hr, hg, hb, ha, 0)
	S.AddPath(into, pts, nib, ink[2], ink[3], ink[4], 1, 1)
end

local function Draw(st, into)
	if st.tool == "mark" then
		local pin = S.AddPin(into, st.pts[1], st.pts[2], { texture = MARK .. (st.mark or 8), size = 22 })
		pin:EnableMouse(false)
		return
	end
	Ink(st, into, Points(st))
end

Redraw = function()
	if not set then return end
	S.ClearPinSet(set)
	for _, st in ipairs(mod.db.sketch.strokes) do Draw(st, set) end
	for _, st in ipairs(session and session.db.strokes or held or {}) do Draw(st, set) end
	S.SetPinSetOn(set, mod.db.sketchShown or drawing or held ~= nil)
end

local function RedrawLive()
	if not liveSet then return end
	S.ClearPinSet(liveSet)
	if stroke then Draw(stroke.record, liveSet) end
end

-- a map pin went: what was drawn on it goes too (Pins.lua)
function mod.DropSketches(pinId)
	local list = DB().strokes
	for i = #list, 1, -1 do if list[i].pin == pinId then tremove(list, i) end end
	Redraw()
end

function mod.SketchCount(pinId)
	local n = 0
	for _, st in ipairs(DB().strokes) do if st.pin == pinId then n = n + 1 end end
	return n
end

--------------------------------------------------------------------------------
-- The quill in hand
--------------------------------------------------------------------------------

-- fewer points where a line runs straight (Douglas-Peucker, within `tol` world units)
local function Thin(p, tol)
	local n = #p / 2
	if n < 3 then return p end
	local keep = { [1] = true, [n] = true }
	local function Run(i, j)
		local ax, ay, bx, by = p[2 * i - 1], p[2 * i], p[2 * j - 1], p[2 * j]
		local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
		local best, at = -1, nil
		for k = i + 1, j - 1 do
			local x, y = p[2 * k - 1], p[2 * k]
			local dist = len > 0 and math.abs((by - ay) * x - (bx - ax) * y + bx * ay - by * ax) / len or math.sqrt((x - ax) ^ 2 + (y - ay) ^ 2)
			if dist > best then best, at = dist, k end
		end
		if at and best > tol then
			keep[at] = true
			Run(i, at)
			Run(at, j)
		end
	end
	Run(1, n)
	local out = {}
	for k = 1, n do if keep[k] then out[#out + 1], out[#out + 2] = p[2 * k - 1], p[2 * k] end end
	return out
end

local function Erase(u, v, pu, pv)
	local list = DB().strokes
	for i = #list, 1, -1 do
		local pts = (not forPin or list[i].pin == forPin.id) and Points(list[i]) or {}   -- (drawing on a pin: its own only)
		for k = 1, #pts - 1, 2 do
			-- (near a point, or near the line from it to the next)
			local x0, y0 = (pts[k] - u) / pu, (pts[k + 1] - v) / pv
			local x1, y1 = pts[k + 2] and (pts[k + 2] - u) / pu, pts[k + 3] and (pts[k + 3] - v) / pv
			local dist = math.sqrt(x0 * x0 + y0 * y0)
			if x1 then
				local dx, dy = x1 - x0, y1 - y0
				local t = (dx * dx + dy * dy) > 0 and math.max(0, math.min(1, -(x0 * dx + y0 * dy) / (dx * dx + dy * dy))) or 0
				local cx, cy = x0 + dx * t, y0 + dy * t
				dist = math.min(dist, math.sqrt(cx * cx + cy * cy))
			end
			if dist < NEAR + (NIBS[list[i].size] or 3) then
				tremove(list, i)
				Redraw()
				return
			end
		end
	end
end

local function Start()
	local u, v, pu, pv = mod.CursorWorld()
	if not u then return end
	local db = DB()
	if db.tool == "erase" then Erase(u, v, pu, pv) return end
	if #db.strokes >= 2000 then ns:Print(L["That's a lot of drawing: take some off (Undo, the eraser, Clear) before drawing more."]) return end
	local st = { tool = db.tool, ink = db.ink, size = db.size, pts = { Round(u), Round(v) }, pin = forPin and forPin.id or nil }
	if db.tool == "mark" then
		st.mark = db.mark
		st.id = db.nextId
		db.nextId = db.nextId + 1
		tinsert(db.strokes, st)
		Redraw()
		return
	end
	local x, y = GetCursorPosition()
	stroke = { record = st, x = x, y = y, lx = x, ly = y, pu = pu }
end

local function Move()
	if not stroke then return end
	local x, y = GetCursorPosition()
	if math.abs(x - stroke.lx) + math.abs(y - stroke.ly) < STEP then return end
	local u, v = mod.CursorWorld()
	if not u then return end
	stroke.lx, stroke.ly = x, y
	local p = stroke.record.pts
	if stroke.record.tool == "quill" then
		-- (the newest piece only: the stroke so far stays as drawn)
		if #p >= MAX_POINTS * 2 or not liveSet then return end
		p[#p + 1], p[#p + 2] = Round(u), Round(v)
		local n = #p
		Ink(stroke.record, liveSet, { p[n - 3], p[n - 2], p[n - 1], p[n] })
	else
		p[3], p[4] = Round(u), Round(v)        -- (the other end, where the cursor is)
		RedrawLive()
	end
end

local function Finish()
	if not stroke then return end
	local st = stroke.record
	local tol = stroke.pu * 0.75
	stroke = nil
	RedrawLive()
	if #st.pts < 4 then return end                -- (a click: nothing drawn)
	if st.tool == "quill" then st.pts = Thin(st.pts, tol) end
	local db = DB()
	st.id = db.nextId
	db.nextId = db.nextId + 1
	tinsert(db.strokes, st)
	Redraw()
	if forPin and mod.RefreshPins then mod.RefreshPins() end
end

local function Undo()
	local list = DB().strokes
	local last, at
	for i, st in ipairs(list) do
		if (not forPin or st.pin == forPin.id) and (not last or st.id > last.id) then last, at = st, i end
	end
	if at then tremove(list, at) Redraw() end
end

--------------------------------------------------------------------------------
-- The tray: tools, inks, nibs; a dark bar in the map window's colours, the inks as drops of ink
--------------------------------------------------------------------------------

local function Tip(owner, title, text)
	GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
	GameTooltip:AddLine(title, 1, 0.82, 0)
	if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
	GameTooltip:Show()
end

local function Slot(parent, size)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size, size)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.bg:SetColorTexture(0, 0, 0, 0.55)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 2, -2)
	b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
	b.edge = b:CreateTexture(nil, "OVERLAY")
	b.edge:SetTexture("Interface\\Buttons\\UI-Quickslot2")
	local o = size * 14 / 36
	b.edge:SetPoint("TOPLEFT", -o, o)
	b.edge:SetPoint("BOTTOMRIGHT", o, -o)
	b.glow = b:CreateTexture(nil, "OVERLAY", nil, 1)
	b.glow:SetAllPoints()
	b.glow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	b.glow:SetBlendMode("ADD")
	b.glow:Hide()
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
	hl:SetBlendMode("ADD")
	return b
end


RefreshTray = function()
	if not tray then return end
	local db = DB()
	local ink = INKS[db.ink] or INKS[1]
	for _, b in ipairs(tray.tools) do
		local on = b.key == db.tool
		b.glow:SetShown(on)
		b.label:SetTextColor(on and 1 or 0.8, on and 0.82 or 0.76, on and 0.3 or 0.65)
		for _, line in ipairs(b.lines or {}) do
			if on then line:SetVertexColor(1, 0.82, 0.3) else line:SetVertexColor(0.93, 0.86, 0.7) end
		end
	end
	tray.markButton.mark:SetTexture(MARK .. db.mark)
	for i, b in ipairs(tray.inks) do b.ring:SetShown(i == db.ink) end
	for i, b in ipairs(tray.nibs) do
		b.glow:SetShown(i == db.size)
		b.dot:SetVertexColor(ink[2], ink[3], ink[4])
	end
	local count = 0
	for _, st in ipairs(db.strokes) do if not forPin or st.pin == forPin.id then count = count + 1 end end
	if session then
		tray.title:SetText(session.title or "")
	elseif forPin then
		local note = forPin.note ~= "" and forPin.note or L["Map pin"]
		if #note > 28 then note = note:sub(1, 26):gsub("[\192-\255][\128-\191]*$", "") .. "..." end
		tray.title:SetText(L["Drawing on the pin: %s"]:format(note))
	else
		tray.title:SetText(L["Drawings: %d"]:format(count))
	end
end

local function TextButton(width, text, fn, tip)
	local b = CreateFrame("Button", nil, tray, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", fn)
	b:SetScript("OnEnter", function(self) Tip(self, text, tip) end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	return b
end

-- a tool's button: what it draws (in the ink in use) over its name
local function ToolButton(t)
	local b = CreateFrame("Button", nil, tray)
	b:SetSize(46, 42)
	b.key = t.key
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.5)
	local edge = CreateFrame("Frame", nil, b, "BackdropTemplate")
	edge:SetAllPoints()
	edge:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	edge:SetBackdropBorderColor(0.66, 0.49, 0.28, 0.9)      -- (the menu's bronze)
	b.glow = b:CreateTexture(nil, "ARTWORK", nil, 1)
	b.glow:SetPoint("TOPLEFT", 1, -1)
	b.glow:SetPoint("BOTTOMRIGHT", -1, 1)
	b.glow:SetColorTexture(1, 0.8, 0.3, 0.18)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetPoint("TOPLEFT", 1, -1)
	hl:SetPoint("BOTTOMRIGHT", -1, 1)
	hl:SetColorTexture(1, 0.85, 0.5, 0.1)
	b.lines = {}
	for _, path in ipairs(t.glyph or {}) do
		for k = 1, #path - 1 do
			local line = b:CreateLine(nil, "OVERLAY")
			line:SetThickness(2)
			line:SetColorTexture(1, 1, 1, 1)
			line:SetStartPoint("TOPLEFT", b, 7 + path[k][1], -5 - path[k][2])
			line:SetEndPoint("TOPLEFT", b, 7 + path[k + 1][1], -5 - path[k + 1][2])
			b.lines[#b.lines + 1] = line
		end
	end
	if t.key == "mark" then
		b.mark = b:CreateTexture(nil, "OVERLAY")
		b.mark:SetSize(20, 20)
		b.mark:SetPoint("TOP", 0, -5)
		tray.markButton = b
	end
	b.label = Look:Font(b:CreateFontString(nil, "OVERLAY"), 10)
	b.label:SetPoint("BOTTOM", 0, 4)
	b.label:SetText(t.name)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnClick", function(_, button)
		local db = DB()
		if t.key == "mark" and button == "RightButton" then db.mark = db.mark % 8 + 1 end
		db.tool = t.key
		RefreshTray()
	end)
	b:SetScript("OnEnter", function(self) Tip(self, t.name, t.tip) end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	return b
end

local function CreateTray()
	tray = CreateFrame("Frame", nil, map)
	mod.padRoots[#mod.padRoots + 1] = tray
	tray:SetPoint("TOP", sc, "TOP", 0, -8)
	tray:SetFrameLevel(math.min(sc:GetFrameLevel() + 9400, 9960))
	tray:EnableMouse(true)
	local top, head = Look:Window(tray, L["Draw on the map"], function() mod:ToggleSketch(false) end)
	tray.head = head
	local y = -top - 20
	-- tools
	tray.tools = {}
	local x = 12
	local captions = {}
	captions[#captions + 1] = { L["Tool"], x }
	for _, t in ipairs(TOOLS) do
		local b = ToolButton(t)
		b:SetPoint("TOPLEFT", x, y)
		tray.tools[#tray.tools + 1] = b
		x = x + 50
	end
	-- inks: a round drop each, ringed so the dark one shows
	x = x + 14
	captions[#captions + 1] = { L["Ink"], x }
	tray.inks = {}
	for i, ink in ipairs(INKS) do
		local b = CreateFrame("Button", nil, tray)
		b:SetSize(24, 24)
		b:SetPoint("TOPLEFT", x, y - 9)
		local mask = b:CreateMaskTexture()
		mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		mask:SetAllPoints()
		local rim = b:CreateTexture(nil, "BACKGROUND")
		rim:SetAllPoints()
		rim:SetColorTexture(0.93, 0.86, 0.7, 1)
		rim:AddMaskTexture(mask)
		local drop = b:CreateTexture(nil, "ARTWORK")
		drop:SetPoint("TOPLEFT", 2, -2)
		drop:SetPoint("BOTTOMRIGHT", -2, 2)
		drop:SetColorTexture(ink[2], ink[3], ink[4], 1)
		local inner = b:CreateMaskTexture()
		inner:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		inner:SetAllPoints(drop)
		drop:AddMaskTexture(inner)
		b.ring = b:CreateTexture(nil, "OVERLAY")
		b.ring:SetPoint("TOPLEFT", -6, 6)
		b.ring:SetPoint("BOTTOMRIGHT", 6, -6)
		b.ring:SetTexture("Interface\\Buttons\\CheckButtonHilight")
		b.ring:SetBlendMode("ADD")
		b:SetScript("OnClick", function()
			local db = DB()
			db.ink = i
			if db.tool == "erase" or db.tool == "mark" then db.tool = "quill" end
			RefreshTray()
		end)
		b:SetScript("OnEnter", function(self) Tip(self, ink[1]) end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		tray.inks[i] = b
		x = x + 30
	end
	-- nibs: a dot each, as wide as its line, in the ink in use
	x = x + 12
	captions[#captions + 1] = { L["Width"], x }
	tray.nibs = {}
	for i, nib in ipairs(NIBS) do
		local b = CreateFrame("Button", nil, tray)
		b:SetSize(26, 26)
		b:SetPoint("TOPLEFT", x, y - 8)
		local bg = b:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.85, 0.78, 0.62, 1)            -- (on a piece of parchment, so every ink shows)
		b.dot = b:CreateTexture(nil, "ARTWORK")
		b.dot:SetSize(nib * 1.6 + 2, nib * 1.6 + 2)
		b.dot:SetPoint("CENTER")
		b.dot:SetColorTexture(1, 1, 1, 1)
		b.glow = b:CreateTexture(nil, "OVERLAY")
		b.glow:SetPoint("TOPLEFT", -5, 5)
		b.glow:SetPoint("BOTTOMRIGHT", 5, -5)
		b.glow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
		b.glow:SetBlendMode("ADD")
		b:SetScript("OnClick", function() DB().size = i RefreshTray() end)
		b:SetScript("OnEnter", function(self) Tip(self, ({ L["Fine"], L["Medium"], L["Broad"] })[i]) end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		tray.nibs[i] = b
		x = x + 32
	end
	for _, c in ipairs(captions) do
		local f = tray:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		f:SetPoint("TOPLEFT", c[2], -top - 6)
		f:SetText(c[1])
	end
	-- undo, clear
	x = x + 14
	local undo = TextButton(64, L["Undo"], Undo, L["Take back the last drawing (Ctrl-Z)"])
	undo:SetPoint("TOPLEFT", x, y - 1)
	local clear = TextButton(64, L["Clear"], function(self)
		if self.armed then
			local list = DB().strokes
			for i = #list, 1, -1 do if not forPin or list[i].pin == forPin.id then tremove(list, i) end end
			Redraw()
			RefreshTray()
			self.armed = nil
			self:SetText(L["Clear"])
		else
			self.armed = true
			self:SetText(L["Sure?"])
			C_Timer.After(3, function() self.armed = nil self:SetText(L["Clear"]) end)
		end
	end, L["Take off every drawing (this pin's, when drawing on one): click twice"])
	clear:SetPoint("TOPLEFT", undo, "BOTTOMLEFT", 0, -2)
	x = x + 64 + 8
	-- done: the drawing kept (drawing on a pin: the pin's card done too, its note and colour kept)
	local done = TextButton(96, L["Done"], function()
		if session then session.finished = true mod:ToggleSketch(false)    -- (on to the report's next step)
		elseif forPin and mod.FinishPin then mod.FinishPin() else mod:ToggleSketch(false) end
	end, L["Finish drawing: it's kept (Escape too)"])
	tray.done = done
	done:SetScript("OnEnter", function(self)
		Tip(self, self:GetText(), session and session.doneTip or L["Finish drawing: it's kept (Escape too)"])
	end)
	done:SetPoint("TOPLEFT", x, y - 12)
	done:SetHeight(30)
	-- (a drawing for something else, the way on: a gold glow round it, breathing)
	done.glow = done:CreateTexture(nil, "BACKGROUND", nil, -1)
	done.glow:SetPoint("TOPLEFT", -5, 5)
	done.glow:SetPoint("BOTTOMRIGHT", 5, -5)
	done.glow:SetColorTexture(1, 0.8, 0.25, 0.55)
	done.pulse = done.glow:CreateAnimationGroup()
	local breathe = done.pulse:CreateAnimation("Alpha")
	breathe:SetFromAlpha(1)
	breathe:SetToAlpha(0.2)
	breathe:SetDuration(0.8)
	breathe:SetSmoothing("IN_OUT")
	done.pulse:SetLooping("BOUNCE")
	done.glow:Hide()
	x = x + 96 + 12
	-- what's drawn, and how
	tray.title = Look:Font(tray:CreateFontString(nil, "OVERLAY"), 11)
	tray.title:SetPoint("BOTTOMLEFT", 12, 9)
	tray.title:SetTextColor(0.96, 0.8, 0.5)
	local help = Look:Font(tray:CreateFontString(nil, "OVERLAY"), 11)
	help:SetPoint("BOTTOMRIGHT", -12, 9)
	help:SetText(L["|cffffd100Drag|r to draw   |cffffd100Right-drag|r to pan   |cffffd100Ctrl-Z|r undo   |cffffd100Esc|r done"])
	tray:SetSize(x, top + 20 + 42 + 30)
	tray:Hide()
end

local function CreateCatcher()
	catcher = CreateFrame("Frame", nil, sc)
	catcher:SetAllPoints(sc)
	catcher:SetFrameLevel(math.min(sc:GetFrameLevel() + 9200, 9940))
	catcher:EnableMouse(true)
	catcher:EnableMouseWheel(true)
	catcher:Hide()
	catcher:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" then
			Start()
		elseif button == "RightButton" then
			panning = true
			sc:OnMouseDown("LeftButton")   -- Blizzard's own drag-to-pan
		end
	end)
	catcher:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			Finish()
			RefreshTray()
		elseif panning then
			panning = false
			sc.mouseButtonInfo.LeftButton.down = false
		end
	end)
	catcher:SetScript("OnMouseWheel", function(_, delta) mod.WheelZoom(delta) end)
	catcher:SetScript("OnUpdate", Move)
	catcher:EnableKeyboard(true)
	catcher:SetPropagateKeyboardInput(true)
	catcher:SetScript("OnKeyDown", function(self, key)
		local undo = key == "Z" and IsControlKeyDown()
		if (undo or key == "ESCAPE") and not InCombatLockdown() then
			self:SetPropagateKeyboardInput(false)
			if undo then Undo() RefreshTray() else mod:ToggleSketch(false) end
			C_Timer.After(0, function() if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end end)
		end
	end)
end

--------------------------------------------------------------------------------

function mod:IsSketching() return drawing end
function mod.SketchPin() return drawing and forPin or nil end

-- the quill up (on) or down; `pin`: what's drawn is attached to that map pin, and `dock` (its card) has
-- the tray right under it, one card for the pin and its drawing. `sess`: a drawing for something else
-- (Report.lua): { head, title, done (its Done button's name), doneTip, onEnd = fn(strokes, finished) },
-- its strokes its own, never kept; onEnd gets them as the quill goes down (finished: by its Done)
function mod:ToggleSketch(on, pin, dock, sess)
	if on == nil then on = not drawing end
	if not map then return end
	if on and not map:IsShown() then
		ToggleWorldMap()                          -- (then once it's up and built)
		C_Timer.After(0, function() if map:IsShown() then mod:ToggleSketch(true, pin, dock, sess) end end)
		return
	end
	if on and (not set or not mod.IsStitched()) then
		ns:Print(L["The quill draws on the world, continent and zone maps."])
		return
	end
	if on and drawing then mod:ToggleSketch(false) end   -- (one drawing at a time: the one before put down)
	if on and mod.IsPainting and mod:IsPainting() then mod:TogglePaint(false) end
	drawing = on and true or false
	forPin = drawing and pin or nil
	if not drawing and stroke then Finish() end
	local ended = not drawing and session
	if drawing and sess then
		sess.db = setmetatable({ strokes = {}, nextId = 1, tool = "quill", ink = 2 },   -- (red; the rest yours)
			{ __index = mod.db.sketch, __newindex = mod.db.sketch })
		session = sess
	elseif not drawing then
		session = nil
	end
	tray.done:SetText(session and session.done or L["Done"])
	tray.done.glow:SetShown(session and true or false)
	if session then tray.done.pulse:Play() else tray.done.pulse:Stop() end
	tray:ClearAllPoints()
	if drawing and dock then
		tray:SetPoint("TOP", dock, "BOTTOM", 0, 2)
		tray:SetFrameStrata(dock:GetFrameStrata())
		tray.head:SetText(L["Drawing on this pin"])
	else
		tray:SetPoint("TOP", sc, "TOP", 0, -8)
		tray:SetFrameStrata(map:GetFrameStrata())
		tray:SetFrameLevel(math.min(sc:GetFrameLevel() + 9400, 9960))
		tray.head:SetText(session and session.head or L["Draw on the map"])
	end
	catcher:SetShown(drawing)
	tray:SetShown(drawing)
	if mod.OnSketchChanged then mod.OnSketchChanged() end
	Redraw()
	RefreshTray()
	if mod.RefreshPanel then mod:RefreshPanel() end
	if ended and ended.onEnd then ended.onEnd(ended.db.strokes, ended.finished) end
end

function mod:SketchOptions(opts, get, set_, off)
	opts.sketchShown = { type = "toggle", name = L["Your drawings"], order = 36.5, width = "full", get = get,
		set = function(info, v) set_(info, v) Redraw() end, disabled = off,
		desc = L["What you've drawn with the quill (the OpenMap menu's Quill), on the map."] }
end

function mod.RefreshSketch() Redraw() end

-- a report's drawing kept on the map after its quill goes down, while its note is written and its code
-- copied (Report.lua); nil: gone
function mod.HoldSketch(strokes)
	held = strokes
	Redraw()
end

function mod:BuildSketch()
	if not S.IsBuilt() then return end
	set = S.PinSet("sketch", 0, 4)
	liveSet = S.PinSet("sketchLive", 0, 4)
	Redraw()
end

function mod:SetupSketch(worldMap)
	map, sc = worldMap, worldMap.ScrollContainer
	CreateCatcher()
	CreateTray()
	map:HookScript("OnHide", function() if drawing then mod:ToggleSketch(false) end end)
end
