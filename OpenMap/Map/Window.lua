--------------------------------------------------------------------------------
-- The map window: drag its title bar to move it, drag either bottom corner's grip to make it
-- any width and height (the stitched map has no edges to keep a shape for); both are
-- remembered, and a size slider scales the whole window. Only the windowed map: the maximized map is left to
-- Blizzard. Blizzard's panel layout tables are left alone (writing to them can
-- taint): the saved place is put back each time Blizzard lays the map out.
--------------------------------------------------------------------------------

local _, ns = ...
local mod = ns:GetModule("worldmap")
local L = ns.L

local d = mod.defaults
d.window = false                -- { point, relPoint, x, y } once moved
d.windowScale = 1
d.windowSize = false            -- { width, height } once resized
d.fullWidth = true              -- the maximized map fills the screen's width (the stitched map has no edges to keep)
local MIN_SCALE, MAX_SCALE = 0.5, 1.6
local MIN_W, MIN_H = 480, 320

d.border = true                 -- the map art's parchment frame round the map, zoomed right out

local map, handle, grip, border  -- (grip: both corners' grips)
local FillScreen, SetupBorder, SetupQuestLog, TurnArrows
local blizzardSize              -- the windowed map's own size, for a reset
local ours = false              -- OpenMap is moving / sizing the window itself (not to be undone)

local function Refit()
	local sc = map.ScrollContainer
	if sc and sc.OnCanvasSizeChanged then sc:OnCanvasSizeChanged() end
end

local function Maximized()
	return map.IsMaximized and map:IsMaximized()
end

local function Apply()
	if not map or Maximized() or ours then return end
	ours = true
	local w = mod.db.window
	if w then
		local point, rel, relPoint, x, y = map:GetPoint(1)
		if map:GetNumPoints() ~= 1 or point ~= w[1] or rel ~= UIParent or relPoint ~= w[2]
			or math.abs((x or 0) - w[3]) > 0.5 or math.abs((y or 0) - w[4]) > 0.5 then
			map:ClearAllPoints()
			map:SetPoint(w[1], UIParent, w[2], w[3], w[4])
		end
	end
	if math.abs((map:GetScale() or 1) - mod.db.windowScale) > 0.001 then map:SetScale(mod.db.windowScale) end
	local size = mod.db.windowSize
	if size and not InCombatLockdown() and (math.abs(map:GetWidth() - size[1]) > 0.5 or math.abs(map:GetHeight() - size[2]) > 0.5) then
		map:SetSize(size[1], size[2])
		Refit()
	end
	ours = false
end

-- maximized: Blizzard keeps the map art's shape (black bars at the sides on a wide
-- screen); the stitched map is the whole world, so it takes the screen's full width
FillScreen = function()
	if not map or not Maximized() or InCombatLockdown() then return end
	if math.abs((map:GetScale() or 1) - 1) > 0.001 then map:SetScale(1) end   -- (the windowed size is the window's)
	if not mod.db.fullWidth then return end
	local w = math.floor(UIParent:GetWidth())
	if math.abs(map:GetWidth() - w) < 1 then return end
	map:SetWidth(w)
	Refit()
end

local function Save()
	local point, _, relPoint, x, y = map:GetPoint(1)
	if point then mod.db.window = { point, relPoint, x, y } end
end

function mod:ResetWindow()
	mod.db.window = false
	mod.db.windowScale = 1
	mod.db.windowSize = false
	if map then
		ours = true
		map:SetScale(1)
		if blizzardSize and not Maximized() then map:SetSize(blizzardSize[1], blizzardSize[2]) Refit() end
		ours = false
		if map:IsShown() and not InCombatLockdown() then HideUIPanel(map) ShowUIPanel(map) end
	end
end

--------------------------------------------------------------------------------
-- The border: the map art's own parchment frame round the map's view, cut in nine
-- (tools/map-art/border.py): the corners as they are, and each edge laid as several copies of
-- its piece at about its own length, every other one mirrored (so the joins meet seamlessly),
-- an odd number of them (so both ends are the piece's own, cut to meet the corners): a frame
-- for a window of any shape without stretching the edges. It's fixed to the view's edge (it doesn't move with the map), and
-- seen only zoomed right out: it fades as you zoom in (BORDER_FADE). It takes no clicks.
--------------------------------------------------------------------------------

local BORDER = ns.Media.path .. "Textures\\MapBorder\\"
local CORNER, SIDE = 192 / 256, 640 / 1024   -- the pieces' content on their canvases (border.py)
local EDGE_LONG, SIDE_LONG = 1024 / 192, 640 / 192   -- an edge piece's length, in corner sizes
local BORDER_SCALE = 0.55       -- the corners' size: their own 192 px x this, per 1024 px of view height
local BORDER_FADE = { 1.15, 1.6 }   -- zoom where it starts / finishes fading out

local function Piece(name, sub)
	local tex = border:CreateTexture(nil, "OVERLAY", nil, sub or 0)
	tex:SetTexture(BORDER .. name, nil, nil, "LINEAR")
	return tex
end

-- an edge: `length` laid with copies of its piece (`natural` long each, as near as an odd count allows)
local function LayEdge(name, length, c, natural)
	local list = border.edges[name]
	local n = math.max(1, math.floor(length / natural / 2 + 0.5) * 2 + 1)
	if length / n < natural * 0.6 then n = math.max(1, n - 2) end
	local seg = length / n
	for i = 1, math.max(n, #list) do
		local tex = list[i]
		if i <= n then
			if not tex then
				tex = Piece(name, -1)             -- (under the corners)
				list[i] = tex
			end
			local flip = i % 2 == 0
			tex:ClearAllPoints()
			local at = c + (i - 1) * seg
			if name == "top" or name == "bottom" then
				tex:SetSize(seg, c)
				tex:SetPoint(name == "top" and "TOPLEFT" or "BOTTOMLEFT", border, name == "top" and "TOPLEFT" or "BOTTOMLEFT", at, 0)
				if flip then tex:SetTexCoord(1, 0, 0, CORNER) else tex:SetTexCoord(0, 1, 0, CORNER) end
			else
				tex:SetSize(c, seg)
				tex:SetPoint(name == "left" and "TOPLEFT" or "TOPRIGHT", border, name == "left" and "TOPLEFT" or "TOPRIGHT", 0, -at)
				if flip then tex:SetTexCoord(0, CORNER, SIDE, 0) else tex:SetTexCoord(0, CORNER, 0, SIDE) end
			end
			tex:Show()
		elseif tex then
			tex:Hide()
		end
	end
end

local function SizeBorder()
	local sc = map.ScrollContainer
	local w, h = sc:GetWidth(), sc:GetHeight()
	if not (w and h and w > 0 and h > 0) then return end
	local c = 192 * BORDER_SCALE * h / 1024
	for _, tex in ipairs(border.corners) do tex:SetSize(c, c) end
	LayEdge("top", w - 2 * c, c, c * EDGE_LONG)
	LayEdge("bottom", w - 2 * c, c, c * EDGE_LONG)
	LayEdge("left", h - 2 * c, c, c * SIDE_LONG)
	LayEdge("right", h - 2 * c, c, c * SIDE_LONG)
end

SetupBorder = function()
	local sc = map.ScrollContainer
	border = CreateFrame("Frame", nil, map)
	border:SetAllPoints(sc)
	border:SetFrameLevel(math.min(sc:GetFrameLevel() + 9000, 9900))   -- (over the map's icons, under OpenMap's menu)
	local tl, tr, bl, br = Piece("tl"), Piece("tr"), Piece("bl"), Piece("br")
	tl:SetPoint("TOPLEFT")
	tr:SetPoint("TOPRIGHT")
	bl:SetPoint("BOTTOMLEFT")
	br:SetPoint("BOTTOMRIGHT")
	for _, tex in ipairs({ tl, tr, bl, br }) do tex:SetTexCoord(0, CORNER, 0, CORNER) end
	border.corners = { tl, tr, bl, br }
	border.edges = { top = {}, bottom = {}, left = {}, right = {} }
	sc:HookScript("OnSizeChanged", SizeBorder)
	SizeBorder()
	-- only round the stitched map (Blizzard's own maps have their frame in their art), and
	-- only zoomed right out
	local alpha = -1
	local watch = CreateFrame("Frame", nil, map)
	watch:SetScript("OnUpdate", function()
		local a = 0
		if mod.db.border and mod.IsStitched() and not (mod.DungeonViewShown and mod.DungeonViewShown()) then
			local _, _, zoom = mod.ViewNow()
			local t = math.max(0, math.min(1, ((zoom or 1) - BORDER_FADE[1]) / (BORDER_FADE[2] - BORDER_FADE[1])))
			a = math.floor((1 - t * t * (3 - 2 * t)) * 50 + 0.5) / 50
		end
		if a ~= alpha then
			alpha = a
			border:SetAlpha(a)
			border:SetShown(a > 0)
		end
	end)
end

-- a resize grip in one of the window's bottom corners: any width and height, the top edge and
-- the far side staying put. In the window's outer corner (clear of Blizzard's quest log button
-- just inside the right one), over everything there; its catch reaches well past the window's
-- edge, and only a little in over the map
local GRIP, GRIP_OUT, GRIP_IN = 20, 10, 4
-- the right one, while the quest log is beside the map: bigger, and over the quest log (Blizzard's HIGH
-- strata, over the map's own), whose scroll bar's bottom arrow was in that corner and took the clicks
-- (the arrows are lifted clear: SetupQuestLog). Without it the map's own corner is there, with
-- Blizzard's quest log button: the grip as it was, under that
local GRIP_RIGHT, GRIP_RIGHT_IN = 30, 10
local function FitRightGrip()
	local g = grip and grip[1]
	if not g then return end
	local log = map.QuestLog and map.QuestLog:IsShown()
	local size, inside = log and GRIP_RIGHT or GRIP, log and GRIP_RIGHT_IN or GRIP_IN
	g:SetSize(size, size)
	g:SetHitRectInsets(-inside, -GRIP_OUT, -inside, -GRIP_OUT)
	g:SetFrameStrata(log and "HIGH" or map:GetFrameStrata())
	g:SetFrameLevel(log and 9990 or border:GetFrameLevel() + 1)
end

local function Grip(corner)
	local left = corner == "BOTTOMLEFT"
	local g = CreateFrame("Button", nil, map)
	g:SetSize(GRIP, GRIP)
	g:SetPoint(corner, map, corner, left and -1 or 1, -1)
	g:SetFrameLevel(math.min(map.ScrollContainer:GetFrameLevel() + 9500, 9990))
	if left then g:SetHitRectInsets(-GRIP_OUT, -GRIP_IN, -GRIP_IN, -GRIP_OUT)
	else g:SetHitRectInsets(-GRIP_IN, -GRIP_OUT, -GRIP_IN, -GRIP_OUT) end
	g:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	g:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	g:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	if left then   -- (the chat frame's grabber points right: mirrored)
		for _, tex in ipairs({ g:GetNormalTexture(), g:GetHighlightTexture(), g:GetPushedTexture() }) do tex:SetTexCoord(1, 0, 0, 1) end
	end
	local start
	g:SetScript("OnMouseDown", function()
		if Maximized() then return end
		local x, y = GetCursorPosition()
		start = { x = x, y = y, w = map:GetWidth(), h = map:GetHeight(), left = map:GetLeft(), right = map:GetRight(), top = map:GetTop() }
	end)
	local function Finish()
		if not start then return end
		local was = start
		start = nil
		-- (a click, no drag: nothing; a refit at the same size puts the whole map up again)
		if math.abs(map:GetWidth() - was.w) < 0.5 and math.abs(map:GetHeight() - was.h) < 0.5 then return end
		mod.db.windowSize = { math.floor(map:GetWidth() + 0.5), math.floor(map:GetHeight() + 0.5) }
		Save()
		if map:IsShown() then Refit() end
	end
	g:SetScript("OnMouseUp", Finish)
	-- (the map closed mid-drag: the mouse-up never comes here, so the drag ends with the map, or
	-- the moment the button turns out not to be held)
	g:SetScript("OnHide", Finish)
	g:SetScript("OnUpdate", function()
		if not start then return end
		if not IsMouseButtonDown("LeftButton") then Finish() return end
		local x, y = GetCursorPosition()
		local s = map:GetEffectiveScale()
		local dx = (x - start.x) / s
		local w = math.max(MIN_W, start.w + (left and -dx or dx))
		local h = math.max(MIN_H, start.h - (y - start.y) / s)
		ours = true
		map:ClearAllPoints()
		-- (offsets in the map's own units, as GetLeft gives)
		map:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left and start.right - w or start.left, start.top)
		map:SetSize(w, h)
		ours = false
	end)
	g:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, left and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
		GameTooltip:AddLine(L["Drag to resize the map"], 1, 1, 1)
		GameTooltip:Show()
	end)
	g:SetScript("OnLeave", GameTooltip_Hide)
	return g
end

function mod:SetupWindow(worldMap)
	map = worldMap
	map:SetClampedToScreen(true)
	if not Maximized() then blizzardSize = { map:GetWidth(), map:GetHeight() } end

	-- the title bar: a strip along the top, clear of the corner buttons
	handle = CreateFrame("Frame", nil, map)
	handle:SetPoint("TOPLEFT", map, "TOPLEFT", 70, 0)
	handle:SetPoint("TOPRIGHT", map, "TOPRIGHT", -70, 0)
	handle:SetHeight(22)
	handle:SetFrameLevel(map:GetFrameLevel() + 5)
	handle:EnableMouse(true)
	handle:RegisterForDrag("LeftButton")
	handle:SetScript("OnDragStart", function()
		if Maximized() then return end
		map:SetMovable(true)
		map:StartMoving()
	end)
	handle:SetScript("OnDragStop", function()
		map:StopMovingOrSizing()
		map:SetUserPlaced(false)            -- (ours to remember, not the layout cache's)
		Save()
	end)
	handle:SetScript("OnEnter", function(self)
		if Maximized() then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Drag to move the map"], 1, 1, 1)
		GameTooltip:Show()
	end)
	handle:SetScript("OnLeave", GameTooltip_Hide)

	grip = { Grip("BOTTOMRIGHT"), Grip("BOTTOMLEFT") }

	-- put the saved place back whenever Blizzard lays the map out: opening shows the map first and
	-- places it after (inside ShowUIPanel), so it's put back once that's done, not a moment later
	map:HookScript("OnShow", Apply)
	if ShowUIPanel then hooksecurefunc("ShowUIPanel", function(frame) if frame == map then Apply() end end) end
	if UpdateUIPanelPositions then hooksecurefunc("UpdateUIPanelPositions", function() if map:IsShown() then Apply() end end) end
	-- ... and the moment anything else sizes, scales or places the windowed map (Blizzard's
	-- layout, its quest log widening it, its minimize ...), so it never shows elsewhere first.
	-- (Not while it's being dragged: the drag places it, and the drop saves where it went.)
	local dragging = false
	local function Hold()
		if ours or dragging or not map:IsShown() then return end
		Apply()
	end
	for _, method in ipairs({ "SetSize", "SetWidth", "SetHeight", "SetScale", "SetPoint" }) do
		if map[method] then hooksecurefunc(map, method, Hold) end
	end
	handle:HookScript("OnDragStart", function() dragging = true end)
	handle:HookScript("OnDragStop", function() dragging = false end)
	-- (the map closed mid-move: no drag stop comes, so the move ends with the map)
	handle:HookScript("OnHide", function()
		if not dragging then return end
		dragging = false
		map:StopMovingOrSizing()
		map:SetUserPlaced(false)
		Save()
	end)
	local function Mode()
		local max = Maximized()
		handle:SetShown(not max)
		for _, g in ipairs(grip) do g:SetShown(not max) end
		if max then FillScreen() else Apply() end
	end
	if map.Maximize then hooksecurefunc(map, "Maximize", Mode) end
	if map.Minimize then hooksecurefunc(map, "Minimize", Mode) end
	-- Blizzard re-sizes the maximized map when the screen or UI scale changes
	if map.UpdateMaximizedSize then hooksecurefunc(map, "UpdateMaximizedSize", function() if Maximized() then FillScreen() end end) end
	map:HookScript("OnShow", Mode)
	SetupBorder()
	for _, g in ipairs(grip) do g:SetFrameLevel(border:GetFrameLevel() + 1) end
	FitRightGrip()
	SetupQuestLog()
	-- Blizzard's buttons on the map over the parchment border (it's over the map's icons): zoomed right
	-- out, it hid the quest log's button; and that button's arrows turned (Blizzard's point the other
	-- way): the log comes in from the right, so in is ◀ and away is ▶
	local function Buttons()
		local over = border:GetFrameLevel() + 2
		for _, f in ipairs(map.overlayFrames or {}) do
			if f.GetFrameLevel and f:GetFrameLevel() < over then f:SetFrameLevel(over) end
		end
		TurnArrows(map.SidePanelToggle)
		TurnArrows(mod.maxLogToggle)
	end
	Buttons()
	if map.RefreshOverlayFrames then hooksecurefunc(map, "RefreshOverlayFrames", Buttons) end
	map:HookScript("OnShow", Buttons)
end

--------------------------------------------------------------------------------
-- The quest log: its list's background is an atlas at its own size, anchored at the top only,
-- so a window taller than Blizzard's ends it in a line: it's stretched to the list's foot.
-- Blizzard's full-screen map always hides the quest log (and its side-panel toggle leaves full
-- screen first); while it's full screen, OpenMap shows it over the map's right edge when asked
-- (maxQuestLog), as Blizzard anchors it, and takes it away again just before the map leaves full
-- screen, so Blizzard's own layout for the window comes back as it was. Never in combat.
--------------------------------------------------------------------------------

d.maxQuestLog = false           -- the quest log on the full-screen map

local function Log() return map.QuestLog end

-- a quest log button's arrows the other way round: its open button ◀ (Blizzard's "hide" art), its
-- close button ▶ ("show"); once each (kept here, not on Blizzard's frame)
local turned = setmetatable({}, { __mode = "k" })
TurnArrows = function(toggle)
	if not toggle or turned[toggle] or not toggle.OpenButton or not toggle.CloseButton then return end
	turned[toggle] = true
	local function Art(b, name)
		if b.SetNormalAtlas then
			b:SetNormalAtlas(name .. "-Up")
			b:SetPushedAtlas(name .. "-Down")
		end
	end
	Art(toggle.OpenButton, "QuestCollapse-Hide")
	Art(toggle.CloseButton, "QuestCollapse-Show")
end

local function ShowMaxLog(on)
	local log = Log()
	if not log or not Maximized() or InCombatLockdown() or on == log:IsShown() then return end
	log:SetShown(on)
	if map.UpdateSpacerFrameAnchoring then map:UpdateSpacerFrameAnchoring() end   -- (the canvas makes room for it)
end

-- the menu's Quest log button while the map is full screen
function mod.MaxQuestLog() return Maximized() and true or false end
function mod.ToggleMaxQuestLog()
	if InCombatLockdown() then
		ns:Print(L["The quest log can't be opened or closed in combat."])
		return
	end
	mod.db.maxQuestLog = not (Log() and Log():IsShown())
	ShowMaxLog(mod.db.maxQuestLog)
	if mod.maxLogToggle then mod.maxLogToggle:Refresh() end
end

-- A quest's details: Blizzard's are a fixed 502 high, anchored at the top, sized for its own
-- window (534 high), so a taller window leaves a gap under them. They reach the quest log's foot
-- instead (as far below the list as Blizzard's do in its window: 502 there), the text with them;
-- the parchment behind the text runs down to the rewards (Blizzard's 440 in its 502), cut from
-- its art as Blizzard cuts it, or stretched once it's taller than the art
local DETAILS_BELOW, TEXT_FOOT, PAPER_FOOT = 6, 29, 62
local function FitDetailsPaper(details)
	local bg = details.Bg
	local atlas = bg and bg.GetAtlas and bg:GetAtlas()
	local info = atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
	local w, h = details:GetWidth(), details:GetHeight()
	if not info or not info.width or info.width <= 0 or not w or not h or h <= PAPER_FOOT then return end
	local natural = info.height * w / info.width
	local want = h - PAPER_FOOT
	bg:SetWidth(w)
	bg:SetTexCoord(0, 1, 0, math.min(1, want / natural))
	bg:SetHeight(want)
end

local function StretchDetails()
	local quests = Log() and Log().QuestsFrame
	local details = quests and quests.DetailsFrame
	if not details or not details.ScrollFrame or details.omStretched then return end
	details.omStretched = true
	details:SetPoint("BOTTOMRIGHT", quests, "BOTTOMRIGHT", 0, -DETAILS_BELOW)
	details.ScrollFrame:SetPoint("BOTTOMLEFT", details, "BOTTOMLEFT", 5, TEXT_FOOT)
	-- (after Blizzard sizes it for its own height, each time the details show)
	details:HookScript("OnShow", FitDetailsPaper)
	details:HookScript("OnSizeChanged", FitDetailsPaper)
end

-- the quest log's scroll bars end this much higher, clear of the window's resize grip in the corner
local BAR_LIFT = 26
local function LiftBar(bar)
	if not bar or bar.omLifted or not bar.GetNumPoints then return end
	bar.omLifted = true
	local points = {}
	for i = 1, bar:GetNumPoints() do points[i] = { bar:GetPoint(i) } end
	bar:ClearAllPoints()
	for _, pt in ipairs(points) do
		local point, rel, relPoint, x, y = pt[1], pt[2], pt[3], pt[4], pt[5]
		if point:find("^BOTTOM") then y = (y or 0) + BAR_LIFT end
		bar:SetPoint(point, rel, relPoint, x, y)
	end
end

SetupQuestLog = function()
	local scroll = _G.QuestScrollFrame
	LiftBar(scroll and scroll.ScrollBar)
	LiftBar(_G.QuestMapDetailsScrollFrame and _G.QuestMapDetailsScrollFrame.ScrollBar)
	local bg = scroll and scroll.Background
	if bg and bg.SetPoint then bg:SetPoint("BOTTOMLEFT", scroll, "BOTTOMLEFT", 0, 0) end
	if not Log() then return end
	StretchDetails()
	-- Blizzard's collapse / expand button for it, in the view's bottom-right corner, hidden while
	-- full screen: a copy of it (its own template, so it looks and turns the same) there instead
	local toggle
	if map.GetCanvasContainer and pcall(function() toggle = CreateFrame("Frame", nil, map, "WorldMapSidePanelToggleTemplate") end) and toggle and toggle.Refresh then
		toggle:SetPoint("BOTTOMRIGHT", map:GetCanvasContainer(), "BOTTOMRIGHT", -2, 1)
		toggle:SetFrameLevel(math.min(map.ScrollContainer:GetFrameLevel() + 9300, 9950))
		toggle.OnClick = function(self) mod.ToggleMaxQuestLog() self:Refresh() end   -- (its buttons call this)
		-- (open or not: the log OpenMap shows over the map, not Blizzard's side panel, which is never open here)
		toggle.Refresh = function(self)
			local open = Log() and Log():IsShown() or false
			self.OpenButton:SetShown(not open)
			self.CloseButton:SetShown(open)
		end
		toggle:Hide()
		mod.maxLogToggle = toggle
	end
	local function ShowToggle()
		if not toggle then return end
		toggle:SetShown(Maximized() and true or false)
		if toggle:IsShown() then toggle:Refresh() end
	end
	-- after Blizzard settles the map's state (opening, maximizing): put it back if it's wanted
	if map.SetDisplayState then
		hooksecurefunc(map, "SetDisplayState", function()
			if Maximized() and mod.db.maxQuestLog then ShowMaxLog(true) end
			ShowToggle()
		end)
	end
	if map.Maximize then hooksecurefunc(map, "Maximize", ShowToggle) end
	if map.Minimize then hooksecurefunc(map, "Minimize", ShowToggle) end
	Log():HookScript("OnShow", function() if toggle and toggle:IsShown() then toggle:Refresh() end FitRightGrip() end)
	Log():HookScript("OnHide", function() if toggle and toggle:IsShown() then toggle:Refresh() end FitRightGrip() end)
	-- leaving full screen: hidden first (Blizzard only widens the window for a quest log it shows itself)
	local mm = map.BorderFrame and map.BorderFrame.MaximizeMinimizeFrame
	local minimize = mm and mm.MinimizeButton
	if minimize then minimize:HookScript("OnMouseDown", function() ShowMaxLog(false) end) end
	map:HookScript("OnHide", function() ShowMaxLog(false) end)
end

function mod:WindowOptions(opts, get, set, off)
	opts.windowScale = { type = "range", name = L["Map size"], order = 25, min = MIN_SCALE, max = MAX_SCALE, step = 0.05, isPercent = true,
		get = get, set = function(info, v) set(info, v) Apply() end, disabled = off,
		desc = L["Scales the whole windowed map. Drag either of its bottom corners to change its width and height, and its title bar to move it."] }
	opts.fullWidth = { type = "toggle", name = L["Full-screen map fills the width"], order = 27, get = get,
		set = function(info, v)
			set(info, v)
			if not map or not Maximized() then return end
			if map.UpdateMaximizedSize then map:UpdateMaximizedSize() else FillScreen() end   -- (off: Blizzard's size again on the next maximize)
		end, disabled = off,
		desc = L["When maximized, the map takes the screen's whole width instead of keeping Blizzard's shape with bars at the sides."] }
	opts.border = { type = "toggle", name = L["Parchment border"], order = 28, get = get, set = set, disabled = off,
		desc = L["The map art's own torn-parchment frame round the map, seen when you're zoomed right out."] }
	opts.resetWindow = { type = "execute", name = L["Reset size and place"], order = 26, disabled = off,
		func = function() mod:ResetWindow() end }
end
