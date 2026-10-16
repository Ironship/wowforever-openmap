--------------------------------------------------------------------------------
-- Dungeons: their entrances on the map (ns.MapPlaces, from the game's tables), each with its level
-- range in the game's quest colours for you. Click one for its map (Blizzard's dungeon map, in the
-- same window; with several at one entrance, pick which), and back out the way you came: right-click,
-- the wheel past all the way out, or the card's Back puts the world back where you were.
-- On a dungeon's map, a card of what's in it: its bosses (the game's list, in its order) and, with
-- Questie, the quests for it. Questie knows no places inside dungeons, so they're listed, not pinned;
-- the game's own boss pins show by themselves where the client has them (its encounter journal).
-- /openmap entrance <name>, standing in a portal: the line for tools/map-data/build.py's ENTRANCES.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local mod = ns:GetModule("worldmap")
local Look, Safe, L = ns.Look, ns.Safe, ns.L

local d = mod.defaults
d.dungeonBosses = true          -- the card lists a dungeon's bosses
d.dungeonQuests = true          -- and, with Questie, its quests
d.dungeonCard = true            -- the card open (false: folded to its title)
d.dungeonLevels = true          -- each entrance's level range under its icon
d.dungeonHints = 0              -- dungeon maps opened with the how-to-leave hint (it shows for the first few)
d.dungeonTab = "floors"         -- the dungeon map's side panel: floors, bosses, quests or loot
d.entrances = {}                -- lines /openmap entrance recorded, to paste into build.py

local LOOK = {
	dungeon = { atlas = "dungeon", texture = "Interface\\Minimap\\ObjectIcons", size = 26 },
	raid = { atlas = "raid", texture = "Interface\\Minimap\\ObjectIcons", size = 26 },
}
-- the floor a wing opens on: its part of the dungeon's map (the game's names for the floors)
local WING_FLOORS = {
	["Dire Maul - East"] = "Warpwood Quarter", ["Dire Maul - West"] = "Capital Gardens", ["Dire Maul - North"] = "Gordok Commons",
	["Scarlet Monastery - Graveyard"] = "Graveyard", ["Scarlet Monastery - Library"] = "Library",
	["Scarlet Monastery - Armory"] = "Armory", ["Scarlet Monastery - Cathedral"] = "Cathedral",
}
local CARD_W = 270

local map, sc, chooser, card
local entrancePins = {}
local byMap                     -- a dungeon's map (each floor) -> { insts = { ... }, u, v (its entrance) }
local returnTo                  -- the world as it was when a dungeon's map was opened: { u, v, zoom, maps = { [mapID] = true } }
local shownMap, lastMap         -- the map the window shows, and the one before it

local function Places() return ns.MapPlaces or {} end

-- an entrance's place on Azeroth's map (normalized): from world yards on its continent, or a spot on
-- a zone's map (Data/Places.lua's `map =`)
function S.EntranceAt(g)
	if g.map then
		if not S.Rect(g.map) then return end
		return mod.ToWorld(g.map, g[2], g[3])
	end
	return S.FromYards(g[1], g[2], g[3])
end

local function Range(inst)
	if not inst[4] or not mod.LevelColor then return end
	local code, range = mod.LevelColor(inst[4], inst[5] or inst[4])
	return code .. range .. "|r"
end

local Index

-- a dungeon's map: the game's kind, or one an entrance opens (a dungeon whose map is a micro map)
local function IsDungeonMap(mapID)
	local info = mapID and C_Map.GetMapInfo(mapID)
	if not info then return false end
	return info.mapType == Enum.UIMapType.Dungeon or (Index and Index()[mapID] ~= nil) or false
end

-- a dungeon's map in this client (Blizzard's, found by its name), every floor of it
local function BaseMap(inst)
	local real = GetRealZoneText and inst[1] > 0 and Safe.Call(GetRealZoneText, inst[1])
	return (real and real ~= "" and S.InstanceMap(real)) or S.InstanceMap(inst[2])
end

local function Floors(id)
	local group = C_Map.GetMapGroupID and Safe.Call(C_Map.GetMapGroupID, id)
	if not group then return {} end
	local ok, floors = pcall(C_Map.GetMapGroupMembersInfo, group)
	return ok and type(floors) == "table" and floors or {}
end

local function MapsOf(id)
	local maps = { [id] = true }
	for _, f in ipairs(Floors(id)) do maps[f.mapID] = true end
	return maps
end

-- the map an instance opens on: its wing's floor where it has one
local function DungeonMap(inst)
	local id = BaseMap(inst)
	local floor = id and WING_FLOORS[inst[2]]
	if floor then
		for _, f in ipairs(Floors(id)) do
			if f.name == floor then return f.mapID end
		end
	end
	return id
end

-- which instances each dungeon map (and floor) is, and where it's entered
Index = function()
	if byMap then return byMap end
	byMap = {}
	local function add(inst, u, v)
		local id = BaseMap(inst)
		if not id then return end
		for m in pairs(MapsOf(id)) do
			local e = byMap[m] or { insts = {} }
			byMap[m] = e
			local known = false
			for _, other in ipairs(e.insts) do known = known or other == inst end
			if not known then e.insts[#e.insts + 1] = inst end
			if u and not e.u then e.u, e.v = u, v end
		end
	end
	for _, g in ipairs(Places().instances or {}) do
		local u, v = S.EntranceAt(g)
		for _, inst in ipairs(g[4]) do add(inst, u, v) end
	end
	for _, inst in ipairs(Places().unplaced or {}) do add(inst) end
	return byMap
end

--------------------------------------------------------------------------------
-- Opening a dungeon's map, and back out to the world
--------------------------------------------------------------------------------

local portalCard                -- the dungeon whose card shows over the world map (no map of it in this client): { inst }
local RefreshCard

--------------------------------------------------------------------------------
-- The dungeon's own map, drawn here: WoW Forever's client has no dungeon maps for Blizzard's map to
-- show, but it has their art (Data/DungeonMaps.lua, each floor's 12 tiles). Over the world map in the
-- same window, fitted, at once; the wheel zooms about the cursor (out past its fit too) and dragging
-- pans; floors with the arrows, the list or the side panel's Floors. Out again (the world as it was,
-- never moved): right-click, Escape, Back.
--------------------------------------------------------------------------------

local PIC_W, PIC_H = 1002, 668  -- the picture in its 4 x 3 tiles of 256 (1024 x 768)
local HEAD_H = 40               -- the view's bar across its top: back, the floor, close
local HINTS = 3                 -- dungeon maps opened with the hint
local ZOOM_OUT = 0.5            -- the furthest out the wheel goes: half its fit
local SIDE_W = 320              -- the view's side panel: what's in the dungeon (bosses, quests, loot); the quest log's width
local LOG_TOP, LOG_BAR = 29, 22 -- the quest log's strip along its top, and its scroll bar's at its right (Blizzard's)
local INNER_TABS = 36           -- the panel's bosses / quests / loot tabs, down from its box's top
local TAB_W, TAB_H = 40, 42     -- a tab by the quest log, out from it by along it (WoW Forever's tab art; a little smaller)
local NEEDROLL_URL = "https://www.curseforge.com/wow/addons/needroll"
local view
local QuestList, EnsureQuests, FillSide, Dock, PlaceTabs, PlaceMarks, EndMarkup   -- (below)

local function Sound(name) if PlaySound and SOUNDKIT and SOUNDKIT[name] then PlaySound(SOUNDKIT[name]) end end

-- one of the game's atlases on a texture, if the client has it: mirrored (left for right), at its own size
-- `mirrored` true or false: turned or not from the corners the texture was first given for that atlas,
-- kept (SetAtlas again with the atlas it has changes nothing, even after SetTexture(nil), so turning
-- what it showed turned a mirrored tab back at every click; and the atlas table's own corners are
-- the 1x file's, the wrong part of the double-size one a high-resolution screen gets)
-- `turn` (true: "right", false: "left"): the side its art's flat edge goes to (the art's own is its
-- left), for a tab on that edge: "left" as it is, "right" mirrored, "top" / "bottom" turned a
-- quarter round
-- the art's l, r, t, b corners on `tex`, turned so its left (flat) side is on `turn`'s side
local function Turned(tex, l, r, t, b, turn)
	-- (corners: upper left, lower left, upper right, lower right, each from the art's)
	if turn == "right" then tex:SetTexCoord(r, l, t, b)
	elseif turn == "bottom" then tex:SetTexCoord(r, t, l, t, r, b, l, b)   -- (a quarter round anticlockwise)
	elseif turn == "top" then tex:SetTexCoord(l, b, r, b, l, t, r, t)      -- (clockwise)
	else tex:SetTexCoord(l, r, t, b) end
end

local function Atlas(tex, name, turn, ownSize)
	if not (C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name)) then return false end
	tex:SetAtlas(name, ownSize and true or false)
	if turn == true then turn = "right" elseif turn == false then turn = "left" end
	if turn then
		tex.omCoords = tex.omCoords or {}
		local c = tex.omCoords[name]
		if not c then
			c = { tex:GetTexCoord() }             -- (UL x, y, LL x, y, UR x, y, LR x, y: as first set, never turned)
			tex.omCoords[name] = c
		end
		Turned(tex, c[1], c[5], c[2], c[4], turn)
	end
	return true
end

local function FloorsOf(inst) return ns.MapDungeonMaps and ns.MapDungeonMaps[inst[1]] end
local BLANK = { { blank = true } }    -- (the floors of a dungeon the client has no map of: one blank page)

local function LayoutView()
	if not view or not view:IsShown() then return end
	local w, h = view.port:GetWidth(), view.port:GetHeight()
	if not w or w <= 0 or not h or h <= 0 then return end
	local s = math.min(w / PIC_W, h / PIC_H) * view.zoom
	local pw, ph = PIC_W * s, PIC_H * s
	-- (kept over the view when it's bigger; centred when it's not)
	local mx, my = math.max(0, (pw - w) / 2), math.max(0, (ph - h) / 2)
	view.ox = math.max(-mx, math.min(mx, view.ox))
	view.oy = math.max(-my, math.min(my, view.oy))
	view.page:SetSize(pw, ph)
	view.page:ClearAllPoints()
	view.page:SetPoint("CENTER", view.port, "CENTER", view.ox, view.oy)
	for i, t in ipairs(view.tiles) do
		local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
		local tw, th = math.min(256, PIC_W - col * 256), math.min(256, PIC_H - row * 256)
		t:SetSize(tw * s, th * s)
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", view.page, "TOPLEFT", col * 256 * s, -row * 256 * s)
		t:SetTexCoord(0, tw / 256, 0, th / 256)
	end
	if PlaceMarks then PlaceMarks(pw, ph) end
end

local function ShowFloor(i, quiet)
	local floors = view.floors
	i = ((i - 1) % #floors) + 1
	if not quiet and i ~= view.floor then Sound("IG_ABILITY_PAGE_TURN") end
	view.floor = i
	local f = floors[i]
	for k, t in ipairs(view.tiles) do
		if f.tiles then t:SetTexture(f.tiles[k], nil, nil, "TRILINEAR") end
		t:SetShown(f.tiles and true or false)
	end
	view.blank:SetShown(f.blank and true or false)
	view.blankText:SetShown(f.blank and true or false)
	view.floorName:SetText(("|cffffd100%s|r%s"):format(view.FloorName(i), #floors > 1 and ("  |cff998866%d / %d|r"):format(i, #floors) or ""))
	view.wing:SetText(f.wing and (f.wing .. "   ") or "")
	view.where:SetText(S.InstanceName(view.inst))
	view.prev:SetShown(#floors > 1)
	view.next:SetShown(#floors > 1)
	view.floorButton:SetWidth(math.max(160, (view.floorName:GetStringWidth() or 120) + 24))
	view.floorButton:EnableMouse(#floors > 1)
	if view.list then view.list:Hide() end
	if view.side and view.side.LightThumbs then view.side.LightThumbs() end
	view.zoom, view.ox, view.oy = 1, 0, 0
	LayoutView()
end

-- out: back to the world, at once
local function CloseView()
	if not view or not view:IsShown() or view.leaving then return end
	if view.list then view.list:Hide() end
	Sound("IG_QUEST_LOG_CLOSE")
	view:Hide()
	RefreshCard()
end

local function Wheel(delta)
	-- (out past its fit too, the picture smaller in the middle: the wheel never leaves it)
	local z = math.max(ZOOM_OUT, math.min(4, view.zoom * (delta > 0 and 1.25 or 0.8)))
	if math.abs(z - view.zoom) < 1e-3 then return end
	-- about the cursor: the point under it stays there
	local x, y = GetCursorPosition()
	local es = view:GetEffectiveScale()
	local cx, cy = view.port:GetCenter()
	local dx, dy = x / es - cx - view.ox, y / es - cy - view.oy
	view.ox, view.oy = view.ox - dx * (z / view.zoom - 1), view.oy - dy * (z / view.zoom - 1)
	view.zoom = z
	LayoutView()
end

local function BuildView()
	view = CreateFrame("Frame", "OpenMapDungeonView", sc)
	view:SetAllPoints(sc)
	view:SetFrameLevel(math.min(sc:GetFrameLevel() + 8800, 9800))   -- (over the map and its icons; under OpenMap's menu and card)
	view:EnableMouse(true)
	view:EnableMouseWheel(true)
	view:SetClipsChildren(true)
	tinsert(UISpecialFrames, "OpenMapDungeonView")
	local bg = view:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.04, 0.03, 0.96)
	-- the picture's own clipped area: under the bar, left of the side panel (zoomed in, it stays in it)
	view.port = CreateFrame("Frame", nil, view)
	view.port:SetPoint("TOPLEFT", 0, -HEAD_H)
	view.port:SetPoint("BOTTOMRIGHT", -SIDE_W, 0)
	view.port:SetClipsChildren(true)
	view.port:SetScript("OnSizeChanged", function() LayoutView() end)
	view.page = CreateFrame("Frame", nil, view.port)
	view.tiles = {}
	for i = 1, 12 do view.tiles[i] = view.page:CreateTexture(nil, "ARTWORK") end
	-- a dungeon the client has no map of: the map's own parchment, blank, and a word on it
	view.blank = view.page:CreateTexture(nil, "ARTWORK")
	view.blank:SetAllPoints()
	view.blank:SetTexture(ns.Media.path .. "Textures\\MapPaper", "REPEAT", "REPEAT")
	view.blank:SetTexCoord(0, 3, 0, 2)          -- (the paper's grain at about the zone maps' size)
	view.blank:Hide()
	view.blankText = Look:Font(view.page:CreateFontString(nil, "OVERLAY"), 16)
	view.blankText:SetPoint("CENTER")
	view.blankText:SetTextColor(0.32, 0.22, 0.12)
	view.blankText:SetText(L["WoW Forever has no map of this dungeon yet."])
	view.blankText:Hide()
	-- the bar across the top: back to the world (the zone it was entered from), the floor (its name
	-- between two arrows, a list of them all from its name), close
	local bar = CreateFrame("Frame", nil, view)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(HEAD_H)
	bar:SetFrameLevel(view:GetFrameLevel() + 20)   -- (over the picture, however far in)
	bar:EnableMouse(true)
	local barBg = bar:CreateTexture(nil, "BACKGROUND")
	barBg:SetAllPoints()
	barBg:SetColorTexture(0.09, 0.07, 0.05, 0.97)
	local rule = bar:CreateTexture(nil, "ARTWORK")
	rule:SetPoint("BOTTOMLEFT")
	rule:SetPoint("BOTTOMRIGHT")
	rule:SetHeight(1)
	rule:SetColorTexture(0.66, 0.49, 0.28, 0.9)
	local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
	close:SetPoint("RIGHT", -4, 0)
	close:SetScript("OnClick", function() CloseView() end)
	-- (back by the close button, top right, where a window's way out is)
	view.back = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
	view.back:SetHeight(24)
	view.back:SetPoint("RIGHT", close, "LEFT", -6, 0)
	view.back:SetScript("OnClick", function() CloseView() end)
	view.back:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L["Back to the world map, where you were"], 1, 1, 1)
		GameTooltip:AddLine(L["Or right-click the map, or press Escape"], 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	view.back:SetScript("OnLeave", GameTooltip_Hide)
	view.where = Look:Font(bar:CreateFontString(nil, "OVERLAY"), 12)
	view.where:SetPoint("LEFT", 12, 0)
	view.where:SetTextColor(0.8, 0.7, 0.5)
	view.floorButton = CreateFrame("Button", nil, bar)
	view.floorButton:SetSize(200, 30)
	view.floorButton:SetPoint("CENTER")
	view.floorButton:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	view.floorName = Look:Font(view.floorButton:CreateFontString(nil, "OVERLAY"), 15)
	view.floorName:SetPoint("CENTER", 0, 4)
	view.wing = Look:Font(view.floorButton:CreateFontString(nil, "OVERLAY"), 10)
	view.wing:SetPoint("TOP", view.floorName, "BOTTOM", 0, -1)
	view.wing:SetTextColor(0.8, 0.7, 0.5)
	function view.FloorName(i)
		local f = view.floors[i]
		return f.name or (#view.floors > 1 and L["Level %d"]:format(i)) or S.InstanceName(view.inst)
	end
	-- every floor by name, to go straight to one
	view.floorButton:SetScript("OnClick", function(self)
		local list = view.list
		if not list then
			list = CreateFrame("Frame", nil, view)
			list:SetFrameLevel(bar:GetFrameLevel() + 10)
			list:EnableMouse(true)
			list.pad = { Look:Dropdown(list) }    -- (the game's own dropdowns' look)
			list.rows = {}
			view.list = list
		end
		if list:IsShown() then list:Hide() return end
		local w = 180
		for i = 1, #view.floors do
			local row = list.rows[i]
			if not row then
				row = CreateFrame("Button", nil, list)
				row:SetHeight(22)
				row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
				row.text = Look:Font(row:CreateFontString(nil, "OVERLAY"), 13)
				row.text:SetPoint("LEFT", 6, 0)
				row:SetScript("OnClick", function(r) list:Hide() ShowFloor(r.floor) end)
				list.rows[i] = row
			end
			row.floor = i
			row.text:SetText((i == view.floor and "|cffffd100" or "|cffffffff") .. view.FloorName(i) .. "|r")
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", list.pad[1], -list.pad[2] - (i - 1) * 22)
			row:SetPoint("TOPRIGHT", -list.pad[3], -list.pad[2] - (i - 1) * 22)
			row:Show()
			w = math.max(w, (row.text:GetStringWidth() or 100) + 24)
		end
		for i = #view.floors + 1, #list.rows do list.rows[i]:Hide() end
		list:SetSize(w + list.pad[1] + list.pad[3], #view.floors * 22 + list.pad[2] + list.pad[4])
		list:ClearAllPoints()
		list:SetPoint("TOP", self, "BOTTOM", 0, -4)
		list:Show()
	end)
	local function Arrow(dir)
		local b = CreateFrame("Button", nil, bar)
		b:SetSize(26, 26)
		b:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-Up")
		b:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-Down")
		b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
		return b
	end
	view.prev = Arrow("Prev")
	view.prev:SetPoint("RIGHT", view.floorButton, "LEFT", -4, 0)
	view.prev:SetScript("OnClick", function() ShowFloor(view.floor - 1) end)
	view.next = Arrow("Next")
	view.next:SetPoint("LEFT", view.floorButton, "RIGHT", 4, 0)
	view.next:SetScript("OnClick", function() ShowFloor(view.floor + 1) end)
	-- how to leave, for the first few dungeon maps opened
	view.hint = CreateFrame("Frame", nil, view)
	view.hint:SetSize(1, 26)
	view.hint:SetPoint("BOTTOM", view.port, "BOTTOM", 0, 14)
	view.hint:SetFrameLevel(view:GetFrameLevel() + 20)
	local hintText = Look:Font(view.hint:CreateFontString(nil, "OVERLAY"), 12)
	hintText:SetPoint("CENTER")
	hintText:SetSpacing(3)
	view.hintText = hintText
	local hintBg = view.hint:CreateTexture(nil, "BACKGROUND")
	hintBg:SetPoint("TOPLEFT", hintText, -12, 6)
	hintBg:SetPoint("BOTTOMRIGHT", hintText, 12, -6)
	hintBg:SetColorTexture(0.06, 0.05, 0.04, 0.85)
	view.hint.fade = view.hint:CreateAnimationGroup()
	local fade = view.hint.fade:CreateAnimation("Alpha")
	fade:SetFromAlpha(1)
	fade:SetToAlpha(0)
	fade:SetStartDelay(5)
	fade:SetDuration(1.2)
	view.hint.fade:SetScript("OnFinished", function() view.hint:Hide() end)
	view.hint:Hide()
	-- the side panel: the quest log's own look (its strip along the top, its paper in its frame): the
	-- dungeon's name and levels along the top, then a tab each for its bosses, its quests, its loot.
	-- With the quest log open it's in the log, a tab beside the log's own (Dock)
	local side = CreateFrame("Frame", nil, view)
	view.side = side
	side:SetWidth(SIDE_W)
	side:EnableMouse(true)
	side:EnableMouseWheel(true)
	local sideBg = side:CreateTexture(nil, "BACKGROUND", nil, -8)
	sideBg:SetAllPoints()
	sideBg:SetColorTexture(0.07, 0.055, 0.04, 1)
	side.title = Look:Font(side:CreateFontString(nil, "OVERLAY"), 15)
	side.title:SetPoint("TOPLEFT", 6, -7)
	side.title:SetJustifyH("LEFT")
	side.title:SetWordWrap(false)
	side.sub = Look:Font(side:CreateFontString(nil, "OVERLAY"), 12)
	side.sub:SetPoint("TOPRIGHT", -6, -9)
	side.sub:SetJustifyH("RIGHT")
	side.title:SetPoint("RIGHT", side.sub, "LEFT", -8, 0)
	-- (the box: where the log's list is, its scroll bar in the strip at its right)
	local box = CreateFrame("Frame", nil, side)
	box:SetPoint("TOPLEFT", 0, -LOG_TOP)
	box:SetPoint("BOTTOMRIGHT", -LOG_BAR, 0)
	local paper = box:CreateTexture(nil, "BACKGROUND")
	paper:SetAllPoints()
	if not Atlas(paper, "QuestLog-main-background") then paper:SetColorTexture(0.11, 0.09, 0.07, 1) end
	local frame = CreateFrame("Frame", nil, box)
	frame:SetPoint("TOPLEFT", -3, 7)
	frame:SetPoint("BOTTOMRIGHT", 3, -6)
	frame.levelOver = 30                            -- (over the list, as the log's is)
	frame:SetFrameLevel(box:GetFrameLevel() + frame.levelOver)
	local rim = frame:CreateTexture(nil, "BORDER")
	rim:SetAllPoints()
	Atlas(rim, "questlog-frame")
	local filigree = frame:CreateTexture(nil, "ARTWORK")
	if Atlas(filigree, "questlog-frame-filigree", nil, true) then filigree:SetPoint("TOP", 0, 1) end
	local shade = frame:CreateTexture(nil, "BACKGROUND")
	if Atlas(shade, "questlog-frame-gradient-bottom", nil, true) then
		shade:SetPoint("BOTTOMLEFT", 3, 4)
		shade:SetPoint("BOTTOMRIGHT", -3, 4)
	end
	side.tabs = {}
	local tx = 8
	for i, t in ipairs({ { "floors", L["Floors"] }, { "bosses", L["Bosses"] }, { "quests", L["Quests"] }, { "loot", L["Loot"] } }) do
		local ok, b = pcall(CreateFrame, "Button", nil, box, "MinimalTabTemplate")
		if ok and b and b.Text then
			b.Text:SetText(t[2])
			b:SetWidth(math.max(62, b.Text:GetStringWidth() + 24))   -- (four across the panel)
		else
			b = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
			b:SetSize(84, 22)
			b:SetText(t[2])
		end
		b.key = t[1]
		b:SetPoint("BOTTOMLEFT", box, "TOPLEFT", tx, -INNER_TABS)
		b:SetScript("OnClick", function()
			mod.db.dungeonTab = t[1]
			Sound("IG_CHARACTER_INFO_TAB")
			FillSide()
		end)
		side.tabs[i] = b
		tx = tx + b:GetWidth() + 2
	end
	local tabRule = box:CreateTexture(nil, "ARTWORK")
	tabRule:SetPoint("TOPLEFT", 6, -INNER_TABS)
	tabRule:SetPoint("TOPRIGHT", -6, -INNER_TABS)
	tabRule:SetHeight(1)
	tabRule:SetColorTexture(0.66, 0.49, 0.28, 0.5)
	side.scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
	side.scroll:SetPoint("TOPLEFT", 6, -INNER_TABS - 6)
	side.scroll:SetPoint("BOTTOMRIGHT", -2, 10)
	side.child = CreateFrame("Frame", nil, side.scroll)
	side.child:SetWidth(SIDE_W - LOG_BAR - 12)
	side.child:SetHeight(1)
	side.scroll:SetScrollChild(side.child)
	side.pool = { row = {}, text = {}, button = {}, link = {}, thumb = {} }
	-- the Floors tab's pictures: the one shown edged in gold (ShowFloor lights them again)
	function side.LightThumbs()
		for _, w in ipairs(side.pool.thumb) do
			local on = w:IsShown() and w.item and w.item.floor == view.floor
			w:SetBackdropBorderColor(on and 1 or 0.66, on and 0.82 or 0.49, on and 0.3 or 0.28, on and 1 or 0.7)
			w.name:SetTextColor(on and 1 or 0.85, on and 0.82 or 0.8, on and 0.3 or 0.7)
		end
	end
	-- (its width follows the log's, docked: laid out again for it)
	side:SetScript("OnSizeChanged", function(self, w)
		if w and math.abs((self.filledW or 0) - w) > 1 then C_Timer.After(0, FillSide) end
	end)
	-- the tabs beside the quest log while the panel's in it: the log's list, or the dungeon (the log's
	-- own tabs' look; WoW Forever's log doesn't show its tabs)
	local tabs = CreateFrame("Frame", nil, map)    -- (the map's: the view clips, and they're past its edge)
	view.sideTabs = tabs
	tabs:SetSize(TAB_W, TAB_H * 2 + 3)
	tabs.list = {}
	for i, t in ipairs({ { "quests", QUESTS_LABEL or L["Quests"], "questlog-tab-icon-quest", "questlog-tab-icon-quest-inactive" },
			{ "dungeon", L["Dungeon"], "questlog-questtypeicon-dungeon" } }) do
		local b = CreateFrame("Button", nil, tabs)
		b:SetSize(TAB_W, TAB_H)
		b:SetPoint("TOPRIGHT", 0, -(i - 1) * (TAB_H + 3))
		b.key, b.tip, b.on, b.off = t[1], t[2], t[3], t[4]
		b.iconSize = 24
		b.bg = b:CreateTexture(nil, "BACKGROUND")
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.selected = b:CreateTexture(nil, "OVERLAY")
		b.hover = b:CreateTexture(nil, "HIGHLIGHT")
		for _, tex in ipairs({ b.bg, b.selected, b.hover }) do tex:SetPoint("CENTER") end
		b:SetScript("OnClick", function(self)
			local log = map.QuestLog
			if log and log:IsVisible() then
				if view.dockTab == self.key then return end
				view.dockTab = self.key
				Sound("IG_CHARACTER_INFO_TAB")
				Dock()
				return
			end
			-- (the log put away: out again, at this tab; as its own button does, never in combat)
			if InCombatLockdown() then
				ns:Print(L["The quest log can't be opened or closed in combat."])
				return
			end
			view.wantTab = self.key
			if mod.MaxQuestLog and mod.MaxQuestLog() then
				if mod.ToggleMaxQuestLog then mod.ToggleMaxQuestLog() end
			elseif map.HandleUserActionToggleSidePanel then
				map:HandleUserActionToggleSidePanel()
			end
			view.wantTab = nil
			Dock()
		end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_LEFT", 4, -4)   -- (over the map, not the log)
			GameTooltip:SetText(self.key == "dungeon" and view.inst and S.InstanceName(view.inst) or self.tip)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		tabs.list[i] = b
	end
	tabs:Hide()
	-- the mouse: the wheel zooms, a drag pans, a right-click goes back to the world
	view:SetScript("OnMouseWheel", function(_, delta) Wheel(delta) end)
	-- (drawing on it for a report, the markup: a left-drag draws, a right-drag pans, a right-click stays)
	view:SetScript("OnMouseDown", function(self, button)
		if self.markup and button == "LeftButton" then self.MarkStart() return end
		if button == (self.markup and "RightButton" or "LeftButton") then
			local x, y = GetCursorPosition()
			self.drag = { x, y, self.ox, self.oy, button = button }
		end
	end)
	view:SetScript("OnMouseUp", function(self, button)
		if self.markup then
			if button == "LeftButton" then self.MarkFinish() end
		elseif button == "RightButton" then
			CloseView()
		end
		self.drag = nil
	end)
	view:SetScript("OnUpdate", function(self)
		if self.markup then self.MarkMove() end
		local d = self.drag
		if not d then return end
		if not IsMouseButtonDown(d.button) then self.drag = nil return end
		local x, y = GetCursorPosition()
		local es = self:GetEffectiveScale()
		self.ox, self.oy = d[3] + (x - d[1]) / es, d[4] + (y - d[2]) / es
		LayoutView()
	end)
	view:SetScript("OnSizeChanged", LayoutView)
	view:SetScript("OnHide", function()
		view.leaving = nil
		EndMarkup(false)                            -- (a report being drawn: no report)
		if view.list then view.list:Hide() end
		Dock()                                      -- (out of the quest log, if it was in it)
		if card and card:IsShown() then C_Timer.After(0, RefreshCard) end
	end)
	view:Hide()
end

--------------------------------------------------------------------------------
-- Markup: drawing on a dungeon's map for a report (Report.lua). Red pen lines on the floor's
-- picture, in its own measure (0..1 across and down, so they keep their place as it zooms and pans),
-- each on the floor it was drawn on. A left-drag draws, a right-drag pans; its bar: Undo, Next, Cancel.
--------------------------------------------------------------------------------

local MARK_STEP = 3             -- px the cursor moves before the pen adds a point
local MARK_MAX = 300            -- points in one line
local MARK_INK = { 0.92, 0.18, 0.14 }

PlaceMarks = function(pw, ph)
	local lines = view.markLines
	if not lines then return end
	local n = 0
	for _, st in ipairs(view.markup and view.markup.strokes or view.heldMarks or {}) do
		if st.floor == view.floor then
			local p = st.pts
			for k = 1, #p - 3, 2 do
				n = n + 1
				local line = lines[n]
				if not line then
					line = view.page:CreateLine(nil, "OVERLAY")
					line:SetColorTexture(MARK_INK[1], MARK_INK[2], MARK_INK[3], 1)
					line:SetThickness(3)
					lines[n] = line
				end
				line:SetStartPoint("TOPLEFT", view.page, p[k] * pw, -p[k + 1] * ph)
				line:SetEndPoint("TOPLEFT", view.page, p[k + 2] * pw, -p[k + 3] * ph)
				line:Show()
			end
		end
	end
	for i = n + 1, #lines do lines[i]:Hide() end
end

local function RedrawMarks()
	local pw, ph = view.page:GetSize()
	if pw and pw > 0 then PlaceMarks(pw, ph) end
end

-- the cursor on the picture: 0..1 across and down (nil off it; `clamp`: kept to its edge)
local function PageAt(clamp)
	local x, y = GetCursorPosition()
	local es = view.page:GetEffectiveScale()
	local l, t, w, h = view.page:GetLeft(), view.page:GetTop(), view.page:GetWidth(), view.page:GetHeight()
	if not (l and t and w and h and w > 0 and h > 0) then return end
	local px, py = (x / es - l) / w, (t - y / es) / h
	if clamp then return math.max(0, math.min(1, px)), math.max(0, math.min(1, py)) end
	if px < 0 or px > 1 or py < 0 or py > 1 then return end
	return px, py
end

local function Round4(x) return math.floor(x * 1e4 + 0.5) / 1e4 end

local function MarkStart()
	local m = view.markup
	local px, py = PageAt()
	if not m or not px then return end
	local st = { floor = view.floor, pts = { Round4(px), Round4(py) } }
	m.strokes[#m.strokes + 1] = st
	local x, y = GetCursorPosition()
	m.live = { st = st, x = x, y = y }
end

local function MarkFinish()
	local m = view.markup
	local live = m and m.live
	if not live then return end
	m.live = nil
	if #live.st.pts < 4 then tremove(m.strokes) end   -- (a click: nothing drawn)
	RedrawMarks()
end

local function MarkMove()
	local live = view.markup and view.markup.live
	if not live then return end
	if not IsMouseButtonDown("LeftButton") then MarkFinish() return end
	local x, y = GetCursorPosition()
	if math.abs(x - live.x) + math.abs(y - live.y) < MARK_STEP or #live.st.pts >= MARK_MAX * 2 then return end
	live.x, live.y = x, y
	local px, py = PageAt(true)
	if not px then return end
	local p = live.st.pts
	p[#p + 1], p[#p + 2] = Round4(px), Round4(py)
	RedrawMarks()
end

-- the markup's bar, over the picture's top: what to do, Undo, Next, Cancel
local function MarkBar()
	if view.markBar then return view.markBar end
	local bar = CreateFrame("Frame", nil, view)
	bar:SetPoint("TOP", view.port, "TOP", 0, -6)
	bar:SetSize(640, 38)
	bar:SetFrameLevel(view:GetFrameLevel() + 30)
	bar:EnableMouse(true)
	Look:Panel(bar, { inset = 0, alpha = 0.92 })
	local text = Look:Font(bar:CreateFontString(nil, "OVERLAY"), 12)
	text:SetPoint("LEFT", 10, 0)
	text:SetText(L["|cffffd100Step 1 of 2:|r draw where it's wrong (right-drag pans)"])
	local function Btn(label, x, fn, w)
		local b = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
		b:SetSize(w or 70, 24)
		b:SetPoint("RIGHT", x, 0)
		b:SetText(label)
		b:SetScript("OnClick", fn)
		return b
	end
	local next = Btn(L["Next"] .. "  >", -82, function() EndMarkup(true) end, 96)
	-- (the way on: a gold glow round it, breathing)
	local glow = next:CreateTexture(nil, "BACKGROUND", nil, -1)
	glow:SetPoint("TOPLEFT", -4, 4)
	glow:SetPoint("BOTTOMRIGHT", 4, -4)
	glow:SetColorTexture(1, 0.8, 0.25, 0.55)
	local pulse = glow:CreateAnimationGroup()
	local breathe = pulse:CreateAnimation("Alpha")
	breathe:SetFromAlpha(1)
	breathe:SetToAlpha(0.2)
	breathe:SetDuration(0.8)
	breathe:SetSmoothing("IN_OUT")
	pulse:SetLooping("BOUNCE")
	pulse:Play()
	Btn(CANCEL or L["Cancel"], -8, function() EndMarkup(false) end)
	Btn(L["Undo"], -184, function()
		local m = view.markup
		if m then tremove(m.strokes) RedrawMarks() end
	end)
	mod.padRoots[#mod.padRoots + 1] = bar      -- (the gamepad's cursor presses its buttons: Gamepad.lua)
	view.markBar = bar
	return bar
end

EndMarkup = function(finished)
	local m = view and view.markup
	if not m then return end
	view.markup = nil
	if view.markBar then view.markBar:Hide() end
	view.heldMarks = finished and m.strokes or nil   -- (Next: still shown while the note's written; else gone)
	RedrawMarks()
	local place = finished and { inst = view.inst[1], u = view.fromU, v = view.fromV } or nil
	if m.onEnd then m.onEnd(finished and m.strokes or nil, place, finished and true or false) end
end

-- the lines a finished markup left on show: gone (the report's done)
function mod.DungeonMarkupRelease()
	if view and view.heldMarks then
		view.heldMarks = nil
		RedrawMarks()
	end
end

-- Report.lua's: on (with onEnd(strokes, place, finished), as the markup ends), or off (no report)
function mod.DungeonMarkup(on, onEnd)
	if not view then return end
	if not on then EndMarkup(false) return end
	if not view:IsShown() then return end
	EndMarkup(false)
	view.MarkStart, view.MarkMove, view.MarkFinish = MarkStart, MarkMove, MarkFinish
	view.markLines = view.markLines or {}
	view.markup = { strokes = {}, onEnd = onEnd }
	view.hint:Hide()
	MarkBar():Show()
	RedrawMarks()
end

-- the tabs beside the quest log: on its right, as the log's own are, or (full screen, the log at the
-- screen's edge) on its left, the art mirrored
-- one tab's art (b.bg, b.selected, b.hover; b.artH: its art's height, else the atlas's own), turned
-- or not; `on` (true / false) shows its selected edge, nil leaves that be (Panel.lua's tabs light
-- it themselves). An icon of the game's (b.on / b.off atlases) is set too; any b.icon is placed
local TOWARD = { left = { -1, 0 }, right = { 1, 0 }, top = { 0, 1 }, bottom = { 0, -1 } }   -- (each edge's way)
-- WoW Forever's own tabs' art (the "c60" set, its bronze edge) and the mask of its face. Its art is
-- 55 x 60, the tab showing 52 out from its flat side by 54 along; the face (the mask's) is 43 by 44
-- of it, 2 in from the flat side
local TAB_ART = { "common-sidetab-c60", "common-sidetab-selected-c60", "common-sidetab-hover-c60" }
local TAB_MASK = "common-sidetab-mask-c60"
local ART_OUT, ART_ALONG, SHOW_OUT, SHOW_ALONG = 55, 60, 52, 54
local FACE_OUT, FACE_ALONG, FACE_IN = 43, 44, 2
local function FaceTab(b, turn, on)
	if turn == true then turn = "right" elseif turn == false then turn = "left" end
	local w, h = b:GetWidth(), b:GetHeight()
	local upright = turn == "left" or turn == "right"
	local out, along = upright and w or h, upright and h or w
	-- the art at the tab's size, its flat side flush with the tab's (its clear strip is on its open side)
	local ao, aa = out * ART_OUT / SHOW_OUT, along * ART_ALONG / SHOW_ALONG
	local aw, ah = upright and ao or aa, upright and aa or ao
	local edge = TOWARD[turn]
	local shift = (ao - out) / 2                -- (away from the edge)
	local cx, cy = -edge[1] * shift, -edge[2] * shift
	local art = { b.bg, b.selected, b.hover }
	for i, tex in ipairs(art) do
		local ok = Atlas(tex, TAB_ART[i], turn, true) or Atlas(tex, (TAB_ART[i]:gsub("%-c60$", "")), turn, true)
		if ok then
			tex:SetSize(aw, ah)
			tex:ClearAllPoints()
			tex:SetPoint("CENTER", cx, cy)
		elseif i == 1 then
			b.bg:SetAllPoints()
			b.bg:SetColorTexture(0.1, 0.08, 0.06, 0.95)
		end
	end
	if on ~= nil then b.selected:SetShown(on) end
	if not b.icon then return end
	if b.fill and b.icon.square ~= false then
		-- (OpenMap's own: the picture filling the face, cut to its shape; the face's middle is nearer the flat side)
		if not b.mask then
			b.mask = b:CreateMaskTexture()
			if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(TAB_MASK) then
				b.mask:SetAtlas(TAB_MASK)
				b.icon:AddMaskTexture(b.mask)
			end
		end
		b.mask:SetSize(aw, ah)
		b.mask:ClearAllPoints()
		b.mask:SetPoint("CENTER", cx, cy)
		pcall(Turned, b.mask, 0, 1, 0, 1, turn)   -- (the mask is its whole file)
		local side = math.max(FACE_OUT * ao / ART_OUT, FACE_ALONG * aa / ART_ALONG)
		local toward = (ART_OUT / 2 - FACE_IN - FACE_OUT / 2) * ao / ART_OUT   -- (the face's middle from the art's)
		b.icon:SetSize(side, side)
		b.icon:ClearAllPoints()
		b.icon:SetPoint("CENTER", cx + edge[1] * toward, cy + edge[2] * toward)
		return
	end
	if b.on and Atlas(b.icon, (on or not b.off) and b.on or b.off, false, true) then
		b.icon:SetSize(b.iconSize or 24, b.iconSize or 24)
		if not b.off then                       -- (one icon for both: dimmed when it's not the one shown)
			b.icon:SetDesaturated(not on)
			b.icon:SetAlpha(on and 1 or 0.75)
		end
	end
	-- (an icon of its own size: in the face's middle)
	local toward = (ART_OUT / 2 - FACE_IN - FACE_OUT / 2) * ao / ART_OUT
	b.icon:ClearAllPoints()
	b.icon:SetPoint("CENTER", cx + edge[1] * toward, cy + edge[2] * toward)
end
mod.FaceSideTab = FaceTab

local function FaceTabs(mirrored, open)
	for _, b in ipairs(view.sideTabs.list) do
		FaceTab(b, mirrored, open and b.key == view.dockTab or false)   -- (the log put away: neither is the one shown)
	end
end

-- a frame of ours to a level, and everything in it above it as it was laid out (its frame over its list)
local function Lift(f, level)
	f:SetFrameLevel(level)
	for _, child in ipairs({ f:GetChildren() }) do Lift(child, level + (child.levelOver or 1)) end
end

-- the side panel's place: in the quest log while it's open (its own tab beside the log's, picked as
-- the dungeon's map opens), else put away with it. Never Blizzard's log's own state: only frames of ours
local DockNow
local railKnew                  -- whether OpenMap's tabs last made room for these
Dock = function()
	DockNow()
	-- (OpenMap's own tabs keep room for these over them while they show, Panel.lua: told when that changes)
	local shown = mod.DungeonTabsShown()
	if shown ~= railKnew and mod.RefreshRail then
		railKnew = shown
		mod.RefreshRail()
	end
end
function mod.DungeonTabsShown() return view and view.sideTabs and view.sideTabs:IsShown() or false end

DockNow = function()
	if not view then return end
	local side, tabs = view.side, view.sideTabs
	if view.leaving then                        -- (going: out of the log at once, not after the view's shrunk)
		tabs:Hide()
		if side:GetParent() ~= view then side:Hide() end
		return
	end
	local log = map.QuestLog
	local open = view:IsShown() and log and log:IsVisible() and true or false
	side:ClearAllPoints()
	view.port:SetPoint("BOTTOMRIGHT", 0, 0)
	if open then
		local anchor = log.ContentsAnchor or log
		side:SetParent(log)
		side:SetPoint("TOPLEFT", anchor, "TOPLEFT")
		side:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT")
		Lift(side, math.min(log:GetFrameLevel() + 600, 9700))   -- (over all of the log: its frames go to 100, its buttons a little past)
		side:SetShown(view.dockTab ~= "quests")
	else
		-- (the log put away: the panel with it, the dungeon's map the whole view)
		side:SetParent(view)
		side:SetPoint("TOPRIGHT", 0, -HEAD_H)
		side:SetPoint("BOTTOMRIGHT")
		side:SetWidth(SIDE_W)
		side:Hide()
	end
	if not view:IsShown() then tabs:Hide() return end
	PlaceTabs(open)
end

-- the tabs, low down inside the map's right edge (the quest log's left while it's open), turned to sit
-- flat to it; past the end of OpenMap's own tabs when they're on that edge too (Panel.lua). Shown with
-- the log put away too: one brings it back, at that tab
PlaceTabs = function(open)
	local tabs, log = view.sideTabs, map.QuestLog
	if mod.PlaceDungeonTabsFrame then mod.PlaceDungeonTabsFrame(tabs)
	else
		tabs:ClearAllPoints()
		tabs:SetPoint("BOTTOMRIGHT", sc, "BOTTOMRIGHT", 0, 44)
	end
	-- (over the view: it's the map's whole view)
	tabs:SetFrameLevel(math.min(math.max(log and log:GetFrameLevel() + 610 or 0, view:GetFrameLevel() + 40), 9900))
	FaceTabs("right", open)
	tabs:Show()
end
-- (OpenMap's tabs grew or moved: these go with them)
function mod.PlaceDungeonTabs()
	if view and view:IsShown() and not view.leaving then
		local log = map.QuestLog
		PlaceTabs(log and log:IsVisible() and true or false)
	end
end

-- a dungeon's map in the view: its wing's first floor, else its first; grown out of `pin` (the entrance)
local function OpenView(inst, pin)
	-- (none in the client, WoW Forever's own dungeons: a blank page, its side panel as any other's)
	local floors = FloorsOf(inst)
	if not floors or #floors == 0 then floors = BLANK end
	if not view then BuildView() end
	portalCard = nil
	view.inst, view.floors = inst, floors
	local first = 1
	for i, f in ipairs(floors) do
		if f.wing == inst[2] or (f.name and f.name == WING_FLOORS[inst[2]]) then first = i break end
	end
	-- back to: the zone the entrance is in
	EndMarkup(false)
	view.heldMarks = nil
	view.fromU, view.fromV = pin and pin.u, pin and pin.v   -- (the entrance: where a report from here says it is)
	local zone = pin and pin.u and S.ChainAt(pin.u, pin.v)
	local info = zone and zone[#zone] and C_Map.GetMapInfo(zone[#zone])
	view.back:SetText("|cffffd100<|r  " .. (info and info.name and L["Back to %s"]:format(info.name) or L["Back"]))
	view.back:SetWidth((view.back:GetFontString():GetStringWidth() or 80) + 28)
	view.leaving = nil
	view:SetAlpha(1)
	view:Show()
	view.dockTab = "dungeon"
	Dock()
	view.floor = nil
	ShowFloor(first, true)
	Sound("IG_QUEST_LOG_OPEN")
	FillSide()
	if (mod.db.dungeonHints or 0) < HINTS then
		mod.db.dungeonHints = (mod.db.dungeonHints or 0) + 1
		local hint = L["|cffffd100Right-click|r or |cffffd100Esc|r to go back to the world map"]
		-- (the log put away: where the dungeon's bosses, quests and loot are)
		if not view.side:IsShown() then hint = hint .. "\n" .. L["Bosses, quests and loot are in the tabs at the map's edge"] end
		view.hintText:SetText(hint)
		view.hint:SetHeight((view.hintText:GetStringHeight() or 14) + 12)
		view.hint:SetAlpha(1)
		view.hint:Show()
		view.hint.fade:Stop()
		view.hint.fade:Play()
	else
		view.hint:Hide()
	end
	RefreshCard()
	return true
end
function mod.DungeonViewShown() return view and view:IsShown() or false end

local function Open(inst, pin)
	if chooser then chooser:Hide() end
	local id = DungeonMap(inst)
	if not id and OpenView(inst, pin) then return end
	if not id then
		-- no map of it at all (WoW Forever's own dungeons): its card over the world map, and down into
		-- its entrance (Close.lua), or just closer in
		portalCard = { inst }
		RefreshCard()
		local cave, u0, v0, u1, v1
		if S.CaveAt and pin.cont then cave, u0, v0, u1, v1 = S.CaveAt(pin.cont, pin.x, pin.y) end
		if cave and S.GlideToRect then S.GlideToRect(u0, v0, u1, v1, 1.1)
		elseif S.GlideToWorld then
			local _, _, zoom = mod.ViewNow()
			S.GlideToWorld(pin.u, pin.v, math.max(zoom or 1, 12))
		end
		return
	end
	local u, v, zoom = mod.ViewNow()
	returnTo = u and { u, v, zoom, maps = MapsOf(id) } or nil
	S.OpenMap(id)
end

-- the stitched map is put up again (WorldMap.lua's view reset): out of a dungeon's map, the world as
-- it was when that map was opened, else around the dungeon's entrance
function mod.ReturnView(newMapID)
	local from = (shownMap == newMapID) and lastMap or shownMap
	local r = returnTo
	returnTo = nil
	if not from or not IsDungeonMap(from) then return end
	-- (only going up out of it: a map it's part of; not the quest log or the dropdown putting up another)
	local up, steps = C_Map.GetMapInfo(from), 0
	local above = false
	while up and up.parentMapID and up.parentMapID > 0 and steps < 8 do
		if up.parentMapID == newMapID then above = true break end
		up, steps = C_Map.GetMapInfo(up.parentMapID), steps + 1
	end
	if not above then return end
	if r and r.maps[from] then return r[1], r[2], r[3] end
	local e = Index()[from]
	if e and e.u then return e.u, e.v, math.max(mod.FitZoom(newMapID) * 2, 6) end
end

local function Back()
	if view and view:IsShown() then CloseView() return end
	if map and not mod.IsStitched() then map:NavigateToParentMap() end
end

--------------------------------------------------------------------------------
-- The entrances
--------------------------------------------------------------------------------

-- a dungeon's first floors' files asked for as the cursor comes onto its entrance, so its map shows
-- at once when it's clicked (not drawn: textures set aside, the client loads their files)
local preload
local function Preload(pin)
	if not preload then
		preload = CreateFrame("Frame", nil, UIParent)
		preload:Hide()
		preload.tex = {}
	end
	local n = 0
	for _, inst in ipairs(pin.instances) do
		local floors = FloorsOf(inst)
		local f = floors and floors[1]
		for _, file in ipairs(f and f.tiles or {}) do
			n = n + 1
			preload.tex[n] = preload.tex[n] or preload:CreateTexture()
			preload.tex[n]:SetTexture(file)
		end
	end
end

local function Enter(pin)
	Preload(pin)
	GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
	for _, inst in ipairs(pin.instances) do
		GameTooltip:AddDoubleLine(S.InstanceName(inst), (Range(inst) or "") .. (inst[3] and ("  " .. L["Raid"]) or ""), 1, 0.82, 0, 1, 1, 1)
	end
	local one = #pin.instances == 1 and pin.instances[1]
	local bosses = one and (Places().bosses or {})[one[1]]
	if bosses and #bosses > 0 then GameTooltip:AddLine(L["%d bosses"]:format(#bosses), 0.8, 0.8, 0.8) end
	if one then
		GameTooltip:AddLine((DungeonMap(one) or FloorsOf(one)) and L["Click to open its map"] or L["Click to see what's inside (no map of it yet)"], 0.6, 0.6, 0.6)
	else
		GameTooltip:AddLine(L["Click to pick one and open its map"], 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

local function Chooser()
	chooser = CreateFrame("Frame", "OpenMapDungeonChooser", map)
	chooser:SetFrameStrata("DIALOG")
	chooser:EnableMouse(true)
	chooser:SetClampedToScreen(true)
	chooser.pad = { Look:Dropdown(chooser) }      -- (the game's own dropdowns' look)
	tinsert(UISpecialFrames, "OpenMapDungeonChooser")
	chooser.rows = {}
	chooser:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
	chooser:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
	chooser:SetScript("OnEvent", function(self) if not self:IsMouseOver() then self:Hide() end end)
	mod.padRoots[#mod.padRoots + 1] = chooser    -- (the gamepad's cursor presses its rows: Gamepad.lua)
	chooser:Hide()
end

local function Choose(pin)
	if not chooser then Chooser() end
	local w = 0
	for i, inst in ipairs(pin.instances) do
		local row = chooser.rows[i]
		if not row then
			row = CreateFrame("Button", nil, chooser)
			row:SetHeight(20)
			row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
			row.name = Look:Font(row:CreateFontString(nil, "OVERLAY"), 13)
			row.name:SetPoint("LEFT", 6, 0)
			row.level = Look:Font(row:CreateFontString(nil, "OVERLAY"), 13)
			row.level:SetPoint("RIGHT", -6, 0)
			row:SetScript("OnClick", function(self) Open(self.inst, chooser.pin) end)
			chooser.rows[i] = row
		end
		row.inst = inst
		row.name:SetText(("|cffffd100%s|r"):format(S.InstanceName(inst)))
		row.level:SetText((Range(inst) or "") .. (inst[3] and ("  |cffbbbbbb" .. L["Raid"] .. "|r") or ""))
		row:SetHeight(24)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", chooser.pad[1], -chooser.pad[2] - (i - 1) * 24)
		row:SetPoint("TOPRIGHT", -chooser.pad[3], -chooser.pad[2] - (i - 1) * 24)
		row:Show()
		w = math.max(w, (row.name:GetStringWidth() or 100) + (row.level:GetStringWidth() or 40) + 44)
	end
	for i = #pin.instances + 1, #chooser.rows do chooser.rows[i]:Hide() end
	chooser.pin = pin
	chooser:SetSize(math.max(200, w) + chooser.pad[1] + chooser.pad[3], #pin.instances * 24 + chooser.pad[2] + chooser.pad[4])
	chooser:ClearAllPoints()
	chooser:SetPoint("TOPLEFT", pin, "BOTTOMRIGHT", 2, 2)
	chooser:Show()
end

local function Click(pin)
	GameTooltip:Hide()
	if #pin.instances == 1 then Open(pin.instances[1], pin) else Choose(pin) end
end

-- the range of levels under the icon: from its lowest to its highest (several at one entrance)
local function Label(pin)
	local lo, hi
	for _, inst in ipairs(pin.instances) do
		if inst[4] then lo, hi = math.min(lo or 99, inst[4]), math.max(hi or 0, inst[5] or inst[4]) end
	end
	if not pin.levelText then
		pin.levelText = Look:Font(pin:CreateFontString(nil, "OVERLAY"), 10, "OUTLINE")
		pin.levelText:SetPoint("TOP", pin, "BOTTOM", 0, 3)
	end
	local code, range
	if lo and mod.LevelColor then code, range = mod.LevelColor(lo, hi) end
	pin.levelText:SetText(range and mod.db.dungeonLevels and (code .. range .. "|r") or "")
end

local function Pin(set, u, v, insts, cont, x, y)
	local raid = true
	for _, inst in ipairs(insts) do raid = raid and inst[3] end
	local pin = S.AddPin(set, u, v, raid and LOOK.raid or LOOK.dungeon)
	pin.instances, pin.cont, pin.x, pin.y = insts, cont, x, y
	pin:SetScript("OnEnter", Enter)
	pin:SetScript("OnLeave", GameTooltip_Hide)
	pin.OnClick = Click
	Label(pin)
	entrancePins[#entrancePins + 1] = pin
	return pin
end

-- the entrances: the tables' (Stitch.lua's BuildPins asks); then any the client itself knows (its
-- encounter journal's, where it has one) for a dungeon the tables give no entrance
function S.BuildDungeonPins(set)
	wipe(entrancePins)
	for _, g in ipairs(Places().instances or {}) do
		local u, v = S.EntranceAt(g)
		if u then
			if g.map then Pin(set, u, v, g[4]) else Pin(set, u, v, g[4], g[1], g[2], g[3]) end
		end
	end
	local entrances = C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap
	if entrances then
		local known = {}
		for _, g in ipairs(Places().instances or {}) do
			for _, inst in ipairs(g[4]) do known[inst[2]] = true known[S.InstanceName(inst)] = true end
		end
		local unplaced = {}
		for _, inst in ipairs(Places().unplaced or {}) do unplaced[inst[2]] = inst end
		for _, zone in ipairs(C_Map.GetMapChildrenInfo(S.WORLD, Enum.UIMapType.Zone, true) or {}) do
			local l, r, t, b = S.Rect(zone.mapID)
			local ok, list = pcall(entrances, zone.mapID)
			for _, e in ipairs(ok and l and list or {}) do
				local name = Safe.Value(e.name)
				local x, y = Safe.XY(e.position)
				if name and x and not known[name] then
					known[name] = true
					Pin(set, l + x * (r - l), t + y * (b - t), { unplaced[name] or { 0, name, false } })
				end
			end
		end
	end
	byMap = nil
	return entrancePins
end

local function Recolour()
	for _, pin in ipairs(entrancePins) do if pin.instances then Label(pin) end end
end

--------------------------------------------------------------------------------
-- Questie's quests for each dungeon (its zoneOrSort: the dungeon's area), read once
--------------------------------------------------------------------------------

local quests                    -- Questie's dungeon area -> { questID, ... } (nil: not read yet; false: it failed, tried again later)
local scanning
local dungeonOf                 -- Questie's area for part of a dungeon -> the dungeon's

local function Questie()
	local loader = _G.QuestieLoader
	if not loader then return end
	local ok, db = pcall(loader.ImportModule, loader, "QuestieDB")
	local ok2, zones = pcall(loader.ImportModule, loader, "ZoneDB")
	if ok and ok2 and db and db.QuestPointers and db.QueryQuestSingle and zones and zones.GetDungeons then return db, zones end
end

-- a dungeon's area as Questie has it: its own, the dungeon its part of belongs to
local function DungeonArea(zones, areaId)
	if not dungeonOf then
		local list = zones:GetDungeons()
		if not list then return end                 -- (Questie's zones not read yet: asked again later)
		dungeonOf = {}
		for base, e in pairs(list) do
			dungeonOf[base] = base
			for _, alt in ipairs(e[2] or {}) do dungeonOf[alt] = dungeonOf[alt] or base end
		end
	end
	return dungeonOf[areaId]
end

local function Scan(done)
	local QDB, zones = Questie()
	if not QDB or not zones:GetDungeons() then return done(false) end
	local ids = {}
	for id in pairs(QDB.QuestPointers) do ids[#ids + 1] = id end
	local found, i = {}, 0
	local function Step()
		local ok, err = pcall(function()
			for _ = 1, 500 do
				i = i + 1
				local id = ids[i]
				if not id then return end
				local z = QDB.QueryQuestSingle(id, "zoneOrSort")
				local area = z and z > 0 and DungeonArea(zones, z)
				if area then
					found[area] = found[area] or {}
					tinsert(found[area], id)
				end
			end
		end)
		if not ok then geterrorhandler()(err) return done(false) end
		if ids[i] then C_Timer.After(0, Step) else done(found) end
	end
	Step()
end

-- whether you could take it: your race and class (Questie's masks: 0 is anyone)
local function ForYou(QDB, id)
	local _, _, race = UnitRace("player")
	local _, _, class = UnitClass("player")
	local races = QDB.QueryQuestSingle(id, "requiredRaces") or 0
	local classes = QDB.QueryQuestSingle(id, "requiredClasses") or 0
	if race and races ~= 0 and bit.band(races, 2 ^ (race - 1)) == 0 then return false end
	if class and classes ~= 0 and bit.band(classes, 2 ^ (class - 1)) == 0 then return false end
	return true
end

local areaOf = {}                -- dungeon map -> Questie's area for it (false: none; Questie's lookup is slow on a miss)

-- Questie's quests read, once (then `after`); again later if its database wasn't ready
EnsureQuests = function(after)
	if quests ~= nil or scanning or not Questie() then return end
	scanning = true
	Scan(function(found)
		scanning = false
		quests = found or false
		-- (Questie's database still loading, most likely: once more in a while)
		if not found then C_Timer.After(15, function() if quests == false then quests = nil after() end end) end
		C_Timer.After(0, after)
	end)
end

-- a dungeon's quests you could take, by level: { id, name, level, done, inLog }; nil while unknown
QuestList = function(mapID, inst)
	local QDB, zones = Questie()
	if not QDB or not quests then return end
	local key = mapID or (inst and inst[2])
	if not key then return end
	local area = areaOf[key]
	if area == nil then
		if mapID then
			local ok, found = pcall(zones.GetAreaIdByUiMapId, zones, mapID)
			area = ok and found and DungeonArea(zones, found)
		end
		if not area then
			local info = mapID and C_Map.GetMapInfo(mapID)
			local name = info and info.name or (inst and S.InstanceName(inst))
			local ok2, byName = pcall(zones.GetAreaIdByName, zones, name)
			area = ok2 and byName and DungeonArea(zones, byName)
		end
		areaOf[key] = area or false
	end
	local list = {}
	for _, id in ipairs(area and quests[area] or {}) do
		if ForYou(QDB, id) then
			list[#list + 1] = { id = id, name = QDB.QueryQuestSingle(id, "name") or "?", level = QDB.QueryQuestSingle(id, "questLevel") or 0 }
		end
	end
	table.sort(list, function(a, b) if a.level ~= b.level then return a.level < b.level end return a.name < b.name end)
	for _, q in ipairs(list) do
		q.done = C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(q.id) or false
		q.inLog = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(q.id) and true or false
	end
	return list
end

local function QuestColour(q)
	local c = q.level > 0 and GetQuestDifficultyColor(q.level)
	return q.done and "|cff808080" or c and ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) or "|cffffffff"
end

local function QuestLines(mapID, inst)
	local list = QuestList(mapID, inst)
	if not list then return end
	local lines = {}
	for _, q in ipairs(list) do
		local done, inLog = q.done, q.inLog
		local c = q.level > 0 and GetQuestDifficultyColor(q.level)
		local code = done and "|cff808080" or c and ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) or "|cffffffff"
		lines[#lines + 1] = ("%s[%d] %s|r%s"):format(code, q.level, q.name,
			done and ("  |cff808080" .. L["done"] .. "|r") or inLog and ("  |cff80f070" .. L["in your log"] .. "|r") or "")
	end
	return lines
end

--------------------------------------------------------------------------------
-- The card on a dungeon's map
--------------------------------------------------------------------------------


local function Card()
	card = CreateFrame("Frame", nil, map)
	card:SetWidth(CARD_W)
	card:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -8, -8)
	card:SetFrameLevel(math.min(sc:GetFrameLevel() + 9300, 9950))
	card:EnableMouse(true)
	Look:Panel(card, { alpha = 0.92 })
	mod.padRoots[#mod.padRoots + 1] = card
	local back = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
	back:SetSize(56, 20)
	back:SetPoint("TOPLEFT", 6, -6)
	back:SetText(L["Back"])
	back:SetScript("OnClick", Back)
	back:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L["Back to the world map, where you were (or right-click the map, or scroll out)"], 1, 1, 1, true)
		GameTooltip:Show()
	end)
	back:SetScript("OnLeave", GameTooltip_Hide)
	card.back = back
	card.close = CreateFrame("Button", nil, card, "UIPanelCloseButton")
	card.close:SetSize(24, 24)
	card.close:SetPoint("TOPRIGHT", 0, 0)
	card.close:SetScript("OnClick", function() portalCard = nil RefreshCard() end)
	card.fold = CreateFrame("Button", nil, card)
	card.fold:SetSize(18, 18)
	card.fold:SetPoint("TOPRIGHT", -26, -5)
	card.fold.icon = card.fold:CreateTexture(nil, "ARTWORK")
	card.fold.icon:SetAllPoints()
	card.fold:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	card.fold:SetScript("OnClick", function()
		mod.db.dungeonCard = not mod.db.dungeonCard
		RefreshCard()
	end)
	card.title = Look:Font(card:CreateFontString(nil, "OVERLAY"), 13)
	card.title:SetPoint("TOP", 0, -9)
	card.title:SetPoint("LEFT", back, "RIGHT", 8, 0)
	card.title:SetPoint("RIGHT", card.fold, "LEFT", -4, 0)
	card.title:SetJustifyH("LEFT")
	card.title:SetWordWrap(false)
	card.scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
	card.scroll:SetPoint("TOPLEFT", 10, -32)
	card.scroll:SetPoint("BOTTOMRIGHT", -28, 8)
	card.child = CreateFrame("Frame", nil, card.scroll)
	card.child:SetWidth(CARD_W - 40)
	card.text = Look:Font(card.child:CreateFontString(nil, "OVERLAY"), 12)
	card.text:SetPoint("TOPLEFT")
	card.text:SetWidth(CARD_W - 40)
	card.text:SetJustifyH("LEFT")
	card.text:SetSpacing(2)
	card.scroll:SetScrollChild(card.child)
	card:Hide()
end

local cardMap                   -- the dungeon map the card was last filled for (API.lua's callbacks)

-- what a dungeon map is, for other addons (API.lua): { mapID, instances = { { name, minLevel,
-- maxLevel, raid, bosses = { name, ... } }, ... } }
local function Info(mapID, insts)
	local list = {}
	for _, inst in ipairs(insts) do
		local bosses = {}
		for i, b in ipairs((Places().bosses or {})[inst[1]] or {}) do bosses[i] = b end
		list[#list + 1] = { name = S.InstanceName(inst), minLevel = inst[4], maxLevel = inst[5], raid = inst[3] and true or false, bosses = bosses }
	end
	return { mapID = mapID, instances = list }
end

RefreshCard = function()
	if not map then return end
	local mapID = map:GetMapID()
	-- on a dungeon's map; or over the world map, for a dungeon the client has no map of (its portal clicked)
	local onView = map:IsShown() and view and view:IsShown() or false
	local onMap = not onView and map:IsShown() and not mod.IsStitched() and IsDungeonMap(mapID)
	local onWorld = not onView and not onMap and map:IsShown() and mod.IsStitched() and portalCard ~= nil
	if not onMap and cardMap then
		cardMap = nil
		if mod.OnDungeonMap then mod.OnDungeonMap(nil) end
	end
	if onView or (not onMap and not onWorld) then
		if card then card:Hide() end
		if onView then FillSide() end
		return
	end
	if not card then Card() end
	local insts
	if onMap then
		local e = Index()[mapID]
		insts = e and e.insts or {}
	else
		insts = onView and { view.inst } or portalCard
		mapID = nil
	end
	local info = Info(mapID, insts)
	if onMap and cardMap ~= mapID then
		cardMap = mapID
		if mod.OnDungeonMap then mod.OnDungeonMap(info) end
	end
	local back = onMap or onView
	card.back:SetShown(back)
	card.close:SetShown(onWorld)
	card.title:SetPoint("LEFT", back and card.back or card, back and "RIGHT" or "LEFT", back and 8 or 10, 0)
	local head = {}
	for _, inst in ipairs(insts) do head[#head + 1] = S.InstanceName(inst) .. (Range(inst) and ("  " .. Range(inst)) or "") end
	local mapInfo = mapID and C_Map.GetMapInfo(mapID)
	card.title:SetText(#head > 0 and ("|cffffd100" .. table.concat(head, ", ") .. "|r") or ("|cffffd100" .. (mapInfo and mapInfo.name or "") .. "|r"))
	local open = mod.db.dungeonCard
	card.fold.icon:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
	local lines = {}
	if open and mod.db.dungeonBosses and insts[1] then
		local bosses = (Places().bosses or {})[insts[1][1]]
		if bosses and #bosses > 0 then
			lines[#lines + 1] = "|cffe6c27a" .. L["Bosses"] .. "|r"
			for i, name in ipairs(bosses) do lines[#lines + 1] = ("|cff998866%d.|r %s"):format(i, name) end
		end
	end
	if open and mod.db.dungeonQuests then
		EnsureQuests(RefreshCard)
		local q = QuestLines(mapID, insts[1])
		if q and #q > 0 then
			if #lines > 0 then lines[#lines + 1] = " " end
			lines[#lines + 1] = "|cffe6c27a" .. L["Quests"] .. "|r  |cff998866(Questie)|r"
			for _, line in ipairs(q) do lines[#lines + 1] = line end
		elseif scanning then
			lines[#lines + 1] = "|cff998866" .. L["Reading Questie's quests..."] .. "|r"
		end
	end
	-- other addons' sections (API.lua): a title and lines of their own, after ours
	if open and mod.CardSections then
		for _, section in ipairs(mod.CardSections()) do
			local ok, title, extra = pcall(section, info)
			if not ok then geterrorhandler()(title)
			elseif type(title) == "string" and type(extra) == "table" and #extra > 0 then
				if #lines > 0 then lines[#lines + 1] = " " end
				lines[#lines + 1] = "|cffe6c27a" .. title .. "|r"
				for i = 1, math.min(#extra, 40) do lines[#lines + 1] = tostring(extra[i]) end
			end
		end
	end
	card.text:SetText(table.concat(lines, "\n"))
	local h = #lines > 0 and math.min((card.text:GetStringHeight() or 0) + 4, math.max(80, sc:GetHeight() - 120)) or 0
	card.child:SetHeight((card.text:GetStringHeight() or 0) + 4)
	card.scroll:SetShown(#lines > 0)
	card:SetHeight(h > 0 and h + 42 or 32)
	card:Show()
end
-- the view's side panel: rows of one tab (bosses, quests, loot), each made as needed and kept
local function NeedRoll() return SlashCmdList and SlashCmdList.NEEDROLL end
-- NeedRoll's window: at this dungeon (and `boss`) if NeedRoll offers a call for it, else just opened
-- (its /nr toggles: an open window is only brought up, not closed)
local function OpenNeedRoll(boss)
	local show = _G.NeedRoll_ShowLoot
	if type(show) == "function" and view and view.inst then
		local ok, done = pcall(show, S.InstanceName(view.inst), boss)
		if ok and done then return end
	end
	for _, name in ipairs({ "NeedRollFrame", "NeedRollNativeFrame" }) do
		local f = _G[name]
		if f and f.IsShown and f:IsShown() then
			if f.Raise then f:Raise() end
			return
		end
	end
	local open = NeedRoll()
	if open then pcall(open, "") end
end

FillSide = function()
	if not view or not view.side or not view:IsShown() then return end
	local side, inst = view.side, view.inst
	side.title:SetText("|cffffd100" .. S.InstanceName(inst) .. "|r")
	side.sub:SetText((Range(inst) and (LEVEL or "Level") .. " " .. Range(inst) or "") .. (inst[3] and ("   |cffbbbbbb" .. L["Raid"] .. "|r") or ""))
	-- the tabs there are (the menu's switches), the one shown
	local shown = { bosses = mod.db.dungeonBosses, quests = mod.db.dungeonQuests, loot = true,
		floors = view.floors and #view.floors > 1 }   -- (a dungeon of several floors: each as a picture)
	local tab = mod.db.dungeonTab
	if not shown[tab] then tab = shown.floors and "floors" or shown.bosses and "bosses" or shown.quests and "quests" or "loot" end
	local tx = 8
	for _, b in ipairs(side.tabs) do
		b:SetShown(shown[b.key] and true or false)
		if shown[b.key] then
			b:ClearAllPoints()
			b:SetPoint("BOTTOMLEFT", b:GetParent(), "TOPLEFT", tx, -INNER_TABS)
			tx = tx + b:GetWidth() + 2
		end
		if b.SetSelected then b:SetSelected(b.key == tab) elseif b.key == tab then b:LockHighlight() else b:UnlockHighlight() end
	end
	-- what to show: { kind = "row" | "text" | "button" | "link", ... }
	local items = {}
	local function Text(t) items[#items + 1] = { kind = "text", t } end
	if tab == "bosses" then
		local bosses = (Places().bosses or {})[inst[1]] or {}
		for i, name in ipairs(bosses) do
			items[#items + 1] = { kind = "row", ("|cff998866%d.|r  %s"):format(i, name), click = NeedRoll() and function() OpenNeedRoll(name) end,
				tip = function(owner)
					GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
					GameTooltip:AddLine(name, 1, 0.82, 0)
					GameTooltip:AddLine(NeedRoll() and L["Click to see loot in NeedRoll"] or L["See the Loot tab for loot"], 0.6, 0.6, 0.6)
					GameTooltip:Show()
				end }
		end
		if #bosses == 0 then Text("|cff998866" .. L["The game lists no bosses for it."] .. "|r") end
		-- other addons' sections (API.lua)
		for _, section in ipairs(mod.CardSections and mod.CardSections() or {}) do
			local ok, title, lines = pcall(section, Info(nil, { inst }))
			if not ok then geterrorhandler()(title)
			elseif type(title) == "string" and type(lines) == "table" and #lines > 0 then
				Text(" ")
				Text("|cffe6c27a" .. title .. "|r")
				for i = 1, math.min(#lines, 40) do Text(tostring(lines[i])) end
			end
		end
	elseif tab == "quests" then
		if not Questie() then
			Text("|cff998866" .. L["With Questie, the quests for this dungeon are listed here."] .. "|r")
		else
			EnsureQuests(FillSide)
			local list = QuestList(nil, inst)
			if not list then Text("|cff998866" .. L["Reading Questie's quests..."] .. "|r")
			elseif #list == 0 then Text("|cff998866" .. L["Questie lists no quests for it that you can take."] .. "|r")
			else
				local QDB = Questie()
				for _, q in ipairs(list) do
					items[#items + 1] = { kind = "row", ("%s[%d] %s|r"):format(QuestColour(q), q.level, q.name),
						right = q.done and ("|cff808080" .. L["done"] .. "|r") or q.inLog and ("|cff80f070" .. L["in your log"] .. "|r") or nil,
						tip = function(owner)
							GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
							GameTooltip:AddLine(q.name, 1, 0.82, 0, true)
							local okText, text = pcall(QDB.QueryQuestSingle, q.id, "objectivesText")
							if okText and type(text) == "table" then
								for _, line in ipairs(text) do GameTooltip:AddLine(line, 1, 1, 1, true) end
							end
							local okReq, req = pcall(QDB.QueryQuestSingle, q.id, "requiredLevel")
							GameTooltip:AddLine((LEVEL or "Level") .. " " .. q.level .. (okReq and req and req > 0 and ("  (" .. L["from %d"]:format(req) .. ")") or ""), 0.8, 0.8, 0.8)
							GameTooltip:AddLine(q.done and L["Done"] or q.inLog and L["In your quest log"] or "", 0.5, 0.95, 0.4)
							GameTooltip:Show()
						end }
				end
			end
		end
	elseif tab == "floors" then
		for i = 1, #view.floors do items[#items + 1] = { kind = "thumb", floor = i } end
	else
		if NeedRoll() then
			Text(L["NeedRoll lists this dungeon's loot: what every boss drops, what you've collected, and a wishlist."])
			items[#items + 1] = { kind = "button", L["Open NeedRoll"], click = function() OpenNeedRoll() end }
		else
			Text(L["For loot, we recommend |cffffd100NeedRoll|r, by mikebvs: what every boss drops, what you've collected, and a wishlist, made for WoW Forever."])
			Text("|cff998866" .. L["Get it from CurseForge (click, then Ctrl-C):"] .. "|r")
			items[#items + 1] = { kind = "link", NEEDROLL_URL }
		end
	end
	-- lay them out
	for _, pool in pairs(side.pool) do for _, w in ipairs(pool) do w:Hide() end end
	local used = { row = 0, text = 0, button = 0, link = 0, thumb = 0 }
	side.filledW = side:GetWidth()
	local listW = side.scroll:GetWidth()
	local width, y = (listW and listW > 100) and (listW - 4) or (SIDE_W - LOG_BAR - 12), 0
	side.child:SetWidth(width)
	for _, it in ipairs(items) do
		used[it.kind] = used[it.kind] + 1
		local w = side.pool[it.kind][used[it.kind]]
		if not w then
			if it.kind == "row" then
				w = CreateFrame("Button", nil, side.child)
				w:SetHeight(24)
				w:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
				w.left = Look:Font(w:CreateFontString(nil, "OVERLAY"), 13)
				w.left:SetPoint("LEFT", 4, 0)
				w.left:SetJustifyH("LEFT")
				w.left:SetWordWrap(false)
				w.right = Look:Font(w:CreateFontString(nil, "OVERLAY"), 11)
				w.right:SetPoint("RIGHT", -4, 0)
				w.left:SetPoint("RIGHT", w.right, "LEFT", -6, 0)
				w:SetScript("OnEnter", function(self) if self.item.tip then self.item.tip(self) end end)
				w:SetScript("OnLeave", GameTooltip_Hide)
				w:SetScript("OnClick", function(self) if self.item.click then self.item.click() end end)
			elseif it.kind == "text" then
				w = Look:Font(side.child:CreateFontString(nil, "OVERLAY"), 13)
				w:SetJustifyH("LEFT")
				w:SetSpacing(3)
			elseif it.kind == "button" then
				w = CreateFrame("Button", nil, side.child, "UIPanelButtonTemplate")
				w:SetSize(150, 26)
				w:SetScript("OnClick", function(self) if self.item.click then self.item.click() end end)
			elseif it.kind == "thumb" then
				-- a floor's picture, small (its 12 tiles), its name under it; click: that floor
				w = CreateFrame("Button", nil, side.child, "BackdropTemplate")
				w:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
				w:SetBackdropColor(0.05, 0.04, 0.03, 0.9)
				w.tiles = {}
				for k = 1, 12 do w.tiles[k] = w:CreateTexture(nil, "ARTWORK") end
				local hl = w:CreateTexture(nil, "HIGHLIGHT")
				hl:SetPoint("TOPLEFT", 1, -1)
				hl:SetPoint("BOTTOMRIGHT", -1, 1)
				hl:SetColorTexture(1, 0.85, 0.5, 0.15)
				w.name = Look:Font(w:CreateFontString(nil, "OVERLAY"), 11)
				w.name:SetPoint("TOP", w, "BOTTOM", 0, -3)
				w.name:SetWordWrap(false)
				w:SetScript("OnClick", function(self) ShowFloor(self.item.floor) end)
			else
				w = CreateFrame("EditBox", nil, side.child, "InputBoxTemplate")
				w:SetSize(width - 12, 22)
				w:SetAutoFocus(false)
				w:SetScript("OnTextChanged", function(self, user) if user then self:SetText(self.item[1]) self:HighlightText() end end)
				w:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
				w:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
			end
			side.pool[it.kind][used[it.kind]] = w
		end
		w.item = it
		w:ClearAllPoints()
		if it.kind == "row" then
			w:SetPoint("TOPLEFT", 0, -y)
			w:SetWidth(width)
			w.left:SetText(it[1])
			w.right:SetText(it.right or "")
			y = y + 24
		elseif it.kind == "text" then
			w:SetPoint("TOPLEFT", 4, -y - 4)
			w:SetWidth(width - 8)
			w:SetText(it[1])
			y = y + (w:GetStringHeight() or 14) + 10
		elseif it.kind == "button" then
			w:SetPoint("TOPLEFT", 4, -y - 2)
			w:SetText(it[1])
			y = y + 34
		elseif it.kind == "thumb" then
			-- (two across: the second beside the first, then on down)
			local tw = math.floor((width - 10) / 2)
			local th = math.floor(tw * PIC_H / PIC_W)
			local col = (used.thumb - 1) % 2
			w:SetSize(tw, th)
			w:SetPoint("TOPLEFT", 2 + col * (tw + 6), -y - 2)
			local s = (tw - 2) / PIC_W
			local f = view.floors[it.floor]
			for k, t in ipairs(w.tiles) do
				local c, r = (k - 1) % 4, math.floor((k - 1) / 4)
				local cw, ch = math.min(256, PIC_W - c * 256), math.min(256, PIC_H - r * 256)
				t:SetTexture(f.tiles and f.tiles[k], nil, nil, "TRILINEAR")
				t:SetSize(cw * s, ch * s)
				t:SetPoint("TOPLEFT", 1 + c * 256 * s, -1 - r * 256 * s)
				t:SetTexCoord(0, cw / 256, 0, ch / 256)
			end
			w.name:SetWidth(tw)
			w.name:SetText(view.FloorName(it.floor))
			if col == 1 or it.floor == #view.floors then y = y + th + 22 end
		else
			w:SetPoint("TOPLEFT", 10, -y - 2)
			w:SetText(it[1])
			w:SetCursorPosition(0)
			y = y + 30
		end
		w:Show()
	end
	side.child:SetHeight(math.max(1, y))
	side.scroll:SetVerticalScroll(0)
	side.LightThumbs()
end

mod.RefreshDungeonCard = function() Recolour() RefreshCard() FillSide() end   -- (settings changed: mod:Refresh)

-- /openmap dungeons: which map each entrance opens (none: the client has no map of it by that name)
function mod:DungeonDiag()
	local found, total = 0, 0
	for _, g in ipairs(Places().instances or {}) do
		for _, inst in ipairs(g[4]) do
			total = total + 1
			local id = DungeonMap(inst)
			local info = id and C_Map.GetMapInfo(id)
			if id then found = found + 1 end
			ns:Print(("%s: %s"):format(S.InstanceName(inst), id and ("map %d, %s"):format(id, info and info.name or "?") or "|cffff6060no map|r"))
		end
	end
	ns:Print(("Dungeon maps: %d of %d entrances open one."):format(found, total))
end

--------------------------------------------------------------------------------
-- /openmap entrance <name>: where you stand, as the line for build.py's ENTRANCES
--------------------------------------------------------------------------------

function mod:Entrance(name)
	name = name and strtrim(name) or ""
	if name == "" then
		ns:Print(L["Stand in the portal and say which: /openmap entrance Dire Maul - East (the name as OpenMap lists it)."])
		return
	end
	local mapID = C_Map.GetBestMapForUnit and Safe.Call(C_Map.GetBestMapForUnit, "player")
	local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
	local x, y = Safe.XY(pos)
	local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
	local wx, wy = Safe.XY(world)
	if not (x and ok and wx and S.Rect(mapID)) then
		ns:Print(L["Where you are isn't on the world map here."])
		return
	end
	-- the tables' order of the two (S.FromYards'): the one that lands where you are
	local u, v = mod.ToWorld(mapID, x, y)
	local best, bestD
	for _, try in ipairs({ { wx, wy }, { wy, wx } }) do
		local tu, tv = S.FromYards(cont, try[1], try[2])
		local dist = tu and ((tu - u) ^ 2 + (tv - v) ^ 2)
		if dist and (not bestD or dist < bestD) then best, bestD = try, dist end
	end
	if not best then
		ns:Print(L["Where you are isn't on the world map here."])
		return
	end
	local line = ('"%s": [(%d, %.1f, %.1f)],'):format(name, cont, best[1], best[2])
	tinsert(mod.db.entrances, line)
	ns:Print(line)
	ns:Print(L["Saved too (OpenMapDB: worldmap, entrances) once you /reload or log out."])
end

--------------------------------------------------------------------------------

function mod:DungeonOptions(opts, get, set, off)
	opts.dungeonBosses = { type = "toggle", name = L["Dungeon maps: bosses"], order = 31.1, width = "full", get = get, set = set, disabled = off,
		desc = L["A dungeon's map lists its bosses, in the game's order."] }
	opts.dungeonLevels = { type = "toggle", name = L["Dungeon level ranges"], order = 31.05, width = "full", get = get, set = set, disabled = off,
		desc = L["Each dungeon entrance's level range under its icon, coloured for your level."] }
	opts.dungeonQuests = { type = "toggle", name = L["Dungeon maps: quests (Questie)"], order = 31.2, width = "full", get = get, set = set, disabled = off,
		desc = L["A dungeon's map lists the quests for it that you can take, from Questie's database, marked done or in your log."] }
end

function mod:SetupDungeons(worldMap)
	map, sc = worldMap, worldMap.ScrollContainer
	-- (the map before this one: the event comes before Blizzard resets the view, so ReturnView knows it)
	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback("MapCanvas.MapSet", function(_, mapID)
			if sc.mapID == mapID and mapID ~= shownMap then lastMap, shownMap = shownMap, mapID end
		end, mod)
	end
	hooksecurefunc(map, "OnMapChanged", function()
		-- (the stitched map's own switch underneath, a moment after the view stopped: it stays; it closed
		-- a dungeon's map clicked just after zooming in)
		if not (S.Switching and S.Switching()) then
			if chooser then chooser:Hide() end
			if view and view:IsShown() then view:Hide() end   -- (another map put up: the quest log, the dropdown)
		end
		RefreshCard()
	end)
	-- the quest log opened or closed over a dungeon's map: the side panel into it (its tab picked) or out
	local function Redock(pick)
		if not (view and view:IsShown()) then return end
		if pick then view.dockTab = view.wantTab or "dungeon" end   -- (opened from one of the tabs: that one)
		Dock()
		FillSide()
	end
	if map.QuestLog then
		map.QuestLog:HookScript("OnShow", function() Redock(true) end)
		map.QuestLog:HookScript("OnHide", function() Redock(false) end)
	end
	for _, method in ipairs({ "Maximize", "Minimize" }) do
		if map[method] then hooksecurefunc(map, method, function() C_Timer.After(0, function() Redock(false) end) end) end
	end
	map:HookScript("OnShow", RefreshCard)
	map:HookScript("OnHide", function()
		returnTo, shownMap, lastMap, portalCard = nil, nil, nil, nil
		if chooser then chooser:Hide() end
		if view then view:Hide() end
		RefreshCard()                               -- (the map's gone: the card too, and other addons told)
	end)
	-- the wheel past all the way out on a dungeon's map: back to the world
	sc:HookScript("OnMouseWheel", function(_, delta)
		if delta < 0 and not mod.IsStitched() and IsDungeonMap(map:GetMapID()) and sc:IsAtMinZoom() and not sc:IsZoomingOut() then Back() end
	end)
	-- (a resize: the card's height once the drag's frame is done, not on every size change in it)
	local sizing = false
	sc:HookScript("OnSizeChanged", function()
		if sizing or not (card and card:IsShown()) then return end
		sizing = true
		C_Timer.After(0, function() sizing = false RefreshCard() end)
	end)
	local events = {}
	ns.RegisterEvent(events, "PLAYER_LEVEL_UP", function()
		C_Timer.After(0, function() Recolour() RefreshCard() end)   -- (UnitLevel catches up after the event)
	end)
	ns.RegisterEvent(events, "QUEST_TURNED_IN", function() if card and card:IsShown() then C_Timer.After(0.5, RefreshCard) end end)
end
