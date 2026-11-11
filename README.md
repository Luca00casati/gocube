# GoCube

Voxel sandbox in Godot 4 + GDScript, built to be modded from day one.

## Engine
Runs on **stock Godot 4.5+** (developed on 4.7.2). The voxel engine is GoCube's own C++
GDExtension in `engine/` (chunk storage, generation, meshing, light, collision, saving),
built against [godot-cpp](https://github.com/godotengine/godot-cpp) (a submodule pinned
to `godot-4.5-stable`). Build it once after cloning, and after changing `engine/src/`:

    git submodule update --init
    scons -C engine -j4         # -> bin/libgocube.linux.template_debug.x86_64.so

It builds with [SCons](https://scons.org) like Godot and godot-cpp do (`pip install scons`,
or your distribution's package); `target=template_release` builds the release library.
Then `godot4 -e --path .` opens the editor. The Windows library is cross-compiled from Linux
with MinGW (`apt install g++-mingw-w64-x86-64`; it needs only Windows' own DLLs):

    scons -C engine platform=windows use_mingw=yes -j4   # -> bin/libgocube.windows.template_debug.x86_64.dll

macOS isn't supported yet (its library has to be built on a Mac).

The game opens on a world menu (play / host / create with optional seed / delete to
trash / join a game). In game, Esc opens the pause menu.

## Multiplayer
Pick a world and press **Host**; others press **Join a game…** and enter the address shown
at the top of the host's screen (UDP port 24680; open it in the host's firewall, or
forward it on the router for play over the internet). The host's machine runs the world
and saves it. World generation is deterministic, so joining players generate the
terrain themselves from the seed; only edits travel over the network.

- Everyone plays with the **same mods**: same ids, versions and files (each mod gets a
  fingerprint of its files, so two different builds with the same version don't pass). A
  player whose mods differ is asked whether to take the server's: the ones they lack are
  downloaded (checked against their fingerprints, at most 64 MB) into
  `user://mods/.server/<id>_<fingerprint>/`, and the game restarts and joins again with
  exactly the server's mods. Their own mods stay installed and come back when they leave
  (the game restarts once more). Downloads are kept, so the next join needs none. Mods are
  sandboxed (see [Sandbox](#sandbox)); a different base game (`core`) is still refused.
- On join the host sends the seed, its block id table and every edited chunk; after
  that each edit is sent as (position, block). A player who hasn't loaded that chunk
  asks the host for the whole chunk.
- Block edits from joining players are requests: the host checks reach (16 blocks), the
  block id and that nobody is inside the block, then applies them (survival: see inventories
  below). Placing is one request
  for all the blocks that go together (a bed's or door's two halves): the host places all of
  them or none, and when it refuses, the item comes back to the player's inventory.
- Players report their own positions, but the host checks each move against the top
  speed for the game mode (sprinting plus knockback; sprint-flying in creative), with a
  short burst allowed for lag, and follows the way there in tenth-of-a-block steps: a move
  that goes through a block (even a door) is refused too. Either way the player is put back
  where the host last accepted them; a jump to the world spawn or their bed (respawning) is
  fine. Getting into and out of bed isn't checked for walls (the eyes drop to the pillow),
  nor are moves where the host hasn't loaded the chunks (far from its own player).
- Chest and furnace clicks are only taken from a player who opened that container and is
  near it, with a real item stack (known item, count within its stack size).
- Every request a joining player sends has a rate limit (edits, hits, chunk requests,
  pickups, containers, inventory actions, mining, beds; `RATES` in `session.gd`); extra ones are ignored. A refused edit is
  answered, so the player doesn't wait for it, and an edit request never answered is forgotten
  after 5 s. Names are cleaned (printable characters, at most 16), positions and facing must be
  finite numbers, and a player can only say hello once.
- **The host keeps every joining player's inventory** (survival). The player's game acts at
  once and tells the host each thing it did (moving items, crafting, eating, armour, chests),
  numbered; the host does the same to its copy where that's allowed, and sends its copy back,
  which the player's game takes once the host has caught up with everything it sent. Placing
  takes the item from the host's copy (a modified game can't place what it doesn't have);
  without an item a player can only break blocks, open doors and till with a hoe. The host
  decides what breaking and tilling drop (with the tool in the slot the player names) and
  makes every item lying around: players can't drop items of their own making. What the mouse
  holds in a chest is the host's too. Inventories are kept by player name in the host's world
  (saved with it), so a player gets theirs back when they join again; one player per name at
  a time. Names aren't passwords: someone joining with your name gets your inventory, so
  play with people you know. In creative, players' games are trusted (anything can be placed,
  breaking is instant). `test_malformed_requests` sends nonsense to every request the host
  takes and checks that nothing changes, including the host's copy of the inventory.
- **Mining takes as long on the host** (survival). The player's game tells the host when it
  starts mining a block; a break counts only for that block, and no sooner than its mining
  time with the tool the player holds (less a little for the network). One that arrives
  sooner, from a modified game or because the host stalled, waits until then; a break without
  a start is refused. A new start doesn't count before a waiting break is done, so mining
  several blocks at once gains nothing.
- **The host keeps every joining player's health** (survival), by the same rules as single
  player: falls (from the positions it accepted), lava, drowning, creatures (armour from its
  copy of the inventory), healing, and food (eating only heals when hurt). The player's game
  shows the host's health and dies when the host says so; until the player respawns the host
  takes no edits, hits or pickups from them, and creatures leave them alone. Health is kept
  by name with the inventory.
- Players see each other as jointed figures (skin, hair and clothes picked from the player's
  id) that hold what that player holds, walk and run at the speed they move, and show
  sneaking, jumping, swinging and sleeping; each player sends its head pitch, held item,
  sneak/sleep/fly flags and a swing counter (the host takes a held item's light from its own
  item data). Ninjas use the same figure (`src/player/figure.gd`).
- Code: `src/net/session.gd` (handshake, positions, edits), `src/player/avatar.gd`,
  `src/player/figure.gd`, `World.build_remote()`.

Launch options (after `--`): `--world=NAME` skip the menu and load or create that world,
`--host` (with `--world`) host it, `--join=ADDR` join a game, `--port=N`, `--name=NAME`,
`--seed=N` seed for a new world (random otherwise), `--time=0..1` time of day (0 midnight,
0.25 sunrise, 0.5 noon, 0.75 sunset), `--day-length=SECONDS` (default 86400: real time), `--view=N` view distance (default 128), `--no-shadows`
(no sun shadows, whatever Settings says), `--bench`
(fly forward 20 s and print FPS stats, the F4 profiler's average time per system, and the
workers' time per chunk), `--profile-startup` (time each startup step and list slow frames),
`--threads=N` chunk worker threads (default: cores − 1, at most 8; also `worker_threads` in
settings.cfg: fewer leaves CPU for other programs but loads chunks slower). Try `--rendering-method gl_compatibility` on old GPUs.
The depth prepass is off (project.godot): chunks hide few pixels behind each other, so
drawing them twice cost more GPU time than it saved (about 1.5 ms per frame on an Intel
Haswell GPU). Only blocks with see-through pixels use a shader that discards pixels
(`chunk_cutout.gdshader`); a discarding shader on every block cost about 2 ms more.

Controls: WASD walk, Space jump (and swim up in water), Ctrl sprint, Shift sneak, F toggle flying (Space/Shift
up/down; fly down onto the ground to land), mouse look, hold LMB mine / LMB break (creative),
RMB place / open a chest or furnace / open or close a door / eat food / till with a hoe /
plant seeds (Shift+RMB places against a chest or door), LMB on a creature attacks it
(6-block reach), 1-9 / mouse wheel pick a hotbar slot, E inventory and crafting (creative:
a palette of every block and item), F5 view (first person / from behind / from in front), F3 debug screen (position, chunk, facing, biome, the
block you look at, chunk timings), F4 profiler (a graph of frame times and what each frame
spends its time on: the world engine and mesh uploads, game systems, rendering CPU and GPU,
with the worst frame of the last second and what took longest in it), Esc pause. Launch option `--mode=creative|survival` for new worlds. All keyboard keys can be
rebound in **Settings…** (title screen or pause menu), along with view distance, mouse
sensitivity, frame rate limit, vsync, **master / effects / ambience volume** (each with
its own audio bus), **smooth lighting** (light blended at block corners
with soft corner shading, instead of the classic flat look; on by default), **sun
shadows** (*blocks*, the default: each block face is either in the sun or in a block's
shadow, worked out by the engine as it meshes chunks, out to the view distance and nearly
free for the GPU, following the sun in 2° steps; *smooth*: Godot's shadow map out to 40
blocks, about 25% of the GPU's time on an integrated GPU; or *off*) and **render
scale** (100 / 85 / 75 / 50%: the world is drawn at that fraction of the window's resolution
and stretched, the menus and HUD stay sharp; 50% roughly halves the GPU's work). Settings are saved in
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

**Ninjas** come out at night in survival worlds (up to 6 around the players), except on a
new world's first night, which is safe (it ends at the next morning, or when everyone sleeps
through it; worlds from before this count as past it): they run at
the nearest player within 24 blocks, jump over obstacles and strike for 3 (armour takes
some off) with a shove. Daylight under open sky makes them vanish in a puff of smoke; in
caves they keep hunting. Four hits with an iron sword defeat one.

**Tools and armour**: wood, stone and iron pickaxes, axes, hoes and swords. Tiers
(`"tier"`: wood 1, stone 2, iron 3) and blocks' `"min_tier"`: iron ore needs stone, gold
and crystal need iron. Tools hit harder than a bare hand (`"damage"`), and nothing wears
out. Iron armour (helmet, chestplate, leggings, boots: 15 points) goes in the armour
slots in the inventory and takes 4% per point off creature damage (up to 60%).

**Farming**: a hoe turns grass or dirt into farmland; tilling grass sometimes turns up a
seed (1 in 10, `"till_drops"`); seeds
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
Torches, ladders, doors and plants pop off when what holds them goes. Holding a torch (any block with `"light"`) lights the world around you as you walk, block by block like a placed torch (one level less per block, and not through walls), and other players see your light (and the torch in your hand) in multiplayer.

**Creative**: every block in the inventory, instant breaking, nothing is used up. Worlds from before game modes are creative.

Survival also has **health** (20 points, shown as a bar above the hotbar): falls of more than 3 blocks hurt
(1 point per extra block), running out of breath underwater (10 s, a blue bar while underwater) hurts,
and health slowly comes back after 4 s without damage. At 0 you respawn at your bed (or the
world's spawn point) and keep your inventory; if that's far away, the loading screen shows
until the ground there has loaded. New worlds start you on dry land, on the surface (grass,
sand or snow) rather than in a pit or cave mouth.

**Water flows**: source blocks (level 8) spread up to 7 blocks sideways, getting lower, and
pour down into air; flowing water without a source drains away (`src/world/fluid_sim.gd`,
run by the single player / host and sent to others as edits).

Crafting (E) lists every hand recipe and crafts straight from the inventory. Recipe types:
`"shapeless"` (`"ingredients": {"core:log": 1}`) and `"shaped"` (`"pattern"` + `"key"`;
only the ingredient counts matter). `"smelting"` recipes (`"input"`, `"output"`) run in a furnace.
Items can set `"max_stack"`, `"texture"` (their icon), `"fuel"`, and for tools `"tool"`
(`"pickaxe"`, `"axe"`, …) and `"speed"`. Blocks with `"block_entity": "chest"` or `"furnace"`
get storage.

## Shipping
GoCube ships with Godot itself, not as an export: the regular Godot binary next to the
project folder, and a launcher that starts the game (no export templates, no `.pck`).

    python3 tools/package.py dist/linux                       # Linux
    python3 tools/package.py dist/windows --platform=windows  # Windows

`dist/.../GoCube/` holds the launcher (`gocube`, or `GoCube.cmd` on Windows; options pass
through, e.g. `./gocube -- --world=MyWorld`), the official Godot (`godot` / `godot.exe`) and
`game/`. The official Godot (`GODOT_VERSION` in the script, 4.7.2-stable) is downloaded from
Godot's GitHub releases, checked against its published SHA-512 sums and kept in
`~/.cache/gocube/godot/` (`--godot=PATH` ships a binary you already have instead).
`game/` has `project.godot`, `src/`, `mods/`, the licenses, the engine library and the few
files Godot needs from `.godot/` to run without importing (class names, the GDExtension list,
resource ids). The game's files ship as they are, so players can read and change the core mod
like their own. It runs from a read-only folder (Godot keeps its shader cache in the player's
data folder). Godot's binary runs the game as a debug build, so the engine library shipped is
the debug one (`bin/libgocube.<platform>.template_debug.x86_64.*`, as the builds above make).
CI (Linux) builds both libraries, runs the tests and packages every push (the
`GoCube-linux-x86_64` and `GoCube-windows-x86_64` artifacts). The Windows package is built
and its layout tested, but nothing here runs it: try it on Windows before a release.

`mods/` has a `.gdignore`: Godot doesn't import the built-in mods' textures and sounds (no
`.import` files, no copies in `.godot/imported/`), and the game reads them straight from the
files, as it does for players' mods.

## Tests
    python3 tests/run_tests.py [filter] [--godot=GODOT] [-j N]

The tests are GDScript; the Python runner starts one headless Godot per test file, several at
once (slowest first), each with its own user data folder (`.godot/test_data/<n>`), so they
never touch your worlds or settings. `godot4 --headless -s res://tests/run_tests.gd [-- filter]`
runs them one after another in a single Godot (what each of those processes does).
A test fails on a failed check, a file that doesn't compile, or any error logged while it
runs (a test that checks something is refused declares the error with `expect_error`). Test
worlds are named `_test…` and, like any other `user://_test…` folder, are deleted for good
(not to the trash) before and after every test. `test_mp_processes` starts a
headless host and a headless client as two separate Godot processes (`mp_smoke.tscn`) and
checks what the client reports; it takes about 20 s (`-- mp_processes` runs only it).
`test_multiplayer` runs a host and a client game in one process (each with its own
network stack); both it and `test_mp_processes` drive the client's player as a person would
(aim, place, break, open doors, use beds; `tests/mp_play.gd`) and check that the host's
and the client's worlds end up the same. A new feature that changes the world or the
player is checked on the client too, including what happens when the host refuses it
(see CLAUDE.md). CI (`.github/workflows/ci.yml`) builds the engine and runs them on every push.

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
  shaders (classic face shading × baked sky/block light; `daylight` uniform; the sun's
  share is added in the terrain shader's `light()` times Godot's shadow, so hills, trees and
  buildings cast shadows, plus drifting cloud shadows and a slow variation in the green of
  grass and leaves, `"tint": true`). Water takes the same shade and shadows. Creatures,
  players, dropped and held items and the first-person hand are lit by where they are
  (`World.light_for`: sky, placed lights from the engine's `light_at`, torches players hold),
  and players and creatures cast shadows.
- `src/world/world.gd` — `World`: the engine plus the world's save folder and id table.
- `src/ui/world_menu.gd` — title screen / world select (the main scene); `settings_screen.gd`,
  `inventory_screen.gd`, `hotbar.gd`.
- `src/core/settings.gd` — autoload `Settings`: settings file, input actions (key bindings).
- `src/player/player.gd` — the player: walking/jumping/flying physics, block break/place.
- `mods/core/` — the base game, written as an ordinary mod.
- `tools/gen_textures.py` — regenerates the core 32×32 block textures (`python3 tools/gen_textures.py`).
- `tools/gen_sounds.py` — regenerates the core sounds (needs numpy).
- `tools/package.py` — builds the game for players (see Shipping).
- `src/audio/sounds.gd` — plays sound sets; `src/world/fluid_sim.gd` — flowing water.

## World generation and time
The terrain comes from the C++ generator (`engine/src/generator.cpp`), deterministic per
seed. The generator supports **biomes**; the core mod loads only one, **vanilla**: plains
(flowers, scattered round oaks, lakes) with **mountain ranges** rising out of
them (grass on the lower slopes, bare stone from y 26, a thin layer of snow on the peaks
from y 36; no trees on the rock). The **snow layer** (`core:snow`) is 1/16 of a block high: you
walk on it, it needs ground under it, and placing a block on its spot replaces it. Breaking
it gives a **snowball** (stacks of 16); 2 snowballs craft a snow layer again. Plains without mountains, forest (round oaks, big branching oaks, birches), desert
(sand over sandstone, cacti, dead bushes) and snow (snowy ground, tall spruces, ice on water)
are kept, unloaded, in `mods/core/content/biomes_unused.json`; add that file to `content` in
`mods/core/mod.json` to bring them back (or a mod can register its own). A biome gets
mountains with `"mountains"` (their extra height in blocks), `"rock"`/`"rock_above"` (bare
top from that height), `"cap"`/`"cap_above"` (a different top block for the peaks) and
`"cover"`/`"cover_above"` (a thin block laid on top, like the snow); ground stays below y 44. Each column's biome is the
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
a faint blue moonlight at night while lamps stay bright, and the haze closes in to about 40
blocks and turns nearly black, so you need a torch (new players start with one in hand).
By day, distant land fades into a haze in the horizon's colour. The sky (`src/world/sky.gdshader`) has a
square pixel sun rising in the east, a pixel moon opposite it, stars that fade in at night
and turn with the sky, and a drifting layer of blocky clouds tinted by the time of day.

## Saving
Worlds live in `user://worlds/<name>/` (on Linux `~/.local/share/godot/app_userdata/GoCube/`):
`world.json` (seed, block id table, player position) and `chunks/` (only chunks the player
edited, run-length encoded; the rest is regenerated from the seed). Saved on quit and
every 60 s. `world.json` has a `format` number (and a `generator` number for the terrain).
An older world is upgraded one format at a time (`World.migrate`), after a copy of its
world.json is kept as `world.json.format<N>.bak`; to change the format, raise
`FORMAT_VERSION` and add a step there. Worlds from the old voxel-module version (format 1)
regenerate their terrain; their edits are not carried over. A world saved by a newer version of the game, or whose world.json is
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
`"extra_drops": [[item, count, chance]]`, `"till_drops"` (the same, when tilled with a hoe), `"min_tier"`, `"hidden"`; fluids: `"flow_step"`,
`"damage"`.

## Writing a mod
Create `user://mods/<id>/mod.json` (see the header of `mod_loader.gd`), add JSON
content files and/or an `entry` script with `init_mod(registry)`. Set `"api_version": 1`;
mods written for a newer API version than the game supports are refused. mod.json is
checked before anything of a mod loads (field types, dependency ids, and that `content` and
`entry` are existing `.json` / `.gd` files inside the mod folder), and so is every content
file (sections must map ids to objects); a broken mod is skipped whole, with the reason in the
log. If a mod's entry script doesn't load, or its `init_mod` returns `false`, everything the
mod registered is undone (including definitions it replaced) and mods depending on it are
skipped.

To share it, zip the mod folder (or its contents, with `mod.json` at the top of the zip).
Players drop the `.zip` into `user://mods/` (Linux:
`~/.local/share/godot/app_userdata/GoCube/mods/`); the game unpacks it to
`user://mods/.unzipped/` and unpacks it again only when the zip changes. Files that would land
outside the mod's folder are refused. Godot `.pck` packs are not loaded
(they could carry any code): zip the mod folder instead.

**Settings → Mods** lists every mod found: where it comes from (built-in, folder or zip), its
size, whether it loaded and, if not, why (a bad `mod.json`, refused by the sandbox, too slow,
a missing dependency). Mods can be turned off there (saved in `settings.cfg`; takes effect on
the next start); a mod that depends on one that's turned off is skipped as well. It also opens
the mods folder and shows the mods downloaded from servers, which it can delete.

### Sandbox
Mods are **sandboxed**, so a mod can't touch your files, the network or the rest of the game:

- The entry script is checked before it is compiled (`src/core/mod_sandbox.gd`) and refused,
  with the line and the name in the log, if it uses anything outside the mod API. It may use
  its own functions and variables, numbers, strings, arrays, dictionaries, vectors and colours,
  the math and string functions and `print`; it must extend `RefCounted` (the default). No
  engine classes (`OS`, `FileAccess`, ...), autoloads, nodes, `load`/`preload`, `self`,
  `call`/`set`, `.new()`, `await`, annotations, inner classes, lambdas or recursion (and so
  no `map`/`filter`/`sort_custom`: write a loop). Loop and function bodies go on lines of their
  own. Read dictionary keys with `d["key"]` or `d.get("key")`, not `d.key`.
- **Time and memory limits**: the game adds a check at the start of every loop body and
  function; a mod still loading after 5 s, or using more than 256 MB, is stopped and undone
  (with the reason in the log and on the Mods screen).
- **Own process**: installed mods' scripts run in a Godot process of their own
  (`src/core/mod_runner.gd`; on Linux capped at 2 GB with `prlimit`), which sends back what the
  mod registered. A mod that asks for gigabytes in one call, or hits any engine error, only
  takes that process down and is refused; the game goes on. Scripts can't use the clock or
  random numbers, so the result depends only on the mod's files and the mods before it: it is
  kept (`user://mods/.results/`) and the next start needs no process. Built-in mods (`core`)
  run in the game itself.
- `init_mod(registry)` gets a `GoCubeModApi`, a native object with only `register_block`,
  `register_item`, `register_recipe`, `register_ore`, `register_tree`, `register_biome`,
  `register_sound_set`, `get_block(id)` and `get_item(id)` (copies), and only while the mod
  loads. Definitions must be plain data (no objects or functions).
- Texture and sound paths must stay inside a mod folder, and an installed mod's files are read
  only as PNG / WAV data, never through Godot's resource loader (a resource can carry a
  script).


## License
GoCube is **source-available**: you may build it yourself and play your own build for free
(personal, non-commercial use); ready-made builds are distributed only by the author, who may
sell them. Redistributing builds or the source, and commercial use, need written permission.
Mods you make are yours. Full terms: [LICENSE.md](LICENSE.md).

Third-party components (Godot Engine, godot-cpp, and libraries bundled in Godot) keep
their own licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Their texts ship with
the game (title screen → **Licenses**).

