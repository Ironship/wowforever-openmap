# Renders a player's report code (from the in-game "Report a problem" button) out of game:
# the same place and zoom with what they drew (in its ink), or, from a dungeon's map, that floor's
# picture with their lines, for triage. The code's format: OpenMap/Map/Report.lua's header.
# usage: python -P tools/map-preview/report.py <db2 dir> <texture cache> <out.png> "OM1|..."
import math, os, re, sys
from PIL import Image, ImageDraw

db2, cache, out, code = sys.argv[1:5]
parts = code.strip().split("|", 7)
if len(parts) < 8 or parts[0] != "OM1":
    sys.exit("not an OpenMap report code (expected OM1|...)")
_, version, mapid, u, v, zoom, marks, note = parts
u, v, zoom = float(u), float(v), float(zoom)
print("version %s, map %s, zoom %.1f, note: %s" % (version, mapid, zoom, note))

# the marks: circles (u:v:r), world drawings (d...), a dungeon (g...) and its floors' lines (f...)
circles, drawings, dungeon, floor_lines = [], [], None, []
for m in filter(None, marks.split(";")):
    if m[0] == "d" and ":" in m:
        head, pts = m.split(":", 1)
        nums = [int(x) / 100000.0 for x in pts.split(",") if x]
        drawings.append((head[1], int(head[2]), int(head[3]) if len(head) > 3 else 2, nums))
    elif m[0] == "g":
        dungeon = int(m[1:])
    elif m[0] == "f" and ":" in m:
        head, pts = m.split(":", 1)
        floor_lines.append((int(head[1:]), [int(x) / 10000.0 for x in pts.split(",") if x]))
    else:
        try:
            cu, cv, r = map(float, m.split(":"))
            circles.append((cu, cv, r))
        except ValueError:
            pass

# Sketch.lua's inks and nibs (px on screen)
INKS = [(26, 20, 15), (235, 46, 36), (56, 128, 255), (61, 209, 82), (255, 204, 41), (255, 255, 255)]
NIBS = [2, 3.5, 6]
RED = (220, 40, 25)

here = os.path.dirname(os.path.abspath(__file__))
sys.argv = ["render.py", db2, cache, os.path.dirname(os.path.abspath(out)) or "."]
g = {"__name__": "report", "__file__": os.path.join(here, "render.py")}
src = open(os.path.join(here, "render.py"), encoding="utf-8").read()
exec(compile(src[:src.index("views = sys.argv[4:]")], "render", "exec"), g)

if dungeon is not None:
    # the floors of that dungeon (Data/DungeonMaps.lua), each with its lines
    data = open(os.path.join(here, "..", "..", "OpenMap", "Data", "DungeonMaps.lua"), encoding="utf-8").read()
    block = re.search(r"\[%d\] = \{.*?\n(.*?)\n\t\},\n" % dungeon, data, re.S)
    floors = re.findall(r"tiles = \{ ([\d, ]+) \}", block.group(1)) if block else []
    shown = sorted({f for f, _ in floor_lines}) or [1]
    sheets = []
    for f in shown:
        im = Image.new("RGB", (1002, 668), (40, 32, 24))
        if f <= len(floors):
            for i, fid in enumerate(int(x) for x in floors[f - 1].split(",")):
                t = g["fetch"](fid)
                if t: im.paste(t.convert("RGB"), ((i % 4) * 256, (i // 4) * 256))
        d = ImageDraw.Draw(im)
        for lf, pts in floor_lines:
            if lf == f and len(pts) >= 4:
                d.line([(pts[k] * 1002, pts[k + 1] * 668) for k in range(0, len(pts) - 1, 2)], fill=RED, width=4, joint="curve")
        d.rectangle([0, 644, 1002, 668], fill=(0, 0, 0))
        d.text((8, 650), ("OpenMap %s  dungeon %d floor %d   %s" % (version, dungeon, f, note))[:180], fill=(255, 220, 120))
        sheets.append(im)
    im = Image.new("RGB", (1002, 668 * len(sheets)))
    for i, s in enumerate(sheets): im.paste(s, (0, 668 * i))
    im.save(out)
    print("wrote", out)
    sys.exit()

g["render"](u, v, zoom, out)
im = Image.open(out).convert("RGB")
d = ImageDraw.Draw(im)
OW, OH = im.size
px = min(OW / 1002.0, OH / 668.0) * zoom
def at(pu, pv): return (pu - u) * 1002 * px + OW / 2, (pv - v) * 668 * px + OH / 2

if not drawings:                                # (an older code: its circles are what was drawn)
    for cu, cv, r in circles:
        x, y = at(cu, cv)
        rx, ry = r * 1002 * px, r * 1.5 * 668 * px
        d.ellipse([x - rx, y - ry, x + rx, y + ry], outline=RED, width=4)
for tool, ink, nib, pts in drawings:
    colour = INKS[ink - 1] if tool != "m" and 1 <= ink <= len(INKS) else RED
    width = max(2, int(round(NIBS[min(max(nib, 1), 3) - 1] * 1.5)))
    if tool == "m" and len(pts) >= 2:           # a raid mark: a ring with its number
        x, y = at(pts[0], pts[1])
        d.ellipse([x - 10, y - 10, x + 10, y + 10], outline=RED, width=3)
        d.text((x - 3, y - 6), str(ink), fill=RED)
        continue
    if len(pts) < 4: continue
    if tool == "r":                             # a ring: round on the screen, the drag its radius
        x, y = at(pts[0], pts[1])
        x1, y1 = at(pts[2], pts[3])
        r = math.hypot(x1 - x, y1 - y)
        d.ellipse([x - r, y - r, x + r, y + r], outline=colour, width=width)
        continue
    xy = [at(pts[k], pts[k + 1]) for k in range(0, len(pts) - 1, 2)]
    if tool in ("l", "a"): xy = [xy[0], xy[-1]]
    d.line(xy, fill=colour, width=width, joint="curve")
    if tool == "a":                             # its head
        (x0, y0), (x1, y1) = xy
        ang, head = math.atan2(y1 - y0, x1 - x0), min(math.hypot(x1 - x0, y1 - y0) * 0.3, 24)
        for s in (0.45, -0.45):
            d.line([(x1, y1), (x1 - math.cos(ang + s) * head, y1 - math.sin(ang + s) * head)], fill=colour, width=width)
d.rectangle([0, OH - 24, OW, OH], fill=(0, 0, 0))
d.text((8, OH - 18), ("OpenMap %s  map %s  zoom %.1f   %s" % (version, mapid, zoom, note))[:180], fill=(255, 220, 120))
im.save(out)
print("wrote", out)
