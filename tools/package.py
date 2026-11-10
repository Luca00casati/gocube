#!/usr/bin/env python3
"""Builds GoCube for players: the official Godot next to the project folder,
and a launcher that starts the game (not the editor). No export templates, no
.pck: the game's files ship as they are (mods included).

    python3 tools/package.py OUT_DIR [--platform=linux|windows] [--godot=GODOT]

Without --godot, the official Godot for the platform is downloaded from
godotengine's GitHub releases (the version in GODOT_VERSION below, or
$GODOT_VERSION), checked against its published SHA-512 sums and kept in
~/.cache/gocube/godot/.

OUT_DIR/GoCube/
  gocube / GoCube.cmd   the launcher: starts the game; options pass through
                        (./gocube -- --world=MyWorld)
  godot / godot.exe     official Godot
  game/                 project.godot, src/, mods/, the licenses, the platform's
                        engine library, and what Godot needs from .godot/ to run
                        without importing

Godot's editor binary runs the game as a debug build, so the engine library
shipped is the debug one (bin/gocube.gdextension: <platform>.debug).
"""

import argparse
import hashlib
import os
import shutil
import stat
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GODOT_VERSION = os.environ.get("GODOT_VERSION", "4.7.2-stable")
PLATFORMS = ["linux", "windows"]
# Project folders and files players get (tests/, tools/, engine/ and the rest stay behind).
DIRS = ["src", "mods", "licenses"]
FILES = ["project.godot", "LICENSE.md", "THIRD_PARTY_NOTICES.md", "bin/gocube.gdextension",
         "bin/gocube.gdextension.uid"]
# The engine library each platform loads (see bin/gocube.gdextension).
LIBRARY = {
    "linux": "bin/libgocube.linux.template_debug.x86_64.so",
    "windows": "bin/libgocube.windows.template_debug.x86_64.dll",
}
# From .godot/: class names, the GDExtension list and resource uids (the import
# cache isn't needed: the game loads its textures and sounds raw).
GODOT_FILES = [".gdignore", "global_script_class_cache.cfg", "extension_list.cfg", "uid_cache.bin"]
GODOT_NAME = {"linux": "godot", "windows": "godot.exe"}
LAUNCHERS = {
    "linux": ("gocube", """#!/bin/sh
# Starts GoCube: Godot runs the game in ./game (not the editor).
# Options pass through, e.g. ./gocube -- --world=MyWorld --view=96
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/godot" --path "$here/game" "$@"
"""),
    "windows": ("GoCube.cmd", "@echo off\r\n"
                "rem Starts GoCube: Godot runs the game in .\\game (not the editor).\r\n"
                "rem Options pass through, e.g. GoCube.cmd -- --world=MyWorld\r\n"
                "start \"\" \"%~dp0godot.exe\" --path \"%~dp0game\" %*\r\n"),
}
RELEASES = "https://github.com/godotengine/godot/releases/download/{v}/"
# The official zip and the binary in it, per platform.
DOWNLOAD = {
    "linux": ("Godot_v{v}_linux.x86_64.zip", "Godot_v{v}_linux.x86_64"),
    "windows": ("Godot_v{v}_win64.exe.zip", "Godot_v{v}_win64.exe"),
}


class PackageError(Exception):
    pass


def published_sum(sums: str, file: str) -> str:
    """The SHA-512 published for `file` in a SHA512-SUMS.txt, or ""."""
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == file and len(parts[0]) == 128:
            return parts[0].lower()
    return ""


def sha512(path: Path) -> str:
    h = hashlib.sha512()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_godot(platform: str, version: str = GODOT_VERSION) -> Path:
    """The official Godot for `platform`: downloaded once, checked, unpacked."""
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "gocube" / "godot" / version / platform
    zip_name, exe_name = (n.format(v=version) for n in DOWNLOAD[platform])
    exe = cache / exe_name
    if exe.is_file():
        return exe
    cache.mkdir(parents=True, exist_ok=True)
    base = RELEASES.format(v=version)
    for name in ["SHA512-SUMS.txt", zip_name]:
        print("Downloading", base + name, flush=True)
        request = urllib.request.Request(base + name, headers={"User-Agent": "GoCube-packager"})
        try:
            with urllib.request.urlopen(request) as response, open(cache / name, "wb") as out:
                shutil.copyfileobj(response, out, 1 << 20)
        except OSError as e:
            raise PackageError(f"downloading {base + name} failed: {e}")
    expected = published_sum((cache / "SHA512-SUMS.txt").read_text(), zip_name)
    if not expected or sha512(cache / zip_name) != expected:
        (cache / zip_name).unlink()
        raise PackageError(f"{zip_name} doesn't match its published checksum")
    with zipfile.ZipFile(cache / zip_name) as z:
        exe.write_bytes(z.read(exe_name))
    exe.chmod(0o755)
    (cache / zip_name).unlink()
    print("Checked and unpacked", exe)
    return exe


def build(out_dir: Path, godot: Path, platform: str = "linux") -> Path:
    """Builds OUT_DIR/GoCube for `platform` with `godot` (that platform's Godot binary)."""
    if platform not in PLATFORMS:
        raise PackageError("unknown platform " + platform)
    dest = Path(out_dir) / "GoCube"
    game = dest / "game"
    if dest.exists():
        raise PackageError(f"{dest} already exists (remove it first)")
    if not Path(godot).is_file():
        raise PackageError(f"no Godot for {platform} at {godot}")
    files = FILES + [LIBRARY[platform]]
    for f in files:
        if not (ROOT / f).is_file():
            raise PackageError(f"missing {f} (build the engine for {platform} first: see README)")
    for f in GODOT_FILES:
        if not (ROOT / ".godot" / f).is_file():
            raise PackageError(f"missing .godot/{f} (open or import the project once)")
    for d in DIRS:
        shutil.copytree(ROOT / d, game / d)
    for f in files:
        (game / f).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / f, game / f)
    (game / ".godot").mkdir()
    for f in GODOT_FILES:
        shutil.copy2(ROOT / ".godot" / f, game / ".godot" / f)
    shutil.copy2(godot, dest / GODOT_NAME[platform])
    name, text = LAUNCHERS[platform]
    (dest / name).write_bytes(text.encode())  # as written: LF for sh, CRLF for cmd
    if platform == "linux":  # executables (Windows goes by file extension)
        for exe in [dest / "godot", dest / "gocube", game / LIBRARY["linux"]]:
            exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return dest


def main() -> int:
    parser = argparse.ArgumentParser(description="Package GoCube with the official Godot.")
    parser.add_argument("out_dir", type=Path)
    parser.add_argument("--platform", choices=PLATFORMS, default="linux")
    parser.add_argument("--godot", type=Path, help="that platform's Godot binary (default: download it)")
    args = parser.parse_args()
    try:
        godot = args.godot or fetch_godot(args.platform)
        dest = build(args.out_dir, godot, args.platform)
    except PackageError as e:
        print("Packaging failed:", e, file=sys.stderr)
        return 1
    print(f"Packaged GoCube for {args.platform} in {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
