"""Static checks the offline run can't do: a local function called before the
line that defines it (and with no forward `local name` above the call), and a
file-level local (a table, a value) used above the line that declares it.

The stub answers any unknown global with a callable placeholder, so in the
offline run such a call silently "works"; in game the name is a nil global and
the call errors (e.g. a module's OnEnable failing at login).

    python tools/offline-test/lint.py        (exit code 1 when anything is found)
"""
import glob
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "OpenMap")

NAME = r"[A-Za-z_][A-Za-z0-9_]*"


def strip(line):
    # drop comments and string literals (enough for these files)
    line = re.sub(r'"(\\.|[^"\\])*"', '""', line)
    line = re.sub(r"'(\\.|[^'\\])*'", "''", line)
    return line.split("--")[0]


def check(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    defined, forward, params = {}, {}, set()
    for i, raw in enumerate(lines, 1):
        line = strip(raw)
        m = re.match(r"\s*local function (" + NAME + r")", line)
        if m:
            defined.setdefault(m.group(1), i)
        m = re.match(r"\s*local (" + NAME + r"(?:\s*,\s*" + NAME + r")*)\s*$", line)
        if m:
            for n in re.split(r"\s*,\s*", m.group(1)):
                forward.setdefault(n, i)
        for m in re.finditer(r"function\s*[\w.:]*\s*\(([^)]*)\)", line):
            for p in re.split(r"\s*,\s*", m.group(1)):
                if re.fullmatch(NAME, p):
                    params.add(p)
    found = []
    for name, at in defined.items():
        if name in params:
            continue
        fwd = forward.get(name)
        for i, raw in enumerate(lines[: at - 1], 1):
            line = strip(raw)
            if re.match(r"\s*local function", line):
                continue
            # called (name(...)) or handed on as a value (Try(name, ...), x = name)
            if (re.search(r"(?<![\w.:])" + re.escape(name) + r"\s*\(", line)
                    or re.search(r"[(,=]\s*" + re.escape(name) + r"\s*[,)]", line)
                    or re.search(r"=\s*" + re.escape(name) + r"\s*$", line)):
                if fwd and fwd < i:
                    break
                # a same-named local declared above (another variable, not the function)
                if any(re.match(r"\s*local\b[^=]*\b" + re.escape(name) + r"\b", strip(prev))
                       and not re.match(r"\s*local function", strip(prev)) for prev in lines[: i]):
                    break
                found.append(f"{os.path.relpath(path, ROOT)}:{i}: {name}() called before its local definition (line {at})")
                break
    return found


def check_values(path):
    """file-level `local name = ...` used on an earlier line: there it's a nil global"""
    lines = [strip(l) for l in open(path, encoding="utf-8").read().split("\n")]
    found = []
    for at, line in enumerate(lines, 1):
        m = re.match(r"local (" + NAME + r"(?:\s*,\s*" + NAME + r")*)\s*=", line)
        if not m:
            continue
        for name in re.split(r"\s*,\s*", m.group(1)):
            n = re.escape(name)
            pat = re.compile(r"(?<![\w.:])" + n + r"\b(?!\s*=[^=])")
            declared = re.compile(r"\blocal\b[^=]*\b" + n + r"\b|function\s*[\w.:]*\s*\([^)]*\b" + n + r"\b|\bfor\s+[\w\s,]*\b" + n + r"\b[\w\s,]*(?:=|\bin\b)")
            for i, prev in enumerate(lines[: at - 1], 1):
                if declared.search(prev):
                    break
                if pat.search(prev):
                    found.append(f"{os.path.relpath(path, ROOT)}:{i}: {name} used before its file-level local (line {at})")
                    break
    return found


def check_escapes(path):
    """a single backslash in a string (a texture path written with one): Lua 5.1 drops it
    silently, so the path is wrong and the texture just doesn't show"""
    found = []
    for i, line in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        code = line.split("--")[0]
        for m in re.finditer(r'"((?:\\.|[^"\\])*)"', code):
            for e in re.finditer(r"\\(.)", m.group(1)):
                if e.group(1) not in "abfnrtv\\\"'0123456789":
                    found.append(f"{os.path.relpath(path, ROOT)}:{i}: \\{e.group(1)} in a string (a path needs two backslashes)")
            # a decimal escape: fine in a byte pattern ("[\128-\191]"), but in a path ("Map\947") it's
            # a wrong byte, or (past 255) a load error that takes the whole file down
            for e in re.finditer(r"\\(\d{1,3}|.)", m.group(1)):     # (each escape in turn: "\\9" is a backslash, then 9)
                if e.group(1).isdigit() and (int(e.group(1)) > 255 or "[" not in m.group(1)):
                    found.append(f"{os.path.relpath(path, ROOT)}:{i}: \\{e.group(1)} in a string (a path needs two backslashes)")
    return found


def check_truncation(path):
    """`local a, b = x and f()`: Lua keeps only f's first value (b is nil). Write
    `local a, b; if x then a, b = f() end` instead"""
    found = []
    pat = re.compile(r"^\s*(?:local\s+)?[A-Za-z_]\w*\s*,[^=]*=\s*[^,]*\band\s+[\w.:]+\([^,]*\)\s*$")
    for i, line in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        code = strip(line)
        if pat.match(code) and " or " not in code:
            found.append(f"{os.path.relpath(path, ROOT)}:{i}: several values from `x and f()`: Lua keeps only the first")
    return found


# Blizzard's API functions the addon calls by bare name. A call to any other capitalised
# name must be defined in its file: one that isn't (a function deleted or never written)
# is a nil global in game, which the offline stub hides. Using a new API: add it here.
WOW_API = {
    "CreateFrame", "CreateFromMixins", "CreateVector2D", "Clamp", "HideUIPanel", "ShowUIPanel",
    "LibStub", "GetTime", "GetCursorPosition", "InCombatLockdown", "IsControlKeyDown", "IsShiftKeyDown",
    "StaticPopup_Show", "StaticPopup_Hide", "UnitClass", "UnitExists", "UnitIsUnit", "UnitFactionGroup", "UnitOnTaxi",
    "IsInGroup", "IsInRaid", "GetNumRoutes", "NumTaxiNodes", "TaxiNodeGetType", "TaxiNodeName",
    "GetAddOnMemoryUsage", "UpdateAddOnMemoryUsage", "UnitLevel", "GetQuestDifficultyColor", "GetCVar",
    "debugprofilestop", "GetFramerate", "IsAddOnLoaded", "GetUnitSpeed", "IsModifiedClick", "GetPhysicalScreenSize", "IsMouseButtonDown",
    "IsInGuild", "UnitIsPlayer", "GetUnitName", "UnitName", "Ambiguate", "ToggleWorldMap",
    "UnitRace", "GetLocale", "PlaySound",
}


def check_calls(path):
    text = open(path, encoding="utf-8").read()
    lines = [strip(l) for l in text.split("\n")]
    code = "\n".join(lines)
    defined = set(re.findall(r"local function (" + NAME + r")", code))
    for decl in re.findall(r"^\s*local (" + NAME + r"(?:\s*,\s*" + NAME + r")*)\s*(?:=|$)", code, re.M):
        defined |= {n.strip() for n in decl.split(",")}
    for params in re.findall(r"function[^(]*\(([^)]*)\)", code):
        defined |= {n.strip() for n in params.split(",")}
    for names in re.findall(r"for\s+([\w\s,]+?)\s+in\b", code):
        defined |= {n.strip() for n in names.split(",")}
    found = []
    for i, line in enumerate(lines, 1):
        for m in re.finditer(r"(?<![\w.:])([A-Z]\w*)\s*\(", line):
            name = m.group(1)
            if name not in defined and name not in WOW_API:
                found.append(f"{os.path.relpath(path, ROOT)}:{i}: {name}() isn't defined in this file (nor a known WoW API)")
    return found


# OpenMap's shared helpers are locals each file declares (`local Safe = ns.Safe`);
# used without that line they are nil globals in game (the stub hides it)
SHARED = ["Safe", "Look", "Fader", "Movers", "Glow", "Alerts"]


def check_shared(path):
    text = open(path, encoding="utf-8").read()
    found = []
    for name in SHARED:
        if not re.search(r"(?<![\w.:])" + name + r"\s*[.:]\s*[A-Za-z_]", "\n".join(strip(l) for l in text.split("\n"))):
            continue
        if re.search(r"^\s*local\s+(?:[\w\s,]*\b)?" + name + r"\b", text, re.M):
            continue
        if re.search(r"^\s*" + name + r"\s*=", text, re.M):
            continue
        found.append(f"{os.path.relpath(path, ROOT)}: uses {name} without `local {name} = ns.{name}`")
    return found


problems = []
for path in sorted(glob.glob(os.path.join(ROOT, "*.lua")) + glob.glob(os.path.join(ROOT, "Map", "*.lua"))):
    problems += check(path)
    problems += check_values(path)
    problems += check_escapes(path)
    problems += check_calls(path)
    problems += check_truncation(path)
    problems += check_shared(path)
# the "What's new" window's notes (Data/Changelog.lua) are made from CHANGELOG.md: they must agree,
# or a release ships last version's notes
sys.path.insert(0, os.path.join(ROOT, "..", "tools", "changelog"))
import build as changelog
_have = os.path.join(ROOT, "Data", "Changelog.lua")
if not os.path.exists(_have) or open(_have, encoding="utf-8").read() != changelog.build():
    problems.append("Data/Changelog.lua is out of date with CHANGELOG.md: run python -P tools/changelog/build.py")
for p in problems:
    print(p)
print(f"lint: {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
