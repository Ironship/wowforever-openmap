--------------------------------------------------------------------------------
-- Blizzard's map pins configure mouse input in CheckMouseButtonPassthrough and
-- SuperTrackablePinMixin:UpdateMousePropagation, called from OnAcquired. Their
-- C setters are restricted in combat when the map's scroll state is tainted.
-- Defer those two methods, then apply the last request when combat ends.
--
-- CreateFromMixins copies methods, so point the existing mixins and pins once;
-- future pins inherit the guards before OnAcquired runs. A new pool's first pin
-- is also found by MarkCanvasDirty, immediately before OnAcquired. Never scan
-- every active pin on each Acquire: creating N pins would do O(N^2) work.
-- shortcut: private mixins copied before setup and custom direct C-setter calls
-- need their own guard; revisit if a map addon uses either path.
--------------------------------------------------------------------------------

local _, ns = ...
local mod = ns:GetModule("worldmap")

local map
local original
local originalPropagation
local waiting = setmetatable({}, { __mode = "k" })
local seen = setmetatable({}, { __mode = "k" })
local owner = {}

local function Deferred(pin, ...)
	if InCombatLockdown() then
		local w = waiting[pin] or {} waiting[pin] = w
		w.passthrough = { n = select("#", ...), ... }
		return
	end
	local w = waiting[pin]
	if w then
		w.passthrough = nil
		if w.propagation == nil then waiting[pin] = nil end
	end
	return original(pin, ...)
end

local function DeferredPropagation(pin, ...)
	if InCombatLockdown() then
		local w = waiting[pin] or {} waiting[pin] = w
		w.propagation = { n = select("#", ...), ... }
		return
	end
	local w = waiting[pin]
	if w then
		w.propagation = nil
		if w.passthrough == nil then waiting[pin] = nil end
	end
	return originalPropagation(pin, ...)
end

local function Point(t)
	if type(t) ~= "table" then return end
	local ok, method = pcall(rawget, t, "CheckMouseButtonPassthrough")
	if ok and method == original then t.CheckMouseButtonPassthrough = Deferred end
	if originalPropagation then
		ok, method = pcall(rawget, t, "UpdateMousePropagation")
		if ok and method == originalPropagation then t.UpdateMousePropagation = DeferredPropagation end
	end
end

local function PointPool(pool)
	for _, enumerate in ipairs({ "EnumerateActive", "EnumerateInactive" }) do
		if type(pool[enumerate]) == "function" then
			local ok, iter, state, start = pcall(pool[enumerate], pool)
			if ok and iter then
				for pin in iter, state, start do Point(pin) end
			end
		end
	end
end

local function PointPins()
	for _, pool in pairs(map.pinPools or {}) do PointPool(pool) end
end

local function PointMixins()
	for _, value in pairs(_G) do Point(value) end
	PointPins()
end

local function ScanPools()
	for _, pool in pairs(map.pinPools or {}) do
		if not seen[pool] then
			seen[pool] = true
			PointPool(pool)
		end
	end
end

local function Flush()
	if InCombatLockdown() then return end
	for pin, w in pairs(waiting) do
		waiting[pin] = nil
		-- Released pins have no owning map; their old mouse setup is no longer needed.
		if pin.IsForbidden and not pin:IsForbidden() and pin:GetMap() then
			if w.passthrough then pcall(original, pin, unpack(w.passthrough, 1, w.passthrough.n)) end
			if w.propagation then pcall(originalPropagation, pin, unpack(w.propagation, 1, w.propagation.n)) end
		end
	end
end

function mod:SetupCombat(worldMap)
	if map then return end
	original = MapCanvasPinMixin and MapCanvasPinMixin.CheckMouseButtonPassthrough
	if type(original) ~= "function" then return end
	originalPropagation = SuperTrackablePinMixin and SuperTrackablePinMixin.UpdateMousePropagation
	map = worldMap
	PointMixins()
	ScanPools()
	map:HookScript("OnShow", PointPins)
	local sc = map.ScrollContainer
	if sc and sc.MarkCanvasDirty then hooksecurefunc(sc, "MarkCanvasDirty", ScanPools) end
	ns.RegisterEvent(owner, "ADDON_LOADED", PointMixins)
	ns.RegisterEvent(owner, "PLAYER_REGEN_ENABLED", Flush)
end
