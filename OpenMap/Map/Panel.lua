--------------------------------------------------------------------------------
-- The map's menu: the OpenMap button in the map's bottom-left corner opens a floating
-- panel in the map window's own frame (its metal border; bronze edges and rules): search,
-- the actions (find me, drop a pin, the quest log, report a problem, options), the
-- checklist of what the map shows, and the deepest zoom. Drag it by its body; it remembers
-- where it was and whether it was open. A star on an action or a setting puts it on the
-- map as a button of its own, in the row beside the OpenMap button (favourites); the arrow
-- beside the OpenMap button folds that row away and back. Or (tabRail) all of them as tabs at
-- the window's edge, the favourites up from the OpenMap tab: the rail, below.
--------------------------------------------------------------------------------

local _, ns = ...
local mod = ns:GetModule("worldmap")
local S = ns.MapStitch
local L = ns.L

local d = mod.defaults
d.menuPos = false               -- { left, top, screen = true } on the screen once dragged (one on the map, from before: dropped)
d.menuOpen = false
d.menuTab = "show"              -- the checklist's tab (TABS)
d.favorites = {}                -- action and row ids, in the order they were starred: a button each on the map
d.trayOpen = true               -- the favourites' row shown (the arrow beside the OpenMap button folds it)
d.trayStarted = false           -- the first favourites given, once (a fresh install's, or one with none yet)
d.tabRail = true                -- the OpenMap button and the favourites as tabs at the window's edge (off: a row in its bottom-left corner)
d.mapButtons = true             -- the OpenMap button and the favourites on the map at all (off: none; /openmap opens the menu)
local TRAY_START = { "find", "pin", "quill" }

local map, sc, menu, toggle, trayArrow, checks, favBar, tiles, zoomRow, miniRow, opacityRow
local W, PAD, COL = 500, 16, 226   -- (two columns of COL, 16 apart, inside the padding)
local BAR_X, BAR_Y = 14, 14     -- the OpenMap button's corner: the map's bottom left (room for its slot's frame)
local TOGGLE = 36               -- the OpenMap button (an action button's size)
local FAV = 30                  -- a favourite's button
local TILE_H = 60               -- an action's tile in the menu (room for a label on two lines)
local BRONZE = { 0.66, 0.49, 0.28 }
local LIT = { 1, 0.82, 0.3 }
local HEAD = { 0.96, 0.80, 0.50 }
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"   -- (the raid marker's star: every client has it)

local function HasAtlas(name)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) and true or false
end

-- Blizzard's icons for the menu (an atlas this client lacks falls back to the texture: S.Look).
-- Returns whether it's a square spell icon (framed like an action button) or a map symbol.
local function Icon(name) return { texture = "Interface\\Icons\\" .. name, icon = true } end
local function SetIcon(tex, look)
	S.Look(tex, look)
	local atlas = look.atlas and (not C_Texture or not C_Texture.GetAtlasInfo or C_Texture.GetAtlasInfo(look.atlas))
	local square = look.icon and not atlas
	if square then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end   -- (the spell icons' own frame cut off)
	return square and true or false
end
local OPENMAP_ICON = Icon("Achievement_Zone_EasternKingdoms_01")

-- Blizzard's action-button frame round `tex` (`size` square): this client's, with its rounded
-- mask on the icon, else the classic slot's
local FRAME_ATLAS = "UI-HUD-ActionBar-IconFrame"
local function IconBorder(owner, tex, size, classic)
	local border = owner:CreateTexture(nil, "OVERLAY")
	if not classic and HasAtlas(FRAME_ATLAS) then
		border:SetAtlas(FRAME_ATLAS)
		border:SetAllPoints(tex)
		if HasAtlas(FRAME_ATLAS .. "-Mask") then
			local mask = owner:CreateMaskTexture()
			mask:SetAtlas(FRAME_ATLAS .. "-Mask")
			mask:SetAllPoints(tex)
			tex:AddMaskTexture(mask)
		end
	else
		border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
		local o = size * 14 / 36                -- (the slot art: 64 px round a 36 px button)
		border:SetPoint("TOPLEFT", tex, "TOPLEFT", -o, o)
		border:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", o, -o)
	end
	return border
end

-- an icon in that frame, on a dark slot (a map symbol sits a little smaller, in the middle);
-- place it by icon.slot
local function FramedIcon(owner, size, classic)
	local slot = owner:CreateTexture(nil, "BACKGROUND", nil, 1)
	slot:SetSize(size, size)
	slot:SetColorTexture(0, 0, 0, 0.6)
	local icon = owner:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("CENTER", slot)
	icon.slot, icon.size = slot, size
	IconBorder(owner, slot, size, classic)
	return icon
end

local function ShowIcon(icon, look)
	local square = SetIcon(icon, look)
	icon.square = square                        -- (a square picture fills a tab's face: FaceSideTab)
	local s = square and icon.size or math.floor(icon.size * 0.78 + 0.5)
	icon:SetSize(s, s)
end

local function Tip(owner, anchor, title, ...)
	GameTooltip:SetOwner(owner, anchor)
	GameTooltip:AddLine(title, LIT[1], LIT[2], 0)
	for i = 1, select("#", ...) do
		local line = select(i, ...)
		if line then GameTooltip:AddLine(line[1], line[2] or 1, line[3] or 1, line[4] or 1, true) end
	end
	GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- The quest log beside the map (Blizzard's side panel): opened and closed as its own
-- button does, never in combat (it lays the window out again)
--------------------------------------------------------------------------------

local function QuestLogShown()
	if map.IsSidePanelShown then return map:IsSidePanelShown() and true or false end
	return map.QuestLog and map.QuestLog:IsShown() or false
end

local function ToggleQuestLog()
	if InCombatLockdown() then
		ns:Print(L["The quest log can't be opened or closed in combat."])
		return
	end
	-- (full screen: Blizzard's toggle would leave it; Window.lua shows it over the map instead)
	if mod.MaxQuestLog and mod.MaxQuestLog() then mod.ToggleMaxQuestLog() return end
	map:HandleUserActionToggleSidePanel()
	if map.SidePanelToggle and map.SidePanelToggle.Refresh then map.SidePanelToggle:Refresh() end
end

--------------------------------------------------------------------------------
-- What the menu offers
--------------------------------------------------------------------------------

-- the actions: { label, id =, icon =, tip =, run = fn(mouseButton), lit = fn (optional: it's on),
-- right = true (it takes right-clicks itself) }
local function Actions()
	local list = {
		{ L["Find me"], id = "find", icon = Icon("Ability_Hunter_SniperShot"),   -- (a crosshair)
			 tip = L["Glide to where you are. Middle-click the map to center on you at the current zoom."],
			run = function() mod:FindMe() end },
		{ L["Drop a pin"], id = "pin", icon = { atlas = "Waypoint-MapPin-Tracked", texture = "Interface\\Icons\\INV_Misc_Map_01" },
			tip = L["Click, then click the map to add a map pin, with a note if you like (Ctrl-click the map does it any time). Right-click: stop following the waypoint."],
			run = function(button)
				if button == "RightButton" then
					mod.SetPinMode(false)
					if mod.ClearPin then mod.ClearPin() end
				else
					mod.SetPinMode(not mod.PinMode())
				end
			end,
			lit = function() return mod.PinMode() end, right = true },
		{ L["Pins"], id = "pins", icon = Icon("INV_Misc_Map_01"),
			tip = L["Every map pin: go to one, share them, or add pins from a code someone gave you."],
			run = function() mod:TogglePins() end, lit = function() return mod.PinsShown and mod.PinsShown() end },
		{ L["Quill"], id = "quill", icon = Icon("INV_Feather_04"),
			tip = L["Draw on the map in ink: lines, arrows, rings and raid marks, kept for you. A map pin's card can draw on that pin."],
			run = function() if mod.ToggleSketch then mod:ToggleSketch() end end, lit = function() return mod.IsSketching and mod:IsSketching() end },
	}
	if map and map.HandleUserActionToggleSidePanel then
		list[#list + 1] = { L["Quest log"], id = "questlog", icon = Icon("INV_Misc_Book_08"),
			tip = L["Show or hide the quest log beside the map, for more room for the map."],
			run = ToggleQuestLog, lit = QuestLogShown }
	end
	list[#list + 1] = { L["Report a problem"], id = "report", icon = Icon("INV_Misc_Note_01"),
		tip = L["OpenMap is in beta: draw on the map where something looks wrong (a dungeon's map too) and tell us about it."],
		run = function() mod:ToggleReport() end, lit = function() return mod.IsReporting and mod.IsReporting() end }
	list[#list + 1] = { L["What's new"], id = "news", icon = Icon("INV_Scroll_03"),
		tip = L["This version's changes (it glows after an update until you've looked)."],
		run = function() mod:ToggleNews() end, lit = function() return mod.NewsUnseen and mod.NewsUnseen() end }
	return list
end

-- the checklist's tabs: what the map shows, how it looks, and the rest (TABS[i].key; a header row
-- names its tab, and the rows after it are in it)
local TABS = {
	{ key = "show", name = L["On the map"] },
	{ key = "look", name = L["Look"] },
	{ key = "more", name = L["More"] },
}

-- the checklist: { header, tab = } or { label, get, set, id = a name for it that doesn't change
-- (favourites), icon = }
local function Rows()
	local db = mod.db
	local function opt(key) return function() return db[key] end, function(v) db[key] = v mod:Refresh() end end
	local function row(label, id, icon, get, set) return { label, get, set, id = id, icon = icon } end
	local function optRow(label, key, icon) local get, set = opt(key) return row(label, key, icon, get, set) end
	local faction = ns.Safe.Call(UnitFactionGroup, "player")
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	local questie = loaded and loaded("Questie")
	local rows = {
		-- on the map
		{ L["Places"], tab = "show" },
		optRow(L["Dungeons, boats, zeppelins"], "icons", { atlas = "dungeon", texture = "Interface\\Icons\\INV_Misc_Key_13", icon = true }),
		optRow(L["Flight masters"], "flight", { atlas = faction == "Horde" and "TaxiNode_Horde" or "TaxiNode_Alliance",
			texture = "Interface\\Icons\\Ability_Mount_Wyvern_01", icon = true }),
		optRow(L["Boat and zeppelin routes"], "routes", { atlas = "Ships_CargoShip-Map", texture = "Interface\\Icons\\INV_Misc_Spyglass_02", icon = true }),
		optRow(L["Party and raid members"], "group", Icon("Spell_Holy_PrayerOfFortitude")),
		optRow(L["Your drawings"], "sketchShown", Icon("INV_Feather_04")),
	}
	-- Questie's quest icons: its own "Enable Map Icons" setting, switched as its options do
	if questie then
		local function profile() return _G.Questie and Questie.db and Questie.db.profile end
		rows[#rows + 1] = row(L["Questie icons"], "questie", { texture = "Interface\\GossipFrame\\AvailableQuestIcon" },
			function() local p = profile() return p and p.enableMapIcons end,
			function(v)
				local p = profile()
				local loader = _G.QuestieLoader
				local quests = loader and loader.ImportModule and loader:ImportModule("QuestieQuest")
				if not p or not quests or not quests.ToggleNotes then return end
				p.enableMapIcons = v
				quests:ToggleNotes(v)
			end)
	end
	rows[#rows + 1] = { L["Dungeons"] }
	rows[#rows + 1] = optRow(L["Level ranges"], "dungeonLevels", Icon("Spell_ChargePositive"))
	rows[#rows + 1] = optRow(L["Dungeon bosses"], "dungeonBosses", Icon("INV_Misc_Bone_ElfSkull_01"))
	if questie then rows[#rows + 1] = optRow(L["Dungeon quests (Questie)"], "dungeonQuests", { texture = "Interface\\GossipFrame\\ActiveQuestIcon" }) end
	rows[#rows + 1] = { L["Townsfolk"] }
	local kinds = {}
	for _, k in ipairs(mod.TOWNSFOLK or {}) do kinds[k.key] = k end
	local function folk(label, key)
		return row(label, "townsfolk." .. key, kinds[key] and kinds[key].look or Icon("INV_Misc_QuestionMark"),
			function() return db.townsfolk[key] end, function(v) db.townsfolk[key] = v mod:RefreshTownsfolk() end)
	end
	for _, k in ipairs(mod.TOWNSFOLK or {}) do
		if not k.rare and k.key ~= "spirit" then rows[#rows + 1] = folk(k.name, k.key) end
	end
	rows[#rows + 1] = folk(L["Spirit healers"], "spirit")
	rows[#rows + 1] = folk(L["Rare mobs"], "rare")
	-- the look
	rows[#rows + 1] = { L["Unexplored areas"], tab = "look" }
	-- (darkened or hidden; neither ticked: shown as they are)
	for _, mode in ipairs({ { "dim", L["Darken unexplored areas"], "Spell_Shadow_Twilight" }, { "hide", L["Hide unexplored areas"], "Ability_Vanish" } }) do
		rows[#rows + 1] = row(mode[2], "unexplored." .. mode[1], Icon(mode[3]), function() return db.unexplored == mode[1] end,
			function(v) db.unexplored = v and mode[1] or "show" mod:Refresh() end)
	end
	rows[#rows + 1] = { L["The map"] }
	rows[#rows + 1] = optRow(L["Parchment border"], "border", Icon("INV_Scroll_03"))
	rows[#rows + 1] = optRow(L["Zone highlight on hover"], "hoverHighlight", Icon("Spell_Holy_MindVision"))
	rows[#rows + 1] = optRow(L["Zone levels"], "zoneLevels", Icon("Spell_ChargePositive"))
	rows[#rows + 1] = optRow(L["Coordinates"], "coords", Icon("INV_Misc_Spyglass_03"))
	rows[#rows + 1] = optRow(L["Buttons as edge tabs"], "tabRail", Icon("INV_Misc_Book_09"))
	rows[#rows + 1] = row(L["OpenMap button on the map"], "mapButtons", Icon("INV_Misc_Map_01"), function() return db.mapButtons end,
		function(v)
			db.mapButtons = v
			if not v then ns:Print(L["The OpenMap button is hidden. Type /openmap to open its menu."]) end
			mod:Refresh()
		end)
	-- (Options' own setters, where they do more than set it: the full-screen map is laid out again)
	local options = mod.Options and mod:Options() or {}
	local function fromOptions(label, key, icon)
		local o = options[key]
		if not o then return end
		rows[#rows + 1] = row(label, key, icon, function() return o.get({ key }) and true or false end,
			function(v) o.set({ key }, v) if ns.NotifyOptions then ns.NotifyOptions() end end)
	end
	fromOptions(L["Full-screen map fills the width"], "fullWidth", Icon("INV_Misc_Map_01"))
	rows[#rows + 1] = { L["Up close"] }
	rows[#rows + 1] = optRow(L["Minimap detail"], "minimap", Icon("Spell_Nature_FarSight"))
	rows[#rows + 1] = optRow(L["Minimap in the gaps"], "gapMinimap", Icon("INV_Misc_Map_01"))
	rows[#rows + 1] = optRow(L["Soften and paper grain"], "soften", Icon("INV_Fabric_Linen_01"))
	rows[#rows + 1] = optRow(L["Caves underground"], "underground", Icon("Trade_Mining"))
	-- the rest
	rows[#rows + 1] = { L["Moving about"], tab = "more" }
	rows[#rows + 1] = optRow(L["Follow the view"], "autoSwitch", Icon("Ability_Hunter_Pathfinding"))
	rows[#rows + 1] = { L["Reopen map (choose one)"] }
	for _, choice in ipairs({ { "player", L["Center on player"] }, { "always", L["Always remember"] },
		{ "visible", L["Remember while visible"] } }) do
		local mode = choice[1]
		rows[#rows + 1] = row(choice[2], "reopenView." .. mode, Icon("INV_Misc_Rune_01"),
			function() return mod.GetReopenView() == mode end,
			function() db.reopenView = mode mod:Refresh() end)
	end
	rows[#rows + 1] = { L["Sharing"] }
	fromOptions(L["Pins others share with you"], "pinsShared", Icon("INV_Misc_Map_01"))
	rows[#rows + 1] = { L["Tools"] }
	if mod.TogglePaint then
		rows[#rows + 1] = row(L["Map notes"], "paint", Icon("INV_Misc_Note_02"), function() return mod:IsPainting() end,
			function(v) mod:TogglePaint(v) end)
	end
	if mod.ToggleDebugOverlay then
		rows[#rows + 1] = row(L["Debug overlay (FPS)"], "debug", Icon("INV_Misc_PocketWatch_01"), function() return mod:IsDebugOverlay() end,
			function(v) mod:ToggleDebugOverlay(v) end)
	end
	-- other addons' switches (API.lua), each under its own heading in its tab
	for _, r in ipairs(mod.ExtraMenuRows and mod.ExtraMenuRows(row) or {}) do rows[#rows + 1] = r end
	return rows
end

-- the rows in one tab
local function TabRows(rows, key)
	local out, tab = {}, TABS[1].key
	for _, r in ipairs(rows) do
		if not r[2] and r.tab then tab = r.tab end
		if tab == key then out[#out + 1] = r end
	end
	return out
end

local function IsFavorite(id)
	for _, f in ipairs(mod.db.favorites) do if f == id then return true end end
end

local function SetFavorite(id, on)
	local favs = mod.db.favorites
	for i = #favs, 1, -1 do if favs[i] == id then table.remove(favs, i) end end
	if on then favs[#favs + 1] = id end
end

-- an entry's state: on (a setting that's on, an action that's running), off (a setting
-- that's off), or neither (a plain action)
local function State(e)
	if e.run then return e.lit and e.lit() and "on" or nil end
	return e[2]() and "on" or "off"
end

--------------------------------------------------------------------------------
-- The look: icons in Blizzard's action-button frame, glowing while on, greyed while off;
-- the menu's tiles also have a dark face and a bronze edge (gold while lit)
--------------------------------------------------------------------------------

local function SetLit(b, state)
	if b.boxed then
		local c = state == "on" and LIT or BRONZE
		b:SetBackdropBorderColor(c[1], c[2], c[3], 1)
	end
	b.glow:SetShown(state == "on")
	b.icon:SetDesaturated(state == "off")
	b.icon:SetAlpha(state == "off" and 0.55 or 1)
end

-- iconSize: a tile with a face and an edge, its icon that size at the top (a label goes under
-- it; move icon.slot for elsewhere); none: an action button, the icon filling it
-- classic: the action bar's own slot frame round it (the OpenMap button and the favourites)
local function Tile(parent, w, h, iconSize, classic)
	local b = CreateFrame("Button", nil, parent, iconSize and "BackdropTemplate" or nil)
	b:SetSize(w, h)
	b.boxed = iconSize ~= nil
	b.icon = FramedIcon(b, iconSize or w, classic)
	local slot = b.icon.slot
	if iconSize then
		b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
		b:SetBackdropColor(0.08, 0.06, 0.04, 0.92)
		slot:SetPoint("TOP", 0, -6)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetPoint("TOPLEFT", 1, -1)
		hl:SetPoint("BOTTOMRIGHT", -1, 1)
		hl:SetColorTexture(1, 0.8, 0.45, 0.14)
	else
		slot:SetPoint("CENTER")
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(slot)
		if not classic and HasAtlas(FRAME_ATLAS .. "-Mouseover") then hl:SetAtlas(FRAME_ATLAS .. "-Mouseover")
		else hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square") hl:SetBlendMode("ADD") end
	end
	-- while on: the action button's checked glow
	b.glow = b:CreateTexture(nil, "OVERLAY", nil, 1)
	b.glow:SetAllPoints(slot)
	b.glow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	b.glow:SetBlendMode("ADD")
	b:SetScript("OnMouseDown", function(self) self.icon:SetVertexColor(0.75, 0.75, 0.75) end)
	b:SetScript("OnMouseUp", function(self) self.icon:SetVertexColor(1, 1, 1) end)
	SetLit(b, nil)
	return b
end

-- the menu's frame: the map window's own border kit (Blizzard's nine-slice, without the
-- portrait), else the classic dialog's gold border
local function Dress(f)
	local util = _G.NineSliceUtil
	local layout = util and util.GetLayout and util.GetLayout("ButtonFrameTemplateNoPortrait") and "ButtonFrameTemplateNoPortrait"
	if layout then
		local ok, nine = pcall(CreateFrame, "Frame", nil, f, "NineSlicePanelTemplate")
		if ok and nine and pcall(util.ApplyLayoutByName, nine, layout) then
			nine:SetAllPoints()
			local bg = f:CreateTexture(nil, "BACKGROUND")
			bg:SetPoint("TOPLEFT", 6, -21)
			bg:SetPoint("BOTTOMRIGHT", -2, 3)
			if bg:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT") == false then
				bg:SetColorTexture(0.1, 0.09, 0.08, 1)
			end
			bg:SetHorizTile(true)
			bg:SetVertTile(true)
			local shade = f:CreateTexture(nil, "BACKGROUND", nil, 1)
			shade:SetAllPoints(bg)
			shade:SetColorTexture(0, 0, 0, 0.45)   -- (the rock darkened, so the small print reads)
			return 21
		end
	end
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	return 0
end

-- a thin bronze rule
local function Rule(parent)
	local t = parent:CreateTexture(nil, "ARTWORK")
	t:SetColorTexture(BRONZE[1], BRONZE[2], BRONZE[3], 0.5)
	t:SetHeight(1)
	return t
end

local function MakeStar(parent, onChange)
	local star = CreateFrame("Button", nil, parent)
	star:SetSize(14, 14)
	star.icon = star:CreateTexture(nil, "OVERLAY")
	star.icon:SetAllPoints()
	star.icon:SetTexture(STAR)
	star:SetScript("OnClick", function(self)
		SetFavorite(self.id, not IsFavorite(self.id))
		onChange()
	end)
	star:SetScript("OnEnter", function(self)
		self.icon:SetAlpha(1)
		Tip(self, "ANCHOR_RIGHT", IsFavorite(self.id) and L["Take this button off the map"] or L["Put this on the map as a button"],
			{ mod.db.tabRail and L["Favourites are tabs at the window's edge, above the OpenMap tab."]
				or L["Favourites sit in a row beside the OpenMap button, in the map's bottom-left corner."], 0.8, 0.8, 0.8 })
	end)
	star:SetScript("OnLeave", function(self)
		if not IsFavorite(self.id) then self.icon:SetAlpha(0.35) end
		GameTooltip:Hide()
	end)
	return star
end

local function SetStar(star, id)
	star.id = id
	local lit = IsFavorite(id)
	star.icon:SetDesaturated(not lit)
	star.icon:SetAlpha(lit and 1 or 0.35)
end

--------------------------------------------------------------------------------
-- The bar: the OpenMap button in the map's bottom-left corner, then a button for each favourite
-- (the arrow beside it folds them away). Lit while it's on; click to use it,
-- right-click to take it off the bar.
--------------------------------------------------------------------------------

local Fill, RefreshTiles, SetOpen, LightToggle

local function Entries()
	local byId = {}
	for _, e in ipairs(Actions()) do byId[e.id] = e end
	for _, r in ipairs(Rows()) do if r.id then byId[r.id] = r end end
	return byId
end

-- the bar's place: the map's bottom-left corner, past whatever Blizzard or another addon keeps there
local function PlaceToggle()
	local left, bottom = sc:GetLeft(), sc:GetBottom()
	local x = BAR_X
	for _, f in ipairs(map.overlayFrames or {}) do
		local fl, fb, fr = f:IsShown() and f:GetLeft(), f:GetBottom(), f:GetRight()
		-- (a button in the corner, not a frame across the map: an addon's can span its width)
		if fl and left and fb and fr and fl - left < 40 and fb - bottom < 40 and fr - fl < 220 then
			x = math.max(x, fr - left + 6)
		end
	end
	toggle:ClearAllPoints()
	toggle:SetPoint("BOTTOMLEFT", sc, "BOTTOMLEFT", x, BAR_Y)
end

-- the room left for favourites: rightward to the coordinates in the bottom-right corner (Extras.lua),
-- or the map's right edge
local function Room()
	local sr, fl = sc:GetRight(), favBar:GetLeft()
	if not (sr and fl) then return math.huge end   -- (not laid out yet: the next refresh trims it)
	local limit = (mod.CoordsLeft and mod.CoordsLeft()) or sr
	return limit - 8 - fl
end

local RefreshFavorites, RefreshRail

-- a favourite's button (in the row or on the rail): click to use it, right-click to take it off
local function FavClick(self, button)
	if button == "RightButton" and (IsShiftKeyDown() or not self.entry.right) then
		SetFavorite(self.entry.id, false)
	elseif self.entry.run then
		self.entry.run(button)
	else
		self.entry[3](not self.entry[2]())
	end
	RefreshFavorites()
	if menu and menu:IsShown() then Fill() end
end

local function FavEnter(self)
	local e2 = self.entry
	local state = State(e2)
	local off = e2.right and L["Shift-right-click: take it off the map"] or L["Right-click: take it off the map"]
	Tip(self, self.tipAnchor or "ANCHOR_TOP", e2[1],
		e2.run and { e2.tip } or { state == "on" and L["On: click to turn it off"] or L["Off: click to turn it on"] },
		{ off .. " " .. L["(the stars in the OpenMap menu put buttons here)"], 0.6, 0.6, 0.6 })
end

--------------------------------------------------------------------------------
-- The rail (tabRail): the same as tabs on the map's edge, in the look of the quest log's tabs: the
-- OpenMap tab, an arrow by it that folds the favourites away, and a tab for each favourite past it,
-- as many as there's room for. Drag the OpenMap tab anywhere round the inside of the map's edge
-- (its right edge is the quest log's left while that's open): the tabs turn to sit flat to that
-- edge, and the favourites go the way along it there's more room. A dungeon map's two tabs
-- (Dungeons.lua) are on the right edge, past the rail's end when it's there too.
--------------------------------------------------------------------------------

d.railPos = false               -- { edge = "right" | "left" | "top" | "bottom", at = 0..1 along it } once dragged

local rail
local RAIL_MAIN = { 40, 42 }    -- the OpenMap tab: out from the edge, along it (WoW Forever's tab art, a little smaller)
local RAIL_FAV = { 32, 34 }     -- a favourite's
local RAIL_GAP, RAIL_ARROW = 3, 16
local RAIL_END = 44             -- kept clear at each end of an edge (the quest log button, the coordinates)
local RAIL_DEFAULT = { edge = "right", at = 0 }   -- (low on the right, past the end kept clear)
local DUNGEON_TABS = 2 * 42 + 3 -- a dungeon map's two tabs, along the right edge
local VERTICAL = { left = true, right = true }
local TIP_TOWARD = { right = "ANCHOR_LEFT", left = "ANCHOR_RIGHT", top = "ANCHOR_BOTTOM", bottom = "ANCHOR_TOP" }

local function RailPos() return rail and rail.dragPos or mod.db.railPos or RAIL_DEFAULT end

-- a frame on the map's inside edge, its middle `s` along it (from the bottom, or the left)
local function OnEdge(f, edge, s)
	f:ClearAllPoints()
	if edge == "right" then f:SetPoint("RIGHT", sc, "BOTTOMRIGHT", 0, s)
	elseif edge == "left" then f:SetPoint("LEFT", sc, "BOTTOMLEFT", 0, s)
	elseif edge == "top" then f:SetPoint("TOP", sc, "TOPLEFT", s, 0)
	else f:SetPoint("BOTTOM", sc, "BOTTOMLEFT", s, 0) end
end

local function EdgeLength(edge)
	return (VERTICAL[edge] and sc:GetHeight() or sc:GetWidth()) or 0
end

-- a tab `size` ({ out from the edge, along it }) on `edge`
local function SizeFor(f, edge, size)
	if VERTICAL[edge] then f:SetSize(size[1], size[2]) else f:SetSize(size[2], size[1]) end
end

-- a dungeon map's two tabs (Dungeons.lua): low on the right edge, or past the rail's end there
function mod.PlaceDungeonTabsFrame(f)
	local half = DUNGEON_TABS / 2
	local s = RAIL_END + half
	if rail and rail:IsShown() and rail.edge == "right" then
		s = rail.far + rail.dir * (12 + half)
		s = math.max(half, math.min(EdgeLength("right") - half, s))
	end
	OnEdge(f, "right", s)
end

local function RailTab()
	local b = CreateFrame("Button", nil, rail)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.hover = b:CreateTexture(nil, "HIGHLIGHT")
	b.selected = b:CreateTexture(nil, "OVERLAY")
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon.size = 24                            -- (ShowIcon's; Dungeons.lua's FaceSideTab sizes it to the face)
	b.fill = true                               -- (the icon filling the tab's face, cut to its shape)
	b.glow = b.selected                         -- (lit: the tab's selected edge, SetLit)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnMouseDown", function(self) self.icon:SetVertexColor(0.75, 0.75, 0.75) end)
	b:SetScript("OnMouseUp", function(self) self.icon:SetVertexColor(1, 1, 1) end)
	return b
end

-- dragging the OpenMap tab: the edge nearest the cursor, and how far along it
local function Drag(self, elapsed)
	self.wait = (self.wait or 0) + elapsed
	if self.wait < 0.03 then return end
	self.wait = 0
	local l, b, w, h = sc:GetLeft(), sc:GetBottom(), sc:GetWidth(), sc:GetHeight()
	if not (l and b and w and h and w > 0 and h > 0) then return end
	local x, y = GetCursorPosition()
	local s = sc:GetEffectiveScale()
	x, y = x / s - l, y / s - b
	local near = { left = x, right = w - x, bottom = y, top = h - y }
	local edge = "right"
	for k, v in pairs(near) do if v < near[edge] then edge = k end end
	local at = VERTICAL[edge] and y / h or x / w
	self.dragPos = { edge = edge, at = math.max(0, math.min(1, at)) }
	RefreshRail()
end

local function EndDrag()
	if not rail.dragPos then return end
	rail:SetScript("OnUpdate", nil)
	mod.db.railPos = rail.dragPos
	rail.dragPos, rail.byId = nil, nil
	rail.dragEnd = GetTime()
	RefreshRail()
	LightToggle()
end

local function BuildRail()
	rail = CreateFrame("Frame", nil, map)
	rail:SetAllPoints(sc)                       -- (its tabs are placed on sc's edges; it takes no clicks itself)
	rail:SetFrameLevel(math.min(sc:GetFrameLevel() + 9300, 9950))   -- (over the map, its border and a dungeon's map)
	rail:SetScript("OnHide", EndDrag)           -- (the map closed mid-drag)
	rail.main = RailTab()
	ShowIcon(rail.main.icon, OPENMAP_ICON)
	rail.main:RegisterForDrag("LeftButton")
	rail.main:SetScript("OnClick", function(_, button)
		if rail.dragEnd and GetTime() - rail.dragEnd < 0.3 then return end   -- (the end of a drag, not a click)
		if button == "LeftButton" then SetOpen(not menu:IsShown()) end
	end)
	rail.main:SetScript("OnDragStart", function()
		GameTooltip:Hide()
		local pos = RailPos()
		rail.byId = Entries()                   -- (the favourites as they are: not looked up again each step)
		rail.dragPos = { edge = pos.edge, at = pos.at }
		rail:SetScript("OnUpdate", Drag)
	end)
	rail.main:SetScript("OnDragStop", EndDrag)
	rail.main:SetScript("OnEnter", function(self)
		Tip(self, self.tipAnchor or "ANCHOR_LEFT", "OpenMap", { L["Search, find me, map pins, the quest log, report a problem, options, and what the map shows."] },
			{ L["Drag it anywhere round the map's edge."], 0.6, 0.6, 0.6 })
	end)
	rail.main:SetScript("OnLeave", GameTooltip_Hide)
	-- the arrow: the way the favourites go to unfold them, back toward the OpenMap tab to fold them
	rail.arrow = CreateFrame("Button", nil, rail)
	rail.arrow.icon = rail.arrow:CreateTexture(nil, "ARTWORK")
	rail.arrow.icon:SetSize(20, 20)
	local hl = rail.arrow:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(rail.arrow.icon)
	hl:SetTexture("Interface\\Buttons\\UI-Common-MouseHilight")
	hl:SetBlendMode("ADD")
	rail.arrow:SetScript("OnClick", function()
		mod.db.trayOpen = not mod.db.trayOpen
		RefreshFavorites()
	end)
	rail.arrow:SetScript("OnEnter", function(self)
		Tip(self, self.tipAnchor or "ANCHOR_LEFT", mod.db.trayOpen and L["Fold your buttons away"] or L["Your buttons"],
			{ L["The stars in the OpenMap menu put buttons here; right-click one to take it off."], 0.8, 0.8, 0.8 })
	end)
	rail.arrow:SetScript("OnLeave", GameTooltip_Hide)
	rail.favs = {}
	local pad = mod.padRoots                    -- (the gamepad's cursor presses its tabs: Gamepad.lua)
	if pad then pad[#pad + 1] = rail end
end

RefreshRail = function()
	if not rail then BuildRail() end
	if not map:IsShown() then rail:Hide() return end
	local pos = RailPos()
	local edge, len = pos.edge, EdgeLength(pos.edge)
	local byId = rail.byId or Entries()
	local list = {}
	for _, id in ipairs(mod.db.favorites) do if byId[id] then list[#list + 1] = byId[id] end end
	local open = mod.db.trayOpen or #list == 0
	-- the OpenMap tab where it was put, kept off the edge's ends; the favourites the way along it
	-- there's more room (on the right edge, less a dungeon map's tabs while they show)
	local half = RAIL_MAIN[2] / 2
	local s0 = math.max(RAIL_END + half, math.min(len - RAIL_END - half, (pos.at or 0) * len))
	local dir = (len - s0 >= s0) and 1 or -1
	local reserve = (edge == "right" and mod.DungeonTabsShown and mod.DungeonTabsShown()) and (DUNGEON_TABS + 12) or 0
	local reach = (dir > 0 and (len - s0) or s0) - RAIL_END - reserve
	SizeFor(rail.main, edge, RAIL_MAIN)
	OnEdge(rail.main, edge, s0)
	local at = half                             -- (from the OpenMap tab's middle to the stack's far end)
	local function Next(f, along)
		OnEdge(f, edge, s0 + dir * (at + RAIL_GAP + along / 2))
		at = at + RAIL_GAP + along
	end
	rail.arrow:SetShown(#list > 0)
	if #list > 0 then
		SizeFor(rail.arrow, edge, { RAIL_FAV[1], RAIL_ARROW })
		Next(rail.arrow, RAIL_ARROW)
	end
	for _, b in ipairs(rail.favs) do b:Hide() end
	local shown = { rail.main }
	if open then
		for i, e in ipairs(list) do
			if at + RAIL_GAP + RAIL_FAV[2] > reach then break end   -- (no more than there's room for)
			local b = rail.favs[i]
			if not b then
				b = RailTab()
				b:SetScript("OnClick", FavClick)
				b:SetScript("OnEnter", FavEnter)
				b:SetScript("OnLeave", GameTooltip_Hide)
				rail.favs[i] = b
			end
			b.entry = e
			ShowIcon(b.icon, e.icon)
			SizeFor(b, edge, RAIL_FAV)
			Next(b, RAIL_FAV[2])
			b:Show()
			shown[#shown + 1] = b
		end
	end
	rail.edge, rail.dir, rail.far = edge, dir, s0 + dir * at
	-- (the arrow: the page arrow turned the way it points; tooltips toward the map's middle)
	local way = open and -dir or dir
	local angle
	if VERTICAL[edge] then angle = way > 0 and math.pi / 2 or -math.pi / 2 else angle = way > 0 and 0 or math.pi end
	rail.arrow.icon:SetTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
	rail.arrow.icon:SetRotation(angle)
	rail.arrow.icon:ClearAllPoints()
	rail.arrow.icon:SetPoint("CENTER")
	local tip = TIP_TOWARD[edge]
	rail.arrow.tipAnchor = tip
	for _, b in ipairs(shown) do
		b.tipAnchor = tip
		if mod.FaceSideTab then mod.FaceSideTab(b, edge, nil) end
		if b ~= rail.main then SetLit(b, State(b.entry)) end
	end
	rail:Show()
	if mod.PlaceDungeonTabs then mod.PlaceDungeonTabs() end
end
function mod.RefreshRail() if mod.db.tabRail and favBar then RefreshFavorites() end end

RefreshFavorites = function()
	if not favBar then return end
	if not mod.db.mapButtons then
		toggle:Hide()
		trayArrow:Hide()
		favBar:Hide()
		if rail then rail:Hide() end
		if mod.PlaceDungeonTabs then mod.PlaceDungeonTabs() end
		return
	end
	-- (the rail, or the row in the bottom-left corner)
	local tabs = mod.db.tabRail and true or false
	toggle:SetShown(not tabs)
	if tabs then
		trayArrow:Hide()
		favBar:Hide()
		RefreshRail()
		LightToggle()
		return
	end
	if rail then rail:Hide() end
	if mod.PlaceDungeonTabs then mod.PlaceDungeonTabs() end
	PlaceToggle()
	local byId = Entries()
	favBar.buttons = favBar.buttons or {}
	for _, b in ipairs(favBar.buttons) do b:Hide() end
	local room, x, n = Room(), 0, 0
	for _, id in ipairs(mod.db.favorites) do
		local e = byId[id]
		if e then
			n = n + 1
			local b = favBar.buttons[n]
			if not b then
				b = Tile(favBar, FAV, FAV, nil, true)
				b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
				b:SetScript("OnClick", FavClick)
				b:SetScript("OnEnter", FavEnter)
				b:SetScript("OnLeave", GameTooltip_Hide)
				favBar.buttons[n] = b
			end
			b.entry = e
			ShowIcon(b.icon, e.icon)
			SetLit(b, State(e))
			b:ClearAllPoints()
			b:SetPoint("BOTTOMLEFT", favBar, "BOTTOMLEFT", x, 0)   -- (the first nearest the button, the rest leftward)
			b:SetShown(x + FAV <= room)             -- (no further than the room there is)
			x = x + FAV + 8
		end
	end
	favBar:SetWidth(math.max(1, x))
	-- the arrow: there with any favourites; folds the row away (into the button) and back out rightward
	local open = mod.db.trayOpen or n == 0
	trayArrow:SetShown(n > 0)
	trayArrow.icon:SetTexture(open and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
	favBar:ClearAllPoints()
	favBar:SetPoint("BOTTOMLEFT", n > 0 and trayArrow or toggle, "BOTTOMRIGHT", n > 0 and 6 or 10, n > 0 and 0 or 3)
	favBar:SetShown(open)
end

--------------------------------------------------------------------------------
-- The panel
--------------------------------------------------------------------------------

RefreshTiles = function()
	if not tiles then return end
	for _, t in ipairs(tiles) do
		SetLit(t, State(t.entry))
		SetStar(t.star, t.entry.id)
		if t.entry.id == "pin" then t.label:SetText(mod.PinMode() and L["Click the map..."] or t.entry[1]) end
	end
end

-- a checkbox: the game's settings' own (Forever's options panel), else the classic one
local function CheckBox(parent)
	if not HasAtlas("checkbox-minimal") then
		local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
		cb:SetSize(22, 22)
		return cb
	end
	local cb = CreateFrame("CheckButton", nil, parent)
	cb:SetSize(20, 20)
	local function Tex(atlas, layer, blend, alpha)
		local t = cb:CreateTexture(nil, layer)
		t:SetAtlas(atlas)
		t:SetAllPoints()
		if blend then t:SetBlendMode(blend) end
		if alpha then t:SetAlpha(alpha) end
		return t
	end
	cb:SetNormalTexture(Tex("checkbox-minimal", "BACKGROUND"))
	cb:SetPushedTexture(Tex("checkbox-minimal", "BACKGROUND"))
	cb:SetHighlightTexture(Tex("checkbox-minimal", "HIGHLIGHT", "ADD", 0.25))
	cb:SetCheckedTexture(Tex("checkmark-minimal", "ARTWORK"))
	if HasAtlas("checkmark-minimal-disabled") then cb:SetDisabledCheckedTexture(Tex("checkmark-minimal-disabled", "ARTWORK")) end
	return cb
end

local ROW_H = 22
local filling = false
Fill = function()
	RefreshTiles()
	local tab = mod.db.menuTab
	for _, b in ipairs(menu.tabs or {}) do
		local on = b.key == tab
		if b.SetSelected then b:SetSelected(on) elseif on then b:LockHighlight() else b:UnlockHighlight() end
	end
	local rows = TabRows(Rows(), tab)
	-- two columns of whole sections, as even as they'll go (each column keeps the sections' order)
	local sections = {}
	for _, row in ipairs(rows) do
		if not row[2] or #sections == 0 then sections[#sections + 1] = {} end
		local s = sections[#sections]
		s[#s + 1] = row
	end
	local function Height(s) return (#s - 1) * ROW_H + 32 end   -- (its heading, the gap before it, its rows)
	local pick, best = 0, math.huge
	for mask = 0, 2 ^ #sections - 1 do
		local a, b, m = 0, 0, mask
		for _, s in ipairs(sections) do
			if m % 2 == 1 then b = b + Height(s) else a = a + Height(s) end
			m = math.floor(m / 2)
		end
		-- (the taller column as short as can be; then the left one the taller)
		local score = math.max(a, b) * 1000 + (a < b and 1 or 0)
		if score < best then pick, best = mask, score end
	end
	local columns = { {}, {} }
	for _, s in ipairs(sections) do
		local c = columns[pick % 2 == 1 and 2 or 1]
		for _, row in ipairs(s) do c[#c + 1] = row end
		pick = math.floor(pick / 2)
	end
	checks.heads = checks.heads or {}
	checks.boxes = checks.boxes or {}
	for _, it in ipairs(checks.heads) do it:Hide() it.rule:Hide() end
	-- (a row's icon, frame and label are the list's, not its box's: hidden with it, or another tab's show through)
	for _, it in ipairs(checks.boxes) do it:Hide() it.hit:Hide() it.star:Hide() it.icon:Hide() it.border:Hide() it.label:Hide() end
	local nh, nb, tallest = 0, 0, 0
	for col = 1, 2 do
		local y = 0
		local x0 = (col - 1) * (COL + 16)
		for _, row in ipairs(columns[col]) do
			if not row[2] then
				nh = nh + 1
				local it = checks.heads[nh]
				if not it then
					it = checks:CreateFontString(nil, "OVERLAY", "GameFontNormal")
					it:SetTextColor(HEAD[1], HEAD[2], HEAD[3])
					it.rule = Rule(checks)
					it.rule:SetPoint("LEFT", it, "RIGHT", 6, 0)
					checks.heads[nh] = it
				end
				if y < 0 then y = y - 10 end
				it:ClearAllPoints()
				it:SetPoint("TOPLEFT", x0 + 2, y)
				it:SetText(row[1])
				it.rule:SetWidth(math.max(1, COL - 10 - (it:GetStringWidth() or 60)))
				it:Show()
				it.rule:Show()
				y = y - 22
			else
				nb = nb + 1
				local it = checks.boxes[nb]
				if not it then
					it = CheckBox(checks)
					it:SetScript("OnClick", function(self) self.row[3](self:GetChecked() and true or false) RefreshFavorites() end)
					it.icon = checks:CreateTexture(nil, "ARTWORK")
					it.icon:SetSize(16, 16)
					it.icon:SetPoint("LEFT", it, "RIGHT", 4, 0)
					it.border = IconBorder(checks, it.icon, 16)   -- (spell icons only: map symbols go bare)
					it.label = checks:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
					it.label:SetPoint("LEFT", it.icon, "RIGHT", 6, 0)
					-- the whole line clicks the box
					it.hit = CreateFrame("Button", nil, checks)
					it.hit:SetHeight(ROW_H)
					it.hit:SetPoint("LEFT", it.icon, "LEFT", -2, 0)
					it.hit:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
					it.hit:SetScript("OnClick", function() it:Click() end)
					it.star = MakeStar(checks, function() Fill() RefreshFavorites() end)
					checks.boxes[nb] = it
				end
				it.row = row
				it:ClearAllPoints()
				it:SetPoint("TOPLEFT", x0, y - 1)
				it.border:SetShown(SetIcon(it.icon, row.icon or Icon("INV_Misc_QuestionMark")))
				it.icon:Show()
				it.label:SetText(row[1])
				it.label:Show()
				it:SetChecked(row[2]() and true or false)
				it.hit:SetWidth(COL - 44)
				SetStar(it.star, row.id)
				it.star:ClearAllPoints()
				it.star:SetPoint("TOPLEFT", x0 + COL - 16, y - 4)
				it.star:SetShown(row.id ~= nil)
				it:Show()
				it.hit:Show()
				y = y - ROW_H
			end
		end
		tallest = math.max(tallest, -y)
	end
	checks:SetHeight(math.max(1, tallest))
	-- the sliders: on the look's tab
	local look = tab == "look"
	menu.sliders:SetShown(look)
	if look then
		zoomRow:Fill()
		miniRow:Fill()
		opacityRow:Fill()
		for _, r in ipairs(menu.extraRows or {}) do r:Fill() end
	end
	menu:SetHeight(checks.top + tallest + (look and (menu.sliders:GetHeight() + 10) or 0) + 30 + PAD)
end

-- the menu stays where it is on the screen while the map window is dragged about: where you put it,
-- or (not moved yet) where it first opens, above the OpenMap button
local function Place()
	menu:ClearAllPoints()
	local p = mod.db.menuPos
	if p and p.screen then menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p[1], p[2]) return end
	-- (beside the OpenMap tab, toward the map's middle from its edge)
	if mod.db.tabRail and rail and rail:IsShown() then
		local e = rail.edge
		if e == "right" then menu:SetPoint("BOTTOMRIGHT", rail.main, "BOTTOMLEFT", -6, 0)
		elseif e == "left" then menu:SetPoint("BOTTOMLEFT", rail.main, "BOTTOMRIGHT", 6, 0)
		elseif e == "top" then menu:SetPoint("TOPLEFT", rail.main, "BOTTOMLEFT", 0, -6)
		else menu:SetPoint("BOTTOMLEFT", rail.main, "TOPLEFT", 0, 6) end
	else
		menu:SetPoint("BOTTOMLEFT", toggle, "TOPLEFT", -6, 12)
	end
	local l, t = menu:GetLeft(), menu:GetTop()
	if l and t then
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
	end
end

-- the OpenMap button: lit while the menu's open, and pulsing while there's news not yet seen (News.lua)
LightToggle = function()
	if not toggle then return end
	local news = mod.NewsUnseen and mod.NewsUnseen()
	local open = menu and menu:IsShown()
	for _, b in ipairs({ toggle, rail and rail.main }) do   -- (the corner's button, the rail's tab)
		SetLit(b, (open or news) and "on" or nil)
		if not b.pulse then
			b.pulse = b.glow:CreateAnimationGroup()
			local a = b.pulse:CreateAnimation("Alpha")
			a:SetFromAlpha(1)
			a:SetToAlpha(0.25)
			a:SetDuration(0.9)
			a:SetSmoothing("IN_OUT")
			b.pulse:SetLooping("BOUNCE")
		end
		if news and not open then b.pulse:Play() else b.pulse:Stop() b.glow:SetAlpha(1) end
	end
end

SetOpen = function(on)
	mod.db.menuOpen = on and true or false
	if on then Fill() Place() menu:Show() else menu:Hide() end
	LightToggle()
end

-- a slider under the checklist (the deepest zoom, the minimap's): { label, icon, range { least, most,
-- step }, get, set, tip }; f:Fill() shows the setting as it is. Its name over it, the slider (and its
-- value) under: a column's width
local SLIDER_H = 46
local function SliderRow(parent, width, spec)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(width, SLIDER_H)
	local icon = f:CreateTexture(nil, "ARTWORK")
	icon:SetSize(16, 16)
	icon:SetPoint("TOPLEFT", 4, -2)
	SetIcon(icon, spec.icon)
	IconBorder(f, icon, 16)
	local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
	label:SetText(spec.label)
	f.value = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.value:SetPoint("TOPRIGHT", -4, -2)
	f.value:SetWidth(44)
	f.value:SetJustifyH("RIGHT")
	local lo, hi, step = spec.range[1], spec.range[2], spec.range[3]
	local function Snap(v)
		v = math.floor(v / step + 0.5) * step
		if step < 1 then v = math.floor(v * 1000 + 0.5) / 1000 end      -- (no float dust in a saved 0.85)
		return v
	end
	local function Shown(v) return (spec.fmt or "%dx"):format(spec.show and spec.show(v) or v) end
	-- the game's settings' own slider, with its arrows (Forever's options panel), where the client has it
	local Mixin = _G.MinimalSliderWithSteppersMixin
	local ok, ms = pcall(CreateFrame, "Frame", nil, f, "MinimalSliderWithSteppersTemplate")
	if ok and ms and ms.Init and Mixin and Mixin.Label and Mixin.Event then
		ms:SetPoint("TOPLEFT", 0, -18)
		ms:SetPoint("TOPRIGHT", -40, -18)          -- (its value at its right)
		ms:SetHeight(28)
		if ms.Slider.SetObeyStepOnDrag then ms.Slider:SetObeyStepOnDrag(true) end
		ms:Init(spec.get(), lo, hi, math.floor((hi - lo) / step + 0.5), { [Mixin.Label.Right] = function(v) return Shown(Snap(v)) end })
		ms:RegisterCallback(Mixin.Event.OnValueChanged, function(_, v)
			v = Snap(v)
			if filling or v == spec.get() then return end
			spec.set(v)
			if ns.NotifyOptions then ns.NotifyOptions() end
		end, f)
		f.value:Hide()
		for _, r in ipairs({ ms.Slider, f }) do
			r:HookScript("OnEnter", function(self) Tip(self, "ANCHOR_TOP", spec.label, { spec.tip }) end)
			r:HookScript("OnLeave", GameTooltip_Hide)
		end
		f:EnableMouse(true)
		function f:Fill()
			filling = true
			ms:SetValue(spec.get())
			filling = false
			ms:SetEnabled(not spec.enabled or spec.enabled())
		end
		f.slider = ms.Slider
		return f
	end
	local s = CreateFrame("Slider", nil, f, "BackdropTemplate")
	s:SetOrientation("HORIZONTAL")
	s:SetHeight(16)
	s:SetPoint("TOPLEFT", 6, -24)
	s:SetPoint("TOPRIGHT", -6, -24)
	s:SetBackdrop({
		bgFile = "Interface\\Buttons\\UI-SliderBar-Background", edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile = true, tileSize = 8, edgeSize = 8, insets = { left = 3, right = 3, top = 6, bottom = 6 },
	})
	s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	s:SetMinMaxValues(lo, hi)
	s:SetValueStep(step)
	if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
	s:SetValue(spec.get())          -- (before its script: setting it up mustn't set anything)
	s:SetScript("OnValueChanged", function(_, v)
		v = math.floor(v / step + 0.5) * step
		if step < 1 then v = math.floor(v * 1000 + 0.5) / 1000 end      -- (no float dust in a saved 0.85)
		f.value:SetText((spec.fmt or "%dx"):format(spec.show and spec.show(v) or v))
		if filling or v == spec.get() then return end
		spec.set(v)
		if ns.NotifyOptions then ns.NotifyOptions() end
	end)
	for _, r in ipairs({ s, f }) do
		r:SetScript("OnEnter", function(self) Tip(self, "ANCHOR_TOP", spec.label, { spec.tip }) end)
		r:SetScript("OnLeave", GameTooltip_Hide)
	end
	function f:Fill()
		filling = true
		s:SetValue(spec.get())
		filling = false
		f.value:SetText((spec.fmt or "%dx"):format(spec.show and spec.show(spec.get()) or spec.get()))
		local on = not spec.enabled or spec.enabled()
		s:SetEnabled(on)
		f:SetAlpha(on and 1 or 0.5)
	end
	f.slider = s
	return f
end

function mod:SetupPanel(worldMap)
	map, sc = worldMap, worldMap.ScrollContainer
	local level = math.min(sc:GetFrameLevel() + 9300, 9950)

	-- the OpenMap button, its icon alone, in the bottom-left corner: placed again whenever
	-- Blizzard refreshes its overlay buttons
	toggle = Tile(map, TOGGLE, TOGGLE, nil, true)
	toggle:SetFrameLevel(level)               -- (over the window's resize grip there: Window.lua)
	ShowIcon(toggle.icon, OPENMAP_ICON)
	toggle:SetScript("OnClick", function() SetOpen(not menu:IsShown()) end)
	toggle:SetScript("OnEnter", function(self)
		Tip(self, "ANCHOR_TOP", "OpenMap", { L["Search, find me, map pins, the quest log, report a problem, options, and what the map shows."] })
	end)
	toggle:SetScript("OnLeave", GameTooltip_Hide)
	map:HookScript("OnShow", PlaceToggle)
	map:HookScript("OnShow", function() LightToggle() end)   -- (news after an update: News.lua)
	if map.RefreshOverlayFrames then hooksecurefunc(map, "RefreshOverlayFrames", function() RefreshFavorites() end) end

	-- the favourites, in a row to the right of it, past an arrow that folds them away; the first
	-- time, a few to start with (a star in the menu adds more, a right-click takes one off)
	if not mod.db.trayStarted then
		mod.db.trayStarted = true
		if #mod.db.favorites == 0 then for _, id in ipairs(TRAY_START) do tinsert(mod.db.favorites, id) end end
	end
	trayArrow = CreateFrame("Button", nil, map)
	trayArrow:SetSize(20, FAV)
	trayArrow:SetPoint("BOTTOMLEFT", toggle, "BOTTOMRIGHT", 8, 3)
	trayArrow:SetFrameLevel(level)
	trayArrow.icon = trayArrow:CreateTexture(nil, "ARTWORK")
	trayArrow.icon:SetSize(24, 24)
	trayArrow.icon:SetPoint("CENTER")
	local hl = trayArrow:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(trayArrow.icon)
	hl:SetTexture("Interface\\Buttons\\UI-Common-MouseHilight")
	hl:SetBlendMode("ADD")
	trayArrow:SetScript("OnClick", function()
		mod.db.trayOpen = not mod.db.trayOpen
		RefreshFavorites()
	end)
	trayArrow:SetScript("OnEnter", function(self)
		Tip(self, "ANCHOR_TOP", mod.db.trayOpen and L["Fold your buttons away"] or L["Your buttons"],
			{ L["The stars in the OpenMap menu put buttons here; right-click one to take it off."], 0.8, 0.8, 0.8 })
	end)
	trayArrow:SetScript("OnLeave", GameTooltip_Hide)
	favBar = CreateFrame("Frame", nil, map)
	favBar:SetHeight(FAV)
	favBar:SetPoint("BOTTOMLEFT", trayArrow, "BOTTOMRIGHT", 6, 0)
	favBar:SetFrameLevel(level)
	map:HookScript("OnShow", function() RefreshFavorites() C_Timer.After(0, RefreshFavorites) end)   -- (and once laid out)
	sc:HookScript("OnSizeChanged", RefreshFavorites)
	-- (full screen and back: the rail's edge is another)
	for _, method in ipairs({ "Maximize", "Minimize" }) do
		if map[method] then hooksecurefunc(map, method, function() C_Timer.After(0, RefreshFavorites) end) end
	end
	RefreshFavorites()

	-- the window's portrait (Blizzard's quest log book): OpenMap's icon, while it's stitching
	local border = map.BorderFrame
	if border and border.SetPortraitToAsset then
		local function Portrait()
			border:SetPortraitToAsset(mod.IsStitched() and OPENMAP_ICON.texture or "Interface\\QuestFrame\\UI-QuestLog-BookIcon")
		end
		Portrait()
		map:HookScript("OnShow", Portrait)
		if map.Minimize then hooksecurefunc(map, "Minimize", Portrait) end
		mod.RefreshPortrait = Portrait
	end

	-- the floating menu
	menu = CreateFrame("Frame", "OpenMapMenu", map, "BackdropTemplate")
	local pad = mod.padRoots      -- (the gamepad's cursor presses their buttons: Gamepad.lua)
	pad[#pad + 1], pad[#pad + 2], pad[#pad + 3], pad[#pad + 4] = toggle, trayArrow, favBar, menu
	menu:SetWidth(W)
	-- (over the quest log, which Blizzard puts in the HIGH strata: the map's own is lower, so at any
	-- frame level the menu went behind it where they overlap)
	menu:SetFrameStrata("DIALOG")
	menu:SetFrameLevel(level + 5)
	local titleH = Dress(menu)
	menu:EnableMouse(true)
	menu:SetMovable(true)
	menu:SetClampedToScreen(true)
	menu:RegisterForDrag("LeftButton")
	menu:SetScript("OnDragStart", function(self) self:StartMoving() end)
	menu:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self:SetUserPlaced(false)
		-- kept on the screen, so it stays put while the map window moves
		mod.db.menuPos = { self:GetLeft(), self:GetTop(), screen = true }
		Place()
	end)
	local title = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	-- the close button over everything else in the menu, and a little easier to catch than it looks;
	-- Escape closes the menu too (the map stays open)
	local close = CreateFrame("Button", nil, menu, "UIPanelCloseButton")
	close:SetFrameLevel(menu:GetFrameLevel() + 20)
	close:SetHitRectInsets(-4, -4, -4, -4)
	close:SetScript("OnClick", function() SetOpen(false) end)
	tinsert(UISpecialFrames, "OpenMapMenu")
	menu:SetScript("OnHide", function()
		-- (Escape, or the X: closed. The map closing hides it too, but then it opens again with the map)
		if map:IsShown() then
			mod.db.menuOpen = false
			LightToggle()
		end
	end)
	if titleH > 0 then
		-- (the nine-slice's own title bar)
		title:SetPoint("TOP", 0, -4)
		close:SetPoint("TOPRIGHT", 1, 0)
	else
		local header = menu:CreateTexture(nil, "ARTWORK")
		header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
		header:SetSize(240, 60)
		header:SetPoint("TOP", 0, 14)
		title:SetPoint("TOP", header, "TOP", 0, -14)
		close:SetPoint("TOPRIGHT", -4, -4)
	end
	title:SetText("OpenMap |cff998866" .. ns.version .. "|r")

	local inner = W - 2 * PAD
	local y = -titleH - 12
	if titleH == 0 then y = -30 end
	local search = mod.CreateSearch and mod.CreateSearch(menu, inner - 8)
	if search then
		search:SetPoint("TOPLEFT", PAD + 6, y)
		y = y - 32
	end

	-- the actions: a tile each, with its star in the corner
	local actions = Actions()
	local gap = 6
	local perRow = #actions > 6 and math.ceil(#actions / 2) or #actions   -- (past six: two rows, room for their labels)
	local tw = (inner - gap * (perRow - 1)) / perRow
	tiles = {}
	for i, e in ipairs(actions) do
		local t = Tile(menu, tw, TILE_H, 26)
		t:SetPoint("TOPLEFT", PAD + ((i - 1) % perRow) * (tw + gap), y - math.floor((i - 1) / perRow) * (TILE_H + gap))
		t.entry = e
		ShowIcon(t.icon, e.icon)
		t.label = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		t.label:SetPoint("TOP", t.icon.slot, "BOTTOM", 0, -4)
		t.label:SetWidth(tw - 6)
		t.label:SetText(e[1])
		t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		t:SetScript("OnClick", function(self, button)
			self.entry.run(button)
			RefreshTiles()
			RefreshFavorites()
		end)
		t:SetScript("OnEnter", function(self) Tip(self, "ANCHOR_TOP", self.entry[1], { self.entry.tip }) end)
		t:SetScript("OnLeave", GameTooltip_Hide)
		t.star = MakeStar(t, function() RefreshTiles() RefreshFavorites() end)
		t.star:SetPoint("TOPRIGHT", -2, -2)
		tiles[i] = t
	end
	y = y - math.floor((#actions - 1) / perRow) * (TILE_H + gap) - TILE_H - 14

	-- the checklist's tabs (the game's own settings tabs, where the client has them), a rule under them
	menu.tabs = {}
	local tx = PAD
	for i, t in ipairs(TABS) do
		local ok, b = pcall(CreateFrame, "Button", nil, menu, "MinimalTabTemplate")
		if ok and b and b.Text then
			b.Text:SetText(t.name)
			b:SetWidth(math.max(84, b.Text:GetStringWidth() + 40))
		else
			b = CreateFrame("Button", nil, menu, "UIPanelButtonTemplate")
			b:SetSize(100, 22)
			b:SetText(t.name)
		end
		b.key = t.key
		b:SetPoint("BOTTOMLEFT", menu, "TOPLEFT", tx, y - 32)
		b:SetScript("OnClick", function()
			mod.db.menuTab = t.key
			if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
			Fill()
		end)
		menu.tabs[i] = b
		tx = tx + b:GetWidth() + 2
	end
	y = y - 32
	local rule = Rule(menu)
	rule:SetPoint("TOPLEFT", PAD + 2, y)
	rule:SetWidth(inner - 4)
	y = y - 12

	checks = CreateFrame("Frame", nil, menu)
	checks:SetPoint("TOPLEFT", PAD, y)
	checks:SetWidth(inner)
	checks.top = -y

	-- the sliders (on the look's tab), in two columns: the map's (how far in, its size and colour) and the
	-- minimap's detail; back to their defaults
	local sliders = CreateFrame("Frame", nil, menu)
	menu.sliders = sliders
	sliders:SetPoint("TOPLEFT", checks, "BOTTOMLEFT", 0, -10)
	sliders:SetWidth(inner)
	local function Head(text, x)
		local head = sliders:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		head:SetTextColor(HEAD[1], HEAD[2], HEAD[3])
		head:SetPoint("TOPLEFT", x + 2, 0)
		head:SetText(text)
		local rule = Rule(sliders)
		rule:SetPoint("LEFT", head, "RIGHT", 6, 0)
		rule:SetWidth(math.max(1, COL - 10 - (head:GetStringWidth() or 40)))
	end
	Head(L["Detail"], 0)
	Head(L["Minimap"], COL + 16)
	zoomRow = SliderRow(sliders, COL, { label = L["Deepest zoom"], icon = Icon("INV_Misc_Spyglass_02"), range = mod.MAX_ZOOM,
		get = function() return mod.db.maxZoom end, set = mod.SetMaxZoom,
		tip = L["How far in the map zooms, in times the whole-world view (cities go half as far again). Past about 48 the art is only enlarged."] })
	miniRow = SliderRow(sliders, COL, { label = L["Minimap detail from"], icon = Icon("Spell_Nature_FarSight"), range = mod.MINI_FROM,
		get = function() return mod.db.minimapFrom end,
		set = function(v) mod.db.minimapFrom = v if mod.RefreshView then mod.RefreshView() end end,
		enabled = function() return mod.db.minimap and (mod.db.minimapMix or 0) > 0 end,
		tip = L["How far in the minimap's detail starts to mix in: lower comes in sooner, higher later."] })
	opacityRow = SliderRow(sliders, COL, { label = L["Minimap opacity"], icon = Icon("Spell_Nature_FarSight"), range = { 0, 1, 0.05 },
		get = function() return mod.db.minimapDeep end,
		set = function(v) mod.db.minimapDeep = v if mod.RefreshView then mod.RefreshView() end end,
		enabled = function() return mod.db.minimap and (mod.db.minimapMix or 0) > 0 end,
		fmt = "%d%%", show = function(v) return math.floor(v * 100 + 0.5) end,
		tip = L["The most the minimap's detail ever shows, at any zoom."] })
	-- (Options' other sliders, through its own setters)
	local options = mod.Options and mod:Options() or {}
	local made = { zoom = zoomRow, from = miniRow, opacity = opacityRow }
	menu.extraRows = {}
	for _, s in ipairs({
		{ "windowScale", L["Map size"], Icon("INV_Misc_Spyglass_02") },
		{ "colorMatch", L["Colour matching"], Icon("INV_Misc_Map_01") },
		{ "desaturate", L["Take colour out"], Icon("Spell_Shadow_Twilight") },
		{ "minimapMix", L["Minimap strength"], Icon("Spell_Nature_FarSight") },
		{ "moveFade", L["Fade while moving"], Icon("Ability_Stealth") },
	}) do
		local key, o = s[1], options[s[1]]
		if o and o.type == "range" then
			local r = SliderRow(sliders, COL, { label = s[2], icon = s[3], range = { o.min, o.max, o.step },
				get = function() return mod:Options()[key].get({ key }) end,
				set = function(v) mod:Options()[key].set({ key }, v) end,
				fmt = o.isPercent and "%d%%" or "%.2f", show = o.isPercent and function(v) return math.floor(v * 100 + 0.5) end or nil,
				tip = o.desc or s[2] })
			made[key] = r
			menu.extraRows[#menu.extraRows + 1] = r
		end
	end
	-- each column's, top down
	local height = 0
	for col, list in ipairs({ { "zoom", "windowScale", "colorMatch", "desaturate" }, { "from", "minimapMix", "opacity", "moveFade" } }) do
		local y = -22
		for _, key in ipairs(list) do
			local r = made[key]
			if r then
				r:SetPoint("TOPLEFT", (col - 1) * (COL + 16), y)
				y = y - SLIDER_H - 2
			end
		end
		height = math.max(height, -y)
	end
	-- the sliders back to their defaults (every slider, Options' too: WorldMap.lua's ResetSliders)
	local defaults = CreateFrame("Button", nil, sliders, "UIPanelButtonTemplate")
	defaults:SetSize(96, 22)
	defaults:SetPoint("TOPRIGHT", -2, -height - 4)
	-- the windowed map's size and place back to Blizzard's
	local resetWindow = CreateFrame("Button", nil, sliders, "UIPanelButtonTemplate")
	resetWindow:SetSize(150, 22)
	resetWindow:SetPoint("RIGHT", defaults, "LEFT", -6, 0)
	resetWindow:SetText(L["Reset size and place"])
	resetWindow:SetScript("OnClick", function() if mod.ResetWindow then mod:ResetWindow() end end)
	defaults:SetText(L["Defaults"])
	defaults:SetScript("OnClick", function() mod:ResetSliders() end)
	defaults:SetScript("OnEnter", function(self)
		Tip(self, "ANCHOR_TOP", L["Defaults"], { L["Every slider back to how OpenMap comes: the deepest zoom, the minimap's detail and opacity, and those in Options."] })
	end)
	defaults:SetScript("OnLeave", GameTooltip_Hide)
	sliders:SetHeight(height + 4 + 22 + 4)

	-- at the foot, on every tab: what the stars do
	local hint = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", PAD + 2, PAD - 2)
	hint:SetWidth(inner - 4)
	hint:SetJustifyH("LEFT")
	hint:SetText(L["A star puts that action or setting on the map as a button of its own."])

	mod.OnPinMode = function() RefreshTiles() RefreshFavorites() end
	-- the quest log opened or closed by Blizzard's own button too
	local log = map.QuestLog or _G.QuestMapFrame
	if log and log.HookScript then
		local function Changed() RefreshTiles() RefreshFavorites() end
		log:HookScript("OnShow", Changed)
		log:HookScript("OnHide", Changed)
	end
	menu:Hide()
	map:HookScript("OnShow", function() if mod.db.menuOpen then SetOpen(true) end end)
	map:HookScript("OnHide", function() menu:Hide() mod.SetPinMode(false) end)
	if map:IsShown() and mod.db.menuOpen then SetOpen(true) end
end

-- the menu: OpenMap's settings, opened with the map if it isn't (/openmap, Blizzard's settings page)
function mod:OpenMenu()
	if not menu then return false end
	if not map:IsShown() then
		ToggleWorldMap()
		C_Timer.After(0, function() if map:IsShown() then SetOpen(true) end end)
	else
		SetOpen(true)
	end
	return true
end

-- the menu's ticks and the favourites follow settings changed elsewhere
function mod:RefreshPanel()
	if menu and menu:IsShown() then Fill() end
	LightToggle()
	RefreshFavorites()
end
