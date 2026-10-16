--------------------------------------------------------------------------------
-- The map's menu: the OpenMap button in the map's bottom-left corner opens a floating
-- panel in the map window's own frame (its metal border; bronze edges and rules): search,
-- the actions (find me, drop a pin, the quest log, report a problem, options), the
-- checklist of what the map shows, and the deepest zoom. Drag it by its body; it remembers
-- where it was and whether it was open. A star on an action or a setting puts it on the
-- map as a button of its own, in the row beside the OpenMap button (favourites).
--------------------------------------------------------------------------------

local _, ns = ...
local mod = ns:GetModule("worldmap")
local S = ns.MapStitch
local L = ns.L

local d = mod.defaults
d.menuPos = false               -- { point, relPoint, x, y } on the map once dragged
d.menuOpen = false
d.favorites = {}                -- action and row ids, in the order they were starred: a button each on the map

local map, sc, menu, toggle, checks, favBar, tiles, zoomRow, miniRow, opacityRow
local W, PAD, COL = 480, 16, 224
local BAR_X, BAR_Y = 2, 1       -- the OpenMap button's corner, as Blizzard's quest log button sits in the other
                                --  (over the window's resize grip: it still catches just outside the corner)
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
local function IconBorder(owner, tex, size)
	local border = owner:CreateTexture(nil, "OVERLAY")
	if HasAtlas(FRAME_ATLAS) then
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
local function FramedIcon(owner, size)
	local slot = owner:CreateTexture(nil, "BACKGROUND", nil, 1)
	slot:SetSize(size, size)
	slot:SetColorTexture(0, 0, 0, 0.6)
	local icon = owner:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("CENTER", slot)
	icon.slot, icon.size = slot, size
	IconBorder(owner, slot, size)
	return icon
end

local function ShowIcon(icon, look)
	local square = SetIcon(icon, look)
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
		{ L["Find me"], id = "find", icon = Icon("Ability_Tracking"), tip = L["Glide to where you are. Middle-click the map to center on you at the current zoom."],
			run = function() mod:FindMe() end },
		{ L["Drop a pin"], id = "pin", icon = Icon("Ability_Hunter_SniperShot"),
			tip = L["Click, then click the map to drop a pin (Ctrl-click the map does it any time). Right-click: remove the pin."],
			run = function(button)
				if button == "RightButton" then
					mod.SetPinMode(false)
					if mod.ClearPin then mod.ClearPin() end
				else
					mod.SetPinMode(not mod.PinMode())
				end
			end,
			lit = function() return mod.PinMode() end, right = true },
	}
	if map and map.HandleUserActionToggleSidePanel then
		list[#list + 1] = { L["Quest log"], id = "questlog", icon = Icon("INV_Misc_Book_08"),
			tip = L["Show or hide the quest log beside the map, for more room for the map."],
			run = ToggleQuestLog, lit = QuestLogShown }
	end
	list[#list + 1] = { L["Report a problem"], id = "report", icon = Icon("INV_Misc_Note_01"),
		tip = L["OpenMap is in beta: circle anything that looks wrong and tell us about it."],
		run = function() mod:ToggleReport() end }
	list[#list + 1] = { L["Options"], id = "options", icon = Icon("Trade_Engineering"), tip = L["All of OpenMap's settings."],
		run = function() if ns.OpenOptions then ns.OpenOptions() end end }
	return list
end

-- the checklist: { header } or { label, get, set, id = a name for it that doesn't change (favourites), icon = }
local function Rows()
	local db = mod.db
	local function opt(key) return function() return db[key] end, function(v) db[key] = v mod:Refresh() end end
	local function row(label, id, icon, get, set) return { label, get, set, id = id, icon = icon } end
	local function optRow(label, key, icon) local get, set = opt(key) return row(label, key, icon, get, set) end
	local faction = ns.Safe.Call(UnitFactionGroup, "player")
	local rows = {
		{ L["Places"] },
		optRow(L["Dungeons, boats, zeppelins"], "icons", { atlas = "dungeon", texture = "Interface\\Icons\\INV_Misc_Key_13", icon = true }),
		optRow(L["Flight masters"], "flight", { atlas = faction == "Horde" and "TaxiNode_Horde" or "TaxiNode_Alliance",
			texture = "Interface\\Icons\\Ability_Mount_Wyvern_01", icon = true }),
		optRow(L["Boat and zeppelin routes"], "routes", { atlas = "Ships_CargoShip-Map", texture = "Interface\\Icons\\INV_Misc_Spyglass_02", icon = true }),
		optRow(L["Party and raid members"], "group", Icon("Spell_Holy_PrayerOfFortitude")),
	}
	-- Questie's quest icons: its own "Enable Map Icons" setting, switched as its options do
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
	if loaded and loaded("Questie") then
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
	rows[#rows + 1] = { L["Creatures"] }
	rows[#rows + 1] = folk(L["Rare mobs"], "rare")
	rows[#rows + 1] = { L["Map"] }
	rows[#rows + 1] = optRow(L["Coordinates"], "coords", Icon("INV_Misc_Spyglass_03"))
	rows[#rows + 1] = optRow(L["Zone levels"], "zoneLevels", Icon("Spell_ChargePositive"))
	rows[#rows + 1] = optRow(L["Parchment border"], "border", Icon("INV_Scroll_03"))
	rows[#rows + 1] = optRow(L["Zone highlight on hover"], "hoverHighlight", Icon("Spell_Holy_MindVision"))
	rows[#rows + 1] = row(L["Fade while moving"], "moveFade", Icon("Ability_Stealth"), function() return (db.moveFade or 0) > 0 end,
		function(v) db.moveFade = v and 0.5 or 0 mod:Refresh() end)   -- (the amount: Options → Fade while moving)
	-- unexplored areas: darkened or hidden (neither ticked: shown as they are)
	for _, mode in ipairs({ { "dim", L["Darken unexplored areas"], "Spell_Shadow_Twilight" }, { "hide", L["Hide unexplored areas"], "Ability_Vanish" } }) do
		rows[#rows + 1] = row(mode[2], "unexplored." .. mode[1], Icon(mode[3]), function() return db.unexplored == mode[1] end,
			function(v) db.unexplored = v and mode[1] or "show" mod:Refresh() end)
	end
	rows[#rows + 1] = optRow(L["Follow the view"], "autoSwitch", Icon("Ability_Hunter_Pathfinding"))
	rows[#rows + 1] = { L["Reopen map (choose one)"] }
	for _, choice in ipairs({ { "player", L["Center on player"] }, { "always", L["Always remember"] },
		{ "visible", L["Remember while visible"] } }) do
		local mode = choice[1]
		rows[#rows + 1] = row(choice[2], "reopenView." .. mode, Icon("INV_Misc_Rune_01"),
			function() return mod.GetReopenView() == mode end,
			function() db.reopenView = mode mod:Refresh() end)
	end
	rows[#rows + 1] = { L["Up close"] }
	rows[#rows + 1] = optRow(L["Minimap detail"], "minimap", Icon("Spell_Nature_FarSight"))
	rows[#rows + 1] = optRow(L["Minimap in the gaps"], "gapMinimap", Icon("INV_Misc_Map_01"))
	rows[#rows + 1] = optRow(L["Soften and paper grain"], "soften", Icon("INV_Fabric_Linen_01"))
	rows[#rows + 1] = optRow(L["Caves underground"], "underground", Icon("Trade_Mining"))
	rows[#rows + 1] = { L["Tools"] }
	if mod.TogglePaint then
		rows[#rows + 1] = row(L["Map notes"], "paint", Icon("INV_Misc_Note_02"), function() return mod:IsPainting() end,
			function(v) mod:TogglePaint(v) end)
	end
	if mod.ToggleDebugOverlay then
		rows[#rows + 1] = row(L["Debug overlay (FPS)"], "debug", Icon("INV_Misc_PocketWatch_01"), function() return mod:IsDebugOverlay() end,
			function(v) mod:ToggleDebugOverlay(v) end)
	end
	return rows
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
local function Tile(parent, w, h, iconSize)
	local b = CreateFrame("Button", nil, parent, iconSize and "BackdropTemplate" or nil)
	b:SetSize(w, h)
	b.boxed = iconSize ~= nil
	b.icon = FramedIcon(b, iconSize or w)
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
		if HasAtlas(FRAME_ATLAS .. "-Mouseover") then hl:SetAtlas(FRAME_ATLAS .. "-Mouseover")
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
			{ L["Favourites sit in a row beside the OpenMap button, in the map's bottom-left corner."], 0.8, 0.8, 0.8 })
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
-- The bar: the OpenMap button in the map's bottom-left corner (above the coordinates, when
-- they show), then a button for each favourite. Lit while it's on; click to use it,
-- right-click to take it off the bar.
--------------------------------------------------------------------------------

local Fill, RefreshTiles

local function Entries()
	local byId = {}
	for _, e in ipairs(Actions()) do byId[e.id] = e end
	for _, r in ipairs(Rows()) do if r.id then byId[r.id] = r end end
	return byId
end

-- the bar's place: past whatever Blizzard or another addon keeps in that corner, and over the
-- coordinates bar when it shows
local function PlaceToggle()
	local left, bottom = sc:GetLeft(), sc:GetBottom()
	local x = BAR_X
	for _, f in ipairs(map.overlayFrames or {}) do
		local fl, fb, fr = f:IsShown() and f:GetLeft(), f:GetBottom(), f:GetRight()
		-- (a button in the corner, not a frame across the map: an addon's can span its width)
		if fl and left and fb and fr and fl - left < 40 and fb - bottom < 40 and fr - fl < 220 then
			x = math.max(x, fr - left + 4)
		end
	end
	toggle:ClearAllPoints()
	toggle:SetPoint("BOTTOMLEFT", sc, "BOTTOMLEFT", x, mod.db.coords and 18 + BAR_Y or BAR_Y)
end

-- the room left for favourites: to the map's right edge, or Blizzard's buttons in the
-- bottom-right corner (the quest log's)
local function Room()
	local sr, sb, tr = sc:GetRight(), sc:GetBottom(), toggle:GetRight()
	if not (sr and sb and tr) then return math.huge end   -- (not laid out yet: the next refresh trims it)
	local limit = sr - 8
	local frames = { mod.maxLogToggle }             -- (Window.lua's quest log button, full screen)
	for _, f in ipairs(map.overlayFrames or {}) do frames[#frames + 1] = f end
	for _, f in ipairs(frames) do
		local fl, fb = f:IsShown() and f:GetLeft(), f:GetBottom()
		if fl and fb and fb - sb < 60 and fl > tr then limit = math.min(limit, fl - 6) end
	end
	return limit - tr - 6
end

local function RefreshFavorites()
	if not favBar then return end
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
				b = Tile(favBar, FAV, FAV)
				b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
				b:SetScript("OnClick", function(self, button)
					if button == "RightButton" and (IsShiftKeyDown() or not self.entry.right) then
						SetFavorite(self.entry.id, false)
					elseif self.entry.run then
						self.entry.run(button)
					else
						self.entry[3](not self.entry[2]())
					end
					RefreshFavorites()
					if menu and menu:IsShown() then Fill() end
				end)
				b:SetScript("OnEnter", function(self)
					local e2 = self.entry
					local state = State(e2)
					local off = e2.right and L["Shift-right-click: take it off the map"] or L["Right-click: take it off the map"]
					Tip(self, "ANCHOR_TOP", e2[1],
						e2.run and { e2.tip } or { state == "on" and L["On: click to turn it off"] or L["Off: click to turn it on"] },
						{ off .. " " .. L["(the stars in the OpenMap menu put buttons here)"], 0.6, 0.6, 0.6 })
				end)
				b:SetScript("OnLeave", GameTooltip_Hide)
				favBar.buttons[n] = b
			end
			b.entry = e
			ShowIcon(b.icon, e.icon)
			SetLit(b, State(e))
			b:ClearAllPoints()
			b:SetPoint("BOTTOMLEFT", favBar, "BOTTOMLEFT", x, 0)
			b:SetShown(x + FAV <= room)             -- (no further than the room there is)
			x = x + FAV + 4
		end
	end
	favBar:SetWidth(math.max(1, x))
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

local filling = false
Fill = function()
	RefreshTiles()
	local rows = Rows()
	-- two columns, split at the section boundary nearest the middle
	local split, best = #rows, math.huge
	for i, row in ipairs(rows) do
		if not row[2] and math.abs(i - #rows / 2) < best then split, best = i, math.abs(i - #rows / 2) end
	end
	checks.heads = checks.heads or {}
	checks.boxes = checks.boxes or {}
	for _, it in ipairs(checks.heads) do it:Hide() it.rule:Hide() end
	for _, it in ipairs(checks.boxes) do it:Hide() it.hit:Hide() it.star:Hide() end
	local nh, nb, tallest = 0, 0, 0
	for col = 1, 2 do
		local y = 0
		local x0 = (col - 1) * (COL + 8)
		local from, to = col == 1 and 1 or split, col == 1 and split - 1 or #rows
		for i = from, to do
			local row = rows[i]
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
				if y < 0 then y = y - 8 end
				it:ClearAllPoints()
				it:SetPoint("TOPLEFT", x0 + 2, y)
				it:SetText(row[1])
				it.rule:SetWidth(math.max(1, COL - 10 - (it:GetStringWidth() or 60)))
				it:Show()
				it.rule:Show()
				y = y - 20
			else
				nb = nb + 1
				local it = checks.boxes[nb]
				if not it then
					it = CreateFrame("CheckButton", nil, checks, "UICheckButtonTemplate")
					it:SetSize(22, 22)
					it:SetScript("OnClick", function(self) self.row[3](self:GetChecked() and true or false) RefreshFavorites() end)
					it.icon = checks:CreateTexture(nil, "ARTWORK")
					it.icon:SetSize(16, 16)
					it.icon:SetPoint("LEFT", it, "RIGHT", 1, 0)
					it.border = IconBorder(checks, it.icon, 16)   -- (spell icons only: map symbols go bare)
					it.label = checks:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
					it.label:SetPoint("LEFT", it.icon, "RIGHT", 5, 0)
					-- the label clicks the box too
					it.hit = CreateFrame("Button", nil, checks)
					it.hit:SetHeight(20)
					it.hit:SetPoint("LEFT", it.icon, "LEFT", 0, 0)
					it.hit:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
					it.hit:SetScript("OnClick", function() it:Click() end)
					it.star = MakeStar(checks, function() Fill() RefreshFavorites() end)
					checks.boxes[nb] = it
				end
				it.row = row
				it:ClearAllPoints()
				it:SetPoint("TOPLEFT", x0, y + 1)
				it.border:SetShown(SetIcon(it.icon, row.icon or Icon("INV_Misc_QuestionMark")))
				it.label:SetText(row[1])
				it:SetChecked(row[2]() and true or false)
				it.hit:SetWidth(COL - 46)
				SetStar(it.star, row.id)
				it.star:ClearAllPoints()
				it.star:SetPoint("TOPLEFT", x0 + COL - 16, y - 3)
				it.star:SetShown(row.id ~= nil)
				it:Show()
				it.hit:Show()
				y = y - 20
			end
		end
		tallest = math.max(tallest, -y)
	end
	checks:SetHeight(tallest)
	zoomRow:Fill()
	miniRow:Fill()
	opacityRow:Fill()
	menu:SetHeight(checks.top + tallest + 14 + zoomRow:GetHeight() + 2 + miniRow:GetHeight() + 2 + opacityRow:GetHeight() + 26 + PAD)
end

local function Place()
	menu:ClearAllPoints()
	local p = mod.db.menuPos
	if p then menu:SetPoint(p[1], map, p[2], p[3], p[4])
	else menu:SetPoint("BOTTOMLEFT", toggle, "TOPLEFT", 0, 6) end
end

local function SetOpen(on)
	mod.db.menuOpen = on and true or false
	if on then Fill() Place() menu:Show() else menu:Hide() end
	if toggle then SetLit(toggle, on and "on" or nil) end
end

-- a slider under the checklist (the deepest zoom, the minimap's): { label, icon, range { least, most,
-- step }, get, set, tip }; f:Fill() shows the setting as it is
local function SliderRow(parent, width, spec)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(width, 24)
	local icon = f:CreateTexture(nil, "ARTWORK")
	icon:SetSize(16, 16)
	icon:SetPoint("LEFT", 4, 0)
	SetIcon(icon, spec.icon)
	IconBorder(f, icon, 16)
	local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("LEFT", icon, "RIGHT", 5, 0)
	label:SetText(spec.label)
	f.value = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.value:SetPoint("RIGHT", -4, 0)
	f.value:SetWidth(40)
	f.value:SetJustifyH("RIGHT")
	local lo, hi, step = spec.range[1], spec.range[2], spec.range[3]
	local s = CreateFrame("Slider", nil, f, "BackdropTemplate")
	s:SetOrientation("HORIZONTAL")
	s:SetHeight(16)
	s:SetPoint("LEFT", 130, 0)
	s:SetPoint("RIGHT", f.value, "LEFT", -8, 0)
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
	toggle = Tile(map, FAV, FAV)
	toggle:SetFrameLevel(level)               -- (over the window's resize grip there: Window.lua)
	ShowIcon(toggle.icon, OPENMAP_ICON)
	toggle:SetScript("OnClick", function() SetOpen(not menu:IsShown()) end)
	toggle:SetScript("OnEnter", function(self)
		Tip(self, "ANCHOR_TOP", "OpenMap", { L["Search, find me, map pins, the quest log, report a problem, options, and what the map shows."] })
	end)
	toggle:SetScript("OnLeave", GameTooltip_Hide)
	map:HookScript("OnShow", PlaceToggle)
	if map.RefreshOverlayFrames then hooksecurefunc(map, "RefreshOverlayFrames", function() RefreshFavorites() end) end

	-- the favourites, in a row to the right of it
	favBar = CreateFrame("Frame", nil, map)
	favBar:SetHeight(FAV)
	favBar:SetPoint("BOTTOMLEFT", toggle, "BOTTOMRIGHT", 6, 0)
	favBar:SetFrameLevel(level)
	map:HookScript("OnShow", function() RefreshFavorites() C_Timer.After(0, RefreshFavorites) end)   -- (and once laid out)
	sc:HookScript("OnSizeChanged", RefreshFavorites)
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
	pad[#pad + 1], pad[#pad + 2], pad[#pad + 3] = toggle, favBar, menu
	menu:SetWidth(W)
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
		-- kept relative to the map, so it moves with the window
		local s = self:GetEffectiveScale() / map:GetEffectiveScale()
		mod.db.menuPos = { "TOPLEFT", "TOPLEFT", self:GetLeft() * s - map:GetLeft(), self:GetTop() * s - map:GetTop() }
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
			if toggle then SetLit(toggle, nil) end
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
	local tw = (inner - gap * (#actions - 1)) / #actions
	tiles = {}
	for i, e in ipairs(actions) do
		local t = Tile(menu, tw, TILE_H, 26)
		t:SetPoint("TOPLEFT", PAD + (i - 1) * (tw + gap), y)
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
	y = y - TILE_H - 12
	local rule = Rule(menu)
	rule:SetPoint("TOPLEFT", PAD + 2, y)
	rule:SetWidth(inner - 4)
	y = y - 10

	checks = CreateFrame("Frame", nil, menu)
	checks:SetPoint("TOPLEFT", PAD, y)
	checks:SetWidth(inner)
	checks.top = -y

	local rule2 = Rule(menu)
	rule2:SetPoint("TOPLEFT", checks, "BOTTOMLEFT", 2, -6)
	rule2:SetWidth(inner - 4)
	zoomRow = SliderRow(menu, inner, { label = L["Deepest zoom"], icon = Icon("INV_Misc_Spyglass_02"), range = mod.MAX_ZOOM,
		get = function() return mod.db.maxZoom end, set = mod.SetMaxZoom,
		tip = L["How far in the map zooms, in times the whole-world view (cities go half as far again). Past about 48 the art is only enlarged."] })
	zoomRow:SetPoint("TOPLEFT", checks, "BOTTOMLEFT", 0, -12)
	miniRow = SliderRow(menu, inner, { label = L["Minimap detail from"], icon = Icon("Spell_Nature_FarSight"), range = mod.MINI_FROM,
		get = function() return mod.db.minimapFrom end,
		set = function(v) mod.db.minimapFrom = v if mod.RefreshView then mod.RefreshView() end end,
		enabled = function() return mod.db.minimap and (mod.db.minimapMix or 0) > 0 end,
		tip = L["How far in the minimap's detail starts to mix in: lower comes in sooner, higher later."] })
	miniRow:SetPoint("TOPLEFT", zoomRow, "BOTTOMLEFT", 0, -2)
	opacityRow = SliderRow(menu, inner, { label = L["Minimap opacity"], icon = Icon("Spell_Nature_FarSight"), range = { 0, 1, 0.05 },
		get = function() return mod.db.minimapDeep end,
		set = function(v) mod.db.minimapDeep = v if mod.RefreshView then mod.RefreshView() end end,
		enabled = function() return mod.db.minimap and (mod.db.minimapMix or 0) > 0 end,
		fmt = "%d%%", show = function(v) return math.floor(v * 100 + 0.5) end,
		tip = L["The most the minimap's detail ever shows, at any zoom."] })
	opacityRow:SetPoint("TOPLEFT", miniRow, "BOTTOMLEFT", 0, -2)
	local hint = menu:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", opacityRow, "BOTTOMLEFT", 2, -6)
	hint:SetWidth(inner - 4)
	hint:SetJustifyH("LEFT")
	hint:SetText(L["A star puts that action or setting on the map as a button, beside OpenMap's."])

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

-- the menu's ticks and the favourites follow settings changed elsewhere
function mod:RefreshPanel()
	if menu and menu:IsShown() then Fill() end
	RefreshFavorites()
end
