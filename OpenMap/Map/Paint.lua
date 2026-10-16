--------------------------------------------------------------------------------
-- Map notes, for working on the map: paint an area, say what's there (fix this, look into
-- this, an idea), and export them all as text, to paste into an issue or back to whoever is
-- working on the map; tools/map-preview/notes.py renders each one out of game. /openmap notes,
-- or the menu's Tools. Saved in OpenMapDB (worldmap -> paint). Players reporting a single
-- problem use the Report button instead (Report.lua).
--
--   left-drag   paint an area, then say what's there      click         a note at a point
--   shift-drag  add to the last note's area                click a note  edit it
--   right-drag  pan        wheel  zoom        Ctrl-Z  take back the last note
--
-- A note: { id, kind, text, zone (uiMapID under it), map (the map shown), u, v (its centre),
-- zoom, radius, strokes = { { u, v, u, v, ... }, ... } } (u, v: Azeroth's map, normalized;
-- radius in the same units, horizontally). No strokes: a note at a point.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local mod = ns:GetModule("worldmap")
local Look = ns.Look
local L = ns.L

mod.defaults.paint = { notes = {}, nextId = 1 }   -- (an older `strokes` list, layer mark-up, becomes notes)

local KINDS = {
	{ key = "fix", name = L["Fix this"], color = { 1, 0.32, 0.24 } },
	{ key = "look", name = L["Look into this"], color = { 1, 0.78, 0.2 } },
	{ key = "idea", name = L["Idea"], color = { 0.42, 0.72, 1 } },
}
local KIND = {}
for _, k in ipairs(KINDS) do KIND[k.key] = k end
local PIN = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up"
local AREA_ALPHA = 0.22         -- each dab (they overlap: the middle of a stroke is denser)
local NEAR_PIN = 14             -- px: a click this close to a note's pin edits it

local tool = { kind = 1, size = 40 }
local painting = false
local map, sc, catcher, bar, notesSet, editor, list, export
local stroke                    -- the stroke being drawn: { note, points, adding, x, y (where it began, px) }
local panning
local Redraw, UpdateBar, RefreshList

local function DB() return mod.db.paint end
local function KindOf(note) return KIND[note.kind] or KINDS[2] end
local function Round(x, k) k = k or 1e5 return math.floor(x * k + 0.5) / k end
local function Hex(c) return ("%02x%02x%02x"):format(c[1] * 255, c[2] * 255, c[3] * 255) end

local function ZoneAt(u, v)
	local chain = S.ChainAt(u, v)
	return chain[#chain]
end

local function ZoneName(id)
	local info = id and C_Map.GetMapInfo(id)
	return info and info.name or "?"
end

-- older saves: layer mark-up strokes and plain notes, folded into notes once
local function Migrate()
	local db = DB()
	db.notes = db.notes or {}
	db.nextId = db.nextId or 1
	for _, st in ipairs(db.strokes or {}) do
		if st.points and #st.points >= 2 then
			tinsert(db.notes, { kind = "fix", text = ("(older mark-up: %s, %s)"):format(st.mode or "?", st.layer or "?"),
				zone = st.zone, radius = st.radius, strokes = { st.points } })
		end
	end
	db.strokes = nil
	for _, n in ipairs(db.notes) do
		n.saved = nil
		n.kind = n.kind or "look"
		if not n.id then n.id = db.nextId db.nextId = db.nextId + 1 end
		if not n.u and n.strokes then
			local su, sv, c = 0, 0, 0
			for _, p in ipairs(n.strokes) do for i = 1, #p, 2 do su, sv, c = su + p[i], sv + p[i + 1], c + 1 end end
			if c > 0 then n.u, n.v = Round(su / c), Round(sv / c) end
		end
	end
end

--------------------------------------------------------------------------------
-- Drawing the notes: their areas as soft dabs in their kind's colour, a pin and the text at
-- each one's centre
--------------------------------------------------------------------------------

-- dabs from (u0, v0) to (u1, v1), a third of a brush width apart
local function Segment(u0, v0, u1, v1, radius, r, g, b)
	local W, H = S.Size()
	local d = math.sqrt(((u1 - u0) * W) ^ 2 + ((v1 - v0) * H) ^ 2)
	local n = math.max(1, math.floor(d / (radius * W * 0.33)))
	for k = 1, n do S.AddMark(u0 + (u1 - u0) * k / n, v0 + (v1 - v0) * k / n, radius, r, g, b, AREA_ALPHA) end
end

local function DrawArea(note)
	if not note.strokes then return end
	local r, g, b = unpack(KindOf(note).color)
	for _, p in ipairs(note.strokes) do
		if #p >= 2 then
			S.AddMark(p[1], p[2], note.radius, r, g, b, AREA_ALPHA)
			for i = 3, #p, 2 do Segment(p[i - 2], p[i - 1], p[i], p[i + 1], note.radius, r, g, b) end
		end
	end
end

local function Caption(note)
	local text = note.text ~= "" and note.text or L["(no text)"]
	if #text > 70 then text = text:sub(1, 68) .. "..." end
	return ("|cff%s#%d|r %s"):format(Hex(KindOf(note).color), note.id, text)
end

Redraw = function()
	if not S.IsBuilt() then return end
	S.ClearMarks()
	for _, note in ipairs(DB().notes) do DrawArea(note) end
	if notesSet then
		S.ClearPinSet(notesSet)
		for _, note in ipairs(DB().notes) do
			if note.u then
				local pin = S.AddPin(notesSet, note.u, note.v, { texture = PIN, size = 18, color = KindOf(note).color })
				pin.note = note
				if not pin.caption then         -- pins are pooled: the caption is made once
					pin.caption = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					pin.caption:SetPoint("LEFT", pin, "RIGHT", 2, 0)
					pin.caption:SetWidth(200)
					pin.caption:SetJustifyH("LEFT")
					Look:Font(pin.caption, 11, "OUTLINE")
				end
				pin.caption:SetText(Caption(note))
			end
		end
	end
	if UpdateBar then UpdateBar() end
	if RefreshList then RefreshList() end
end

--------------------------------------------------------------------------------
-- The note editor: its kind, its text; Enter saves, Escape cancels (a new note's paint goes too)
--------------------------------------------------------------------------------

local function Remove(note)
	local notes = DB().notes
	for i = #notes, 1, -1 do if notes[i] == note then tremove(notes, i) end end
end

local function CloseEditor(save)
	local note = editor.note
	editor.note = nil
	editor:Hide()
	if not note then return end
	if save then
		note.kind = editor.kind
		note.text = strtrim(((editor.box:GetText() or ""):gsub("[\r\n]", " ")))   -- (gsub's count isn't strtrim's)
		if editor.isNew then
			note.id = DB().nextId
			DB().nextId = note.id + 1
			tinsert(DB().notes, note)
		end
	end
	Redraw()
end

local function ShowKinds()
	for _, b in ipairs(editor.kinds) do
		if b.key == editor.kind then b:LockHighlight() else b:UnlockHighlight() end
	end
end

local function Editor()
	if editor then return editor end
	editor = CreateFrame("Frame", "OpenMapNoteEditor", UIParent)
	editor:SetSize(420, 118)
	editor:SetFrameStrata("DIALOG")
	editor:EnableMouse(true)
	Look:Panel(editor, { alpha = 0.95 })
	editor.title = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	editor.title:SetPoint("TOPLEFT", 12, -10)
	editor.kinds = {}
	for i, k in ipairs(KINDS) do
		local b = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
		b:SetSize(126, 22)
		b:SetPoint("TOPLEFT", 12 + (i - 1) * 132, -30)
		b:SetText(("|cff%s%s|r"):format(Hex(k.color), k.name))
		b.key = k.key
		b:SetScript("OnClick", function() editor.kind = k.key ShowKinds() editor.box:SetFocus() end)
		editor.kinds[i] = b
	end
	editor.box = CreateFrame("EditBox", nil, editor, "InputBoxTemplate")
	editor.box:SetSize(390, 22)
	editor.box:SetPoint("TOPLEFT", 18, -58)
	editor.box:SetAutoFocus(false)
	editor.box:SetMaxLetters(400)
	editor.box:SetScript("OnEnterPressed", function() CloseEditor(true) end)
	editor.box:SetScript("OnEscapePressed", function() CloseEditor(false) end)
	local function Btn(text, x, fn)
		local b = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
		b:SetSize(80, 22)
		b:SetPoint("BOTTOMRIGHT", x, 10)
		b:SetText(text)
		b:SetScript("OnClick", fn)
		return b
	end
	Btn(L["Save"], -12, function() CloseEditor(true) end)
	Btn(L["Cancel"], -96, function() CloseEditor(false) end)
	editor.delete = Btn(L["Delete"], -180, function()
		local note = editor.note
		editor.note = nil
		editor:Hide()
		if note then Remove(note) end
		Redraw()
	end)
	local hint = editor:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", 12, 15)
	hint:SetText(L["Enter saves, Escape cancels"])
	editor:Hide()
	return editor
end

local function EditNote(note, isNew)
	Editor()
	if editor.note and editor.note ~= note then CloseEditor(true) end   -- (one at a time: the open one is kept)
	editor.note, editor.isNew = note, isNew
	editor.kind = note.kind
	editor.title:SetText(isNew and (L["New note"] .. " · " .. ZoneName(note.zone))
		or (("%s #%d · %s"):format(L["Note"], note.id, ZoneName(note.zone))))
	editor.box:SetText(note.text or "")
	editor.delete:SetShown(not isNew)
	ShowKinds()
	editor:ClearAllPoints()
	editor:SetPoint("TOP", sc, "TOP", 0, -66)
	editor:Show()
	editor.box:SetFocus()
	editor.box:HighlightText()
end

--------------------------------------------------------------------------------
-- Brush input
--------------------------------------------------------------------------------

local function NoteNear(u, v, pu, pv)
	local best, bestD
	for _, note in ipairs(DB().notes) do
		if note.u then
			local d = math.sqrt(((note.u - u) / pu) ^ 2 + ((note.v - v) / pv) ^ 2)
			if d < NEAR_PIN and (not bestD or d < bestD) then best, bestD = note, d end
		end
	end
	return best
end

local function AddPoint(u, v)
	local p = stroke.points
	local n = #p
	u, v = Round(u), Round(v)
	p[n + 1], p[n + 2] = u, v
	local r, g, b = unpack(KindOf(stroke.note).color)
	if n == 0 then S.AddMark(u, v, stroke.note.radius, r, g, b, AREA_ALPHA)
	else Segment(p[n - 1], p[n], u, v, stroke.note.radius, r, g, b) end
end

local function StrokeUpdate()
	if not stroke then return end
	local u, v = mod.CursorWorld()
	if not u then return end
	local x, y = GetCursorPosition()
	if not stroke.moved and math.abs(x - stroke.x) + math.abs(y - stroke.y) > 4 then stroke.moved = true end
	local p = stroke.points
	local W, H = S.Size()
	-- a point every half brush width (the dabs between are drawn from the line)
	if math.sqrt(((u - p[#p - 1]) * W) ^ 2 + ((v - p[#p]) * H) ^ 2) >= stroke.note.radius * W * 0.5 then AddPoint(u, v) end
end

local function StartStroke()
	if editor and editor:IsShown() then CloseEditor(true) return end   -- (a click away from the editor keeps it)
	local u, v, pu, pv = mod.CursorWorld()
	if not u then return end
	local near = NoteNear(u, v, pu, pv)
	if near and not IsShiftKeyDown() then EditNote(near, false) return end
	local x, y = GetCursorPosition()
	local notes = DB().notes
	local last = notes[#notes]
	if IsShiftKeyDown() and last and last.strokes then
		-- more of the last note's area
		stroke = { note = last, points = {}, adding = true, x = x, y = y }
		tinsert(last.strokes, stroke.points)
	else
		local _, _, zoom = mod.ViewNow()
		local note = { kind = KINDS[tool.kind].key, text = "", zone = ZoneAt(u, v), map = mod.HostMap(),
			zoom = zoom and Round(zoom, 10), radius = Round((tool.size / 2) * pu, 1e6), strokes = {} }
		stroke = { note = note, points = {}, x = x, y = y }
		tinsert(note.strokes, stroke.points)
	end
	AddPoint(u, v)
end

local function EndStroke()
	if not stroke then return end
	local st = stroke
	stroke = nil
	if st.adding then Redraw() return end
	local note = st.note
	local p = st.points
	if not st.moved then
		note.u, note.v = p[1], p[2]
		note.strokes, note.radius = nil, nil      -- (a click: a note at a point)
	else
		local su, sv = 0, 0
		for i = 1, #p, 2 do su, sv = su + p[i], sv + p[i + 1] end
		note.u, note.v = Round(su / (#p / 2)), Round(sv / (#p / 2))
	end
	EditNote(note, true)
end

-- the last note made goes (Ctrl-Z, Undo)
local function Undo()
	local notes = DB().notes
	local last
	for _, n in ipairs(notes) do if not last or n.id > last.id then last = n end end
	if last then Remove(last) Redraw() end
end

--------------------------------------------------------------------------------
-- The notes list: every note, newest first; click flies there, right-click edits
--------------------------------------------------------------------------------

local ROWS = 18

RefreshList = function()
	if not list or not list:IsShown() then return end
	local notes = {}
	for _, n in ipairs(DB().notes) do notes[#notes + 1] = n end
	table.sort(notes, function(a, b) return a.id > b.id end)
	list.offset = math.max(0, math.min(list.offset or 0, #notes - ROWS))
	list.head:SetFormattedText(L["Notes (%d)"], #notes)
	for i, row in ipairs(list.rows) do
		local note = notes[i + list.offset]
		row.note = note
		if note then
			row.text:SetText(("%s |cff999999%s|r"):format(Caption(note), ZoneName(note.zone)))
			row:Show()
		else
			row:Hide()
		end
	end
	list.empty:SetShown(#notes == 0)
end

local function BuildList()
	list = CreateFrame("Frame", nil, map)
	mod.padRoots[#mod.padRoots + 1] = list      -- (the gamepad's cursor presses its buttons: Gamepad.lua)
	list:SetSize(320, ROWS * 18 + 40)
	list:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -8, -66)
	list:SetFrameLevel(math.min(sc:GetFrameLevel() + 9410, 9965))
	list:EnableMouse(true)
	list:EnableMouseWheel(true)
	Look:Panel(list, { alpha = 0.92 })
	list.head = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	list.head:SetPoint("TOPLEFT", 10, -8)
	list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	list.empty:SetPoint("TOPLEFT", 10, -30)
	list.empty:SetText(L["No notes yet: paint an area on the map."])
	list.rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, list)
		row:SetSize(300, 18)
		row:SetPoint("TOPLEFT", 10, -26 - (i - 1) * 18)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.text:SetAllPoints()
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row:SetScript("OnClick", function(self, button)
			local note = self.note
			if not note then return end
			if button == "RightButton" then EditNote(note, false)
			elseif note.u then mod.Glide(note.u, note.v, note.zoom or 8) end
		end)
		row:SetScript("OnEnter", function(self)
			if not self.note then return end
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:AddLine(("#%d %s · %s"):format(self.note.id, KindOf(self.note).name, ZoneName(self.note.zone)), 1, 0.82, 0)
			if self.note.text ~= "" then GameTooltip:AddLine(self.note.text, 1, 1, 1, true) end
			GameTooltip:AddLine(L["Click to go there, right-click to edit"], 0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", GameTooltip_Hide)
		list.rows[i] = row
	end
	list:SetScript("OnMouseWheel", function(self, delta)
		self.offset = (self.offset or 0) - delta * 3
		RefreshList()
	end)
	list:Hide()
end

--------------------------------------------------------------------------------
-- Export: every note as text, to copy (Ctrl-C) and paste wherever it's needed
--   OpenMap map notes | <version> | <date> | <n> notes
--   #<id> <kind> | <zone> (<uiMapID>) | at <u> <v> | zoom <z> | <text>
--      area r=<radius> <u> <v>, <u> <v>, ...; <the next stroke> ...
--------------------------------------------------------------------------------

local function ExportText()
	local notes = {}
	for _, n in ipairs(DB().notes) do notes[#notes + 1] = n end
	table.sort(notes, function(a, b) return a.id < b.id end)
	local lines = {
		("OpenMap map notes | %s | %s | %d notes"):format(ns.version, date("%Y-%m-%d %H:%M"), #notes),
		"(each: #id kind | zone (uiMapID) | at u v | zoom | text; a painted area follows as: area r=radius u v, u v, ...; next stroke)",
	}
	for _, n in ipairs(notes) do
		local text = (n.text or ""):gsub("|", "/")
		lines[#lines + 1] = ("#%d %s | %s (%d) | at %.5f %.5f | zoom %.1f | %s"):format(n.id, n.kind, ZoneName(n.zone), n.zone or 0,
			n.u or 0, n.v or 0, n.zoom or 0, text)
		if n.strokes then
			local parts = {}
			for _, p in ipairs(n.strokes) do
				local pts = {}
				for i = 1, #p - 1, 2 do pts[#pts + 1] = ("%.5f %.5f"):format(p[i], p[i + 1]) end
				parts[#parts + 1] = table.concat(pts, ", ")
			end
			lines[#lines + 1] = ("   area r=%.6f %s"):format(n.radius or 0, table.concat(parts, "; "))
		end
	end
	return table.concat(lines, "\n")
end

local function ShowExport()
	if not export then
		export = CreateFrame("Frame", "OpenMapNotesExport", UIParent)
		export:SetSize(620, 380)
		export:SetPoint("CENTER")
		export:SetFrameStrata("DIALOG")
		export:EnableMouse(true)
		Look:Panel(export, { alpha = 0.96 })
		tinsert(UISpecialFrames, "OpenMapNotesExport")
		local close = CreateFrame("Button", nil, export, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", 2, 2)
		local title = export:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOPLEFT", 12, -10)
		title:SetText(L["Map notes: Ctrl-C to copy them all, then paste them where they're needed"])
		local scroll = CreateFrame("ScrollFrame", nil, export, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 12, -32)
		scroll:SetPoint("BOTTOMRIGHT", -32, 34)
		local box = CreateFrame("EditBox", nil, scroll)
		box:SetMultiLine(true)
		box:SetMaxLetters(0)
		box:SetAutoFocus(false)
		box:SetFontObject(ChatFontNormal)
		box:SetWidth(570)
		box:SetScript("OnEscapePressed", function() export:Hide() end)
		box:SetScript("OnTextChanged", function(self, user) if user then self:SetText(export.text) self:HighlightText() end end)
		box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
		scroll:SetScrollChild(box)
		export.box = box
		local tip = export:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		tip:SetPoint("BOTTOMLEFT", 12, 12)
		tip:SetWidth(596)
		tip:SetJustifyH("LEFT")
		tip:SetText(L["They're also saved in WTF\\Account\\<account>\\SavedVariables\\OpenMap.lua once you /reload or log out."])
	end
	export.text = ExportText()
	export.box:SetText(export.text)
	export:Show()
	export.box:SetFocus()
	export.box:HighlightText()
end

--------------------------------------------------------------------------------
-- The toolbar
--------------------------------------------------------------------------------

UpdateBar = function()
	if not bar then return end
	for i, b in ipairs(bar.kinds) do
		if i == tool.kind then b:LockHighlight() else b:UnlockHighlight() end
	end
	bar.size:SetFormattedText(L["Brush %d"], tool.size)
	bar.count:SetFormattedText(L["%d notes"], #DB().notes)
end

local function Button(parent, width, text, onClick, tip)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function(self, button) onClick(self, button) UpdateBar() end)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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

local function CreateBar()
	bar = CreateFrame("Frame", nil, map)
	mod.padRoots[#mod.padRoots + 1] = bar      -- (the gamepad's cursor presses its buttons: Gamepad.lua)
	bar:SetPoint("TOP", sc, "TOP", 0, -6)
	bar:SetSize(736, 54)
	bar:SetFrameLevel(math.min(sc:GetFrameLevel() + 9400, 9960))
	bar:EnableMouse(true)
	Look:Panel(bar, { inset = 0, alpha = 0.92 })
	bar.kinds = {}
	local prev
	for i, k in ipairs(KINDS) do
		local b = Button(bar, 104, ("|cff%s%s|r"):format(Hex(k.color), k.name), function() tool.kind = i end,
			L["What the next note is: paint its area (or click) and say what's there."])
		if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 8, -6) end
		bar.kinds[i], prev = b, b
	end
	local smaller = Button(bar, 24, "-", function() tool.size = math.max(10, tool.size - 10) end, L["A smaller brush"])
	smaller:SetPoint("LEFT", prev, "RIGHT", 12, 0)
	bar.size = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.size:SetPoint("LEFT", smaller, "RIGHT", 4, 0)
	bar.size:SetWidth(58)
	local bigger = Button(bar, 24, "+", function() tool.size = math.min(300, tool.size + 10) end, L["A bigger brush"])
	bigger:SetPoint("LEFT", bar.size, "RIGHT", 4, 0)
	local listButton = Button(bar, 54, L["List"], function()
		list:SetShown(not list:IsShown())
		RefreshList()
	end, L["Every note: click one to go there."])
	listButton:SetPoint("LEFT", bigger, "RIGHT", 12, 0)
	local exportButton = Button(bar, 64, L["Export"], ShowExport, L["All the notes as text, to copy and paste where they're needed."])
	exportButton:SetPoint("LEFT", listButton, "RIGHT", 4, 0)
	local undo = Button(bar, 54, L["Undo"], Undo, L["Take back the last note (Ctrl-Z)"])
	undo:SetPoint("LEFT", exportButton, "RIGHT", 4, 0)
	local clear = Button(bar, 54, L["Clear"], function(self)
		if self.armed then
			wipe(DB().notes)
			Redraw()
			self.armed = nil
			self:SetText(L["Clear"])
		else
			self.armed = true
			self:SetText(L["Sure?"])
			C_Timer.After(3, function() self.armed = nil self:SetText(L["Clear"]) end)
		end
	end, L["Remove every note (click twice)"])
	clear:SetPoint("LEFT", undo, "RIGHT", 4, 0)
	local done = Button(bar, 54, L["Done"], function() mod:TogglePaint(false) end)
	done:SetPoint("LEFT", clear, "RIGHT", 4, 0)

	local help = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("BOTTOMLEFT", 10, 6)
	Look:Font(help, 11)
	help:SetText(L["|cffffd100Drag|r paint an area   |cffffd100Click|r a note at a point   |cffffd100Shift-drag|r add to the last   |cffffd100Click a note|r edit   |cffffd100Right-drag|r pan   |cffffd100Ctrl-Z|r undo"])
	bar.count = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bar.count:SetPoint("BOTTOMRIGHT", -10, 6)
	Look:Font(bar.count, 11)
	bar:Hide()
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
			StartStroke()
		elseif button == "RightButton" then
			panning = true
			sc:OnMouseDown("LeftButton")   -- Blizzard's own drag-to-pan
		end
	end)
	catcher:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			EndStroke()
		elseif panning then
			panning = false
			sc.mouseButtonInfo.LeftButton.down = false
		end
	end)
	catcher:SetScript("OnMouseWheel", function(_, delta) mod.WheelZoom(delta) end)
	catcher:SetScript("OnUpdate", StrokeUpdate)
	catcher:EnableKeyboard(true)
	catcher:SetPropagateKeyboardInput(true)
	catcher:SetScript("OnKeyDown", function(self, key)
		if key == "Z" and IsControlKeyDown() and not InCombatLockdown() then
			self:SetPropagateKeyboardInput(false)
			Undo()
			C_Timer.After(0, function() if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end end)
		end
	end)
end

--------------------------------------------------------------------------------

function mod:IsPainting() return painting end

function mod:TogglePaint(on)
	if on == nil then on = not painting end
	if not map or not S.IsBuilt() then
		ns:Print("Open the world map first.")
		return
	end
	if on and not mod.IsStitched() then
		ns:Print("Map notes work on the world, continent and zone maps.")
		return
	end
	if on and mod.ToggleReport then mod:ToggleReport(false) end
	if on and mod.IsSketching and mod:IsSketching() then mod:ToggleSketch(false) end   -- (one catcher on the map at a time)
	painting = on and true or false
	catcher:SetShown(painting)
	bar:SetShown(painting)
	S.SetMarksShown(painting)
	if notesSet then S.SetPinSetOn(notesSet, painting) end
	if painting then
		Redraw()
	else
		stroke = nil
		if editor and editor:IsShown() then CloseEditor(true) end
		if list then list:Hide() end
		S.ClearMarks()
	end
	if mod.RefreshPanel then mod:RefreshPanel() end
end

function mod:BuildPaint()
	if not S.IsBuilt() then return end
	notesSet = S.PinSet("notes", 1, 5)
	S.SetPinSetOn(notesSet, painting)
	if painting then Redraw() end
end

function mod:SetupPaint(worldMap)
	map, sc = worldMap, worldMap.ScrollContainer
	Migrate()
	CreateCatcher()
	CreateBar()
	BuildList()
	map:HookScript("OnHide", function() if painting then mod:TogglePaint(false) end end)
end
