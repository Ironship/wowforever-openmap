# Builds OpenMap's dungeon and raid maps: Blizzard's own maps of the instances (the classic
# world map layout, 4 x 3 tiles of 256 px, ~1002 x 668 of it the picture), whose art WoW
# Forever ships but doesn't wire to C_Map (its UiMap table has no dungeons).
#   OpenMap/Data/DungeonMaps.lua   per instance: its floors' tile file IDs, names and wings
# Which art is which instance's, its floors and their names come from the UiMap tables of
# Mists of Pandaria Classic (TABLES), whose maps of the classic instances are the ones the
# Forever client has the files for; the wings from retail's journal (JournalInstance,
# JournalEncounter: which wing's bosses are on which floor). Every tile is read from the
# Forever install (tools/casc); a floor is kept only when all 12 are there, and not when its
# picture is another floor's (Dire Maul's one-level map is its Gordok Commons floor again).
# The instances are Places.lua's (tools/map-data/build.py). WoW Forever's own new dungeons
# have no UiMap anywhere; the script looks for art folders named after them in the listfile
# and says what it finds.
#
# usage: python -P tools/map-dungeons/build.py <cache dir> <World of Warcraft folder> [preview dir]
#   (tables and the listfile are fetched from wago.tools into the cache; preview dir: one
#   PNG per floor, and per unlisted floor found beside them, to look at)
import csv, io, json, os, re, sys, time, urllib.request
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
sys.path.insert(0, os.path.join(ROOT, "tools", "casc"))
from casc import Casc

if len(sys.argv) < 3:
    sys.exit("usage: python -P tools/map-dungeons/build.py <cache dir> <World of Warcraft folder> [preview dir]")
cache, wow = sys.argv[1], sys.argv[2]
preview = sys.argv[3] if len(sys.argv) > 3 else None
os.makedirs(cache, exist_ok=True)
TABLES = "5.5.4.70268"          # Mists of Pandaria Classic
RETAIL = "12.1.5.70391"
UA = {"User-Agent": "openmap-tools/1"}


def get(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 50:
        return path
    for attempt in range(3):
        try:
            print("  fetching", url, flush=True)
            data = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60).read()
            open(path, "wb").write(data)
            time.sleep(0.3)
            return path
        except Exception as e:
            print("  failed:", e, flush=True)
            time.sleep(2)
    sys.exit("couldn't fetch " + url)


def table(name, build):
    p = get("https://wago.tools/db2/%s/csv?build=%s" % (name, build), os.path.join(cache, "%s-%s.csv" % (name, build)))
    return list(csv.DictReader(open(p, encoding="utf-8")))


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def squash(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


# ------------------------------------------------------------------ the instances (Places.lua)
places = open(os.path.join(ROOT, "OpenMap", "Data", "Places.lua"), encoding="utf-8").read()
places = places[places.index("instances = {"):places.index("bosses = {")]
instances = []                  # (mapID, name), in Places' order, a wing each
for mid, name in re.findall(r'\{ (\d+), "((?:[^"\\]|\\.)*)", (?:true|false)', places):
    if (int(mid), name) not in instances:
        instances.append((int(mid), name))
print("instances:", len(instances), flush=True)

# ------------------------------------------------------------------ the tables
print("tables", flush=True)
uimap = {r["ID"]: r for r in table("UiMap", TABLES)}
art_of = {}
for r in table("UiMapXMapArt", TABLES):
    if r["PhaseID"] == "0":
        art_of.setdefault(r["UiMapID"], r["UiMapArtID"])
tiles_of = {}
for r in table("UiMapArtTile", TABLES):
    if r["LayerIndex"] == "0":
        tiles_of.setdefault(r["UiMapArtID"], {})[(int(r["RowIndex"]), int(r["ColIndex"]))] = int(r["FileDataID"])
group = {r["UiMapID"]: r for r in table("UiMapGroupMember", TABLES)}
uimaps_of = {}
for r in table("UiMapAssignment", TABLES):
    uimaps_of.setdefault(int(r["MapID"]), set()).add(r["UiMapID"])
# wings: which of retail's journal instances (a wing each) has its bosses on which floor
jinst = {r["ID"]: r for r in table("JournalInstance", RETAIL)}
wings_on = {}                   # uiMapID -> {journal instance name}
journals_of = {}                # mapID -> {journal instance name}
for r in table("JournalEncounter", RETAIL):
    ji = jinst.get(r["JournalInstanceID"])
    if not ji: continue
    journals_of.setdefault(int(ji["MapID"]), set()).add(ji["Name_lang"])
    if r["UiMapID"] not in ("", "0"):
        wings_on.setdefault(r["UiMapID"], set()).add(ji["Name_lang"])
# Forever's group finder names Dire Maul's wings by side, the journal by quarter: the same
# wings (LFGDungeons 33/35/37 in Forever's tables, 34/36/38 in later ones, each wing's
# own last boss: Alzzin the Wildshaper, Prince Tortheldrin, King Gordok)
WING_NAMES = {"Dire Maul - Warpwood Quarter": "Dire Maul - East", "Dire Maul - Capital Gardens": "Dire Maul - West",
              "Dire Maul - Gordok Commons": "Dire Maul - North"}

# ------------------------------------------------------------------ the listfile (paths, other floors)
print("listfile", flush=True)
listfile = json.load(open(get("https://wago.tools/api/files?search=interface/worldmap/",
                              os.path.join(cache, "listfile-worldmap.json")), encoding="utf-8"))
path_of = {int(f): p for f, p in listfile.items()}


def parse(p):
    """a tile's path -> (folder, file prefix, floor ("" for a one-level map), tile n), or None"""
    m = re.match(r"interface/worldmap/([^/]+)/(.*?)(\d+)_(\d+)\.blp$", p) \
        or re.match(r"interface/worldmap/([^/]+)/(.*?[a-z_])()(\d+)\.blp$", p)
    return (m.group(1), m.group(2), m.group(3), int(m.group(4))) if m else None


by_folder = {}                  # folder -> {(file prefix, floor): {tile n: fid}}
for f, p in path_of.items():
    t = parse(p)
    if t and 1 <= t[3] <= 12:
        by_folder.setdefault(t[0], {}).setdefault((t[1], t[2]), {})[t[3]] = f

# ------------------------------------------------------------------ the install
print("install", flush=True)
casc = Casc(wow, "wow_classic_beta")


def tile(fid):
    """the tile's file, if it's in the install and a 256 px BLP"""
    try:
        d = casc.read(fid)
    except Exception:
        return None
    return d if d[:4] == b"BLP2" and d[12:20] == (256).to_bytes(4, "little") * 2 else None


def picture(fids):
    im = Image.new("RGBA", (1024, 768))
    for i, f in enumerate(fids):
        try:
            t = Image.open(io.BytesIO(casc.read(f))).convert("RGBA")
        except Exception:
            continue
        im.paste(t, ((i % 4) * 256, (i // 4) * 256))
    return im


def folder_floor(fid):
    """'folder/prefix<floor>' of a tile, from the listfile"""
    t = parse(path_of.get(fid, ""))
    return "%s/%s%s" % t[:3] if t else "?"


# Floors in an instance's folder that no UiMap points at, kept by hand: [mapID] = [(folder,
# file prefix, floor, wing)]. Blackrock Spire's 7th floor is titled "Blackrock Spire" and
# names Upper Blackrock Spire's rooms (Blackrock Stadium, Spire Throne, Blackwing's Gate);
# the tables' six floors hold only Lower Blackrock Spire's bosses (retail's journal).
EXTRA = {229: [("blackrockspire", "blackrockspire", "7", "Upper Blackrock Spire")]}

# ------------------------------------------------------------------ per instance, its floors
out = {}                        # key -> [floor]
report = []
used_floors = set()             # (folder, prefix, floor) the tables use
wings_listed = {}               # mapID -> Places' wings at it
for mid, name in instances:
    wings_listed.setdefault(mid, []).append(name)
for mid, name in instances:
    if mid in out or (mid == 0 and name in out):
        continue
    floors = []
    for u in uimaps_of.get(mid, ()) if mid else ():     # (0: not in the tables)
        um = uimap.get(u)
        if not um or u not in art_of: continue
        t = tiles_of.get(art_of[u], {})
        if sorted(t) != [(r, c) for r in range(3) for c in range(4)]:
            report.append("  %s: UiMap %s's art isn't 4 x 3 tiles: skipped" % (name, u))
            continue
        fids = [t[(r, c)] for r in range(3) for c in range(4)]
        g = group.get(u)
        floors.append({"ui": int(u), "fids": fids, "name": g["Name_lang"] if g else None,
                       "order": (int(g["FloorIndex"]) if g else 99, int(u)), "wings": wings_on.get(u, set())})
        t = parse(path_of.get(fids[0], ""))
        if t: used_floors.add(t[:3])
    floors.sort(key=lambda f: f["order"])          # (a one-level map after the floors: they have names)
    for folder, prefix, fl, wing in EXTRA.get(mid, ()):
        tiles = by_folder.get(folder, {}).get((prefix, fl), {})
        if len(tiles) == 12:
            floors.append({"ui": 0, "fids": [tiles[n] for n in range(1, 13)], "name": None, "wings": {wing}})
            used_floors.add((folder, prefix, fl))
    kept, seen = [], {}
    # a floor's wing: when the instance has wings (Places') or the journal splits it
    split = len(wings_listed.get(mid, ())) > 1 or len(journals_of.get(mid, ())) > 1
    for f in floors:
        data = [tile(x) for x in f["fids"]]
        status = "complete" if all(data) else "%d/12" % sum(1 for d in data if d)
        wing = None
        if split and len(f["wings"]) == 1:
            wing = next(iter(f["wings"]))
            wing = WING_NAMES.get(wing, wing)
        f["wing"] = wing
        same = seen.get(tuple(data)) if all(data) else None
        if same:
            status += ", the same picture as UiMap %d: left out" % same["ui"]
        report.append("  %-22s UiMap %-4s %-34s %-26s %s%s" % (name[:22], f["ui"] or "-", folder_floor(f["fids"][0]),
                      f["name"] or "-", status, ("  wing: " + wing) if wing else ""))
        if all(data) and not same:
            kept.append(f)
            seen[tuple(data)] = f
    if not floors:
        hits = [fo for fo in by_folder if squash(name).replace("the", "") in fo.replace("the", "")]
        report.append("  %-22s no UiMap in the tables; listfile folders named after it: %s" % (name[:22], ", ".join(hits) or "none"))
    if kept:
        out[mid or name] = kept
        # Places' name; for one with wings, the UiMap's (the instance's, not a wing's)
        title = name if len(wings_listed[mid]) == 1 else uimap[str(floors[0]["ui"])]["Name_lang"]
        out[mid or name][0]["title"] = title

# floors beside the used ones that no table points at
unlisted = []
for folder in sorted({u[0] for u in used_floors}):
    for (prefix, floor), tiles in sorted(by_folder[folder].items()):
        if (folder, prefix, floor) in used_floors or len(tiles) != 12: continue
        fids = [tiles[n] for n in range(1, 13)]
        unlisted.append((folder, prefix, floor, fids, all(tile(x) for x in fids)))

# ------------------------------------------------------------------ write
lines = [
    "-- Dungeon and raid maps: Blizzard's own map of each instance, a picture per floor (the classic",
    "-- world map layout: 4 x 3 tiles of 256 px, the picture ~1002 x 668 of its 1024 x 768).",
    "--   [instance mapID] = { { tiles = { 12 file IDs, row-major }, name = the floor's name (nil: the",
    "--     tables give none), wing = the wing whose bosses are on it (nil: one wing, or not said) }, ... }",
    "-- Generated by tools/map-dungeons/build.py from the UiMap tables of build %s, retail's journal" % TABLES,
    "-- (%s, the wings) and the WoW Forever install's files; regenerate rather than edit." % RETAIL,
    "",
    "local _, ns = ...",
    "",
    "ns.MapDungeonMaps = {",
]
for key in sorted(out, key=lambda k: (isinstance(k, str), k)):
    floors = out[key]
    lines.append("\t[%s] = { -- %s" % (key if isinstance(key, int) else lua_str(key), floors[0]["title"]))
    for f in floors:
        extra = ""
        if f["name"]: extra += ", name = " + lua_str(f["name"])
        if f["wing"]: extra += ", wing = " + lua_str(f["wing"])
        lines.append("\t\t{ tiles = { %s }%s }," % (", ".join(str(x) for x in f["fids"]), extra))
    lines.append("\t},")
lines.append("}")
with open(os.path.join(ROOT, "OpenMap", "Data", "DungeonMaps.lua"), "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(lines) + "\n")

print("\nfloors (UiMap, art, name, tiles in the install):")
print("\n".join(report))
print("\nfloors in the same folders that no table points at:")
for folder, prefix, floor, fids, ok in unlisted:
    print("  %s/%s%s: %d.. %s" % (folder, prefix, floor, fids[0], "complete" if ok else "not all in the install"))
print("\nwrote OpenMap/Data/DungeonMaps.lua:", len(out), "instances,", sum(len(v) for v in out.values()), "floors")

if preview:
    os.makedirs(preview, exist_ok=True)
    for key, floors in out.items():
        for i, f in enumerate(floors, 1):
            n = "%s-%d-%s.png" % (squash(floors[0]["title"]), i, squash(f["name"] or "") or "floor")
            picture(f["fids"]).save(os.path.join(preview, n))
    for folder, prefix, floor, fids, ok in unlisted:
        if ok:
            picture(fids).save(os.path.join(preview, "unlisted-%s-%s%s.png" % (folder, prefix, floor)))
    print("previews in", preview)
