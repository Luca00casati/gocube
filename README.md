# GoCube

Voxel sandbox in Godot 4 + GDScript, built to be modded from day one.

## Engine
Runs on **stock Godot 4.5+** (developed on 4.7.2). The voxel engine is GoCube's own C++
GDExtension in `engine/` (chunk storage, generation, meshing, light, collision, saving),
built against [godot-cpp](https://github.com/godotengine/godot-cpp) (a submodule pinned
to `godot-4.5-stable`). Build it once after cloning, and after changing `engine/src/`:

    git submodule update --init
    cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release
    cmake --build engine/build -j4        # -> bin/libgocube.linux.template_debug.x86_64.so

Then `godot4 -e --path .` opens the editor (Linux only so far: other platforms need their
library entries in `bin/gocube.gdextension`).

The game opens on a world menu (play / host / create with optional seed / delete to
trash / join a game). In game, Esc opens the pause menu.

## Multiplayer
Pick a world and press **Host**; others press **Join a game…** and enter the address shown
at the top of the host's screen (UDP port 24680; open it in the host's firewall, or
forward it on the router for play over the internet). The host's machine runs the world
and saves it. World generation is deterministic, so joining players generate the
terrain themselves from the seed; only edits travel over the network.

- Everyone must have the **same mods** (ids and versions). Mods are never downloaded from
  the server — mod scripts are unsandboxed — so mismatched players are refused with a list.
- On join the host sends the seed, its block id table and every edited chunk; after
  that each edit is sent as (position, block). A player who hasn't loaded that chunk
  asks the host for the whole chunk.
- Block edits from joining players are requests: the host checks reach (16 blocks), the
  block id and that nobody is inside the block, then applies them.
- Code: `src/net/session.gd` (handshake, positions, edits), `src/player/avatar.gd`,
  `World.build_remote()`.

Launch options (after `--`): `--world=NAME` skip the menu and load or create that world,
`--host` (with `--world`) host it, `--join=ADDR` join a game, `--port=N`, `--name=NAME`,
`--seed=N` seed for a new world (random otherwise), `--time=0..1` time of day (0 midnight,
0.25 sunrise, 0.5 noon, 0.75 sunset), `--day-length=SECONDS` (default 86400: real time), `--view=N` view distance (default 128), `--shadows` /
`--cheap-shadows` (off by default: they cost ~40% FPS on integrated GPUs), `--bench`
(fly forward 20 s and print FPS stats), `--profile-startup` (time each startup step and list slow frames). Try `--rendering-method gl_compatibility` on old GPUs.

Controls: WASD walk, Space jump (and swim up in water), Ctrl sprint, Shift sneak, F toggle flying (Space/Shift
up/down; fly down onto the ground to land), mouse look, hold LMB mine / LMB break (creative),
RMB place (6-block reach), 1-9 / mouse wheel pick a hotbar slot, E inventory and crafting,
Esc pause. Launch option `--mode=creative|survival` for new worlds. All keyboard keys can be
rebound in **Settings…** (title screen or pause menu), along with view distance, mouse
sensitivity, frame rate limit, vsync and **smooth lighting** (light blended at block corners
with soft corner shading, instead of the classic flat look). Settings are saved in
`user://settings.cfg`.

## Survival and creative
New worlds are **survival** by default (chosen in the New world dialog): hold left click to
mine (time = the block's `hardness` × 0.75 s), the block's `"drops"` (or the block itself)
goes into the 36-slot inventory, and placing uses items up. **Creative**: every block in the
inventory, instant breaking, nothing is used up. Worlds from before game modes are creative.

Survival also has **health** (20 points, shown as a bar above the hotbar): falls of more than 3 blocks hurt
(1 point per extra block), running out of breath underwater (10 s, a blue bar while underwater) hurts,
and health slowly comes back after 4 s without damage. At 0 you respawn at the world's spawn
point and keep your inventory. New worlds start you on dry land.

**Water flows**: source blocks (level 8) spread up to 7 blocks sideways, getting lower, and
pour down into air; flowing water without a source drains away (`src/world/fluid_sim.gd`,
run by the single player / host and sent to others as edits).

Crafting (E) lists every hand recipe and crafts straight from the inventory. Recipe types:
`"shapeless"` (`"ingredients": {"core:log": 1}`) and `"shaped"` (`"pattern"` + `"key"`;
only the ingredient counts matter). `"smelting"` recipes need a furnace (not in yet).
Items can set `"max_stack"` and `"texture"` (their inventory icon).

## Exporting
`export_presets.cfg` has a Linux preset using Godot's official export templates (install
them from the editor: Editor → Manage Export Templates). Exports need the engine's
release library:

    cmake -S engine -B engine/build-release -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_TARGET=template_release
    cmake --build engine/build-release -j4   # -> bin/libgocube.linux.template_release.x86_64.so
    godot4 --headless --export-release "Linux" export/linux/gocube.x86_64

The preset includes `*.json` (mod manifests and content are not Godot resources, so
they'd be left out otherwise) and the license files.

## Tests
    godot4 --headless -s res://tests/run_tests.gd [-- filter]   # unit + engine tests
    bash tests/mp_smoke.sh godot4                                # host + client processes
A test fails on a failed check, a file that doesn't compile, or any error logged while it
runs. CI (`.github/workflows/ci.yml`) builds the engine and runs both on every push.

## Prototypes
Feasibility results that led to the own engine (lighting, caves/trees/water, many
creatures) and the engine's phase tests: [PROTOTYPES.md](PROTOTYPES.md),
`prototypes/engine_phase*.tscn` (run with `godot4 res://prototypes/engine_phase3.tscn`).

## Layout
- `src/core/registry.gd` — autoload `Registry`: blocks, items, recipes (namespaced `mod:name` ids).
- `src/core/mod_loader.gd` — autoload `ModLoader`: finds, orders and loads mods.
- `engine/src/` — the C++ voxel engine (`GoCubeWorld` node): `generator`, `mesher`, `light`,
  `storage`, `gocube_world` (streaming on worker threads, editing, raycast, box collision).
- `src/engine/` — `BlockAtlas` (registry → texture atlas + engine block table) and the chunk
  shaders (classic face shading × baked sky/block light; `daylight` uniform).
- `src/world/world.gd` — `World`: the engine plus the world's save folder and id table.
- `src/ui/world_menu.gd` — title screen / world select (the main scene); `settings_screen.gd`,
  `inventory_screen.gd`, `hotbar.gd`.
- `src/core/settings.gd` — autoload `Settings`: settings file, input actions (key bindings).
- `src/player/player.gd` — the player: walking/jumping/flying physics, block break/place.
- `mods/core/` — the base game, written as an ordinary mod.
- `tools/gen_textures.py` — regenerates the core 32×32 block textures (`python3 tools/gen_textures.py`).
- `tools/gen_sounds.py` — regenerates the core sounds (needs numpy).
- `src/audio/sounds.gd` — plays sound sets; `src/world/fluid_sim.gd` — flowing water.

## World generation and time
The terrain shape (hills, beaches, sea, caves) comes from the C++ generator
(`engine/src/generator.cpp`), deterministic per seed. **Ores and trees are defined by
mods** in content files; the core mod's own are in `mods/core/content/base.json`:

```json
"ores": {
  "ruby": {"block": "mymod:ruby_ore", "min_y": -96, "max_y": -40,
           "veins_per_chunk": 3, "size": [2, 5], "replaces": "core:stone"}
},
"trees": {
  "birch": {"log": "mymod:birch_log", "leaves": "mymod:birch_leaves",
            "trunk": [5, 7], "chance": 10}
}
```
Ores are random-walk veins through the `replaces` block (default stone), keyed to the ore's
id so installing more mods doesn't move existing veins. Trees share the same spots: each
spot gets one tree kind by `chance` (percent), or none. Core: coal (y ≤ 40), iron (y ≤ 8),
gold (y ≤ −28), crystal (y ≤ −56), oak trees (30%).

The time of day is your computer's local time (in multiplayer: the host's), so the sky
follows real day and night (`DayCycle`, `src/world/day_cycle.gd`; `--time=0..1` or
`--day-length=SECONDS` switch this off for testing): sky light dims to a moonlit
level at night while lamps stay bright; the sky colours and sun follow the time, which is
saved with the world and synced from the host in multiplayer.

## Saving
Worlds live in `user://worlds/<name>/` (on Linux `~/.local/share/godot/app_userdata/GoCube/`):
`world.json` (seed, block id table, player position) and `chunks/` (only chunks the player
edited, run-length encoded; the rest is regenerated from the seed). Saved on quit and
every 60 s. Worlds from the old voxel-module version regenerate their terrain; their edits
are not carried over.

Voxels store numeric block ids, so each world keeps its own id table: adding mods appends
new ids, and blocks from a removed mod keep their slot (shown magenta) until it returns.

## Sounds
All sounds are original and generated by `tools/gen_sounds.py` (`python3 tools/gen_sounds.py`):
footsteps, breaking and placing per material (grass, stone, wood, sand, gravel), splashes,
getting hurt, and day/night ambience (wind; crickets at night). Underwater, everything is
muffled. Mods define sound sets in content files and blocks pick one with `"sound"`:

```json
"sound_sets": {"metal": {"step": ["sounds/metal_step_1.wav"], "break": [...], "place": [...]}},
"blocks": {"steel_block": {"sound": "mymod:metal", ...}}
```

## Block textures
In a block definition: `"textures": {"all": "textures/stone.png"}` or per face
`{"top": ..., "side": ..., "bottom": ...}`. Paths are relative to the mod folder
(`"othermod:textures/x.png"` borrows another mod's file). Any square PNG works; it is
scaled to 32×32 and packed into a shared, mipmapped atlas at startup (textures should
tile seamlessly: the atlas pads each tile with repeats of itself to prevent mip bleeding). Blocks without textures
fall back to their `"color"`.

Other block keys: `"solid": false` (no collision), `"transparent": true` (doesn't hide
neighbours or block light), `"fluid": "water"`, `"light": 0..15` (glows, e.g. `core:lamp`).

## Writing a mod
Create `user://mods/<id>/mod.json` (see the header of `mod_loader.gd`), add JSON
content files and/or an `entry` script with `init_mod(registry)`. Set `"api_version": 1`;
mods written for a newer API version than the game supports are refused.

To distribute it as a pack: make a Godot project with the same engine build whose files
live under `mods/<id>/`, add an export preset with `include_filter="*.json"`, and run
`godot4 --headless --export-pack "<preset>" <id>.pck`. Players drop the `.pck` into
`user://mods/` (Linux: `~/.local/share/godot/app_userdata/GoCube/mods/`).

Mods are **not sandboxed**: only install mods you trust.

## Next steps
- Survival bits: health, fall damage, inventory, mining time per block (`hardness`).
- Tools (faster mining), a furnace for smelting, dropped item entities, creatures.
- Creatures on `GoCubeWorld.move_box` (step-up built in).
- Windows/macOS builds of the engine library.
- Consider a double-precision build if worlds get large.
- Evaluate [Godot Mod Loader](https://github.com/GodotModding/godot-mod-loader) if you
  want script hooks/extensions beyond this registry.

## License
GoCube is **source-available**: you may build it yourself and play your own build for free
(personal, non-commercial use); ready-made builds are distributed only by the author, who may
sell them. Redistributing builds or the source, and commercial use, need written permission.
Mods you make are yours. Full terms: [LICENSE.md](LICENSE.md).

Third-party components (Godot Engine, godot-cpp, and libraries bundled in Godot) keep
their own licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Their texts ship with
the game (title screen → **Licenses**).

