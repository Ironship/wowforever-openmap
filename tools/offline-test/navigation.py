"""Navigation behavior checks in Lua 5.1; run with python tools/offline-test/navigation.py."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[2] / "OpenMap"


class NavigationTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("""
            zone, playerU, playerV = 1, .5, .5
            mod = { defaults = {}, db = {}, char = {} }
            ns = {
                MapStitch = { Rect = function() return 0, 1, 0, 1 end },
                Safe = {
                    Call = function(fn, ...) if fn then return fn(...) end end,
                    XY = function(p) return p.x, p.y end,
                    IsSecret = function() return false end,
                },
                L = setmetatable({}, { __index = function(_, key) return key end }),
            }
            function ns:GetModule() return mod end
            C_Map = {
                GetBestMapForUnit = function() return zone end,
                GetPlayerMapPosition = function()
                    if playerU then return { x = playerU, y = playerV } end
                end,
            }
            function mod.ToWorld(_, x, y) return x, y end
            function mod.ViewNow() return .5, .5, 4 end
            function mod.HostMap() return 1 end
            function mod.ViewHalfExtents() return .1, .05 end
            function mod.IsStitched() return true end
            function mod.FitZoom() return 8 end
            function mod.Glide(u, v, zoom) target = { u, v, zoom } end
            function ns:Print() end
        """)
        self.lua.execute((ROOT / "Map/Nav.lua").read_text(encoding="utf-8"),
                         "OpenMap", self.lua.globals().ns)
        self.lua.execute("""
            function options()
                local opts = {}
                mod:NavOptions(opts,
                    function(info) return mod.db[info[#info]] end,
                    function(info, value) mod.db[info[#info]] = value end,
                    function() return false end)
                return opts
            end
        """)

    def test_one_exclusive_choice(self):
        self.lua.execute("""
            local opts = options()
            assert(opts.reopenView.type == 'select')
            assert(not opts.rememberView and not opts.rememberViewInView)
            local count = 0
            for _ in pairs(opts.reopenView.values) do count = count + 1 end
            assert(count == 3)
            for _, mode in ipairs({ 'player', 'always', 'visible' }) do
                opts.reopenView.set({ 'reopenView' }, mode)
                assert(opts.reopenView.get({ 'reopenView' }) == mode)
            end
        """)

    def test_saved_preferences_migrate(self):
        for old, expected in [('', 'player'), ('rememberView=true', 'always'),
                              ("reopenView='zone'", 'always'),
                              ('rememberView=false', 'player'),
                              ('rememberView=true,rememberViewInView=true', 'visible')]:
            with self.subTest(old=old):
                self.lua.execute(f"""
                    mod.db = {{ {old} }}
                    local opt = options().reopenView
                    assert(opt.get({{ 'reopenView' }}) == '{expected}')
                    assert(mod.db.reopenView == '{expected}')
                    assert(mod.db.rememberView == nil and mod.db.rememberViewInView == nil)
                """)

    def test_visible_mode_checks_both_axes_across_zones(self):
        self.lua.execute("""
            mod.db.reopenView = 'visible'
            mod:OnMapHidden()
            zone = 2
            assert(mod.SavedView() == .5)
            playerU = .61
            local u, v, zoom = mod.SavedView()
            assert(u == playerU and v == playerV and zoom == 8)
            playerU, playerV = .5, .56
            u, v, zoom = mod.SavedView()
            assert(u == playerU and v == playerV and zoom == 8)
            playerV = .5
            assert(mod.SavedView() == .5)
        """)

    def test_unknown_position_and_explicit_quest_map_do_not_restore(self):
        self.lua.execute("""
            mod.db.reopenView = 'visible'
            mod:OnMapHidden()
            playerU = nil
            assert(mod.SavedView() == nil)
            playerU = .5
            assert(mod.SavedView(999) == nil)
        """)

    def test_always_mode_restores_across_zones_outside_previous_view(self):
        self.lua.execute("""
            mod.db.reopenView = 'always'
            mod:OnMapHidden()
            playerU = .8
            assert(mod.SavedView() == .5)
            zone = 2
            local u, v, zoom = mod.SavedView(2)
            assert(u == .5 and v == .5 and zoom == 4)
            assert(mod.SavedView(999) == nil)
        """)

    def test_player_mode_never_restores(self):
        self.lua.execute("""
            mod.db.reopenView = 'player'
            mod:OnMapHidden()
            playerU, playerV = .8, .7
            local u, v, zoom = mod.SavedView()
            assert(u == playerU and v == playerV and zoom == 8)
            assert(mod.SavedView(999) == nil)
        """)

    def test_first_open_centers_on_player(self):
        self.lua.execute("""
            playerU, playerV = .8, .7
            local u, v, zoom = mod.SavedView(1)
            assert(u == playerU and v == playerV and zoom == 8)
        """)

    def test_find_me_can_preserve_zoom(self):
        self.lua.execute("""
            mod:FindMe(true)
            assert(target[1] == playerU and target[2] == playerV and target[3] == 4)
            mod:FindMe()
            assert(target[3] == 8)
        """)

    def test_map_menu_choices_are_exclusive(self):
        self.lua.execute((ROOT / "Map/Panel.lua").read_text(encoding="utf-8"),
                         "OpenMap", self.lua.globals().ns)
        self.lua.execute("""
            -- Reach the real menu rows without building game frames.
            local function upvalue(fn, wanted)
                for i = 1, 100 do
                    local name, value = debug.getupvalue(fn, i)
                    if name == wanted then return value end
                    if not name then break end
                end
                error('Missing menu function: ' .. wanted)
            end
            local rows = upvalue(upvalue(mod.RefreshPanel, 'Fill'), 'Rows')()
            local choices = {}
            for _, row in ipairs(rows) do
                assert(row.id ~= 'rememberView')
                if row.id and row.id:match('^reopenView%.') then
                    choices[#choices + 1] = row
                end
            end
            assert(#choices == 3)
            function mod:Refresh() end
            for _, selected in ipairs(choices) do
                selected[3](true)
                local checked = 0
                for _, row in ipairs(choices) do
                    if row[2]() then checked = checked + 1 end
                end
                assert(checked == 1 and selected[2]())
                selected[3](false)
                assert(selected[2]()) -- the current choice cannot be deselected
            end
        """)


if __name__ == "__main__":
    unittest.main()
