#!/usr/bin/env python3
"""Distill Discord's public detectable-games database into a compact catalog
Rewind bundles for game detection.

Output: Resources/games.tsv  (lines of `executable-basename<TAB>Game Name`)

Only native macOS (darwin) executables are kept, and only unambiguous
basenames — any basename used by two or more different games is dropped, along
with a blocklist of generic runtimes — so a process match maps to exactly one
game with no false positives.
"""
import json
import os
import sys
import urllib.request

SOURCE = "https://discord.com/api/v9/applications/detectable"

# Generic runtime/launcher names to never match on, even if they happen to be
# unique in the data.
RUNTIME_BLOCKLIST = {
    "java", "javaw", "javaw.exe", "java.exe", "mono", "mono.exe",
    "python", "python.exe", "python3", "pythonw.exe", "node", "node.exe",
    "electron", "electron.exe", "love", "love.exe", "nw", "nw.exe",
    "wine", "wine64", "wineloader", "dosbox", "dosbox.exe", "scummvm",
    "retroarch", "game", "game.exe", "launcher", "launcher.exe",
    "client", "client.exe", "start", "start.exe", "play", "play.exe",
    "autorun", "autorun.exe", "engine", "engine.exe", "main", "main.exe",
    "app", "app.exe", "hl2.exe", "srcds.exe", "fm.exe",
}


def basenames(raw: str):
    """Candidate lookup keys for a Discord executable name."""
    name = raw.lstrip(">").replace("\\", "/").split("/")[-1].strip().lower()
    if not name:
        return []
    keys = {name}
    if name.endswith(".app"):
        keys.add(name[:-4])
    return list(keys)


def main():
    print(f"fetching {SOURCE} ...", file=sys.stderr)
    req = urllib.request.Request(SOURCE, headers={"User-Agent": "Mozilla/5.0 (Macintosh)"})
    with urllib.request.urlopen(req) as resp:
        games = json.load(resp)
    print(f"  {len(games)} games", file=sys.stderr)

    owners = {}  # basename -> set of game names
    for game in games:
        name = (game.get("name") or "").strip()
        if not name:
            continue
        for exe in game.get("executables") or []:
            if exe.get("os") != "darwin":
                continue
            for key in basenames(exe.get("name") or ""):
                if key in RUNTIME_BLOCKLIST:
                    continue
                owners.setdefault(key, set()).add(name)

    catalog = {k: next(iter(v)) for k, v in owners.items() if len(v) == 1}

    out_dir = os.path.join(os.path.dirname(__file__), "..", "Resources")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "games.tsv")
    with open(out_path, "w", encoding="utf-8") as f:
        for key in sorted(catalog):
            name = catalog[key].replace("\t", " ").replace("\n", " ")
            f.write(f"{key}\t{name}\n")

    dropped = len(owners) - len(catalog)
    print(f"wrote {len(catalog)} entries to {out_path} "
          f"(dropped {dropped} ambiguous basenames)", file=sys.stderr)


if __name__ == "__main__":
    main()
