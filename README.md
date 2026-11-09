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
- Players report their own positions, but the host checks each move against the top
  speed for the game mode (sprinting plus knockback; sprint-flying in creative), with a
  short burst allowed for lag. Too fast and the player is put back where the host last
  accepted them; a jump to the world spawn (respawning) is fine. Walls aren't checked.
- Chest and furnace clicks are only taken from a player who opened that container and is
  near it, with a real item stack (known item, count within its stack size).
- Code: `src/net/session.gd` (handshake, positions, edits), `src/player/avatar.gd`,
  `World.build_remote()`.

Launch options (after `--`): `--world=NAME` skip the menu and load or create that world,
`--host` (with `--world`) host it, `--join=ADDR` join a game, `--port=N`, `--name=NAME`,
`--seed=N` seed for a new world (random otherwise), `--time=0..1` time of day (0 midnight,
0.25 sunrise, 0.5 noon, 0.75 sunset), `--day-length=SECONDS` (default 86400: real time), `--view=N` view distance (default 128), `--shadows` /
`--cheap-shadows` (off by default: they cost ~40% FPS on integrated GPUs), `--bench`
(fly forward 20 s and print FPS stats), `--profile-startup` (time each startup step and list slow frames),
`--threads=N` chunk worker threads (default: cores − 1, at most 8; also `worker_threads` in
settings.cfg: fewer leaves CPU for other programs but loads chunks slower). Try `--rendering-method gl_compatibility` on old GPUs.

Controls: WASD walk, Space jump (and swim up in water), Ctrl sprint, Shift sneak, F toggle flying (Space/Shift
up/down; fly down onto the ground to land), mouse look, hold LMB mine / LMB break (creative),
RMB place / open a chest or furnace / open or close a door / eat food / till with a hoe /
plant seeds (Shift+RMB places against a chest or door), LMB on a creature attacks it
(6-block reach), 1-9 / mouse wheel pick a hotbar slot, E inventory and crafting (creative:
a palette of every block and item), F3 debug screen (position, chunk, facing, biome, the
block you look at, chunk timings), Esc pause. Launch option `--mode=creative|survival` for new worlds. All keyboard keys can be
rebound in **Settings…** (title screen or pause menu), along with view distance, mouse
sensitivity, frame rate limit, vsync, **master / effects / ambience volume** (each with
its own audio bus) and **smooth lighting** (light blended at block corners
with soft corner shading, instead of the classic flat look). Settings are saved in
`user://settings.cfg`.

## Survival and creative
New worlds are **survival** by default (chosen in the New world dialog): hold left click to
mine (time = the block's `hardness` × 0.75 s). The block's `"drops"` (or the block itself)
pops out as a **dropped item** that drifts to you and goes into the 36-slot inventory when
you're close (same items nearby merge; they vanish after 5 minutes). Placing uses items up.
In multiplayer, dropped items are shared: the host owns them all (`src/world/item_drops.gd`)
and sends them to everyone ~10 times a second; whoever reaches one first gets it (clients ask
the host, so an item can't be picked up twice).

**Tools**: wooden and stone pickaxes and axes (3 planks or cobblestone + 2 sticks). A block's
`"tool"` mines `"speed"` times faster with that tool (wood ×2, stone ×4); blocks with
`"requires_tool": true` (stone, ores, the furnace) take 3× as long by hand and drop nothing.
Coal ore drops coal.

**Chests** (8 planks, 27 slots) and **furnaces** (8 cobblestone): right click to open. A
furnace burns fuel (an item's or block's `"fuel"` seconds: coal 40, logs/chests 15, planks
7.5, sticks 2.5) to run `"smelting"` recipes, 5 s each (cobblestone → stone, iron/gold ore
→ ingots). Breaking one drops its contents. Contents are saved in `world.json`; in
multiplayer the host keeps them and runs the furnaces.

**Creatures**: Block Eaters, slow grazers, spawn on grass around players by day (up to 12),
wander, avoid water and drops, and run off when hit; three hits defeat one. The regular one
(3 in 4) is slim with moss on its back and drops nothing, but now and then it eats the block
in front of it (the block is gone) and becomes that block's form. Every solid block, mods'
blocks included, has a form built from its textures, which drops that block when defeated
(the lamp one glows). Forms also spawn directly (ore, lamp, chest and furnace ones rarely); a
block's `"eater_weight"` sets how often its Block Eater turns up (1 = an ordinary block, 0 = never).
In multiplayer the host simulates them and sends positions (`src/mobs/`).

**Ninjas** come out at night in survival worlds (up to 6 around the players): they run at
the nearest player within 24 blocks, jump over obstacles and strike for 3 (armour takes
some off) with a shove. Daylight under open sky makes them vanish in a puff of smoke; in
caves they keep hunting. Four hits with an iron sword defeat one.

**Tools and armour**: wood, stone and iron pickaxes, axes, hoes and swords. Tiers
(`"tier"`: wood 1, stone 2, iron 3) and blocks' `"min_tier"`: iron ore needs stone, gold
and crystal need iron. Tools hit harder than a bare hand (`"damage"`), and nothing wears
out. Iron armour (helmet, chestplate, leggings, boots: 15 points) goes in the armour
slots in the inventory and takes 4% per point off creature damage (up to 60%).

**Farming**: a hoe turns grass or dirt into farmland; seeds (from tall grass, sometimes)
planted on it grow through 8 stages over a few minutes (`"grows_into"`, `"grow_seconds"`;
`src/world/plant_sim.gd`, saved with the world); ripe wheat gives wheat and seeds; 3 wheat
make bread, and eating food (`"food"`) heals when you're hurt.

**Saplings** (oak, birch, spruce) drop now and then from leaves, broken or decaying
(`"sapling"` on the leaves). Planted on grass or dirt, one grows after about 4 minutes into
the same tree the world generator makes (`"grows_tree"`: a tree id, or `{id: weight}`: an
oak sapling sometimes becomes a big oak); with no room yet it tries again later.

**Bed** (3 planks + 3 wheat): two blocks long, with the pillow at the end you face when you
place it (it needs room for both halves; breaking either removes the whole bed). Right click
to make it your respawn point; at night, sleep in it. When everyone in the game is in bed for a moment the night is skipped to the morning
(move or jump to get up). You can't sleep with a ninja close by. If the bed is gone when you
respawn, you're back at the world spawn. The bed is saved with your player.

**Building**: torches (coal + stick; light 13, on floors and walls), slabs and stairs
(stone, cobblestone, planks), wooden doors (right click opens both halves), fences,
ladders (climb with Space or by walking into them; no fall damage), glass (smelt sand).
Torches, ladders, doors and plants pop off when what holds them goes. Holding a torch (any block with `"light"`) lights the world around you as you walk, and other players see your light (and the torch in your hand) in multiplayer.

**Creative**: every block in the inventory, instant breaking, nothing is used up. Worlds from before game modes are creative.

Survival also has **health** (20 points, shown as a bar above the hotbar): falls of more than 3 blocks hurt
(1 point per extra block), running out of breath underwater (10 s, a blue bar while underwater) hurts,
and health slowly comes back after 4 s without damage. At 0 you respawn at your bed (or the
world's spawn point) and keep your inventory. New worlds start you on dry land.

**Water flows**: source blocks (level 8) spread up to 7 blocks sideways, getting lower, and
pour down into air; flowing water without a source drains away (`src/world/fluid_sim.gd`,
run by the single player / host and sent to others as edits).

Crafting (E) lists every hand recipe and crafts straight from the inventory. Recipe types:
`"shapeless"` (`"ingredients": {"core:log": 1}`) and `"shaped"` (`"pattern"` + `"key"`;
only the ingredient counts matter). `"smelting"` recipes (`"input"`, `"output"`) run in a furnace.
Items can set `"max_stack"`, `"texture"` (their icon), `"fuel"`, and for tools `"tool"`
(`"pickaxe"`, `"axe"`, …) and `"speed"`. Blocks with `"block_entity": "chest"` or `"furnace"`
get storage.

## Exporting
`export_presets.cfg` has a Linux preset using Godot's official export templates (install
them from the editor: Editor → Manage Export Templates). Exports need the engine's
release library:

    cmake -S engine -B engine/build-release -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_TARGET=template_release
    cmake --build engine/build-release -j4   # -> bin/libgocube.linux.template_release.x86_64.so
    godot4 --headless --export-release "Linux" export/linux/gocube.x86_64

`mods/` has a `.gdignore`: Godot doesn't import the built-in mods' textures and sounds (no
`.import` files, no copies in `.godot/imported/`), and the game reads them straight from the
files, as it does for players' mods. Since Godot also leaves ignored folders out of exports, the
`addons/gocube_export` editor plugin (enabled in `project.godot`) adds every file under `mods/`
to the export unchanged. The preset also includes `*.json` and the license files.

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
The terrain comes from the C++ generator (`engine/src/generator.cpp`), deterministic per
seed. New worlds have **biomes**: plains (tall grass, flowers, scattered round oaks, lakes),
forest (round oaks, big branching oaks, birches), desert (sand over sandstone, cacti, dead
bushes) and snow (snowy ground, tall spruces, ice on water). Each column's biome is the
nearest one in climate space (two slow noise fields: temperature and humidity); hill
height is blended between biomes so borders have no cliffs. Also: lakes in flat places,
worm caves plus big caverns deep down, **lava** filling the lowest caves (it burns, glows,
flows 4 blocks, and turns to stone or cobblestone where it meets water), falling sand and
gravel, and leaves that decay once their tree is gone (placed leaves don't). Worlds made
before biomes keep the original generator (`"generator"` in world.json) so their
unexplored land still matches what's saved; likewise worlds from before generator 3 keep
the classic blocky oak, which new worlds replace with a rounder, uneven one.

**Ores, trees and biomes are defined by mods** in content files; the core mod's own are in
`mods/core/content/base.json`:

```json
"ores": {
  "ruby": {"block": "mymod:ruby_ore", "min_y": -96, "max_y": -40,
           "veins_per_chunk": 3, "size": [2, 5], "replaces": "core:stone"}
},
"trees": {
  "palm": {"log": "mymod:palm_log", "leaves": "mymod:palm_leaves",
           "trunk": [5, 7], "style": "birch"}
},
"biomes": {
  "jungle": {"temperature": 0.8, "humidity": 0.8, "height": 26, "base": 3,
             "surface": "core:grass", "filler": "core:dirt",
             "trees": {"mymod:palm": 40}, "plants": {"core:tall_grass": 120}, "lakes": 20}
}
```
Tree styles: `round_oak`, `big_oak`, `birch`, `spruce`, `cactus` (no leaves), and `oak`
(the classic blocky oak, used by older worlds). A biome's `trees` are
percents of 8×8 tree spots, `plants` per mille of surface columns; also `filler_depth`,
`under` / `under_depth` (a layer below the filler, like sandstone), `frozen` (ice on
water) and `lakes` (percent).
Ores are random-walk veins through the `replaces` block (default stone), keyed to the ore's
id so installing more mods doesn't move existing veins. Trees share the same spots: each
spot gets one tree kind by `chance` (percent), or none. Core: coal (y ≤ 40), iron (y ≤ 8),
gold (y ≤ −28), crystal (y ≤ −56).

Time runs at real speed (a day lasts 24 hours; `DayCycle`, `src/world/day_cycle.gd`). A new
world starts at your computer's local time; after that the time is saved with the world and
resumes where you left off (in multiplayer: the host's, synced to everyone). Offline, pausing
stops it. `--time=0..1` and `--day-length=SECONDS` override it for testing. Sky light dims to
a moonlit level at night while lamps stay bright. The sky (`src/world/sky.gdshader`) has a
square pixel sun rising in the east, a pixel moon opposite it, stars that fade in at night
and turn with the sky, and a drifting layer of blocky clouds tinted by the time of day.

## Saving
Worlds live in `user://worlds/<name>/` (on Linux `~/.local/share/godot/app_userdata/GoCube/`):
`world.json` (seed, block id table, player position) and `chunks/` (only chunks the player
edited, run-length encoded; the rest is regenerated from the seed). Saved on quit and
every 60 s. Worlds from the old voxel-module version regenerate their terrain; their edits
are not carried over. A world saved by a newer version of the game, or whose world.json is
damaged, is refused with a message and left untouched (nothing is written to it).

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
`"random_rotation": true` turns the top and bottom texture by 0/90/180/270° per block
position, so large flat areas (grass, sand, stone) don't show a repeating grid.

Shapes (`"shape"`, `src/core/block_shapes.gd`): `slab`, `stairs`, `torch`, `ladder`, `door`,
`fence`, `cross` (plants), or `boxes` with your own `"boxes": [[x0, y0, z0, x1, y1, z1], ...]`
in 1/16 units (the cactus). Shapes that face a way get variant blocks (`<id>_e`,
`<id>_wall_n`, `<id>_n_upper_open`, …) chosen when placing; they drop the base item. The
engine draws and collides with the actual boxes. More keys: `"plant_on": [blocks]`,
`"needs_support"`, `"climbable"`, `"replaceable"` (tall grass), `"falls"`, `"leaves"`,
`"extra_drops": [[item, count, chance]]`, `"min_tier"`, `"hidden"`; fluids: `"flow_step"`,
`"damage"`.

## Writing a mod
Create `user://mods/<id>/mod.json` (see the header of `mod_loader.gd`), add JSON
content files and/or an `entry` script with `init_mod(registry)`. Set `"api_version": 1`;
mods written for a newer API version than the game supports are refused. mod.json is
checked before anything of a mod loads (field types, dependency ids, and that `content` and
`entry` are existing `.json` / `.gd` files inside the mod folder); a broken mod is skipped
with the reason in the log. Content sections must map ids to objects.

To share it, zip the mod folder (or its contents, with `mod.json` at the top of the zip).
Players drop the `.zip` into `user://mods/` (Linux:
`~/.local/share/godot/app_userdata/GoCube/mods/`); the game unpacks it to
`user://mods/.unzipped/` and unpacks it again only when the zip changes. Files that would land
outside the mod's folder are refused. Godot `.pck` packs that contain `mods/<id>/...` still work too.

Players can turn mods off under **Settings → Mods** (saved in `settings.cfg`; takes effect on
the next start). A mod that depends on one that's turned off is skipped as well.

Mods are **not sandboxed**: only install mods you trust.

## License
GoCube is **source-available**: you may build it yourself and play your own build for free
(personal, non-commercial use); ready-made builds are distributed only by the author, who may
sell them. Redistributing builds or the source, and commercial use, need written permission.
Mods you make are yours. Full terms: [LICENSE.md](LICENSE.md).

Third-party components (Godot Engine, godot-cpp, and libraries bundled in Godot) keep
their own licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Their texts ship with
the game (title screen → **Licenses**).

