"""Taken-over pin lifecycle and culling checks in the real Extras.lua, using Lua 5.1."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[2] / "OpenMap"


class CullingTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("""
            view = { .5, .5, 2, .1, .1 }
            stitched, shown, mapID = true, true, 12
            requests, visits = 0, 0
            mod = { defaults = {}, db = { pinsFrom = 1.5 } }
            function mod.IsStitched() return stitched end
            function mod.FromWorld(_, x, y) return x, y end
            function mod.ViewNow() if stitched then return unpack(view, 1, 3) end end
            function mod.ViewHalfExtents() return view[4], view[5] end
            function mod.RefreshView() requests = requests + 1 end
            function mod.OnStitchedChanged(on) stitched = on end
            S = { WORLD = 947, Rect = function() return 0, 1, 0, 1 end,
                  SetView = function() end }
            ns = { MapStitch = S, L = {}, GetModule = function() return mod end }
            function CreateFrame() return { Hide = function() end, SetScript = function() end } end
            function hooksecurefunc(t, name, hook)
                local original = t[name]
                t[name] = function(...)
                    local out = { original(...) }
                    hook(...)
                    return unpack(out)
                end
            end
            function Up(fn, name)
                for i = 1, 100 do
                    local n, v = debug.getupvalue(fn, i)
                    if not n then break end
                    if n == name then return v end
                end
                error('missing upvalue ' .. name)
            end
            function Put(fn, name, value)
                for i = 1, 100 do
                    local n = debug.getupvalue(fn, i)
                    if not n then break end
                    if n == name then debug.setupvalue(fn, i, value) return end
                end
                error('missing upvalue ' .. name)
            end
            function Holder()
                local f = { shown = false }
                function f:Show() self.shown = true end
                function f:Hide() self.shown = false end
                function f:IsShown() return self.shown end
                function f:SetPosition(x, y) self.x, self.y = x, y end
                function f:OnReleased()
                    self:Hide()
                    if self.icon then self.icon.parent = nil end
                    self.icon = nil
                end
                return f
            end
            pool = { active = {}, inactive = {} }
            function pool:Release(frame)
                frame:OnReleased()
                self.active[frame] = nil
                self.inactive[#self.inactive + 1] = frame
            end
            function pool:ReleaseAll()
                for frame in pairs(self.active) do self:Release(frame) end
            end
            map = { pinPools = { HereBeDragonsPinsTemplate = pool } }
            function map:GetMapID() return mapID end
            function map:IsShown() return shown end
            function map:AcquirePin(_, icon, x, y)
                local f = table.remove(pool.inactive) or Holder()
                pool.active[f] = true
                f.icon, icon.parent = icon, f
                f:Show()
                f:SetPosition(x, y)
                return f
            end
            function Icon() return { GetParent = function(self) return self.parent end } end
            function Provider()
                local p = { GetMap = function() return map end, data = {}, lastMap = -1 }
                function p:HandlePin(icon, data)
                    if not self.moveOnly then
                        map:AcquirePin('HereBeDragonsPinsTemplate', icon, data.mapX, data.mapY)
                    end
                end
                function p:RemoveAllData() pool:ReleaseAll() end
                function p:RefreshAllData()
                    if self.lastMap ~= mapID or self.forceUpdate then
                        self:RemoveAllData()
                        for icon, data in pairs(self.data) do self:HandlePin(icon, data) end
                        self.lastMap, self.forceUpdate = mapID, false
                    end
                end
                return p
            end
        """)
        self.lua.execute((ROOT / "Map/Extras.lua").read_text(encoding="utf-8"),
                         "OpenMap", self.lua.globals().ns)
        self.lua.execute("""
            Put(mod.SetupExtras, 'map', map)
            SetupPins = Up(Up(mod.SetupExtras, 'SetUpAllPins'), 'SetUpPins')
            Up(mod.SetupExtras, 'SetUpCull')()
            provider = Provider()
            SetupPins('HereBeDragons-Pins-2.0', { worldmapProvider = provider })
            provider:RefreshAllData()
            CullPins = Up(S.SetView, 'hook')
            recordSets = Up(CullPins, 'recordSets')
            local originalPairs = pairs
            pairs = function(t)
                local iter, state, key = originalPairs(t)
                local tracked = false
                for _, records in ipairs(recordSets) do
                    if records == t then tracked = true break end
                end
                if not tracked then return iter, state, key end
                return function(s, k)
                    local nk, value = iter(s, k)
                    if nk then visits = visits + 1 end
                    return nk, value
                end, state, key
            end
            function Add(x, y, p)
                p = p or provider
                local icon = Icon()
                local data = { uiMapID = mapID, mapX = x, mapY = y }
                p.data[icon] = data
                p:HandlePin(icon, data)
                return icon.parent, icon
            end
            function Cull(u, v, zoom, hu, hv)
                view = { u or view[1], v or view[2], zoom or view[3], hu or view[4], hv or view[5] }
                S.SetView(view[1], view[2], view[4], view[5], view[3], view[3])
            end
            function Tracked()
                local n = 0
                for _, records in ipairs(recordSets) do for _ in pairs(records) do n = n + 1 end end
                return n
            end
        """)

    def test_release_drops_records_and_never_reshows_inactive_holder(self):
        self.lua.execute("""
            local f = Add(.9, .9)
            Cull()
            assert(not f:IsShown())
            pool:Release(f)
            assert(Tracked() == 0)
            Cull(.9, .9)
            assert(not f:IsShown())
        """)

    def test_reuse_and_same_map_forced_refresh_replace_old_state(self):
        self.lua.execute("""
            local old, icon = Add(.9, .9)
            Cull()
            provider.data[icon] = nil
            pool:Release(old)
            local reused = Add(.5, .5)
            assert(old == reused)
            Cull()
            assert(reused:IsShown() and Tracked() == 1)
            provider.forceUpdate = true
            provider:RefreshAllData()
            assert(Tracked() == 1)
            provider:RemoveAllData()
            assert(Tracked() == 0)
        """)

    def test_noop_refresh_keeps_hidden_pins_for_later_pan(self):
        self.lua.execute("""
            local f = Add(.9, .9)
            Cull()
            provider:RefreshAllData()
            assert(not f:IsShown() and Tracked() == 1)
            Cull(.9, .9)
            assert(f:IsShown())
        """)

    def test_hidden_zoom_and_small_pans_do_not_rescan_1900_pins(self):
        self.lua.execute("""
            for i = 1, 1900 do Add(.9, .9) end
            Cull(.5, .5, 1)
            visits = 0
            for i = 1, 600 do Cull(.5 + i / 100000, .5, 1) end
            assert(visits == 0, 'hidden pins rescanned: ' .. visits)
            Cull(.5, .5, 2)
            visits = 0
            for i = 1, 600 do Cull(.5 + i / 100000, .5, 2) end
            assert(visits == 0, 'small pans rescanned: ' .. visits)
        """)

    def test_margin_boundary_zoom_and_aspect_ratio_changes_recull(self):
        self.lua.execute("""
            local f = Add(.63, .5)
            Cull()
            assert(f:IsShown())
            visits = 0
            Cull(.54, .5)
            assert(visits > 0)
            Cull(.5, .5, 4, .02, .1)
            assert(not f:IsShown())
            Cull(.5, .5, 4, .2, .1)
            assert(f:IsShown())
            local vertical = Add(.5, .63)
            Cull()
            Cull(.5, .5, 4, .2, .02)
            assert(not vertical:IsShown())
            Cull(.5, .5, 4, .2, .2)
            assert(vertical:IsShown())
        """)

    def test_zoom_threshold_crossings_and_setting_changes(self):
        self.lua.execute("""
            local f = Add(.5, .5)
            Cull(.5, .5, 1)
            assert(not f:IsShown())
            Cull(.5, .5, 1.5)
            assert(f:IsShown())
            mod.db.pinsFrom = 3
            Cull()
            assert(not f:IsShown())
            mod.db.pinsFrom = 1
            Cull()
            assert(f:IsShown())
        """)

    def test_stationary_addition_and_movement_invalidate_cached_view(self):
        self.lua.execute("""
            Cull()
            requests = 0
            local f, icon = Add(.9, .9)
            assert(requests > 0)
            Cull()
            assert(not f:IsShown())
            provider.moveOnly = true
            requests = 0
            provider:HandlePin(icon, { uiMapID = mapID, mapX = .5, mapY = .5 })
            assert(requests > 0)
            Cull()
            assert(f:IsShown())
        """)

    def test_owner_hidden_holder_is_not_claimed_by_culling(self):
        self.lua.execute("""
            local f = Add(.9, .9)
            f:Hide()
            Cull()
            Cull(.9, .9)
            assert(not f:IsShown())
        """)

    def test_gamepad_reposition_that_shows_holder_is_culled_again(self):
        self.lua.execute("""
            local f, icon = Add(.9, .9)
            Cull()
            assert(not f:IsShown())
            function f:SetPosition(x, y)
                self.x, self.y = x, y
                self:Show()
            end
            provider.moveOnly = true
            provider:HandlePin(icon, { uiMapID = mapID, mapX = .8, mapY = .8 })
            Cull()
            assert(not f:IsShown())
        """)

    def test_retained_pins_are_reculled_after_map_reopens(self):
        self.lua.execute("""
            local near, far = Add(.5, .5), Add(.9, .9)
            Cull()
            assert(near:IsShown() and not far:IsShown())
            shown = false
            Cull(.5, .5, 1)
            assert(Tracked() == 2)
            shown = true
            Cull()
            assert(not near:IsShown() and not far:IsShown())
            Cull(.5, .5, 2)
            assert(near:IsShown() and not far:IsShown())
        """)

    def test_library_positions_without_map_coordinates_follow_zoom_rule(self):
        self.lua.execute("""
            local icon = Icon()
            provider:HandlePin(icon, {})
            local f = icon.parent
            Cull()
            assert(f:IsShown())
            Cull(.5, .5, 1)
            assert(not f:IsShown())
            Cull(.5, .5, 2)
            assert(f:IsShown())
        """)

    def test_shared_pool_release_cleans_all_library_copies(self):
        self.lua.execute("""
            local other = Provider()
            SetupPins('HereBeDragonsOther-Pins-2.0', { worldmapProvider = other })
            local f, icon = Add(.9, .9)
            other.moveOnly = true
            other:HandlePin(icon, { uiMapID = mapID, mapX = .9, mapY = .9 })
            assert(Tracked() == 2)
            pool:Release(f)
            assert(Tracked() == 0)
        """)

    def test_map_change_and_stitching_exit_restore_and_clear_records(self):
        self.lua.execute("""
            local f, icon = Add(.9, .9)
            Cull()
            mapID = 13
            provider.data[icon] = nil
            provider:RefreshAllData()
            assert(Tracked() == 0 and not f:IsShown())
            local kept = Add(.9, .9)
            Cull()
            mod.OnStitchedChanged(false)
            assert(kept:IsShown() and Tracked() == 0)
            mod.OnStitchedChanged(true)
            shown = false
            Cull()
            shown = true
            visits = 0
            Cull()
            assert(visits == 0)
        """)


if __name__ == "__main__":
    unittest.main()
