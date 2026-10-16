# Out-of-game preview of OpenMap's stitched world map: the same maps, placements,
# masks, fades and colour matching as OpenMap/Map/Stitch.lua, composited
# offline, so the blend can be checked without logging in.
#
# usage: python -P tools/map-preview/render.py <db2 dir> <texture cache dir> <out dir> [view ...]
#   db2 dir: the Forever build's UiMap* CSVs (wago.tools, build 1.60.1.70245)
#   views:   name=u,v,zoom   (world-normalized centre on Azeroth's map, zoom 1 = whole world)
import csv, math, os, re, sys, time, urllib.request
import numpy as np
from PIL import Image
from scipy import ndimage

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
WM = os.path.join(REPO, "OpenMap", "Data")
TEXDIR = os.path.join(REPO, "OpenMap", "Media", "Textures")
BUILD = "1.60.1.70245"
OW, OH = (int(v) for v in os.environ.get("OPENMAP_SIZE", "1400x900").split("x"))
WORLD = 947

# Stitch.lua's constants
CONT_FADE, DETAIL_FADE, CITY_FADE, MUTE_FADE = (1.3, 2.2), (3, 4.5), (0.2, 0.4), (4, 7)
DETAIL_HINT = (1.8, 3, 0.3)     # (the zones' hint from further out: Stitch.lua's)
CITY_FADE_OF = {1454: (0.08, 0.25), 1456: (0.08, 0.25)}   # (cities that come in sooner: Stitch.lua's)
BANNER_OUT = (0.25, 0.4)        # (a zone's banner for a city that keeps its own goes: Stitch.lua's)
BORDER_OUT, BORDER_SCALE = (1.15, 1.6), 0.55   # (the border round the view: Window.lua's)
SEA = (0.50, 0.49, 0.41)        # the sea's colour where no map paints one (MapSeaField covers the rest)
SEA_REACH = 1.5                 # how far past the world art the sea runs (Stitch.lua's): MapSeaFieldOut over it
BACK_MUTE = 0.92                # how far the world / continent art fades as it mutes (alpha 1 - this)
# the ocean (Stitch.lua's sea section): Blizzard's sea paper and coastal strokes, tiled at the
# continent art's own scale and in finer octaves as you close in, so the sea keeps its texture
SEA_FADE = (1.2, 1.9)           # Stitch.lua's: where the backdrop goes from over the sea
SEA_TILE, HATCH_TILE = 128, (34, 84)   # tile sizes in continent-art pixels (tools/map-preview/sea.py)
SEA_OCTAVE, HATCH_OCTAVE = 4, 7        # zoom where each starts halving to keep its size on screen
HATCH_ALPHA = 0.6
USE_SEA = os.environ.get("OPENMAP_SEA", "1") == "1"
USE_GAP = os.environ.get("OPENMAP_GAP", "1") == "1"
USE_BAKED = os.environ.get("OPENMAP_BAKED", "0") == "1"   # the zones from their baked tiles (--bake-zones), as the game draws them
ZONES_ONLY, FADE_ZOOM = False, None   # (gapfill.py: only the zone layers, at full detail)

db2, cache, outdir = sys.argv[1:4]
os.makedirs(cache, exist_ok=True)
os.makedirs(outdir, exist_ok=True)
read = lambda n: list(csv.DictReader(open(os.path.join(db2, n + ".csv"), encoding="utf-8")))

# ---------------------------------------------------------------- data
uimap = {int(r["ID"]): r for r in read("UiMap")}
art_of = {}
for r in read("UiMapXMapArt"):
    if r["PhaseID"] == "0": art_of[int(r["UiMapID"])] = int(r["UiMapArtID"])
tiles = {}
for r in read("UiMapArtTile"):
    if r["LayerIndex"] == "0":
        tiles.setdefault(int(r["UiMapArtID"]), {})[(int(r["RowIndex"]), int(r["ColIndex"]))] = int(r["FileDataID"])
assign = {}
for r in read("UiMapAssignment"):
    assign.setdefault(int(r["UiMapID"]), []).append(r)

def f(r, k): return float(r[k])

def rect(mapid):
    """the map's rectangle on Azeroth's map (normalized), as GetMapRectOnMap"""
    if mapid == WORLD: return (0, 1, 0, 1)
    a = assign.get(mapid)
    if not a: return None
    a = a[0]
    cont = a["MapID"]
    w = next((r for r in assign[WORLD] if r["MapID"] == cont), None)
    if not w: return None
    def U(y): return f(w, "UiMin_0") + (f(w, "Region_4") - y) / (f(w, "Region_4") - f(w, "Region_1")) * (f(w, "UiMax_0") - f(w, "UiMin_0"))
    def V(x): return f(w, "UiMin_1") + (f(w, "Region_3") - x) / (f(w, "Region_3") - f(w, "Region_0")) * (f(w, "UiMax_1") - f(w, "UiMin_1"))
    # the region is the part UiMin..UiMax of the map's own art
    l, r = U(f(a, "Region_4")), U(f(a, "Region_1"))
    t, b = V(f(a, "Region_3")), V(f(a, "Region_0"))
    um0, um1, uM0, uM1 = f(a, "UiMin_0"), f(a, "UiMin_1"), f(a, "UiMax_0"), f(a, "UiMax_1")
    w_, h_ = (r - l) / (uM0 - um0), (b - t) / (uM1 - um1)
    return (l - um0 * w_, l - um0 * w_ + w_, t - um1 * h_, t - um1 * h_ + h_)

# OPENMAP_WOW: the game's folder (World of Warcraft); its own files are read there first
# (tools/casc), wago.tools only for what the install doesn't have
WOW = os.environ.get("OPENMAP_WOW")
_casc = []
def local(fid, p):
    if not WOW: return False
    if not _casc:
        sys.path.insert(0, os.path.join(REPO, "tools", "casc"))
        import casc
        _casc.append(casc.Casc(WOW, os.environ.get("OPENMAP_PRODUCT", "wow_classic_beta")))
    try:
        data = _casc[0].read(fid)
    except Exception:
        return False
    open(p, "wb").write(data)
    return True

def fetch(fid):
    p = os.path.join(cache, "%d.blp" % fid)
    if (not os.path.exists(p) or os.path.getsize(p) == 0) and not local(fid, p):
        url = "https://wago.tools/api/casc/%d?download&version=%s" % (fid, BUILD)
        req = urllib.request.Request(url, headers={"User-Agent": "openmap-tools/1"})
        for attempt in range(3):
            try:
                open(p, "wb").write(urllib.request.urlopen(req, timeout=30).read())
                break
            except Exception as e:
                print("retry", fid, e, flush=True); time.sleep(2)
        time.sleep(0.1)
    try:
        return Image.open(p).convert("RGBA")
    except Exception:
        return None

def canvas_from_tiles(artid):
    img = Image.new("RGBA", (1002, 668), (0, 0, 0, 0))
    for (row, col), fid in tiles.get(artid, {}).items():
        t = fetch(fid)
        if t: img.paste(t, (col * 256, row * 256))
    return np.asarray(img).astype(np.float32) / 255

# overlays from OpenMap's reveal data (by art ID)
reveal = {}
src = open(os.path.join(WM, "Reveal.lua"), encoding="utf-8").read()
for artid, body in re.findall(r'\[(\d+)\] = \{(.*?)\},\n', src):
    reveal[int(artid)] = re.findall(r'\["([\d:]+)"\] = "([^"]+)"', body)

def overlay_canvas(artid, keys=None):
    """a zone's overlay pieces composited (only those in `keys`, when given)"""
    img = Image.new("RGBA", (1002, 668), (0, 0, 0, 0))
    for key, files in reveal.get(artid, []):
        if keys is not None and key not in keys: continue
        w, h, x, y = map(int, key.split(":"))
        ids = [int(s) for s in files.split(",")]
        cols, rows = math.ceil(w / 256), math.ceil(h / 256)
        for j in range(rows):
            ph = 256 if j < rows - 1 else h - (rows - 1) * 256
            for k in range(cols):
                n = j * cols + k
                if n >= len(ids): continue
                t = fetch(ids[n])
                if not t: continue
                pw = 256 if k < cols - 1 else w - (cols - 1) * 256
                t = t.crop((0, 0, min(pw, t.width), min(ph, t.height)))
                layer = Image.new("RGBA", (1002, 668), (0, 0, 0, 0))
                layer.paste(t, (x + k * 256, y + j * 256))
                img = Image.alpha_composite(img, layer)
    return np.asarray(img).astype(np.float32) / 255

grade = {int(k): tuple(map(float, v)) for k, *v in re.findall(r'\[(\d+)\] = \{ ([\d.]+), ([\d.]+), ([\d.]+) \}',
         open(os.path.join(WM, "Grade.lua"), encoding="utf-8").read())}

def mask(name):
    p = os.path.join(TEXDIR, name + ".tga")
    if not os.path.exists(p): return None
    return np.asarray(Image.open(p).convert("RGBA").getchannel("A").resize((1002, 668), Image.BILINEAR)).astype(np.float32) / 255

M_FEATHER, M_THIN, M_WIDE, M_ROUND = mask("MapFeather"), mask("MapFeatherThin"), mask("MapFeatherWide"), mask("MapFeatherRound")

def gap_art():
    """Gaps.lua's `art` (gapfill.py): finer maps of land no zone covers, through MapCoastArt/<name>"""
    if "gap_art" not in _cache:
        out_ = []
        src_ = open(os.path.join(WM, "Gaps.lua"), encoding="utf-8").read()
        for name, rect, files in re.findall(r'\{ "([^"]+)", \d+, \{ ([-\d., ]+) \}, \{ ([\d, ]+) \} \}', src_):
            img = Image.new("RGBA", (1024, 768))
            for i, fid in enumerate(int(s_) for s_ in files.split(",")):
                t_ = fetch(fid) if fid else None             # (0: not drawn)
                if t_: img.paste(t_, ((i % 4) * 256, (i // 4) * 256))
            out_.append({"id": name, "rect": tuple(float(v_) for v_ in rect.split(",")),
                         "img": np.asarray(img.crop((0, 0, 1002, 668))).astype(np.float32) / 255,
                         "mask": mask("MapCoastArt/" + name)})
        _cache["gap_art"] = out_
    return _cache["gap_art"]

def banner(city):
    """a city's banner (Data/Banners.lua, MapBanner/<city>), as a map of its own: its rectangle on
    the world and its image stretched to the 1002 x 668 canvas place() expects"""
    k = ("banner", city)
    if k not in _cache:
        _cache[k] = None
        m_ = re.search(r"\[%d\] = \{ (\d+), (\d+), (\d+), (\d+), (\d+) \}" % city,
                       open(os.path.join(WM, "Banners.lua"), encoding="utf-8").read())
        zone = m_ and next((z for z in maps if z["id"] == int(m_.group(1))), None)
        if zone:
            x, y, w, h = (int(m_.group(i)) for i in range(2, 6))
            l, r, t, b = zone["rect"]
            sx, sy = (r - l) / 1002, (b - t) / 668
            img = Image.open(os.path.join(TEXDIR, "MapBanner", "%d.tga" % city)).convert("RGBA").resize((1002, 668), Image.LANCZOS)
            _cache[k] = {"id": "banner%d" % city, "rect": (l + x * sx, l + (x + w) * sx, t + y * sy, t + (y + h) * sy),
                         "img": np.asarray(img).astype(np.float32) / 255}
    return _cache[k]

def city_title(city):
    """whether the city's cut keeps its own name banner (Data/Banners.lua's MapCityTitles)"""
    m_ = re.search(r"ns\.MapCityTitles = \{(.*?)\}", open(os.path.join(WM, "Banners.lua"), encoding="utf-8").read(), re.S)
    return bool(m_ and re.search(r"\[%d\] = true" % city, m_.group(1)))


# ---------------------------------------------------------------- the maps
def under_world(mid):
    """as C_Map.GetMapChildrenInfo(947, ..., true): maps in Azeroth's tree only"""
    for _ in range(8):
        if mid == WORLD: return True
        r = uimap.get(mid)
        if not r: return False
        mid = int(r["ParentUiMapID"])
    return False

maps = []   # { id, kind, rect, base, over, band, m }
for mid, r in uimap.items():
    kind = int(r["Type"])
    if kind not in (1, 2, 3) or mid not in art_of or not under_world(mid): continue
    rc = rect(mid)
    if not rc: continue
    maps.append({"id": mid, "name": r["Name_lang"], "kind": kind, "rect": rc, "art": art_of[mid]})
zones = [m for m in maps if m["kind"] == 3]
SKIP = set(n for n in os.environ.get("OPENMAP_SKIP", "").split("|") if n)   # debugging: leave these zones out
zones = [m for m in zones if m["name"] not in SKIP]
zones.sort(key=lambda m: -(m["rect"][1] - m["rect"][0]) * (m["rect"][3] - m["rect"][2]))
print(len(maps), "maps", len(zones), "zones", flush=True)

_cache = {}
EDITED = os.path.join(REPO, "art-edits", "edited")
def base(m):
    """a map's art: the hand-cleaned copy (tools/map-art) where there is one, as the addon draws it"""
    k = ("b", m["id"])
    if k not in _cache:
        art = canvas_from_tiles(m["art"])
        if os.path.isdir(EDITED):
            for f in os.listdir(EDITED):
                if f.startswith("%d " % m["id"]) and f.endswith(".png") and not f.endswith("labels.png"):
                    e = np.asarray(Image.open(os.path.join(EDITED, f)).convert("RGB")).astype(np.float32) / 255
                    art = art.copy(); art[:e.shape[0], :e.shape[1], :3] = e
        _cache[k] = art
    return _cache[k]
def over(m):
    k = ("o", m["id"])
    if k not in _cache:
        o = overlay_canvas(m["art"])
        hole = mask("MapBannerHole/%d" % m["id"])        # (drawn without its banner for a city: banners.py)
        if hole is not None:
            o = o.copy()
            o[..., 3] *= hole
        _cache[k] = o
    return _cache[k]
def band(m):
    k = ("band", m["id"])
    if k not in _cache: _cache[k] = mask("MapBand/%d" % m["id"])
    return _cache[k]
TERR_OWN = False                # (gapfill.py: each zone through its own territory only)
def terr(m):
    if TERR_OWN: return terr_own(m)
    k = ("terr", m["id"])
    if k not in _cache: _cache[k] = mask("MapTerritory/%d" % m["id"])
    return _cache[k]

def core(m):
    k = ("core", m["id"])
    if k not in _cache:
        p = os.path.join(TEXDIR, "MapCore", "%d.tga" % m["id"])
        if os.path.exists(p):
            _cache[k] = np.asarray(Image.open(p).convert("RGBA").getchannel("A").resize((1002, 668), Image.BILINEAR)).astype(np.float32) / 255
        else:
            from scipy import ndimage
            land = over(m)[..., 3] > 0.5
            land = ndimage.binary_fill_holes(ndimage.binary_closing(land, np.ones((3, 3)), iterations=6))
            din = ndimage.distance_transform_edt(land)
            t = np.clip((din - CORE_IN) / CORE_SOFT, 0, 1)
            small = Image.fromarray((t * t * (3 - 2 * t) * 255).astype(np.uint8)).resize((128, 128), Image.LANCZOS)
            _cache[k] = np.asarray(small.resize((1002, 668), Image.BILINEAR)).astype(np.float32) / 255
    return _cache[k]

GRAIN_TILE = 14                 # world units per grain tile (about a zone map's parchment scale)
GRAIN_OCTAVES = ((1, 0.0, 0.55), (2.618, 0.37, 0.5))   # Stitch.lua's: size x, offset (tiles), strength
def tex_rgba(name):
    k = ("tex", name)
    if k not in _cache:
        p = os.path.join(TEXDIR, name + ".tga")
        _cache[k] = np.asarray(Image.open(p).convert("RGBA")).astype(np.float32) / 255 if os.path.exists(p) else None
    return _cache[k]

def grain_tex():
    if "grain" not in _cache:
        p = os.path.join(TEXDIR, "MapGrain.tga")
        _cache["grain"] = np.asarray(Image.open(p).convert("RGBA")).astype(np.float32) / 255 if os.path.exists(p) else None
    return _cache["grain"]

GAP_TILE = 64                   # world units per MapGap tile (tools/map-preview/gapfill.py)
def gap_tiles(cid):
    """MapGapLand masks per tile: (col, row) -> land alpha"""
    k = ("gap", cid)
    if k not in _cache:
        got = {}
        land_dir = os.path.join(TEXDIR, "MapGapLand")
        if os.path.isdir(land_dir):
            for f in os.listdir(land_dir):
                m_ = re.match(r"%d_(\d+)_(\d+)\.tga$" % cid, f)
                if not m_: continue
                got[(int(m_.group(1)), int(m_.group(2)))] = np.asarray(Image.open(os.path.join(land_dir, f)).convert("RGBA")).astype(np.float32)[..., 3] / 255
        _cache[k] = got
    return _cache[k]

PAPER_LAYERS = ((1, 0.0, 1.0), (2.618, 0.41, 0.5))   # Stitch.lua's: size x, offset (tiles), alpha
def paper_world():
    """MapPaper's size in world units (Data/Gaps.lua)"""
    if "paper" not in _cache:
        p_ = os.path.join(WM, "Gaps.lua")
        m_ = re.search(r"paper = ([\d.]+)", open(p_, encoding="utf-8").read()) if os.path.exists(p_) else None
        _cache["paper"] = float(m_.group(1)) if m_ else None
    return _cache["paper"]

UNDER_T = 0.0                   # how far a cave has surfaced (set by callers; Close.lua's underground)
LAND_FILL = os.environ.get("OPENMAP_LAND", "1") == "1"
LAND_TINT, LAND_DSAT = (0.96, 0.92, 0.84), 0.25
USE_CORE = os.environ.get("OPENMAP_CORE", "1") == "1"
USE_BASE = os.environ.get("OPENMAP_BASE", "1") == "1"
# "Darken unexplored areas" (Stitch.lua's UNDISCOVERED): a shade over the zones' land (MapZoneLand), all of
# a zone not found at all, or its unexplored pieces. Out of game nothing is known about what a player
# has explored, so a preview picks it: OPENMAP_UNEXPLORED="Westfall=all;Duskwood=half"
# (all: none of it found; half: every other overlay piece unexplored)
UNDISCOVERED = (0.05, 0.06, 0.08, 0.62)
DIM = (0.38, 0.39, 0.43, 0.25)  # an unexplored piece's colour in a zone you've been to (Stitch.lua's Shade.DIM): r, g, b, desaturation
UNEXPLORED_SIM = dict(p.split("=", 1) for p in os.environ.get("OPENMAP_UNEXPLORED", "").split(";") if "=" in p)

def smooth(z, rng):
    t = max(0.0, min(1.0, (z - rng[0]) / (rng[1] - rng[0])))
    return t * t * (3 - 2 * t)


def detail_at(z):
    """the zone detail's zoom fade (Stitch.lua's detailNow)"""
    return DETAIL_HINT[2] * smooth(z, DETAIL_HINT[:2]) + (1 - DETAIL_HINT[2]) * smooth(z, DETAIL_FADE)

def desat(rgb, amount):
    if amount <= 0: return rgb
    l = (rgb[..., 0] * 0.299 + rgb[..., 1] * 0.587 + rgb[..., 2] * 0.114)[..., None]
    return rgb + (l - rgb) * amount

# ---------------------------------------------------------------- compositing
def render(cu, cv, zoom, path):
    W, H = 1002.0, 668.0
    px = min(OW / W, OH / H) * zoom                      # output px per world unit
    out = np.zeros((OH, OW, 3), np.float32)
    out[:] = SEA
    # the sea's colour past the world art (MapSeaFieldOut, sea_world.py), as Stitch.lua lays it
    fo = tex_rgba("MapSeaFieldOut") if USE_SEA and not ZONES_ONLY else None
    if fo is not None:
        ys0, xs0 = np.mgrid[0:OH, 0:OW].astype(np.float32)
        span = 1 + 2 * SEA_REACH
        fu = ((xs0 - OW / 2) / px + cu * W) / W
        fv = ((ys0 - OH / 2) / px + cv * H) / H
        fx = (fu + SEA_REACH) / span * fo.shape[1] - 0.5
        fy = (fv + SEA_REACH) / span * fo.shape[0] - 0.5
        out[:] = np.dstack([ndimage.map_coordinates(fo[..., c], [fy, fx], order=1, mode="nearest") for c in range(3)])
    def place(m, img, alpha_mask, tint=(1, 1, 1), dsat=0.0, alpha=1.0):
        if alpha <= 0.001: return
        l, r, t, b = m["rect"]
        if (r * W - cu * W) * px + OW / 2 < 0 or (l * W - cu * W) * px + OW / 2 > OW: return
        if (b * H - cv * H) * px + OH / 2 < 0 or (t * H - cv * H) * px + OH / 2 > OH: return
        if callable(img): img = img(m)
        if img is None: return
        l, r, t, b = m["rect"]
        x0, x1 = (l * W - cu * W) * px + OW / 2, (r * W - cu * W) * px + OW / 2
        y0, y1 = (t * H - cv * H) * px + OH / 2, (b * H - cv * H) * px + OH / 2
        vx0, vx1, vy0, vy1 = max(0, x0), min(OW, x1), max(0, y0), min(OH, y1)
        if vx1 - vx0 < 1 or vy1 - vy0 < 1: return
        # the visible part of the map's 1002 x 668 canvas
        sx0, sx1 = (vx0 - x0) / (x1 - x0) * 1002, (vx1 - x0) / (x1 - x0) * 1002
        sy0, sy1 = (vy0 - y0) / (y1 - y0) * 668, (vy1 - y0) / (y1 - y0) * 668
        a = img[..., 3] * (alpha_mask if alpha_mask is not None else 1) * alpha
        rgba = np.dstack([desat(img[..., :3], dsat) * np.array(tint, np.float32), a])
        crop = Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8), "RGBA").crop(
            (int(sx0), int(sy0), max(int(sx0) + 1, int(math.ceil(sx1))), max(int(sy0) + 1, int(math.ceil(sy1)))))
        tw, th = int(round(vx1)) - int(vx0), int(round(vy1)) - int(vy0)
        if tw < 1 or th < 1: return
        crop = np.asarray(crop.resize((tw, th), Image.BILINEAR)).astype(np.float32) / 255
        X0, Y0 = int(vx0), int(vy0)
        dst = out[Y0:Y0 + th, X0:X0 + tw]
        ca = crop[..., 3:4]
        dst[:] = dst * (1 - ca) + crop[..., :3] * ca

    def gap_over(cont, alpha):
        """the gaps: MapPaper repeated (paper_world() world units a tile) through the MapGapLand
        masks, under the continent art's wide edge fade"""
        tiles_ = gap_tiles(cont["id"])
        if not tiles_ or alpha <= 0: return
        pw, pap = paper_world(), tex_rgba("MapPaper")
        cl, ct = cont["rect"][0] * W, cont["rect"][2] * H
        for (i, j), land in tiles_.items():
            x0, y0 = cl + i * GAP_TILE, ct + j * GAP_TILE
            X0, X1 = (x0 - cu * W) * px + OW / 2, (x0 + GAP_TILE - cu * W) * px + OW / 2
            Y0, Y1 = (y0 - cv * H) * px + OH / 2, (y0 + GAP_TILE - cv * H) * px + OH / 2
            if X1 < 0 or X0 > OW or Y1 < 0 or Y0 > OH: continue
            xa, xb, ya, yb = max(0, int(X0)), min(OW, int(math.ceil(X1))), max(0, int(Y0)), min(OH, int(math.ceil(Y1)))
            if xb <= xa or yb <= ya: continue
            n = land.shape[0]
            ty = ((np.arange(ya, yb) + 0.5 - Y0) / (Y1 - Y0) * n - 0.5)[:, None].repeat(xb - xa, 1)
            tx = ((np.arange(xa, xb) + 0.5 - X0) / (X1 - X0) * n - 0.5)[None, :].repeat(yb - ya, 0)
            wx_ = (np.arange(xa, xb) + 0.5 - OW / 2) / px + cu * W
            wy_ = (np.arange(ya, yb) + 0.5 - OH / 2) / px + cv * H
            mx = np.clip((wx_ / W - cont["rect"][0]) / (cont["rect"][1] - cont["rect"][0]) * 1002, 0, 1001).astype(np.int32)
            my = np.clip((wy_ / H - cont["rect"][2]) / (cont["rect"][3] - cont["rect"][2]) * 668, 0, 667).astype(np.int32)
            fade = M_WIDE[my[:, None], mx[None, :]] * alpha
            dst = out[ya:yb, xa:xb]
            if pw and pap is not None:
                la = ndimage.map_coordinates(land, [ty, tx], order=1, mode="nearest")
                ps = pap.shape[0]
                for k_, off, al in PAPER_LAYERS:                  # Stitch.lua's: two sizes that never line up
                    s_ = pw * k_
                    py_ = ((wy_ / s_ + off * 1.7) % 1 * ps - 0.5)[:, None].repeat(xb - xa, 1)
                    px_ = ((wx_ / s_ + off) % 1 * ps - 0.5)[None, :].repeat(yb - ya, 0)
                    col = np.dstack([ndimage.map_coordinates(pap[..., c_], [py_, px_], order=1, mode="grid-wrap") for c_ in range(3)])
                    aa = (la * fade * al)[..., None]
                    dst[:] = dst * (1 - aa) + col * aa

    def grain_over(cont, alpha):
        """MapGrain tiled every GRAIN_TILE world units over the continent's land"""
        g = grain_tex()
        if g is None or alpha <= 0: return
        ys, xs = np.mgrid[0:OH, 0:OW].astype(np.float32)
        wx = (xs - OW / 2) / px + cu * W                      # world units
        wy = (ys - OH / 2) / px + cv * H
        cl, cr, ct, cb = cont["rect"]
        lx = np.clip(((wx / W - cl) / (cr - cl) * 1002).astype(np.int32), 0, 1001)
        ly = np.clip(((wy / H - ct) / (cb - ct) * 668).astype(np.int32), 0, 667)
        inside = (wx / W >= cl) & (wx / W <= cr) & (wy / H >= ct) & (wy / H <= cb)
        on = (field_img(cont)[..., 3] * M_WIDE)[ly, lx] * inside * alpha
        for k, off, strength in GRAIN_OCTAVES:              # two sizes that don't line up: no visible repeat
            size = GRAIN_TILE * k
            gx = ((((wx - cl * W) / size + off) % 1) * 256).astype(np.int32) % 256
            gy = ((((wy - ct * H) / size + off * 1.7) % 1) * 256).astype(np.int32) % 256
            a = g[gy, gx, 3] * on * strength
            out[:] = out * (1 - a[..., None]) + g[gy, gx, :3] * a[..., None]

    ys_, xs_ = np.mgrid[0:OH, 0:OW].astype(np.float32)
    WX, WY = (xs_ - OW / 2) / px + cu * W, (ys_ - OH / 2) / px + cv * H     # world units
    def octaves(zoom_from):
        """the two octaves in play: (scale divisor, weight)"""
        o = max(0.0, math.log(zoom / zoom_from, 2))
        n, f = int(math.floor(o)), o - math.floor(o)
        return ((2 ** n, 1.0), (2 ** (n + 1), f))
    def tiled(img, sx, sy, shift=0.0):
        """img (h, w, c) repeated every sx x sy world units over the output"""
        h_, w_ = img.shape[:2]
        ty, tx = ((WY / sy + shift * 1.6) % 1) * h_ - 0.5, ((WX / sx + shift) % 1) * w_ - 0.5
        return np.dstack([ndimage.map_coordinates(img[..., c], [ty, tx], order=1, mode="grid-wrap") for c in range(img.shape[2])])
    def cont_px(cont):
        return (cont["rect"][1] - cont["rect"][0]) * W / 1002        # world units per continent-art px
    def sea_field():
        """MapSeaField: the world's, then each continent's through its wide feather"""
        for mid in (WORLD, 1414, 1415):
            m = next(x for x in maps if x["id"] == mid)
            f = tex_rgba("MapSeaField/%d" % mid)
            if f is None: continue
            img = np.dstack([np.asarray(Image.fromarray((f[..., :3] * 255).astype(np.uint8)).resize((1002, 668), Image.BILINEAR)).astype(np.float32) / 255, np.ones((668, 1002), np.float32)])
            place(m, img, None if mid == WORLD else M_WIDE)
    def sea_over(alpha):
        ek = next(m for m in maps if m["id"] == 1415)
        base_ = SEA_TILE * cont_px(ek)
        for k_, (div, wgt) in enumerate(octaves(SEA_OCTAVE)):
            a = alpha * (wgt if k_ else 1 - octaves(SEA_OCTAVE)[1][1])
            if a <= 0.001: continue
            for name in ("MapSeaDark", "MapSeaLight"):
                t = tiled(tex_rgba(name), base_ / div, base_ / div, (round(math.log(div, 2)) * 0.37) % 1)   # (Stitch.lua: each size its own offset)
                aa = t[..., 3:4] * a
                out[:] = out * (1 - aa) + t[..., :3] * aa
    def hatch_over(cont, alpha):
        t, coast = tex_rgba("MapHatch"), tex_rgba("MapCoast/%d" % cont["id"])
        if t is None or coast is None: return
        cl, cr, ct, cb = cont["rect"]
        lx = np.clip((WX / W - cl) / (cr - cl) * coast.shape[1], 0, coast.shape[1] - 1)
        ly = np.clip((WY / H - ct) / (cb - ct) * coast.shape[0], 0, coast.shape[0] - 1)
        inside = (WX / W >= cl) & (WX / W <= cr) & (WY / H >= ct) & (WY / H <= cb)
        band_ = ndimage.map_coordinates(coast[..., 3], [ly, lx], order=1) * inside
        k = cont_px(cont)
        for div, wgt in octaves(HATCH_OCTAVE):
            a = alpha * HATCH_ALPHA * math.sqrt(wgt)
            if a <= 0.001: continue
            h = tiled(t, HATCH_TILE[0] * k / div, HATCH_TILE[1] * k / div)
            aa = (h[..., 3] * band_ * a)[..., None]
            out[:] = out * (1 - aa) + h[..., :3] * aa

    # (tools bake at a fixed fade) the layers fade by the view's area, not its fit to the world
    # (WorldMap.lua's DetailK: a view the world's shape is the same, a tall or very wide one later)
    zf = FADE_ZOOM or zoom * min(OW / W, OH / H) / math.sqrt(OW * OH / (W * H))
    m_ = math.floor(smooth(zf, MUTE_FADE) * 20) / 20
    sm_ = math.floor(smooth(zf, SEA_FADE) * 20) / 20 if USE_SEA else 0
    if USE_SEA and not ZONES_ONLY: sea_field()
    wo_ = math.floor(smooth(zf, (1.7, 2.2)) * 20) / 20
    ws_ = math.floor(smooth(zf, (4, 7)) * 20) / 20
    if USE_SEA and ws_ > 0 and not ZONES_ONLY: sea_over(ws_)
    c = 1 - 0.45 * m_
    back = dict(tint=(c, c * 0.97, c * 0.92), dsat=0.8 * m_, alpha=1 - (BACK_MUTE if USE_SEA else 0.7) * m_)
    world = next(m for m in maps if m["id"] == WORLD)
    def backdrop(m, feather, alpha):
        """Stitch.PlaceBackdrop: the art over its land, and over its sea (gone sooner)"""
        land, sea = mask("MapBackLand/%d" % m["id"]), mask("MapSeaMask/%d" % m["id"])
        f = feather if feather is not None else 1
        if land is None or sea is None:
            place(m, base, feather, **dict(back, alpha=alpha)); return
        place(m, base, f * land, **dict(back, alpha=alpha))
        if m["id"] == WORLD:                          # (Stitch.lua: the world's sea stays the ocean until well in)
            place(m, base, f * sea, alpha=1 - math.floor(smooth(zf, (4, 7)) * 20) / 20)
        else:
            place(m, base, f * sea, **dict(back, alpha=alpha * (1 - sm_)))
    if not ZONES_ONLY: backdrop(world, M_WIDE, back["alpha"] * (1 - math.floor(smooth(zf, (1.7, 2.2)) * 20) / 20))   # (Stitch.lua: its land gives way to the continents')
    for m in maps:
        if m["kind"] == 2 and not ZONES_ONLY:
            backdrop(m, M_WIDE, back["alpha"] * smooth(zf, (1.3, 1.7)))
            if USE_SEA and max(m_, sm_) > 0: hatch_over(m, max(m_, sm_) * smooth(zf, CONT_FADE))
            lf = max(m_, UNDER_T)
            if LAND_FILL and lf > 0:                     # its land stays land as the sea mutes
                place(m, field_img, M_WIDE, tint=LAND_TINT, dsat=LAND_DSAT, alpha=smooth(zf, CONT_FADE) * lf)
            if USE_GAP: gap_over(m, smooth(zf, CONT_FADE) * detail_at(zf) * (1 - 0.75 * UNDER_T))
            if LAND_FILL and lf > 0:
                grain_over(m, smooth(zf, CONT_FADE) * lf)
    d = detail_at(zf) * (1 - 0.75 * UNDER_T)    # (a cave surfacing: Stitch.SetUnderground)
    if USE_BAKED:                                         # the zones' baked tiles (--bake-zones), as Stitch.lua draws them
        T_ = ZONE_STEP / ZONE_PX
        for f_ in os.listdir(os.path.join(TEXDIR, "MapZones")):
            i_, j_ = map(int, f_[:-4].split("_"))
            img_ = np.asarray(Image.open(os.path.join(TEXDIR, "MapZones", f_)).convert("RGBA")).astype(np.float32) / 255
            img_ = np.asarray(Image.fromarray((img_ * 255).astype(np.uint8)).crop((1, 1, ZONE_TILE - 1, ZONE_TILE - 1)).resize((1002, 668), Image.BILINEAR)).astype(np.float32) / 255
            place({"rect": (i_ * T_ / W, (i_ + 1) * T_ / W, j_ * T_ / H, (j_ + 1) * T_ / H)}, img_, None,
                  alpha=1 - (1 - d) ** 2)                 # (Stitch.lua's: as strong as the live layers stacked)
    if USE_GAP and not ZONES_ONLY and not USE_BAKED:
        for x in gap_art():                               # finer maps of land no zone covers (Gilneas), under every zone
            place(x, x["img"], x["mask"], alpha=d)
    has_over = {m["id"]: bool(reveal.get(m["art"])) for m in zones}
    for m in zones:                                       # base art, biggest zone first, with its border copy
        if not has_over[m["id"]] or not USE_BASE or USE_BAKED: continue
        t_ = terr(m)
        fm = M_FEATHER * t_ if t_ is not None else M_FEATHER
        place(m, base, fm, alpha=d)
        g = grade.get(m["id"])
        bd = band(m)
        if g and bd is not None: place(m, base, fm * bd, tint=g, alpha=d)
    for m in zones:                                       # overlays
        if has_over[m["id"]] and not USE_BAKED: place(m, over, edge(m), alpha=d)
    for m in zones:                                       # their border copies
        g = grade.get(m["id"]); bd = band(m)
        if has_over[m["id"]] and g and bd is not None and not USE_BAKED: place(m, over, edge(m) * bd, tint=g, alpha=d)
    if USE_CORE and not USE_BAKED:
        for m in zones:                                   # every zone's interior again, over its neighbours' halos
            if has_over[m["id"]]: place(m, over, edge(m) * core(m), alpha=d)
    if UNEXPLORED_SIM and not ZONES_ONLY:                 # a zone you've been to: each piece's art again, the unexplored
        for m in zones:                                   # darkened, the explored over them (Stitch.lua's Shade.Pieces)
            if UNEXPLORED_SIM.get(m["name"]) != "half" or not has_over[m["id"]]: continue
            keys = sorted(key for key, _ in reveal.get(m["art"], []))
            unexplored = set(keys[::2])
            hole = mask("MapBannerHole/%d" % m["id"])
            g, bd = grade.get(m["id"]), band(m)
            land = mask("MapZoneLand/%d" % m["id"])
            for dark in (True, False):
                img = overlay_canvas(m["art"], {k for k in keys if (k in unexplored) == dark})
                if hole is not None:
                    img = img.copy()
                    img[..., 3] *= hole
                if dark:                                  # (on its land alone, without its colour-match copy)
                    place(m, img, edge(m) * (land if land is not None else 1), tint=DIM[:3], dsat=max(ZONE_DESAT, DIM[3]))
                    continue
                place(m, img, edge(m), dsat=ZONE_DESAT)
                if g and bd is not None:
                    place(m, img, edge(m) * bd, tint=g, dsat=ZONE_DESAT)
    for m in zones:                                       # cities
        if not has_over[m["id"]]:
            f_ = 1 / (m["rect"][1] - m["rect"][0])
            fade = CITY_FADE_OF.get(m["id"], CITY_FADE)
            a_ = smooth(zf, (fade[0] * f_, fade[1] * f_))
            cut_ = os.path.join(TEXDIR, "MapCityMask", "%d.tga" % m["id"])    # (cut down to the city: banners.py)
            place(m, base, mask("MapCityMask/%d" % m["id"]) if os.path.exists(cut_) else M_ROUND, alpha=a_)
            b_ = banner(m["id"])                          # its zone's banner for it: its title at every zoom,
            if b_:                                        # or giving way to its own (Stitch.lua's MapCityTitles)
                out_ = smooth(zf, (BANNER_OUT[0] * f_, BANNER_OUT[1] * f_)) if city_title(m["id"]) else 0
                place(b_, b_["img"], None, alpha=d * (1 - out_))
    if UNEXPLORED_SIM and not ZONES_ONLY:                 # unexplored land, shaded over the art (Stitch.lua's shadeRoot)
        solid = np.dstack([np.full((668, 1002, 3), UNDISCOVERED[:3], np.float32), np.ones((668, 1002), np.float32)])
        for m in zones:
            how, land = UNEXPLORED_SIM.get(m["name"]), mask("MapZoneLand/%d" % m["id"])
            if not how or land is None: continue
            if how == "all":
                place(m, solid, land, alpha=UNDISCOVERED[3])
                rim = mask("MapZoneBorder/%d" % m["id"])      # its share of the border land round it
                if rim is not None:
                    l, r, t, b = m["rect"]
                    out_rect = (l - BORDER_REACH / W_, r + BORDER_REACH / W_, t - BORDER_REACH / H_, b + BORDER_REACH / H_)
                    place({"id": m["id"], "rect": out_rect}, solid, rim, alpha=UNDISCOVERED[3])
            # ("half": a zone you've been to, its pieces' copies under the cities, above)
    ba = 1 - smooth(zf, BORDER_OUT)                       # the parchment border round the view (Window.lua's)
    if ba > 0.003 and not ZONES_ONLY:
        c = int(round(192 * BORDER_SCALE * OH / 1024))
        pieces = (("tl", 0, 0, c, c, .75, .75), ("tr", OW - c, 0, c, c, .75, .75), ("bl", 0, OH - c, c, c, .75, .75),
                  ("br", OW - c, OH - c, c, c, .75, .75), ("top", c, 0, OW - 2 * c, c, 1, .75), ("bottom", c, OH - c, OW - 2 * c, c, 1, .75),
                  ("left", 0, c, c, OH - 2 * c, .75, 640 / 1024), ("right", OW - c, c, c, OH - 2 * c, .75, 640 / 1024))
        for name, x, y, w, h, u1, v1 in pieces:
            if w < 1 or h < 1: continue
            src = Image.open(os.path.join(TEXDIR, "MapBorder", name + ".tga")).convert("RGBA")
            src = src.crop((0, 0, int(src.width * u1), int(src.height * v1)))
            piece = np.asarray(src.resize((w, h), Image.BILINEAR)).astype(np.float32) / 255
            a = piece[..., 3:4] * ba
            dst = out[y:y + h, x:x + w]
            dst[:] = dst * (1 - a) + piece[..., :3] * a
    Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8)).save(path)
    print("wrote", path, flush=True)

#   or name=@Zone Name,zoom (centred on that map; @A+B centres between two maps)
HATCH_STRIPE = 0.012            # vertical-over-horizontal contrast that marks sea hatching
def land_of(cont):
    """where the continent art is land (saturated) rather than sea / parchment"""
    k = ("land", cont["id"])
    if k not in _cache:
        from PIL import ImageFilter
        img = Image.fromarray((base(cont)[..., :3] * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(4))
        sat = np.asarray(img.convert("HSV")).astype(np.float32)[..., 1] / 255
        soft = np.clip((sat - 0.42) / 0.12, 0, 1)
        # the parchment's aged edges and corners are saturated too: keep land that stays
        # clear of the frame
        from scipy import ndimage
        h, w = soft.shape
        land = soft > 0.5
        land[: int(h * .05)] = land[int(h * .95):] = False          # the frame band is never land
        land[:, : int(w * .05)] = land[:, int(w * .95):] = False
        for ys in (slice(0, int(h * .22)), slice(int(h * .78), h)):  # nor the decorated corners
            for xs in (slice(0, int(w * .16)), slice(int(w * .84), w)):
                land[ys, xs] = False
        # Blizzard's sea hatching (brown horizontal strokes) is as saturated as land: it's the
        # light / dark alternation down the image with little across it
        L = base(cont)[..., :3].mean(2)
        dy = np.abs(np.diff(L, axis=0, prepend=L[:1]))
        dx = np.abs(np.diff(L, axis=1, prepend=L[:, :1]))
        stripe = ndimage.gaussian_filter(ndimage.gaussian_filter(dy, 4) - ndimage.gaussian_filter(dx, 4), 3)
        hatch = ndimage.binary_dilation(ndimage.binary_opening(stripe > HATCH_STRIPE, iterations=2), iterations=2)
        land &= ~hatch
        lab, n = ndimage.label(land)
        sizes = ndimage.sum(land, lab, range(1, n + 1))
        # pieces against the frame band are the paper's aged edge, unless they're the continent
        edge = np.zeros((h, w), bool); edge[: int(h * .07)] = edge[int(h * .93):] = True
        edge[:, : int(w * .07)] = edge[:, int(w * .93):] = True
        touch = ndimage.sum(edge.astype(np.float32), lab, range(1, n + 1)) > 0
        # and a piece no zone sits on, unless it's big, is decoration (the compass, scrollwork)
        zoned = np.zeros((h, w), bool)
        cl, cr, ct, cb = cont["rect"]
        for z in zones:
            zl, zr, zt, zb = z["rect"]
            x0, x1 = int((zl - cl) / (cr - cl) * w), int((zr - cl) / (cr - cl) * w)
            y0, y1 = int((zt - ct) / (cb - ct) * h), int((zb - ct) / (cb - ct) * h)
            if x1 - x0 < 2 or y1 - y0 < 2: continue
            if not reveal.get(z["art"]):                       # (a city: its rectangle is all land)
                zoned[max(0, y0):max(0, y1), max(0, x0):max(0, x1)] = True
                continue
            own = np.asarray(Image.fromarray((own_land(z) * 255).astype(np.uint8)).resize((x1 - x0, y1 - y0), Image.NEAREST)) > 127
            X0, Y0, X1, Y1 = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
            if X1 > X0 and Y1 > Y0:
                zoned[Y0:Y1, X0:X1] |= own[Y0 - y0:Y1 - y0, X0 - x0:X1 - x0]
        zoned = ndimage.binary_dilation(zoned, iterations=6)
        on_zone = ndimage.sum(zoned.astype(np.float32), lab, range(1, n + 1)) > 0
        keep = np.isin(lab, [i + 1 for i in range(n) if sizes[i] > 300 and (not touch[i] or sizes[i] > 0.3 * sizes.max())
                             and (on_zone[i] or sizes[i] == sizes.max())])   # (ornaments: the ship, scrollwork)
        _cache[k] = soft * ndimage.gaussian_filter(keep.astype(np.float32), 2)
    return _cache[k]

def land_field(cont):
    """MapLand: a continent's land as a smooth colour field (its art's colours with the
    ink strokes and baked-in letters left out, spread and blurred), alpha = its land
    (letters closed over). Drawn, tinted and grained, over land with no zone map."""
    k = ("field", cont["id"])
    if k not in _cache:
        from scipy import ndimage
        a = base(cont)
        rgb = a[..., :3]
        L = rgb.mean(2)
        land = land_of(cont) > 0.5
        land = ndimage.binary_closing(land, np.ones((3, 3)), iterations=6)
        land = ndimage.binary_fill_holes(land)
        local = ndimage.median_filter(L, size=25)
        clean = land & (L > local - 0.06)                   # no dark strokes / letters
        w = ndimage.gaussian_filter(clean.astype(np.float32), 10)
        col = np.dstack([ndimage.gaussian_filter(rgb[..., c] * clean, 10) for c in range(3)]) / np.maximum(w[..., None], 1e-4)
        col = np.dstack([ndimage.gaussian_filter(col[..., c], 4) for c in range(3)])
        alpha = ndimage.gaussian_filter(land.astype(np.float32), 2.5)
        img = np.dstack([np.clip(col, 0, 1), np.clip(alpha, 0, 1)])
        small = Image.fromarray((img * 255).astype(np.uint8), "RGBA").resize((256, 256), Image.LANCZOS)
        _cache[k] = small
    return _cache[k]

def field_img(m):
    p = os.path.join(TEXDIR, "MapLand", "%d.tga" % m["id"])
    src = Image.open(p).convert("RGBA") if os.path.exists(p) else land_field(m)
    return np.asarray(src.resize((1002, 668), Image.BILINEAR)).astype(np.float32) / 255

EDGE_SOFT = 14                  # art px: a zone's overlays fade in over this, inside its frame
EDGE_RANGE = (12, 80)           # art px: the frame widths looked for
EDGE_CLAMP = (16, 36)           # ... and the widths Blizzard's frames actually come in

def edge(m):
    """MapEdge: where a zone's overlay art shows: inside its frame. The frame (burnt paper,
    dark ink) is measured on each side, as far in as the art's edge band stays darker than
    the parchment inside, so whatever the zone paints right up to it (Dalaran at Alterac's
    edge) isn't cut off by a fixed inset"""
    k = ("edge", m["id"])
    if k not in _cache:
        p_ = os.path.join(TEXDIR, "MapEdge", "%d.tga" % m["id"])
        if os.path.exists(p_) and not _cache.get("rebake_edges"):
            _cache[k] = np.asarray(Image.open(p_).convert("RGBA").getchannel("A").resize((1002, 668), Image.BILINEAR)).astype(np.float32) / 255
            return _cache[k]
        from scipy import ndimage
        L = base(m)[..., :3].mean(2)
        inner = np.median(L[100:568, 150:850])
        def depth(profile):
            sm = ndimage.uniform_filter1d(profile, 5)
            for i in range(EDGE_RANGE[0], EDGE_RANGE[1]):
                if sm[i] > inner * 0.88: return i
            return EDGE_RANGE[1]
        # each side's profile, through the middle half of that side (corners have their knots)
        left = depth(np.median(L[167:501, :EDGE_RANGE[1] + 10], axis=0))
        right = depth(np.median(L[167:501, ::-1][:, :EDGE_RANGE[1] + 10], axis=0))
        top = depth(np.median(L[:EDGE_RANGE[1] + 10, 250:752], axis=1))
        bottom = depth(np.median(L[::-1][:EDGE_RANGE[1] + 10, 250:752], axis=1))
        # dark terrain or sea running to the edge reads as frame: Blizzard's frame is about the
        # same on every map, so a measurement outside its usual width is clamped to it
        left, right, top, bottom = (int(np.clip(v_, *EDGE_CLAMP)) for v_ in (left, right, top, bottom))
        ys, xs = np.mgrid[0:668, 0:1002].astype(np.float32)
        def ramp(d, at): return np.clip((d - at) / EDGE_SOFT, 0, 1)
        e = ramp(xs, left) * ramp(1001 - xs, right) * ramp(ys, top) * ramp(667 - ys, bottom)
        # the corners' knots: rounded off
        cx = np.minimum(xs - left, 1001 - right - xs); cy = np.minimum(ys - top, 667 - bottom - ys)
        corner = np.clip((np.hypot(np.clip(60 - cx, 0, None), np.clip(60 - cy, 0, None)) * -1 + 60) / EDGE_SOFT, 0, 1)
        e = e * corner
        _cache[k] = (e * e * (3 - 2 * e)).astype(np.float32)
        _cache[("edge_px", m["id"])] = (left, right, top, bottom)
    return _cache[k]

def bake_edges():
    os.makedirs(os.path.join(TEXDIR, "MapEdge"), exist_ok=True)
    _cache["rebake_edges"] = True
    for m in zones:
        if not reveal.get(m["art"]): continue
        e = edge(m)
        a = Image.fromarray((e * 255).astype(np.uint8)).resize((128, 128), Image.LANCZOS)   # (soft rectangles: small is plenty)
        Image.merge("RGBA", (Image.new("L", (128, 128), 255),) * 3 + (a,)).save(os.path.join(TEXDIR, "MapEdge", "%d.tga" % m["id"]))
        print("edge", m["name"], _cache[("edge_px", m["id"])], flush=True)
    _cache["rebake_edges"] = False

TERR_MARGIN = (0, 8)            # a zone's base art: full this far (its art px) past its land, gone after this much more
SHORE = (13.0, 17.0)            # world units off a zone's coast where its own painted sea is full / gone (its islets, hatching)
SHORE_FRAME = 70                # zone art px inside its frame over which that painted sea fades in
LETTER_OFF = 10                 # art px off a coast before dark ink can be a sea name

def own_land(m):
    """where the zone's own land is, in its art px: its overlay pieces, closed and filled"""
    k = ("own", m["id"])
    if k not in _cache:
        from scipy import ndimage
        o = over(m)
        _cache[k] = ndimage.binary_fill_holes(ndimage.binary_closing(o[..., 3] > 0.5, np.ones((3, 3)), iterations=6))
    return _cache[k]

def zone_sea(m):
    """where the zone's own art shows sea (its art px): the open water (low saturation:
    land parchment is strongly saturated), grown back to the coast over the hatched band,
    never onto its own land, inside its frame"""
    k = ("zsea", m["id"])
    if k not in _cache:
        from scipy import ndimage
        b = base(m)[..., :3]
        bb = np.dstack([ndimage.gaussian_filter(b[..., c], 5) for c in range(3)])
        mx, mn = bb.max(2), bb.min(2)
        core = ((mx - mn) / np.maximum(mx, 1e-3) < 0.42) & (M_FEATHER > 0.5)
        land = ndimage.binary_dilation(own_land(m), iterations=2)
        sea = ndimage.binary_dilation(core, iterations=30) & ~land & (M_FEATHER > 0.2)
        _cache[k] = sea
    return _cache[k]

def find_letters(m, region, size=(8, 26), mates=2, grow=8):
    """lettering in a zone's base art, inside `region` (its art px): dark ink set apart in
    letter-sized blocks, at least `mates` others of about the same height on the same line nearby
    (a word, not the long horizontal wave strokes or a mountain's pen strokes); 0..1"""
    from scipy import ndimage
    L = base(m)[..., :3].mean(2)
    # thin dark strokes (a letter's lines), not the broad mottling: what a closing fills in
    ink = (ndimage.grey_closing(L, size=(5, 5)) - L > 0.09) & region
    lab, n = ndimage.label(ink)
    boxes = ndimage.find_objects(lab)
    cand = []
    for i, sl in enumerate(boxes, 1):
        h, w = sl[0].stop - sl[0].start, sl[1].stop - sl[1].start
        area = int((lab[sl] == i).sum())
        if size[0] <= h <= size[1] and 2 <= w <= size[1] + 2 and 12 <= area <= size[1] * 9:   # letter-sized, not a stroke or a speck
            cand.append((i, (sl[0].start + sl[0].stop) / 2, (sl[1].start + sl[1].stop) / 2, h))
    hit = np.zeros(L.shape, bool)
    for i, cy, cx, h in cand:
        near = sum(1 for j, y2, x2, h2 in cand if j != i and abs(y2 - cy) < h * 0.5 and abs(x2 - cx) < 70 and abs(h2 - h) < 6)
        if near >= mates: hit |= lab == i
    # ... then the rest of each word and line: smaller ink beside what's found (twice over)
    small = np.isin(lab, [i for i, sl in enumerate(boxes, 1) if (sl[0].stop - sl[0].start) <= size[1] and (sl[1].stop - sl[1].start) <= 40])
    for _ in range(2):
        g_ = ndimage.binary_dilation(hit, iterations=22)
        ids = np.unique(lab[g_ & small])
        hit |= np.isin(lab, ids[ids > 0])
    return np.clip(ndimage.gaussian_filter(ndimage.binary_dilation(hit, iterations=grow).astype(np.float32), 3) * 1.5, 0, 1)

def sea_letters(m):
    """the sea names printed in a zone's painted sea ("The Great Sea" ...): away from its coast"""
    k = ("letters", m["id"])
    if k not in _cache:
        from scipy import ndimage
        _cache[k] = find_letters(m, zone_sea(m) & (ndimage.distance_transform_edt(~own_land(m)) > LETTER_OFF))
    return _cache[k]

COMPASS_FROM = ("Tanaris", 800, 525, 40)   # a compass rose to find the others by: its centre (art px) and half its size
COMPASS_MATCH = 0.26            # how alike (normalized correlation of their ink) a compass rose must be: low, as it's
                                #  only looked for in the zone's open sea (a false one there costs a patch of sea)
COMPASS_SCALES = (0.85, 1.0, 1.15)
def compass_ink(m):
    from scipy import ndimage
    L = base(m)[..., :3].mean(2)
    return ndimage.grey_closing(L, size=(5, 5)) - L          # (thin dark strokes)

def compasses(m):
    """the compass roses Blizzard draws in a zone's sea (one drawing, on many maps), found by their
    likeness to one of them (COMPASS_FROM); its art px, 0..1"""
    k = ("compass", m["id"])
    if k not in _cache:
        from scipy import ndimage
        def conv(a, k):                                   # (same-size correlation by FFT, numpy's)
            sh = (a.shape[0] + k.shape[0], a.shape[1] + k.shape[1])
            r = np.fft.irfft2(np.fft.rfft2(a, sh) * np.fft.rfft2(k[::-1, ::-1], sh), sh)
            oy, ox = k.shape[0] // 2, k.shape[1] // 2
            return r[oy:oy + a.shape[0], ox:ox + a.shape[1]]
        if "compass_t" not in _cache:
            name, cx, cy, r = COMPASS_FROM
            src_ = next(z for z in zones if z["name"] == name)
            _cache["compass_t"] = compass_ink(src_)[cy - r:cy + r, cx - r:cx + r]
        t0 = _cache["compass_t"]
        ink = compass_ink(m).astype(np.float32)
        where = zone_sea(m) & (ndimage.distance_transform_edt(~own_land(m)) > 15) & (edge(m) > 0.05)
        hit = np.zeros(ink.shape, np.float32)
        ys, xs = np.mgrid[0:668, 0:1002].astype(np.float32)
        for sc in COMPASS_SCALES:
            n_ = max(8, int(round(t0.shape[0] * sc)))
            t = np.asarray(Image.fromarray(t0.astype(np.float32), "F").resize((n_, n_), Image.BILINEAR))
            t = (t - t.mean()) / (t.std() + 1e-6)
            n = t.size
            num = conv(ink, t)
            ones = np.ones_like(t)
            mean = conv(ink, ones) / n
            sq = conv(ink * ink, ones) / n
            sd = np.sqrt(np.maximum(sq - mean * mean, 1e-8))
            ncc = num / (n * sd)
            peaks = (ncc > COMPASS_MATCH) & (ncc == ndimage.maximum_filter(ncc, size=30)) & where
            for py, px_ in zip(*np.nonzero(peaks)):
                d = np.hypot(ys - py, xs - px_)
                rr = COMPASS_FROM[3] * sc
                hit = np.maximum(hit, np.clip(1 - (d - rr) / (rr * 0.5), 0, 1))
        _cache[k] = hit
    return _cache[k]

def land_letters(m):
    """the names a zone's base art prints on the land round it ("The Blasted Lands" on Swamp of
    Sorrows' painting of it ...): anywhere off its own land, in its frame"""
    k = ("lletters", m["id"])
    if k not in _cache:
        from scipy import ndimage
        off = ~ndimage.binary_dilation(own_land(m), iterations=4) & (edge(m) > 0.3)
        _cache[k] = find_letters(m, off, size=(9, 34), mates=3, grow=10)
    return _cache[k]

def shore(m):
    """the zone's own painted sea near its coast (0..1, its art px): full SHORE[0] world units
    out, gone by SHORE[1]; not where it prints a sea name"""
    k = ("shore", m["id"])
    if k not in _cache:
        from scipy import ndimage
        l, r, t, b = m["rect"]
        px_per_unit = 1002 / ((r - l) * 1002)
        d = ndimage.distance_transform_edt(~own_land(m)) / px_per_unit
        t_ = np.clip(1 - (d - SHORE[0]) / (SHORE[1] - SHORE[0]), 0, 1)
        _cache[k] = (zone_sea(m) * t_ * t_ * (3 - 2 * t_) * (1 - sea_letters(m))).astype(np.float32)
    return _cache[k]

# MapZoneLand: a zone's land as it shows (its territory, MapTerritory) without the sea its own art
# paints (Westfall's Great Sea, coastal hatching, islets), for darkening unexplored land and not
# the sea: open sea in its base art (low saturation: its land is plain parchment; only patches
# that reach the art's frame and are big, not lakes), grown through the zone as drawn while it
# stays sea-coloured (the hatched band up to the coast)
ZONE_LAND_SEED, ZONE_LAND_GROW, ZONE_LAND_MIN = 0.42, 0.47, 4000   # saturation; saturation; art px
ZONE_LAND_ISLAND = 3000         # art px: land patches smaller than this, apart from the rest, are left out
ZONE_LAND_SOFT = 5.0            # art px: the land mask's edge falloff (the darkening's, Stitch.lua's Shade)
def zone_land(m):
    k = ("zland", m["id"])
    if k not in _cache:
        from scipy import ndimage
        sea = zone_sea_found(m)
        t = terr_own(m)
        if t is None:
            _cache[k] = None
            return None
        # its land: the territory less that sea (a pixel more, so the edge sits on the coast's ink),
        # never its own land (its pieces, own_land: pale land, the Plaguelands' blight, reads as sea by
        # colour); small patches cut off out in the sea (a compass rose, specks the sea's colour missed) go
        sea_ = sea & ~ndimage.binary_dilation(own_land(m), iterations=2)
        coast = island_coast(m)
        if coast is not None:                             # (an island: its land is known, the rest is its sea)
            sea_ |= ~ndimage.binary_dilation(own_land(m) | coast, iterations=2)
        solid = (t > 0.5) & ~ndimage.binary_dilation(sea_, iterations=1)
        lab, n = ndimage.label(solid)
        if n:
            sizes = ndimage.sum(np.ones_like(lab), lab, index=range(1, n + 1))
            solid = np.isin(lab, [i + 1 for i, s in enumerate(sizes) if s >= ZONE_LAND_ISLAND])
        _cache[k] = t * ndimage.gaussian_filter(solid.astype(np.float32), ZONE_LAND_SOFT)
    return _cache[k]

# MapZoneBorder: a zone's share of the land round it that's no zone's (the mountains along its
# border, blank land between zones): each bit of it goes to the nearest zone's land, up to
# BORDER_REACH world units, never onto sea. Shaded with an undiscovered zone (Stitch.lua), so a
# stretch of zones you haven't found is dark from one to the next, not dark zones in bright
# parchment; the shares don't overlap, so where two meet there's no doubled seam. Each covers
# the zone's art rectangle and BORDER_REACH round it (Stitch.lua places it so), coarsely: mountains
BORDER_REACH = 12               # world units (Stitch.lua's BORDER_REACH)
BORDER_GRID = 2                 # px per world unit, laying a continent's zones out together
BORDER_PX = 128                 # the masks' size
BORDER_SOFT = 2.5               # its edge falloff, in BORDER_GRID px (it meets the zones' land masks soft too)
W_, H_ = 1002.0, 668.0          # Azeroth's map in world units (render()'s W, H)

def zone_borders():
    """zone id -> its share of the border land, on its art rectangle and BORDER_REACH round it"""
    from scipy import ndimage
    out_ = {}
    G = BORDER_GRID
    for c in maps:
        if c["kind"] != 2: continue
        cl, cr, ct, cb = c["rect"]
        gw, gh = int((cr - cl) * W_ * G), int((cb - ct) * H_ * G)
        def box(m):                                   # a map's rectangle on the continent's grid
            l, r, t, b = m["rect"]
            return (int(round((l - cl) * W_ * G)), int(round((t - ct) * H_ * G)),
                    int(round((r - cl) * W_ * G)), int(round((b - ct) * H_ * G)))
        def paste(dst, img, bx, op):
            x0, y0, x1, y1 = bx
            if x1 - x0 < 2 or y1 - y0 < 2: return
            a = np.asarray(Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).resize((x1 - x0, y1 - y0), Image.BILINEAR)).astype(np.float32) / 255
            X0, Y0, X1, Y1 = max(0, x0), max(0, y0), min(gw, x1), min(gh, y1)
            if X1 <= X0 or Y1 <= Y0: return
            op(dst[Y0:Y1, X0:X1], a[Y0 - y0:Y1 - y0, X0 - x0:X1 - x0])
        mine = [m for m in zones if reveal.get(m["art"]) and m["id"] in grade and zone_land(m) is not None
                and cl <= (m["rect"][0] + m["rect"][1]) / 2 <= cr and ct <= (m["rect"][2] + m["rect"][3]) / 2 <= cb]
        if not mine: continue
        best = np.zeros((gh, gw), np.float32)
        label = np.zeros((gh, gw), np.int32)
        sea = np.zeros((gh, gw), np.float32)
        covered = np.zeros((gh, gw), np.float32)          # all the zones' land, added up
        for i, m in enumerate(mine, 1):
            cover = np.zeros((gh, gw), np.float32)
            paste(cover, zone_land(m), box(m), lambda d, a: np.maximum(d, a, out=d))
            covered += cover
            take = (cover > 0.5) & (cover > best)
            label[take], best[take] = i, cover[take]
            t = terr_own(m)                               # (its own painted sea: territory less land)
            paste(sea, np.clip(t - zone_land(m), 0, 1), box(m), lambda d, a: np.maximum(d, a, out=d))
        land = np.zeros((gh, gw), np.float32)
        paste(land, field_img(c)[..., 3], (0, 0, gw, gh), lambda d, a: np.maximum(d, a, out=d))
        free = (land > 0.5) & (sea < 0.5) & (covered < 0.99)
        dist, (iy, ix) = ndimage.distance_transform_edt(label == 0, return_indices=True)
        nearest = label[iy, ix]
        free &= dist <= BORDER_REACH * G
        for i, m in enumerate(mine, 1):
            share = ndimage.gaussian_filter((free & (nearest == i)).astype(np.float32), BORDER_SOFT)
            share *= np.clip(1 - covered, 0, 1)              # (only what the zones' own land leaves)
            x0, y0, x1, y1 = box(m)
            R = BORDER_REACH * G
            crop = np.zeros((y1 - y0 + 2 * R, x1 - x0 + 2 * R), np.float32)
            X0, Y0, X1, Y1 = max(0, x0 - R), max(0, y0 - R), min(gw, x1 + R), min(gh, y1 + R)
            crop[Y0 - (y0 - R):Y1 - (y0 - R), X0 - (x0 - R):X1 - (x0 - R)] = share[Y0:Y1, X0:X1]
            out_[m["id"]] = crop
    return out_

def neighbours_on(m):
    """the other zones' land (zone_land) laid on this zone's art px, added up, where they overlap it"""
    l, r, t, b = m["rect"]
    total = np.zeros((668, 1002), np.float32)
    for n in zones:
        if n is m or zone_land(n) is None: continue
        nl, nr, nt, nb = n["rect"]
        if nr <= l or nl >= r or nb <= t or nt >= b: continue
        # m's art px -> n's: x_n = a x + c, y_n = e y + f
        a, e = (r - l) / (nr - nl), (b - t) / (nb - nt)
        c, f = (l - nl) / (nr - nl) * 1002, (t - nt) / (nb - nt) * 668
        img = Image.fromarray(zone_land(n).astype(np.float32), "F")
        total += np.asarray(img.transform((1002, 668), Image.AFFINE, (a, 0, c, 0, e, f), Image.BILINEAR, fillcolor=0))
    return total

def zone_land_shared(m):
    """zone_land, with land neighbouring zones also cover shared out between them (each its part),
    so two zones' shades never land twice on one spot (no dark seams where they meet)"""
    k = ("zshared", m["id"])
    if k not in _cache:
        own = zone_land(m)
        _cache[k] = None if own is None else own / np.maximum(1.0, own + neighbours_on(m))
    return _cache[k]

def saturation(img, s):
    """an image's saturation, blurred by s px"""
    bb = np.dstack([ndimage.gaussian_filter(img[..., c], s) for c in range(3)])
    mx, mn = bb.max(2), bb.min(2)
    return (mx - mn) / np.maximum(mx, 1e-3)

def drawn_art(m):
    """a zone's base art with its overlays over it, as drawn (its art px, rgb)"""
    b, o = base(m)[..., :3], over(m)
    return b * (1 - o[..., 3:4]) + o[..., :3] * o[..., 3:4]

def zone_sea_found(m):
    """the sea zone_land finds in a zone's art (its art px): open sea reaching its frame, grown to
    the coast; stricter than zone_sea (no lakes, no grey land, no small maps' inlets)"""
    k = ("zsea_found", m["id"])
    if k not in _cache:
        from scipy import ndimage
        b, drawn = base(m)[..., :3], drawn_art(m)
        seed = (saturation(b, 5) < ZONE_LAND_SEED) & (M_FEATHER > 0.5)
        lab, n = ndimage.label(seed)
        frame = ndimage.binary_dilation(M_FEATHER < 0.6, iterations=8)
        keep = sorted(set(np.unique(lab[frame & (lab > 0)]).tolist()) - {0})
        sizes = ndimage.sum(np.ones_like(lab), lab, index=keep) if keep else []
        seed = np.isin(lab, [i for i, s in zip(keep, sizes) if s >= ZONE_LAND_MIN])
        sea = ndimage.binary_propagation(seed, mask=seed | (saturation(drawn, 2) < ZONE_LAND_GROW))
        _cache[k] = ndimage.binary_opening(sea, iterations=2)
    return _cache[k]

def continent_land(m):
    """the land of the continent a zone is on (MapLand), on the zone's art px"""
    k = ("cland", m["id"])
    if k not in _cache:
        l, r, t, b = m["rect"]
        mx, my = (l + r) / 2, (t + b) / 2
        c = next((c for c in maps if c["kind"] == 2 and c["rect"][0] <= mx <= c["rect"][1] and c["rect"][2] <= my <= c["rect"][3]), None)
        if c is None:
            _cache[k] = np.zeros((668, 1002), np.float32)
        else:
            cl, cr, ct, cb = c["rect"]
            xs = (l + (np.arange(1002) + 0.5) / 1002 * (r - l) - cl) / (cr - cl) * 1002 - 0.5
            ys = (t + (np.arange(668) + 0.5) / 668 * (b - t) - ct) / (cb - ct) * 668 - 0.5
            Y, X = np.meshgrid(ys, xs, indexing="ij")
            _cache[k] = ndimage.map_coordinates(field_img(c)[..., 3], [Y, X], order=1, mode="constant", cval=0)
    return _cache[k]

# An island zone the continent's art doesn't show as land (Teldrassil, in Kalimdor's decorated corner)
# has no coast for the territories' painted sea to reach from (terr_shared's TERR_SEA), and its overlays
# leave out the coast it paints round them (Teldrassil's roots, whose grain also reads as lettering), so
# its territory had holes all round its shore: that coast is taken from its own art instead
ISLAND_OFF = 0.05               # a zone with less than this share of its own land on the continent's land is such an island
ISLAND_FRAME = 35               # zone art px inside its frame the coast stops at (the parchment's burnt edge isn't land)
def island_coast(m):
    """the coast an island zone paints past its overlays (its art px; None if it isn't one): what its
    art paints that isn't sea (zone_sea_found, nor the sea's colour: the inlets between Teldrassil's
    roots) joined to its own land, up to SHORE[1] world units off it, short of its frame"""
    k = ("island", m["id"])
    if k not in _cache:
        _cache[k] = None
        own = own_land(m)
        if own.any() and (own & (continent_land(m) > 0.5)).sum() < ISLAND_OFF * own.sum():
            l, r, t, b = m["rect"]
            d = ndimage.distance_transform_edt(~own) * (r - l)        # (world units: an art px is r - l of them)
            inside = ndimage.distance_transform_edt(edge(m) > 0.5)
            land = ~zone_sea_found(m) & (saturation(drawn_art(m), 2) >= ZONE_LAND_GROW)
            lab, _ = ndimage.label(own | (land & (inside > ISLAND_FRAME) & (d <= SHORE[1])))
            ids = np.unique(lab[own])
            coast = ndimage.binary_fill_holes(np.isin(lab, ids[ids > 0])) & ~own
            if coast.any(): _cache[k] = coast
    return _cache[k]

def bake_zone_land():
    outdir_ = os.path.join(TEXDIR, "MapZoneLand")
    os.makedirs(outdir_, exist_ok=True)
    n = 0
    for m in zones:
        if not reveal.get(m["art"]) or m["id"] not in grade: continue   # (Stitch.lua's ZoneMask: colour-matched zones)
        land = zone_land_shared(m)
        if land is None: continue
        a = Image.fromarray((np.clip(land, 0, 1) * 255).astype(np.uint8)).resize((256, 256), Image.LANCZOS)
        Image.merge("RGBA", (Image.new("L", (256, 256), 255),) * 3 + (a,)).save(os.path.join(outdir_, "%d.tga" % m["id"]))
        n += 1
    print("baked", n, "zone land masks", flush=True)
    outdir_ = os.path.join(TEXDIR, "MapZoneBorder")
    os.makedirs(outdir_, exist_ok=True)
    borders = zone_borders()
    for zid, share in borders.items():
        a = Image.fromarray((np.clip(share, 0, 1) * 255).astype(np.uint8)).resize((BORDER_PX, BORDER_PX), Image.LANCZOS)
        Image.merge("RGBA", (Image.new("L", (BORDER_PX, BORDER_PX), 255),) * 3 + (a,)).save(os.path.join(outdir_, "%d.tga" % zid))
    print("baked", len(borders), "zone border masks", flush=True)

def terr_own_raw(m):
    """a zone's own territory: its land and a little past it, its own painted sea off its coasts
    (SHORE), the cities in it; inside its frame (the unexplored shading's masks, MapZoneLand and
    MapZoneBorder, are made from this)"""
    k = ("terr_own_raw", m["id"])
    if k in _cache: return _cache[k]
    from scipy import ndimage
    o = over(m)
    if not o[..., 3].any():
        _cache[k] = None
        return None
    land = ndimage.binary_fill_holes(ndimage.binary_closing(o[..., 3] * edge(m) > 0.5, np.ones((3, 3)), iterations=6))
    dout = ndimage.distance_transform_edt(~land)
    tt = np.clip(1 - np.maximum(0, dout - TERR_MARGIN[0]) / TERR_MARGIN[1], 0, 1)
    terr = tt * tt * (3 - 2 * tt)
    inside = ndimage.distance_transform_edt(edge(m) > 0.5)
    sf = np.clip(inside / SHORE_FRAME, 0, 1)
    terr = np.maximum(terr, shore(m) * sf * sf * (3 - 2 * sf))
    # an island's coast its overlays leave out (Teldrassil's roots), with the land's margin, fading in at
    # its frame as the shore does
    coast = island_coast(m)
    if coast is not None:
        ct_ = np.clip(1 - np.maximum(0, ndimage.distance_transform_edt(~coast) - TERR_MARGIN[0]) / TERR_MARGIN[1], 0, 1)
        terr = np.maximum(terr, ct_ * ct_ * (3 - 2 * ct_) * sf * sf * (3 - 2 * sf))
    # the cities inside it (Orgrimmar in Durotar ...): maps of their own, shown only once you're
    # close, so until then the zone's painting of them shows. (The game lists cities under their
    # continent: a city belongs to the zone whose own land is at its centre)
    l, r, t, b = m["rect"]
    for c in zones:
        if reveal.get(c["art"]): continue
        if os.path.exists(os.path.join(TEXDIR, "MapCityMask", "%d.tga" % c["id"])): continue   # (cut to the city: banners.py)
        cl, cr, ct, cb = c["rect"]
        cx, cy = int(((cl + cr) / 2 - l) / (r - l) * 1002), int(((ct + cb) / 2 - t) / (b - t) * 668)
        if not (0 <= cx < 1002 and 0 <= cy < 668) or not ndimage.binary_dilation(own_land(m), iterations=40)[cy, cx]: continue
        box = (int((cl - l) / (r - l) * 1002), int((ct - t) / (b - t) * 668), int((cr - l) / (r - l) * 1002), int((cb - t) / (b - t) * 668))
        w_, h_ = box[2] - box[0], box[3] - box[1]
        if w_ < 4 or h_ < 4: continue
        city = np.asarray(Image.fromarray((M_ROUND * 255).astype(np.uint8)).resize((w_, h_), Image.BILINEAR)).astype(np.float32) / 255
        x0, y0, x1, y1 = max(0, box[0]), max(0, box[1]), min(1002, box[2]), min(668, box[3])
        if x1 <= x0 or y1 <= y0: continue
        piece = city[y0 - box[1]:y1 - box[1], x0 - box[0]:x1 - box[0]]
        terr[y0:y1, x0:x1] = np.maximum(terr[y0:y1, x0:x1], piece)
    # never past the zone's own frame: its burnt edge and dark ink would smear over the land beside it
    _cache[k] = terr * edge(m)
    return _cache[k]

def terr_own(m):
    """terr_own_raw as the 128-px mask it was baked to (MapTerritory, before it took in the
    zone's whole painting): what MapZoneLand and MapZoneBorder are made from"""
    k = ("terr_own", m["id"])
    if k not in _cache:
        t = terr_own_raw(m)
        if t is None: _cache[k] = None
        else:
            a = Image.fromarray((np.clip(t, 0, 1) * 255).astype(np.uint8)).resize((128, 128), Image.LANCZOS)
            _cache[k] = np.asarray(a.resize((1002, 668), Image.BILINEAR)).astype(np.float32) / 255
    return _cache[k]

# MapTerritory: where a zone's base art shows, as far as Blizzard painted it: its own land (and
# cities), and past it everything else its map paints inside its frame (the sea off its coasts, the
# land round it no zone owns: Tanaris' painting of the coast south of Un'Goro ...; not where Blizzard's
# classic map of that land is drawn, which paints it where Forever's maps leave it blank), never another
# zone's own land (its blank painting of a neighbour, with that neighbour's name on it). Where two
# zones paint the same place, the one whose own land is nearer has it, crossfading over
# TERR_BLEND world units. Its sea reaches TERR_SEA world units off the continent's coast (not out
# to its frame: the open sea's lettering), and never the names it prints (the sea's, its
# neighbours' on their land) or its compass roses; at its frame its painting fades into the paper
# over TERR_FRAME. Past every
# zone's painting the land is the gap fill's blank paper (gapfill.py), which each zone's art fades
# into at its frame.
TERR_GRID = 4                   # px per world unit, laying a continent's zones out together
TERR_BLEND = 3.0                # world units: how fast a zone's claim on land two zones paint falls off past the nearer one's
TERR_SEA = (12.0, 20.0)         # world units off the continent's coast where a zone's painted sea is full / gone
TERR_OTHER = 1.0                # world units over which a zone's painting gives way to another zone's own land
TERR_FRAME = 5.0                # world units inside its frame over which its painting (not its own land) fades into the paper
TERR_PX = 256                   # the masks' size
def terr_shared():
    """zone id -> its territory (its art px), the zones of each continent laid out together"""
    from scipy import ndimage
    G = TERR_GRID
    out_ = {}
    for c in maps:
        if c["kind"] != 2: continue
        cl, cr, ct, cb = c["rect"]
        gw, gh = int((cr - cl) * W_ * G), int((cb - ct) * H_ * G)
        mine = [m for m in zones if reveal.get(m["art"]) and terr_own_raw(m) is not None
                and cl <= (m["rect"][0] + m["rect"][1]) / 2 <= cr and ct <= (m["rect"][2] + m["rect"][3]) / 2 <= cb]
        if not mine: continue
        def box(m):
            l, r, t, b = m["rect"]
            return (int(round((l - cl) * W_ * G)), int(round((t - ct) * H_ * G)),
                    int(round((r - cl) * W_ * G)), int(round((b - ct) * H_ * G)))
        def to_grid(img, m):
            """an art-px image of zone m on the continent's grid (0 outside its rectangle)"""
            x0, y0, x1, y1 = box(m)
            dst = np.zeros((gh, gw), np.float32)
            if x1 - x0 < 2 or y1 - y0 < 2: return dst
            a = np.asarray(Image.fromarray(np.clip(img, 0, 1).astype(np.float32), "F").resize((x1 - x0, y1 - y0), Image.BILINEAR))
            X0, Y0, X1, Y1 = max(0, x0), max(0, y0), min(gw, x1), min(gh, y1)
            if X1 > X0 and Y1 > Y0: dst[Y0:Y1, X0:X1] = a[Y0 - y0:Y1 - y0, X0 - x0:X1 - x0]
            return dst
        def to_art(img, m):
            """back: the grid over zone m's rectangle, at its art px"""
            x0, y0, x1, y1 = box(m)
            pad = np.zeros((y1 - y0, x1 - x0), np.float32)
            X0, Y0, X1, Y1 = max(0, x0), max(0, y0), min(gw, x1), min(gh, y1)
            if X1 > X0 and Y1 > Y0: pad[Y0 - y0:Y1 - y0, X0 - x0:X1 - x0] = img[Y0:Y1, X0:X1]
            return np.asarray(Image.fromarray(pad, "F").resize((1002, 668), Image.BILINEAR))
        own, frame, dist = {}, {}, {}
        for m in mine:
            own[m["id"]] = to_grid(terr_own_raw(m), m)                   # (its own land, cities and shore)
            frame[m["id"]] = to_grid(edge(m), m)
            land = ndimage.binary_fill_holes(ndimage.binary_closing(over(m)[..., 3] * edge(m) > 0.5, np.ones((3, 3)), iterations=6))
            dist[m["id"]] = ndimage.distance_transform_edt(to_grid(land.astype(np.float32), m) < 0.5) / G
        # the continent's land (its map's coast, coarse but sure of itself), and how far each spot is
        # from it: a zone's painted sea reaches only so far off a coast
        cland = np.asarray(Image.fromarray((field_img(c)[..., 3] * 255).astype(np.uint8)).resize((gw, gh), Image.BILINEAR)).astype(np.float32) / 255
        from_land = ndimage.distance_transform_edt(cland < 0.5) / G
        u = np.clip(1 - (from_land - TERR_SEA[0]) / (TERR_SEA[1] - TERR_SEA[0]), 0, 1)
        reach = u * u * (3 - 2 * u)
        # where Blizzard's classic maps of the land are drawn (Gaps.lua's art: Gilneas, the ridges round
        # Orgrimmar ...): theirs, over a Forever zone's blank painting of the same land
        classic = np.zeros((gh, gw), np.float32)
        for x in gap_art():
            al, ar, at, ab = x["rect"]
            a_ = x["img"][..., 3] * (x["mask"] if x["mask"] is not None else 1)
            x0, y0 = int(round((al - cl) * W_ * G)), int(round((at - ct) * H_ * G))
            x1, y1 = int(round((ar - cl) * W_ * G)), int(round((ab - ct) * H_ * G))
            if x1 - x0 < 2 or y1 - y0 < 2: continue
            a = np.asarray(Image.fromarray(a_.astype(np.float32), "F").resize((x1 - x0, y1 - y0), Image.BILINEAR))
            X0, Y0, X1, Y1 = max(0, x0), max(0, y0), min(gw, x1), min(gh, y1)
            if X1 > X0 and Y1 > Y0: classic[Y0:Y1, X0:X1] = np.maximum(classic[Y0:Y1, X0:X1], a[Y0 - y0:Y1 - y0, X0 - x0:X1 - x0])
        # each zone's claim on the land round it: its painting where it can show it (inside its frame,
        # fading out over TERR_FRAME; off the others' own land; not where it prints a name), weighed by
        # how near its own land is. The claims are shared out where they overlap, so where one zone's
        # frame ends the next takes over, and where none reaches there's paper
        claim, avail = {}, {}
        big = np.float32(1e6)
        dmin = np.full((gh, gw), big, np.float32)
        for m in mine:
            i = m["id"]
            # off the others' own land, as much as that's drawn: where a neighbour's art fades out at its
            # frame, this one's painting comes in by as much, so no paper shows between them
            others = np.zeros((gh, gw), np.float32)
            for n in mine:
                if n is not m: others = np.maximum(others, ndimage.gaussian_filter((dist[n["id"]] <= 0).astype(np.float32), TERR_OTHER * G / 2) * frame[n["id"]])
            keep = np.clip(1 - others, 0, 1)
            letters = to_grid(np.maximum(sea_letters(m), land_letters(m)), m)
            t = np.clip(ndimage.distance_transform_edt(frame[i] > 0.5) / G / TERR_FRAME, 0, 1)
            avail[i] = (t * t * (3 - 2 * t)) * keep * (1 - letters)
            dmin = np.minimum(dmin, np.where(avail[i] > 0.01, dist[i], big))
        total = np.zeros((gh, gw), np.float32)
        for m in mine:
            i = m["id"]
            claim[i] = avail[i] * np.exp(-np.clip(dist[i] - dmin, 0, 60) / TERR_BLEND)
            total += claim[i]
        norm = np.maximum(total, 1)
        for m in mine:
            i = m["id"]
            # its painted sea only so far off the coast; not where Blizzard's classic map of the land is drawn
            beyond = claim[i] / norm * reach * (1 - np.clip(classic * 1.25, 0, 1))
            terr = np.maximum(own[i], beyond) * np.clip(frame[i] * 1.0, 0, 1)
            out_[i] = to_art(terr, m) * edge(m) * (1 - compasses(m))       # (never its compass roses)
        print("  territories:", c["name"], len(mine), flush=True)
    return out_

def bake_territory():
    outdir_ = os.path.join(TEXDIR, "MapTerritory")
    os.makedirs(outdir_, exist_ok=True)
    n = 0
    for i, terr in terr_shared().items():
        alpha = Image.fromarray((np.clip(terr, 0, 1) * 255).astype(np.uint8)).resize((TERR_PX, TERR_PX), Image.LANCZOS)
        Image.merge("RGBA", (Image.new("L", (TERR_PX, TERR_PX), 255),) * 3 + (alpha,)).save(os.path.join(outdir_, "%d.tga" % i))
        _cache.pop(("terr", i), None)
        n += 1
    print("baked", n, "territories", flush=True)

ZONE_PX = 16                    # baked zone art: px per world unit (a zone map's own: 4 in the Barrens, 11 most, 22 the smallest; 16 carries zone-fit zooms)
ZONE_TILE, ZONE_STEP = 512, 510 # ... its tiles, and the world each covers (the other 2 px: its neighbours' edge, for filtering)
ZONE_DESAT, ZONE_MATCH = 0.1, 1 # the settings it's baked at (Stitch.lua's defaults: desaturate, colorMatch)

def bake_zones():
    """MapZones/<i>_<j>.blp and Data/ZoneArt.lua: every zone's art as the stitched map draws it at
    full detail, on the world, in tiles (Stitch.lua's zone layers, in its order and with its masks:
    the gaps' finer maps, each zone's base art and its colour-match copy, the overlays, theirs, and
    the interiors), so the map can draw a few dozen tiles where it drew every zone's hundreds"""
    sys.path.insert(0, os.path.join(REPO, "tools", "map-textures"))
    import blp
    W, H = 1002.0, 668.0
    T = ZONE_STEP / ZONE_PX                              # world units a tile covers
    has_over = {m["id"]: bool(reveal.get(m["art"])) for m in zones}
    live = [m for m in zones if has_over[m["id"]]]
    # the layers, bottom to top, as Stitch.lua builds them: (rect, image(), mask(), tint, desaturation)
    layers = []
    for x in gap_art():                                  # (tilesRoot, under every zone's frame; not graded)
        layers.append((x["rect"], lambda x=x: x["img"], lambda x=x: x["mask"], None, 0))
    for m in live:                                       # (a frame each, biggest first: base, then its copy)
        g = grade.get(m["id"])
        layers.append((m["rect"], lambda m=m: base(m), lambda m=m, g=g: M_FEATHER * terr(m) if g and terr(m) is not None else M_FEATHER, None, ZONE_DESAT))
        if g and band(m) is not None:
            layers.append((m["rect"], lambda m=m: base(m), lambda m=m: M_FEATHER * band(m), g, ZONE_DESAT))
    def edge_of(m): return edge(m) if grade.get(m["id"]) else M_THIN   # (Stitch.lua: MapEdge for graded zones)
    for m in live:                                       # (overlayRoot: every zone's overlays, then their copies)
        layers.append((m["rect"], lambda m=m: over(m), lambda m=m: edge_of(m), None, ZONE_DESAT))
    for m in live:
        g = grade.get(m["id"])
        if g and band(m) is not None:
            layers.append((m["rect"], lambda m=m: over(m), lambda m=m: edge_of(m) * band(m), g, ZONE_DESAT))
    for m in live:                                       # (coreRoot: the interiors, graded zones only)
        if grade.get(m["id"]) and os.path.exists(os.path.join(TEXDIR, "MapCore", "%d.tga" % m["id"])):
            layers.append((m["rect"], lambda m=m: over(m), lambda m=m: edge_of(m) * core(m), None, ZONE_DESAT))
    out_dir = os.path.join(TEXDIR, "MapZones")
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith(".blp"): os.remove(os.path.join(out_dir, f))
    cols, rows = int(math.ceil(W / T)), int(math.ceil(H / T))
    made = []
    for j in range(rows):
        for i in range(cols):
            # the tile's pixels' centres, in world units (its first and last px are its neighbours' edge)
            x0, y0 = i * T - 1 / ZONE_PX, j * T - 1 / ZONE_PX
            wx = x0 + (np.arange(ZONE_TILE) + 0.5) / ZONE_PX
            wy = y0 + (np.arange(ZONE_TILE) + 0.5) / ZONE_PX
            acc = np.zeros((ZONE_TILE, ZONE_TILE, 3), np.float32)       # (premultiplied)
            acc_a = np.zeros((ZONE_TILE, ZONE_TILE), np.float32)
            for (l, r, t, b), img_, mask_, tint, dsat in layers:
                cx = np.nonzero((wx >= l * W - 1) & (wx <= r * W + 1))[0]
                cy = np.nonzero((wy >= t * H - 1) & (wy <= b * H + 1))[0]
                if len(cx) == 0 or len(cy) == 0: continue
                img, msk = img_(), mask_()
                if img is None: continue
                sx = (wx[cx] / W - l) / (r - l) * img.shape[1] - 0.5
                sy = (wy[cy] / H - t) / (b - t) * img.shape[0] - 0.5
                SY, SX = np.meshgrid(sy, sx, indexing="ij")
                def sample(ch): return ndimage.map_coordinates(ch, [SY, SX], order=1, mode="constant", cval=0)
                a = sample(img[..., 3])
                if msk is not None: a = a * sample(msk)
                if a.max() <= 0: continue
                rgb = np.dstack([sample(img[..., c]) for c in range(3)])
                rgb = desat(rgb, dsat)
                if tint is not None: rgb = rgb * np.array(tint, np.float32)
                ys_, xs_ = slice(cy[0], cy[-1] + 1), slice(cx[0], cx[-1] + 1)
                acc[ys_, xs_] = acc[ys_, xs_] * (1 - a[..., None]) + rgb * a[..., None]
                acc_a[ys_, xs_] = acc_a[ys_, xs_] * (1 - a) + a
            if acc_a.max() < 1 / 255: continue
            rgb = acc / np.maximum(acc_a[..., None], 1e-6)
            # clear pixels take the nearest seen colour, so filtering at the art's soft edges doesn't darken them
            seen = acc_a >= 1 / 255
            if not seen.all():
                _, (iy, ix) = ndimage.distance_transform_edt(~seen, return_indices=True)
                rgb = rgb[iy, ix]
            rgba = np.dstack([np.clip(rgb, 0, 1), np.clip(acc_a, 0, 1)])
            blp.write(os.path.join(out_dir, "%d_%d.blp" % (i, j)), np.round(rgba * 255).astype(np.uint8))
            made.append(i * 256 + j)
            print("zone tile", i, j, flush=True)
    with open(os.path.join(WM, "ZoneArt.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("-- The zones' art baked into world tiles (Media/Textures/MapZones/<i>_<j>.blp): every zone's layers as\n"
                "-- Stitch.lua draws them at full detail, at the settings below. Stitch.lua draws these in their place.\n"
                "-- Generated by tools/map-preview/render.py --bake-zones (build %s); regenerate rather than edit.\n\n" % BUILD)
        f.write("local _, ns = ...\n\n")
        f.write("ns.MapZoneArt = {\n")
        f.write("\tpx = %d, size = %d, step = %d,   -- px per world unit; a tile's px, and those of it the world (the rest: its neighbours' edge)\n" % (ZONE_PX, ZONE_TILE, ZONE_STEP))
        f.write("\tdesaturate = %g, colorMatch = %g,   -- the settings it's baked at\n" % (ZONE_DESAT, ZONE_MATCH))
        f.write("\ttiles = {   -- i * 256 + j: column i, row j\n")
        for k in range(0, len(made), 16):
            f.write("\t\t" + ", ".join(str(v_) for v_ in made[k:k + 16]) + ",\n")
        f.write("\t},\n}\n")
    print("baked", len(made), "zone tiles", flush=True)

views = sys.argv[4:] or ["world=0.5,0.5,1"]
if views and views[0] == "--bake-zones":
    bake_zones()
    views = views[1:]
if views and views[0] == "--bake-land":
    # MapLand/<continent>.tga: where a continent's art is land, for the land fill and grain
    os.makedirs(os.path.join(TEXDIR, "MapLand"), exist_ok=True)
    for m in maps:
        if m["kind"] == 2:
            land_field(m).save(os.path.join(TEXDIR, "MapLand", "%d.tga" % m["id"]))
            print("baked land", m["id"], m["name"], flush=True)
    views = views[1:]
if views and views[0] == "--bake-edges":
    bake_edges()
    views = views[1:]
if views and views[0] == "--bake-territory":
    bake_territory()
    views = views[1:]
if views and views[0] == "--bake-zone-land":
    bake_zone_land()
    views = views[1:]
for v in views:
    name, spec = v.split("=", 1)
    if spec.startswith("@"):
        where, z = spec[1:].rsplit(",", 1)
        pts = []
        for nm in where.split("+"):
            m = next(m for m in maps if m["name"] == nm)
            l, r, t, b = m["rect"]
            pts.append(((l + r) / 2, (t + b) / 2))
        u, vv, z = sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts), float(z)
    else:
        u, vv, z = map(float, spec.split(","))
    render(u, vv, z, os.path.join(outdir, name + ".png"))
