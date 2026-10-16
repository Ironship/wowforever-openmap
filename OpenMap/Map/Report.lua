--------------------------------------------------------------------------------
-- Report a problem (beta feedback), from the map's menu: draw where it's wrong if it's about a spot
-- (the quill, Sketch.lua, in red; on a dungeon's map, on its picture: Dungeons.lua's markup), or
-- nothing (the menu, settings, another addon), say what's wrong, and get a short report code to paste
-- into a GitHub issue (addons can't send anything themselves). The code carries the place, zoom, what
-- was drawn and the note, so tools/map-preview/report.py can render what the player saw.
--
-- Code: OM1|<version>|<mapID>|<u>|<v>|<zoom>|<marks>|<note>
-- marks, ";" between: a circle "u:v:r" round each drawing (the web map's markers), then each drawing:
--   d<tool><ink><nib>:<u>,<v>,...   on the world (tool q pen, l line, a arrow, r ring, m mark: then its
--                                   ink is the mark's number); u, v x 100000
--   g<instance>                     a dungeon's map (the instance's map ID), its drawings as
--   f<floor>:<x>,<y>,...            pen lines on that floor's picture, x, y (0..1 of it) x 10000
-- (Readers that know only circles skip the rest: they don't split into three numbers.)
--------------------------------------------------------------------------------

local _, ns = ...
local mod = ns:GetModule("worldmap")
local L = ns.L

local map
local drawn = {}                -- what was drawn for this report: the quill's strokes, or the dungeon's lines
local where                     -- on a dungeon's map: { inst, u, v (its entrance) }
local reporting = false
local codeFrame

-- the report over: its drawing off the map (and off a dungeon's)
local function EndReport()
	reporting = false
	if mod.HoldSketch then mod.HoldSketch(nil) end
	if mod.DungeonMarkupRelease then mod.DungeonMarkupRelease() end
end
local MAX_POINTS = 600          -- in all (the code stays a line you can paste)

-- a circle round some world points: u, v, r (r across, in u; it's r x 1.5 tall in v: the world's 3:2)
local function Round(pts)
	local u0, v0, u1, v1 = math.huge, math.huge, -math.huge, -math.huge
	for k = 1, #pts - 1, 2 do
		u0, u1 = math.min(u0, pts[k]), math.max(u1, pts[k])
		v0, v1 = math.min(v0, pts[k + 1]), math.max(v1, pts[k + 1])
	end
	return (u0 + u1) / 2, (v0 + v1) / 2, math.max(0.0005, math.max(u1 - u0, (v1 - v0) / 1.5) / 2 * 1.15)
end

local TOOL = { quill = "q", line = "l", arrow = "a", ring = "r", mark = "m" }

local function Marks()
	local circles, lines, left = {}, {}, MAX_POINTS
	local function Ints(pts, k)
		local out = {}
		for i = 1, #pts do out[i] = math.floor(pts[i] * k + 0.5) end
		return table.concat(out, ",")
	end
	if where then
		if where.u then circles[1] = ("%.5f:%.5f:%.5f"):format(where.u, where.v, 0.002) end   -- (its entrance)
		lines[1] = "g" .. where.inst
		for _, st in ipairs(drawn) do
			if #st.pts / 2 <= left then
				left = left - #st.pts / 2
				lines[#lines + 1] = ("f%d:%s"):format(st.floor, Ints(st.pts, 10000))
			end
		end
	else
		for _, st in ipairs(drawn) do
			if #st.pts / 2 <= left and TOOL[st.tool] then
				left = left - #st.pts / 2
				local pts = st.pts
				if st.tool == "ring" and #pts >= 4 then
					-- (round on the screen: as wide across in world units as the drag)
					local W, H = ns.MapStitch.Size()
					local r = math.sqrt(((pts[3] - pts[1]) * W) ^ 2 + ((pts[4] - pts[2]) * H) ^ 2) / W
					circles[#circles + 1] = ("%.5f:%.5f:%.5f"):format(pts[1], pts[2], math.max(0.0005, r * 1.1))
				else
					circles[#circles + 1] = ("%.5f:%.5f:%.5f"):format(Round(pts))
				end
				local ink = st.tool == "mark" and (st.mark or 8) or (st.ink or 2)
				lines[#lines + 1] = ("d%s%d%d:%s"):format(TOOL[st.tool], ink % 10, (st.size or 2) % 10, Ints(pts, 100000))
			end
		end
	end
	for i = #circles, 21, -1 do circles[i] = nil end   -- (the web map takes twenty)
	for _, l in ipairs(lines) do circles[#circles + 1] = l end
	return table.concat(circles, ";")
end

local function Code(note)
	local u, v, zoom = mod.ViewNow()
	if where and where.u then u, v = where.u, where.v end   -- (a dungeon's map: where its entrance is)
	note = (note or ""):gsub("[|\n\r]", " ")
	return ("OM1|%s|%d|%.5f|%.5f|%.2f|%s|%s"):format(ns.version, map:GetMapID() or 0, u or 0, v or 0, zoom or 0,
		Marks(), note)
end

StaticPopupDialogs.OPENMAP_REPORT_NOTE = {
	text = "|cffffd100Report, step 2 of 2:|r what's wrong?\n|cffaaaaaa(the map, the menu, a setting ... anything: a sentence is plenty)|r",
	hasEditBox = true,
	editBoxWidth = 340,
	button1 = CONTINUE or "Continue",
	button2 = CANCEL,
	OnAccept = function(self)
		local box = self.editBox or self.EditBox
		mod:ShowReportCode(Code(box:GetText()))
	end,
	EditBoxOnEnterPressed = function(box)
		local dialog = box:GetParent()
		mod:ShowReportCode(Code(box:GetText()))
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
	-- (put away without a code: the report's over, what was drawn with it)
	OnHide = function() if not (codeFrame and codeFrame:IsShown()) then EndReport() end end,
	timeout = 0, whileDead = true, hideOnEscape = true,
}

-- the code and where to paste it, both selectable for Ctrl-C
function mod:ShowReportCode(code)
	-- the last few, in case one needs copying again
	mod.char.reports = mod.char.reports or {}
	tinsert(mod.char.reports, code)
	while #mod.char.reports > 10 do tremove(mod.char.reports, 1) end
	if not codeFrame then
		codeFrame = CreateFrame("Frame", "OpenMapReport", UIParent)
		codeFrame:SetSize(520, 200)
		codeFrame:SetPoint("CENTER")
		codeFrame:SetFrameStrata("DIALOG")
		codeFrame:EnableMouse(true)
		ns.Look:Panel(codeFrame, { inset = 0, alpha = 0.95 })
		tinsert(UISpecialFrames, "OpenMapReport")
		local close = CreateFrame("Button", nil, codeFrame, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", 2, 2)
		local function Field(label, y)
			local fs = codeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			fs:SetPoint("TOPLEFT", 14, y)
			fs:SetText(label)
			local box = CreateFrame("EditBox", nil, codeFrame, "InputBoxTemplate")
			box:SetSize(480, 22)
			box:SetPoint("TOPLEFT", 20, y - 18)
			box:SetAutoFocus(false)
			box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
			box:SetScript("OnEscapePressed", function() codeFrame:Hide() end)
			box:SetScript("OnTextChanged", function(self, user) if user then self:SetText(self.value) self:HighlightText() end end)
			return box
		end
		codeFrame.url = Field("1. Open this page (Ctrl-C, then paste in your browser):", -16)
		codeFrame.code = Field("2. Paste this code into the report, with a screenshot if you can:", -76)
		local tip = codeFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		tip:SetPoint("TOPLEFT", 14, -140)
		tip:SetWidth(490)
		tip:SetJustifyH("LEFT")
		tip:SetText("Thanks! The code says where you were looking (and what you drew, if anything), so we can see what you saw.")
		codeFrame:SetScript("OnHide", function() EndReport() end)   -- (its drawing kept on show till then)
	end
	codeFrame.url.value = ns.ISSUES_URL
	codeFrame.url:SetText(ns.ISSUES_URL)
	codeFrame.code.value = code
	codeFrame.code:SetText(code)
	codeFrame:Show()
	codeFrame.code:SetFocus()
end

-- on to the note, with what was drawn (nothing: the report's about no one spot); the drawing stays on
-- show while the note's written and the code's copied
local function Next(list, place)
	drawn, where = list or {}, place
	if not place and mod.HoldSketch and #drawn > 0 then mod.HoldSketch(drawn) end
	StaticPopup_Show("OPENMAP_REPORT_NOTE")
end

function mod.IsReporting() return reporting end

-- start a report (on: true), or put one down (false); nil: start one, or put down the one going
function mod:ToggleReport(on)
	if on == nil then on = not reporting end
	if not on then
		if reporting then
			reporting = false
			if mod:IsSketching() then mod:ToggleSketch(false) end
			if mod.DungeonMarkup then mod.DungeonMarkup(false) end
			StaticPopup_Hide("OPENMAP_REPORT_NOTE")
		end
		EndReport()
		return
	end
	EndReport()                                 -- (one before it, its drawing still on show)
	if mod.IsPainting and mod:IsPainting() then mod:TogglePaint(false) end
	reporting = true
	drawn, where = {}, nil
	-- a dungeon's map: drawn on its picture
	if mod.DungeonViewShown and mod.DungeonViewShown() and mod.DungeonMarkup then
		mod.DungeonMarkup(true, function(list, place, finished)
			if finished then Next(list, place) else reporting = false end
		end)
		return
	end
	-- Blizzard's own maps (not stitched): nothing to draw on, but the problem can still be said
	if not mod.IsStitched() then Next() return end
	mod:ToggleSketch(true, nil, nil, {
		head = L["Report a problem"],
		title = L["|cffffd100Step 1 of 2:|r draw where it's wrong (if it's a spot), then Next"],
		done = L["Next"] .. "  >",
		doneTip = L["On to saying what's wrong (Escape: no report)"],
		onEnd = function(strokes, finished)
			if finished then Next(strokes) else reporting = false end
		end,
	})
end

function mod:SetupReport(worldMap)
	map = worldMap
	map:HookScript("OnHide", function() if reporting then mod:ToggleReport(false) end end)
end
