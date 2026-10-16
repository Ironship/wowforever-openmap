"""Unexplored-shading checks in the real Stitch.lua with Lua 5.1: the shade slider's strength
(0 takes the layers away), the darkened copies staying opaque (an overlap darkens once) and the
unfound cities following the slider."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[2] / "OpenMap"


class ShadingTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("""
            function Up(fn, wanted)
                for i = 1, 100 do
                    local name, value = debug.getupvalue(fn, i)
                    if not name then break end
                    if name == wanted then return value end
                end
                error('missing upvalue: ' .. wanted)
            end
            function Put(fn, wanted, value)
                for i = 1, 100 do
                    local name = debug.getupvalue(fn, i)
                    if not name then break end
                    if name == wanted then debug.setupvalue(fn, i, value) return end
                end
                error('missing upvalue: ' .. wanted)
            end
            function Frame()
                return {
                    shown = true,
                    Hide = function(self) self.shown = false end,
                    Show = function(self) self.shown = true end,
                    IsShown = function(self) return self.shown end,
                    SetShown = function(self, v) self.shown = v and true or false end,
                    SetScript = function() end,
                    SetAlpha = function(self, v) self.alpha = v end,
                    SetVertexColor = function(self, r, g, b, a) self.r, self.g, self.b, self.alpha = r, g, b, a end,
                    SetDesaturation = function(self, v) self.desat = v end,
                    SetDrawLayer = function() end,
                    AddMaskTexture = function() end,
                    RemoveMaskTexture = function() end,
                }
            end
            CreateFrame = Frame
            ns = { Media = { path = '' }, L = {} }
        """)
        self.lua.execute((ROOT / "Map/Stitch.lua").read_text(encoding="utf-8"), "OpenMap", self.lua.globals().ns)
        self.lua.execute("""
            S = ns.MapStitch
            Shade = Up(S.SetShadeStrength, 'Shade')
            pieces = Up(Shade.Unexplored, 'pieces')
            cities = Up(S.ApplyGrade, 'cities')
            zoneTex = Up(cities.Dim, 'zoneTex')
            Put(Shade.Colour, 'gradeNow', { 1, 0.1, 'dim' })   -- (the desaturation setting the map runs with)
            Shade.on = true
            dark, light = { unexplored = true }, { unexplored = false }
            pieces[1] = { dark }                -- a zone you haven't found: "all"
            pieces[2] = { dark, light }         -- a visited zone with some unexplored land
            z1, z2 = { frame = Frame() }, { frame = Frame(), dim = Frame(), pieces = {} }
            texDark, texLight, texTwin = Frame(), Frame(), Frame()
            z2.pieces[dark], z2.pieces[light] = { { texDark }, { texTwin, twin = true } }, { { texLight } }
            Shade.zones[1], Shade.zones[2] = z1, z2
            cityTex, bannerTex = Frame(), Frame()
            cities[1] = { mapID = 3, piece = dark, bannerTex = bannerTex }
            zoneTex[3] = { { cityTex } }
        """)

    def test_strength_zero_takes_the_layers_away_and_back(self):
        self.lua.execute("""
            S.SetShadeStrength(0)
            assert(Shade.Unexplored(1) == 'all')
            assert(not z1.frame.shown, 'an unfound zone keeps its shade layer at 0')
            assert(not z2.dim.shown, 'a visited zone keeps its darkened copies at 0')
            assert(texLight.shown, 'an explored piece is hidden with the shade at 0')
            S.SetShadeStrength(0.62)
            assert(z1.frame.shown and z2.dim.shown)
            S.SetShadeStrength(0)
            assert(not z1.frame.shown and not z2.dim.shown)
        """)

    def test_dark_copies_stay_opaque_and_follow_the_slider(self):
        self.lua.execute("""
            local D = Shade.DIM
            S.SetShadeStrength(0.62)                  -- the default: exactly how the map comes
            assert(texDark.alpha == 1, 'a darkened copy blends instead of replacing (overlaps darken twice)')
            assert(math.abs(texDark.r - D[1]) < 1e-9 and math.abs(texDark.g - D[2]) < 1e-9 and math.abs(texDark.b - D[3]) < 1e-9)
            assert(math.abs(texDark.desat - math.max(0.1, D[4])) < 1e-9)
            assert(not texTwin.shown, 'a darkened piece keeps its colour-match copy')
            S.SetShadeStrength(0.31)                  -- half way: half the colour work, still opaque
            assert(texDark.alpha == 1)
            assert(math.abs(texDark.r - (D[1] * 0.5 + 0.5)) < 1e-9, 'dark copy red: ' .. texDark.r)
            assert(math.abs(texDark.desat - (0.1 + (math.max(0.1, D[4]) - 0.1) * 0.5)) < 1e-9, 'dark copy desat: ' .. texDark.desat)
            assert(not texTwin.shown)
            assert(texLight.shown and math.abs(texLight.r - 1) < 1e-9, 'an explored piece is not shaded')
        """)

    def test_unfound_cities_follow_the_slider(self):
        self.lua.execute("""
            local D = Shade.DIM
            S.SetShadeStrength(0)
            cities.Dim()
            assert(math.abs(cityTex.r - 1) < 1e-9 and math.abs(cityTex.desat - 0.1) < 1e-9, 'a city is still darkened at 0')
            assert(math.abs(bannerTex.r - 1) < 1e-9 and math.abs(bannerTex.desat) < 1e-9)
            S.SetShadeStrength(0.62)
            cities.Dim()
            assert(math.abs(cityTex.r - D[1]) < 1e-9, 'the default must match how the map comes: ' .. cityTex.r)
            assert(math.abs(bannerTex.r - D[1]) < 1e-9 and math.abs(bannerTex.desat - D[4]) < 1e-9)
            S.SetShadeStrength(0.31)
            cities.Dim()
            assert(math.abs(cityTex.r - (1 + (D[1] - 1) * 0.5)) < 1e-9, 'half: ' .. cityTex.r)
            assert(math.abs(bannerTex.r - (1 + (D[1] - 1) * 0.5)) < 1e-9)
        """)


if __name__ == "__main__":
    unittest.main()
