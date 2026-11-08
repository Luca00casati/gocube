# GoCube

Voxel sandbox in Godot 4 + GDScript, built to be modded from day one.

## Engine
Requires **Godot 4.7.2 with the [voxel module](https://github.com/Zylann/godot_voxel) v1.7
compiled in** (the `godot.linuxbsd.editor.x86_64` build from the module's
[v1.7 release](https://github.com/Zylann/godot_voxel/releases/tag/v1.7)); here it is
installed as `godot-voxel`. `godot-voxel -e` opens the editor. Stock Godot will fail to
parse scripts that use `Voxel*` classes. Everyone working on the project needs this
exact build.

The game opens on a world menu (play / host / create with optional seed / delete to
trash / join a game). In game, Esc opens the pause menu.

## Multiplayer
Pick a world and press **Host**; others press **Join a game…** and enter the address shown
at the top of the host's screen (UDP port 24680; open it in the host's firewall, or
forward it on the router for play over the internet). The host's machine runs the world
and saves it; joining players see what it streams to them.

- Everyone must have the **same mods** (ids and versions). Mods are never downloaded from
  the server — mod scripts are unsandboxed — so mismatched players are refused with a list.
- Block edits from joining players are requests: the host checks reach (16 blocks) and the
  block id, then applies them; the voxel module forwards changes to everyone nearby.
- Code: `src/net/session.gd` (handshake, positions, edit requests), `src/player/avatar.gd`,
  `World.build_remote()`, terrain sync via `VoxelTerrainMultiplayerSynchronizer`.

Launch options (after `--`): `--world=NAME` skip the menu and load or create that world,
`--host` (with `--world`) host it, `--join=ADDR` join a game, `--port=N`, `--name=NAME`,
`--seed=N` seed for a new world (random otherwise), `--view=N` view distance (default 128), `--shadows` /
`--cheap-shadows` (off by default: they cost ~40% FPS on integrated GPUs), `--bench`
(fly forward 20 s and print FPS stats), `--profile-startup` (time each startup step and list slow frames). Try `--rendering-method gl_compatibility` on old GPUs.

Controls: WASD walk, Space jump (and swim up in water), Ctrl sprint, Shift sneak, F toggle flying (Space/Shift
up/down; fly down onto the ground to land), mouse look, LMB break, RMB place (6-block
reach), 1-9 / mouse wheel pick block, Esc pause.

## Exporting
`export_presets.cfg` has a Linux preset using the voxel module's release template
(`godot.linuxbsd.template_release.x86_64` from the same v1.7 release). Its path is set
in `custom_template/release`; adjust it on another machine. Then:

    godot-voxel --headless --export-release "Linux" export/linux/gocube.x86_64

The preset includes `*.json` (mod manifests and content are not Godot resources, so
they'd be left out otherwise). Windows needs the module's Windows template the same way.

## Prototypes
Feasibility results for lighting, caves/trees/water and many creatures: see
[PROTOTYPES.md](PROTOTYPES.md).

## Layout
- `src/core/registry.gd` — autoload `Registry`: blocks, items, recipes (namespaced `mod:name` ids).
- `src/core/mod_loader.gd` — autoload `ModLoader`: finds, orders and loads mods.
- `src/world/` — `World` (terrain + save folder), `BlockLibrary` (registry → voxel models + texture atlas), native terrain generator (`VoxelGeneratorGraph`).
- `src/ui/world_menu.gd` — title screen / world select (the main scene).
- `src/player/player.gd` — the player: walking/jumping/flying physics, block break/place.
- `mods/core/` — the base game, written as an ordinary mod.
- `tools/gen_textures.py` — regenerates the core 32×32 block textures (`python3 tools/gen_textures.py`).

## Saving
Worlds live in `user://worlds/<name>/` (on Linux `~/.local/share/godot/app_userdata/GoCube/`):
`world.json` (seed, block id table, player position) and `blocks.sqlite` (only chunks
the player edited; the rest is regenerated from the seed). Saved on quit and every 60 s.

Voxels store numeric block ids, so each world keeps its own id table: adding mods appends
new ids, and blocks from a removed mod keep their slot (shown magenta) until it returns.

## Block textures
In a block definition: `"textures": {"all": "textures/stone.png"}` or per face
`{"top": ..., "side": ..., "bottom": ...}`. Paths are relative to the mod folder
(`"othermod:textures/x.png"` borrows another mod's file). Any square PNG works; it is
scaled to 32×32 and packed into a shared, mipmapped atlas at startup (textures should
tile seamlessly: the atlas pads each tile with repeats of itself to prevent mip bleeding). Blocks without textures
fall back to their `"color"`.

## Writing a mod
Create `user://mods/<id>/mod.json` (see the header of `mod_loader.gd`), add JSON
content files and/or an `entry` script with `init_mod(registry)`.

To distribute it as a pack: make a Godot project with the same engine build whose files
live under `mods/<id>/`, add an export preset with `include_filter="*.json"`, and run
`godot-voxel --headless --export-pack "<preset>" <id>.pck`. Players drop the `.pck` into
`user://mods/` (Linux: `~/.local/share/godot/app_userdata/GoCube/mods/`).

Mods are **not sandboxed**: only install mods you trust.

## Next steps
- Survival bits: health, fall damage, inventory, mining time per block (`hardness`).
- Caves/ores: add nodes to the graph in `graph_terrain_generator.gd` and extend the remap categories.
- Consider a double-precision build if worlds get large.
- Evaluate [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) if you
  want script hooks/extensions beyond this registry.

## License
GoCube is **source-available**: you may build it yourself and play your own build for free
(personal, non-commercial use); ready-made builds are distributed only by the author, who may
sell them. Redistributing builds or the source, and commercial use, need written permission.
Mods you make are yours. Full terms: [LICENSE.md](LICENSE.md).

Third-party components (Godot Engine, the voxel module, and libraries bundled in Godot) keep
their own licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Their texts ship with
the game (title screen → **Licenses**).

