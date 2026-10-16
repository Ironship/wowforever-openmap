"""Combat pin guards in Lua 5.1; python tools/offline-test/combat.py."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[2] / "OpenMap"


class CombatTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("""
            combat, visits, setters = false, 0, 0
            events, mod = {}, {}
            ns = { GetModule = function() return mod end }
            function ns.RegisterEvent(_, event, callback) events[event] = callback end
            function InCombatLockdown() return combat end
            function Pack(...) return { n = select('#', ...), ... } end
            function CreateFromMixins(...)
                local out = {}
                for i = 1, select('#', ...) do
                    for key, value in pairs(select(i, ...)) do out[key] = value end
                end
                return out
            end
            function hooksecurefunc(t, key, callback)
                local original = t[key]
                t[key] = function(...)
                    local result = Pack(original(...))
                    callback(...)
                    return unpack(result, 1, result.n)
                end
            end
            MapCanvasPinMixin = {
                SetOwningMap = function(self, map) self.owningMap = map end,
                GetMap = function(self) return self.owningMap end,
                IsForbidden = function(self) return self.forbidden or false end,
                OnLoad = function() end,
                Show = function() end,
                SetPassThroughButtons = function(self, ...)
                    assert(not combat, 'SetPassThroughButtons in combat')
                    setters = setters + 1
                    self.buttons = Pack(...)
                end,
                SetPropagateMouseClicks = function(self, enabled)
                    assert(not combat, 'SetPropagateMouseClicks in combat')
                    setters = setters + 1
                    self.propagates = enabled
                end,
                ShouldMouseButtonBePassthrough = function(_, button)
                    return button == 'RightButton'
                end,
            }
            function MapCanvasPinMixin:CheckMouseButtonPassthrough(...)
                self.receivedButtons = Pack(...)
                self:SetPassThroughButtons()
                local buttons = {}
                for i = 1, select('#', ...) do
                    local button = select(i, ...)
                    if self:ShouldMouseButtonBePassthrough(button) then
                        table.insert(buttons, button)
                    end
                end
                self:SetPassThroughButtons(unpack(buttons))
            end
            SuperTrackablePinMixin = {}
            function SuperTrackablePinMixin:DoesMapTypeAllowSuperTrack()
                return self:GetMap().allowSuperTrack
            end
            function SuperTrackablePinMixin:UpdateMousePropagation(...)
                self.receivedPropagation = Pack(...)
                self:SetPropagateMouseClicks(not self:DoesMapTypeAllowSuperTrack())
            end
            function SuperTrackablePinMixin:OnAcquired()
                self:UpdateMousePropagation()
            end
            ExistingPinMixin = CreateFromMixins(MapCanvasPinMixin, SuperTrackablePinMixin)
            function CreatePool(mixin)
                local pool = { active = {}, inactive = {} }
                function pool:Acquire()
                    local pin = table.remove(self.inactive)
                    local new = not pin
                    if new then pin = CreateFromMixins(mixin) end
                    self.active[pin] = true
                    return pin, new
                end
                function pool:Release(pin)
                    self.active[pin] = nil
                    pin:SetOwningMap(nil)
                    table.insert(self.inactive, pin)
                end
                function pool:EnumerateActive()
                    return function(state, previous)
                        local pin = next(state, previous)
                        if pin then visits = visits + 1 end
                        return pin
                    end, self.active
                end
                function pool:EnumerateInactive()
                    local index = 0
                    return function()
                        index = index + 1
                        local pin = self.inactive[index]
                        if pin then visits = visits + 1 end
                        return pin
                    end
                end
                return pool
            end
            map = {
                allowSuperTrack = true,
                pinPools = {},
                SetPropagateMouseClicks = MapCanvasPinMixin.SetPropagateMouseClicks,
                ScrollContainer = { MarkCanvasDirty = function() end },
                HookScript = function(self, script, callback) self[script] = callback end,
            }
            -- Order from Blizzard_MapCanvas.lua:280-335, Forever build 70425,
            -- Gethe/wow-ui-source@b401e0332adfbf0460d319b06d8ea29279a941f1.
            function map:AcquirePin(template, mixin)
                local pool = self.pinPools[template]
                if not pool then
                    pool = CreatePool(mixin)
                    self.pinPools[template] = pool
                end
                local pin, new = pool:Acquire()
                pin:SetOwningMap(self)
                if new then pin:OnLoad() end
                self.ScrollContainer:MarkCanvasDirty()
                pin:Show()
                pin:OnAcquired()
                pin:CheckMouseButtonPassthrough('RightButton')
                return pin
            end
        """)
        self.lua.execute((ROOT / "Map/Combat.lua").read_text(encoding="utf-8"),
                         "OpenMap", self.lua.globals().ns)

    def test_existing_copies_and_late_pool_are_guarded_before_on_acquired(self):
        self.lua.execute("""
            mod:SetupCombat(map)
            combat = true
            local pin = map:AcquirePin('late', ExistingPinMixin)
            assert(setters == 0)
            combat = false
            events.PLAYER_REGEN_ENABLED()
            assert(setters == 3 and pin.propagates == false)
            assert(pin.buttons.n == 1 and pin.buttons[1] == 'RightButton')
        """)

    def test_new_mixin_copies_inherit_guards(self):
        self.lua.execute("""
            mod:SetupCombat(map)
            local late = CreateFromMixins(MapCanvasPinMixin, SuperTrackablePinMixin)
            combat = true
            map:AcquirePin('late', late)
            assert(setters == 0)
            combat = false
            events.PLAYER_REGEN_ENABLED()
            assert(setters == 3)
        """)

    def test_addon_loaded_points_preexisting_private_copy_exported_later(self):
        self.lua.execute("""
            local late = CreateFromMixins(ExistingPinMixin)
            mod:SetupCombat(map)
            LaterPinMixin = late
            if events.ADDON_LOADED then events.ADDON_LOADED() end
            combat = true
            map:AcquirePin('late', LaterPinMixin)
            map:AcquirePin('late', LaterPinMixin)
            assert(setters == 0)
        """)

    def test_existing_active_and_inactive_pins(self):
        self.lua.execute("""
            local active = map:AcquirePin('existing', ExistingPinMixin)
            local inactive = map:AcquirePin('existing', ExistingPinMixin)
            map.pinPools.existing:Release(inactive)
            mod:SetupCombat(map)
            combat, setters = true, 0
            active:UpdateMousePropagation()
            active:CheckMouseButtonPassthrough('RightButton')
            local reused = map:AcquirePin('existing', ExistingPinMixin)
            assert(reused == inactive and setters == 0)
        """)

    def test_last_request_preserves_false_and_trailing_nil(self):
        self.lua.execute("""
            mod:SetupCombat(map)
            combat = true
            local pin = map:AcquirePin('pins', ExistingPinMixin)
            pin:CheckMouseButtonPassthrough('RightButton', false, nil)
            pin:UpdateMousePropagation(false, nil)
            map.allowSuperTrack = false
            combat = false
            events.PLAYER_REGEN_ENABLED()
            assert(pin.receivedButtons.n == 3)
            assert(pin.receivedButtons[2] == false and pin.receivedButtons[3] == nil)
            assert(setters == 3 and pin.propagates == true)
            assert(pin.receivedPropagation.n == 2)
            assert(pin.receivedPropagation[1] == false and pin.receivedPropagation[2] == nil)
            events.PLAYER_REGEN_ENABLED()
            assert(setters == 3)
        """)

    def test_released_and_forbidden_pins_are_not_flushed(self):
        self.lua.execute("""
            mod:SetupCombat(map)
            combat = true
            local released = map:AcquirePin('pins', ExistingPinMixin)
            local forbidden = map:AcquirePin('pins', ExistingPinMixin)
            map.pinPools.pins:Release(released)
            forbidden.forbidden = true
            combat = false
            events.PLAYER_REGEN_ENABLED()
            assert(setters == 0)
        """)

    def test_out_of_combat_request_replaces_pending_request(self):
        self.lua.execute("""
            mod:SetupCombat(map)
            combat = true
            local pin = map:AcquirePin('pins', ExistingPinMixin)
            combat = false
            pin:CheckMouseButtonPassthrough()
            pin:UpdateMousePropagation()
            assert(setters == 3 and pin.buttons.n == 0)
            events.PLAYER_REGEN_ENABLED()
            assert(setters == 3 and pin.buttons.n == 0)
        """)

    def test_1900_acquisitions_do_not_rescan_existing_pins(self):
        self.lua.execute("""
            mod:SetupCombat(map)
            combat, visits = true, 0
            for i = 1, 1900 do map:AcquirePin('many', ExistingPinMixin) end
            assert(setters == 0)
            assert(visits == 1, 'expected one new-pool visit, got ' .. visits)
            combat = false
            events.PLAYER_REGEN_ENABLED()
            assert(setters == 5700)
        """)

    def test_hbd_private_mixin_owns_its_mouse_passthrough(self):
        self.lua.execute("""
            -- HereBeDragons-Pins-2.0 r17 copies its private mixin before login,
            -- defines no-op SetPassThroughButtons and has no propagation call.
            local hbd = CreateFromMixins(MapCanvasPinMixin)
            local custom = function() end
            hbd.SetPassThroughButtons = custom
            hbd.OnAcquired = function() end
            mod:SetupCombat(map)
            combat = true
            for i = 1, 20 do
                local pin = map:AcquirePin('hbd', hbd)
                assert(pin.SetPassThroughButtons == custom)
            end
            assert(setters == 0)
            combat = false
            events.PLAYER_REGEN_ENABLED()
            assert(setters == 0)
        """)


if __name__ == "__main__":
    unittest.main()
