--------------------------------------------------------------------------------
-- The map in combat. Blizzard's map pins set which mouse buttons pass through them each time one is
-- put on the map, and super-tracked pins whether they take mouse clicks at all
-- (MapCanvasPinMixin:CheckMouseButtonPassthrough, SuperTrackablePinMixin:UpdateMousePropagation in
-- OnAcquired). On this engine those calls (SetPassThroughButtons, SetPropagateMouseClicks) are
-- blocked in combat once the map's own code has met an addon's, and the stitched map's zoom is
-- OpenMap's (its zoom levels in Blizzard's scroll container): every map refresh in combat (opening
-- it, the quest log updating) was an "action blocked" error. So in combat a pin's mouse setup waits,
-- and is set as soon as combat ends; until then a right-click on a pin acquired in combat doesn't
-- zoom the map out.
--
-- Every pin is covered as it is acquired, whenever that is: a pool hands one out a moment before
-- Blizzard's AcquirePin reaches OnAcquired and CheckMouseButtonPassthrough (Blizzard_MapCanvas.lua
-- :286-331), so each pool's Acquire is post-hooked, and MarkCanvasDirty - called right there, after
-- the pin exists and before those two calls - scans again, catching a pool made since (another
-- addon's pins, an addon loaded later, a template first used later). A pin pool's own Acquire and the
-- canvas's pinPools are read by Blizzard's own map code: neither is replaced and pinPools gets no
-- metatable, so that code keeps running untainted (HFWM's installed Taint.lua warns of exactly that
-- trap; its older PinTaint.lua took it).
--------------------------------------------------------------------------------

local _, ns = ...
local mod = ns:GetModule("worldmap")

local map                   -- the map, once set up
local original              -- Blizzard's CheckMouseButtonPassthrough
local originalPropagate     -- SetPropagateMouseClicks (a region method: present on every pin)
local waiting = setmetatable({}, { __mode = "k" })   -- pin -> { passthrough = {buttons}, propagate = {...} }
local propagate = setmetatable({}, { __mode = "k" }) -- pin -> its SetPropagateMouseClicks, before ours
local hooked = setmetatable({}, { __mode = "k" })    -- pool -> true (its Acquire post-hooked)
local owner = {}

local function Deferred(pin, ...)
	if InCombatLockdown() then
		local w = waiting[pin] or {} waiting[pin] = w
		w.passthrough = { ... }
		return
	end
	local w = waiting[pin]
	if w then
		w.passthrough = nil
		if w.propagate == nil then waiting[pin] = nil end
	end
	return original(pin, ...)
end

local function DeferredPropagate(pin, ...)
	if InCombatLockdown() then
		local w = waiting[pin] or {} waiting[pin] = w
		w.propagate = { ... }
		return
	end
	local w = waiting[pin]
	if w then
		w.propagate = nil
		if w.passthrough == nil then waiting[pin] = nil end
	end
	return propagate[pin](pin, ...)
end

-- every pin mixin made from MapCanvasPinMixin has its own copy of the method (CreateFromMixins copies
-- it), and so does every pin already made from one: each copy of Blizzard's is pointed at ours
local function Point(t)
	if type(t) ~= "table" then return end
	local ok, method = pcall(rawget, t, "CheckMouseButtonPassthrough")   -- (a forbidden table: left alone)
	if ok and method == original then t.CheckMouseButtonPassthrough = Deferred end
end

-- a pin's own SetPropagateMouseClicks (a region method, or an addon's own): taken once, skipped in
-- combat, set as soon as combat ends
local function PointPin(pin)
	Point(pin)
	if not originalPropagate then return end
	local ok, method = pcall(function() return pin.SetPropagateMouseClicks end)
	if ok and type(method) == "function" and method ~= DeferredPropagate then
		propagate[pin] = propagate[pin] or method
		pin.SetPropagateMouseClicks = DeferredPropagate
	end
end

local function PointPool(pool)
	for _, enumerate in ipairs({ "EnumerateActive", "EnumerateInactive" }) do
		if type(pool[enumerate]) == "function" then
			local ok, iter, state, start = pcall(pool[enumerate], pool)
			if ok and iter then
				for pin in iter, state, start do PointPin(pin) end
			end
		end
	end
end

local function PointPins()
	for _, pool in pairs(map.pinPools or {}) do PointPool(pool) end
end

local function Flush()
	if InCombatLockdown() then return end
	for pin, w in pairs(waiting) do
		waiting[pin] = nil
		if pin.IsForbidden and not pin:IsForbidden() then
			if w.passthrough then pcall(original, pin, unpack(w.passthrough)) end
			if w.propagate and propagate[pin] then pcall(propagate[pin], pin, unpack(w.propagate)) end
		end
	end
end

-- pools that exist now, and pools made since: each wrapped once, and the pins they hold pointed
-- (AcquirePin's own steps run after both of these hooks - see the header)
local function ScanPools()
	for _, pool in pairs(map.pinPools or {}) do
		if not hooked[pool] then
			hooked[pool] = true
			if type(pool.Acquire) == "function" then
				hooksecurefunc(pool, "Acquire", function(self) PointPool(type(self) == "table" and self or pool) end)
			end
			PointPool(pool)             -- (what it already holds: pins taken before this scan)
		end
	end
end

function mod:SetupCombat(worldMap)
	if map then return end
	original = MapCanvasPinMixin and MapCanvasPinMixin.CheckMouseButtonPassthrough
	if type(original) ~= "function" then return end
	map = worldMap
	originalPropagate = map.SetPropagateMouseClicks
	for _, value in pairs(_G) do Point(value) end   -- (mixin tables made before login: pointed once)
	PointPins()
	ScanPools()
	map:HookScript("OnShow", PointPins)             -- (the pins of every pool at each open: belt and braces)
	local sc = map.ScrollContainer
	if sc and sc.MarkCanvasDirty then hooksecurefunc(sc, "MarkCanvasDirty", ScanPools) end
	ns.RegisterEvent(owner, "PLAYER_REGEN_ENABLED", Flush)
end
