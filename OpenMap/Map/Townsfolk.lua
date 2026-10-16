--------------------------------------------------------------------------------
-- Townsfolk and rare mobs on the world map, from Questie's NPC database
-- (npcFlags, rank, spawns). Each kind is a pin set, built the first time it's
-- turned on (a few hundred NPCs a frame, so nothing stalls).
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.MapStitch
local mod = ns:GetModule("worldmap")

-- kind -> look, the zoom it shows from, and what picks its NPCs
local KINDS = {
	{ key = "vendor", name = "Vendors", flag = "VENDOR", zoom = 8,
		look = { texture = "Interface\\GossipFrame\\VendorGossipIcon", size = 14 } },
	{ key = "repair", name = "Repair", flag = "REPAIR", zoom = 6,
		look = { texture = "Interface\\Minimap\\Tracking\\Repair", fallback = "Interface\\GossipFrame\\VendorGossipIcon", size = 16 } },
	{ key = "innkeeper", name = "Innkeepers", flag = "INNKEEPER", zoom = 4,
		look = { texture = "Interface\\Minimap\\Tracking\\Innkeeper", fallback = "Interface\\GossipFrame\\BinderGossipIcon", size = 16 } },
	{ key = "banker", name = "Bankers", flag = "BANKER", zoom = 6,
		look = { texture = "Interface\\Minimap\\Tracking\\Banker", fallback = "Interface\\GossipFrame\\BankerGossipIcon", size = 16 } },
	{ key = "auctioneer", name = "Auctioneers", flag = "AUCTIONEER", zoom = 6,
		look = { texture = "Interface\\Minimap\\Tracking\\Auctioneer", fallback = "Interface\\GossipFrame\\VendorGossipIcon", size = 16 } },
	{ key = "stable", name = "Stable masters", flag = "STABLEMASTER", zoom = 6,
		look = { texture = "Interface\\Minimap\\Tracking\\StableMaster", fallback = "Interface\\GossipFrame\\PetitionGossipIcon", size = 16 } },
	{ key = "classTrainer", name = "Class trainers", flag = "TRAINER", class = true, zoom = 6,
		look = { texture = "Interface\\Minimap\\Tracking\\Class", fallback = "Interface\\GossipFrame\\TrainerGossipIcon", size = 16 } },
	{ key = "profTrainer", name = "Profession trainers", flag = "TRAINER", profession = true, zoom = 8,
		look = { texture = "Interface\\Minimap\\Tracking\\Profession", fallback = "Interface\\GossipFrame\\TrainerGossipIcon", size = 14 } },
	-- spirit healers: the game ships no graveyard table for this client, so they come from
	-- Questie's NPC spawns too (the Spirit Healer NPC; both factions use the same ones)
	{ key = "spirit", name = "Spirit healers", ids = { [6491] = true }, zoom = 3, hostile = true,
		look = { atlas = "poi-soulspiritghost", texture = "Interface\\Minimap\\ObjectIcons", size = 16 } },
	{ key = "rare", name = "Rare mobs", rare = true, zoom = 3, hostile = true,
		look = { atlas = "VignetteKillElite", texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", size = 18 } },
}
mod.TOWNSFOLK = KINDS

local d = mod.defaults
d.townsfolk = {}
for _, k in ipairs(KINDS) do d.townsfolk[k.key] = false end

local built = {}                -- kind key -> true once its pins exist
local building = false
local tries = 0                 -- retries while Questie's database loads
local RANK = { [2] = "Rare Elite", [4] = "Rare" }

local function Questie()
	local loader = _G.QuestieLoader
	if not loader then return end
	local ok, db = pcall(loader.ImportModule, loader, "QuestieDB")
	local ok2, zones = pcall(loader.ImportModule, loader, "ZoneDB")
	if ok and ok2 and db and db.NPCPointers and db.QueryNPCSingle and zones then return db, zones end
end

-- Questie at all: its loader carries the database. Without it there is nothing to wait for, so the
-- kinds asked for go back off and it is said once - here, not after a minute of silence.
function mod.QuestiePresent()
	return _G.QuestieLoader ~= nil
end

local told
function mod.QuestieMissing()
	if mod.QuestiePresent() then return false end
	if not told then
		told = true
		ns:Print("World map: Questie isn't loaded. Its quest icons, townsfolk, rares and dungeon quests aren't available.")
	end
	return true
end

local function PinEnter(pin)
	local n = pin.data
	GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
	GameTooltip:AddLine(n.name, 1, 0.82, 0)
	if n.sub then GameTooltip:AddLine(n.sub, 1, 1, 1) end
	local lv = n.min and (n.min == n.max and tostring(n.min) or (n.min .. "-" .. (n.max or n.min)))
	if lv or n.rank then
		GameTooltip:AddLine(((lv and (LEVEL .. " " .. lv)) or "") .. (n.rank and ("  " .. n.rank) or ""), 0.8, 0.8, 0.8)
	end
	GameTooltip:Show()
end

-- every wanted NPC, sorted into kinds; then pins for the kinds that are on
local function Build(kinds, done)
	local QDB, ZoneDB = Questie()
	if not QDB then return done(false) end
	local flags = QDB.npcFlags or {}
	local faction = UnitFactionGroup("player") == "Horde" and "H" or "A"
	local className = UnitClass("player")
	local classNames = {}
	for _, n in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do classNames[n] = true end

	local ids = {}
	for id in pairs(QDB.NPCPointers) do ids[#ids + 1] = id end
	local i = 0
	local Step
	local function Chunk()
		for _ = 1, 400 do
			i = i + 1
			local id = ids[i]
			if not id then return true end
			local f = QDB.QueryNPCSingle(id, "npcFlags") or 0
			local rank = QDB.QueryNPCSingle(id, "rank") or 0
			local want = {}
			for _, k in ipairs(kinds) do
				local hit
				if k.ids then
					hit = k.ids[id] or false
				elseif k.rare then
					hit = RANK[rank] ~= nil
				elseif flags[k.flag] and bit.band(f, flags[k.flag]) ~= 0 then
					hit = true
					if k.class or k.profession then
						local sub = QDB.QueryNPCSingle(id, "subName") or ""
						local cls
						for name in pairs(classNames) do
							if sub:find(name, 1, true) then cls = name break end
						end
						if k.class then hit = cls ~= nil and cls == className else hit = cls == nil end
					end
				end
				if hit then want[#want + 1] = k end
			end
			if #want > 0 then
				local friendly = QDB.QueryNPCSingle(id, "friendlyToFaction") or ""
				local spawns = QDB.QueryNPCSingle(id, "spawns")
				local info = {
					name = QDB.QueryNPCSingle(id, "name") or "?", sub = QDB.QueryNPCSingle(id, "subName"),
					min = QDB.QueryNPCSingle(id, "minLevel"), max = QDB.QueryNPCSingle(id, "maxLevel"), rank = RANK[rank],
				}
				for _, k in ipairs(want) do
					if (k.hostile or friendly:find(faction, 1, true)) and spawns then
						local set = S.PinSet("tf_" .. k.key, k.zoom, 3)
						for areaID, coords in pairs(spawns) do
							local uiMapID = ZoneDB:GetUiMapIdByAreaId(areaID)
							local l, r, t, b
							if uiMapID then l, r, t, b = S.Rect(uiMapID) end
							if l then
								for _, c in ipairs(coords) do
									if c[1] and c[1] >= 0 then
										local pin = S.AddPin(set, l + c[1] / 100 * (r - l), t + c[2] / 100 * (b - t), k.look, info)
										pin:SetScript("OnEnter", PinEnter)
										pin:SetScript("OnLeave", GameTooltip_Hide)
									end
								end
							end
						end
					end
				end
			end
		end
	end
	function Step()
		local ok, finished = pcall(Chunk)
		if not ok then
			geterrorhandler()(finished)
			return done(false)
		end
		if finished then return done(true) end
		C_Timer.After(0, Step)
	end
	Step()
end

-- shows / hides each kind; builds the ones turned on for the first time
function mod:RefreshTownsfolk()
	if not S.IsBuilt() then return end
	local todo = {}
	for _, k in ipairs(KINDS) do
		local on = self.db.townsfolk[k.key]
		if on and not built[k.key] then todo[#todo + 1] = k end
		local set = S.GetPinSet("tf_" .. k.key)
		if set then S.SetPinSetOn(set, on) end
	end
	if #todo == 0 or building then return end
	if mod.QuestieMissing() then
		-- (nothing to wait for: back off, so the menu shows what's real; the line above says why)
		for _, k in ipairs(todo) do self.db.townsfolk[k.key] = false end
		return
	end
	building = true
	for _, k in ipairs(todo) do built[k.key] = true end
	Build(todo, function(ok)
		building = false
		if not ok then
			-- Questie's database isn't ready yet (it loads after login), or a build failed: try again shortly
			for _, k in ipairs(todo) do
				built[k.key] = nil
				local set = S.GetPinSet("tf_" .. k.key)
				if set then S.ClearPinSet(set) end
			end
			tries = tries + 1
			if tries <= 12 then C_Timer.After(5, function() self:RefreshTownsfolk() end)
			else ns:Print("World map: townsfolk and rares need Questie's database, which isn't available.") end
			return
		end
		tries = 0
		self:RefreshTownsfolk()
	end)
end
