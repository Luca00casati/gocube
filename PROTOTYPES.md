# Feasibility prototypes

> **Update — own engine.** These findings (GDScript light too slow, per-block tint, physics
> bodies collapsing against trimesh terrain) led to GoCube's own C++ voxel engine
> (`engine/`), which replaced the voxel module. Phase tests on stock Godot 4.7.2, same laptop:
>
> | | Voxel module | Own engine |
> |---|---|---|
> | Spawn area ready | ~3.5 s (with terrain features) | 0.39 s; 0.77 s with full block light |
> | Fly-through benchmark | 59.9 FPS, 0 frames > 33 ms (column skylight) | 60.1 FPS, 0 frames > 33 ms (block light) |
> | Light per 32³ chunk | GDScript ≈ 685 ms per 64³ | 5.6 ms (≈100× faster), per-face, torches |
> | Edit visible | — | 6 edits in ~83 ms; relight 14–24 ms |
> | 1000 box moves / raycasts | — | 4.2 ms / 2.9 ms (no physics engine) |
>
> The sections below describe the original voxel-module prototypes; their code was removed
> when the game moved to the own engine (it is in the git history, branch `prototypes`).

Branch `prototypes`. Measured on the dev laptop (Intel i5-4210M, 4 threads, Intel HD 4600),
Godot 4.7.2 + voxel module v1.7. Benchmark scenes are in `prototypes/` and can be rerun, e.g.
`godot-voxel res://prototypes/mobs.tscn -- voxel`.

## Summary

| Feature | Verdict | Notes |
|---|---|---|
| Caves | **Works** (native graph) | spaghetti tunnels from two 3D noises; kept away from the sea floor |
| Sea, beaches | **Works** (native graph) | sea level −4; sand near/below sea level |
| Trees | **Works** (GDScript pass) | cross chunk borders; ~0.5 ms/chunk extra at the surface |
| Water rendering + swimming | **Works** | module fluid model; non-solid; buoyancy; underwater tint |
| Flowing water | Not prototyped | module renders fluid levels; a local GDScript flow sim on edits is expected to be fine |
| Classic lighting (face shading + column skylight) | **Works** (shader) | shadows under trees, roofs, overhangs, in caves; synced in multiplayer |
| Light that spreads (torches, light around corners) | **Needs native code** | GDScript far too slow; module tint is per block, not per face |
| Many creatures | **Works with `VoxelBoxMover`** | ~200 on this laptop; physics-engine bodies collapse past ~50 |

## Classic lighting (implemented)

`src/world/terrain.gdshader` + `src/world/sky_light.gd`. No real-time lights or shadow maps:

- **Face shading**: top 1.0, north/south 0.8, east/west 0.6, bottom 0.5.
- **Column skylight**: a face is shadowed (0.55) when the air in front of it is below the
  highest opaque block of its column. Column tops come from the generator's height function
  plus tree canopies (no voxel scanning); edits update them and are saved per world
  (`sky_overrides`) and sent to multiplayer clients. Because the shader samples the air *in
  front of* each face, walls are lit correctly on each side.
- The mesher's per-corner occlusion is off for the flat look (`use_vertex_ao` brings it back).

Cost: 51 ms to build the 320×320 column window (behind the loading screen), 11 ms per
recentre (every 48 blocks travelled). Fly-through benchmark with all terrain features:
**59.9 FPS, 0 frames over 33 ms**, better than the lit StandardMaterial (≈53 FPS, 34).

Limits: two light levels only (lit / shadow); caves are as dark as any overhang; no torches.

## Spreading light (not implemented)

The module has no light propagation. It can tint each block by a per-voxel colour
(`VoxelMesherBlocky.TINT_RAW_COLOR` + 16-bit `CHANNEL_COLOR` = RGBA4444, 16 levels/channel,
even coloured light). `src/world/light_prototype.gd` floods sky and block light in GDScript
and writes that channel (enable with `World.LIGHTING_PROTOTYPE`).

- **Rendering works**: an enclosed room goes dark, light falls through a doorway, a lamp glows.
- **Flaw**: the tint applies to the whole block. A solid block takes its brightest neighbour,
  so the inside face of a 1-block wall shows the outside light. Proper per-face light needs a
  module mesher patch (sample the voxel in front of each face) or a custom terrain shader.
- **Too slow in GDScript**: 32³ = 95 ms, 64³ = 685 ms (≈12 ms per 16³ chunk → ~25 s for the
  ~2000 chunks in view). Native code is typically 50–100× faster.

**Recommendation**: a C++ (GDExtension) light engine plus per-face sampling (module patch or
shader). This is the largest remaining technical project. Until then, caves are fully lit.

## Terrain features

Generation cost per 16³ chunk (graph + tree pass): average 0.66 ms (was 0.20), surface band
0.90 ms (was 0.38). Runs on background threads.

In-game (20 s fly-through benchmark, fixed seed): everything on ≈ 53 FPS with 34 frames over
33 ms; everything off ≈ 56 FPS with 1. Single-feature A/B runs were too noisy to attribute
reliably (the runs vary by several FPS). The likely cause is chunk-arrival bursts now that
generation is ~3× slower. **Next step**: profile with the module's Tracy build and spread
mesh uploads; consider occlusion of underground caves.

Spawn loading screen: ~3.5 s with the new features (was ~1.7 s).

## Creatures

`prototypes/mobs.tscn`, vsync off, wandering box creatures on terrain:

| Creatures | `VoxelBoxMover` | `CharacterBody3D` + Jolt |
|---|---|---|
| 0 | 20.9 ms/frame | 31.1 ms/frame |
| 50 | 27.8 ms | 48.3 ms |
| 100 | 31.9 ms | 156 ms |
| 200 | 33.6 ms | 264 ms |
| 400 | 35.1 ms | 433 ms |
| 800 | 69.6 ms | 748 ms |

(Godot's default physics engine was worse than Jolt: 50 creatures ≈ 6 FPS.) Baselines vary
between runs; the gap between methods is far larger than that noise.

**Recommendation**: creatures use `VoxelBoxMover` (box vs voxel grid, no physics engine;
`src/mobs/voxel_wanderer.gd`). Next: MultiMesh rendering and slower updates for far creatures.
The player can keep `CharacterBody3D`.
