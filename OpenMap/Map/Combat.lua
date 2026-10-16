--------------------------------------------------------------------------------
-- The map in combat. Blizzard's map pins set which mouse buttons pass through them each time one is
-- put on the map (MapCanvasPinMixin:CheckMouseButtonPassthrough: right-clicks go to the map, to zoom
-- out). On this engine that call (SetPassThroughButtons) is blocked in combat once the map's own code
-- has met an addon's, and the stitched map's zoom is OpenMap's (its zoom levels in Blizzard's scroll
-- container): every map refresh in combat (opening it, the quest log updating) was an "action
-- blocked" error. So in combat a pin's passthrough waits, and is set as soon as combat ends; until
-- then a right-click on a pin acquired in combat doesn't zoom the map out.
--------------------------------------------------------------------------------

local _, ns = ...
local mod = ns:GetModule("worldmap")

local map
local original                  -- Blizzard's CheckMouseButtonPassthrough
local waiting = setmetatable({}, { __mode = "k" })   -- pin -> the buttons it asked for, in combat
local owner = {}

local function Deferred(pin, ...)
	if InCombatLockdown() then
		waiting[pin] = { ... }
		return
	end
	waiting[pin] = nil
	return original(pin, ...)
end

-- every pin mixin made from MapCanvasPinMixin has its own copy of the method (CreateFromMixins copies
-- it), and so does every pin already made from one: each copy of Blizzard's is pointed at ours
local function Point(t)
	if type(t) ~= "table" then return end
	local ok, method = pcall(rawget, t, "CheckMouseButtonPassthrough")   -- (a forbidden table: left alone)
	if ok and method == original then t.CheckMouseButtonPassthrough = Deferred end
end

local function PointPins()
	for _, pool in pairs(map.pinPools or {}) do
		for _, enumerate in ipairs({ "EnumerateActive", "EnumerateInactive" }) do
			if type(pool[enumerate]) == "function" then
				local ok, iter, state, start = pcall(pool[enumerate], pool)
				if ok and iter then
					for pin in iter, state, start do Point(pin) end
				end
			end
		end
	end
end

local function Flush()
	if InCombatLockdown() then return end
	for pin, buttons in pairs(waiting) do
		waiting[pin] = nil
		if pin.IsForbidden and not pin:IsForbidden() then pcall(original, pin, unpack(buttons)) end
	end
end

function mod:SetupCombat(worldMap)
	map = worldMap
	original = MapCanvasPinMixin and MapCanvasPinMixin.CheckMouseButtonPassthrough
	if type(original) ~= "function" then return end
	for _, value in pairs(_G) do Point(value) end
	PointPins()
	-- (pin pools made since, and mixins of addons loaded since: their pins are pointed as the map opens)
	map:HookScript("OnShow", PointPins)
	ns.RegisterEvent(owner, "PLAYER_REGEN_ENABLED", Flush)
end
