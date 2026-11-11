// Turns a chunk (plus its 6 neighbours, for faces on the border) into vertex
// arrays: an opaque surface, a cutout surface (blocks whose textures have
// see-through pixels) and a fluid surface. Pure C++, thread-safe.
#pragma once

#include "chunk.h"
#include "light.h"

#include <vector>

namespace gocube {

struct AtlasLayout {
	int cols = 1, rows = 1; // tiles in the atlas grid
	int cell = 4;           // each tile owns a cell x cell area of repeated copies
	int face_x = 1, face_y = 1; // which copy inside the cell faces use
};

struct MeshOptions {
	// Per-corner light: each vertex averages the 4 cells touching it on the
	// face's air side, and solid cells there darken the corner (ambient
	// occlusion). Off: one flat light value per face (the classic look).
	bool smooth_lighting = false;
	// World block position of the chunk's (0, 0, 0) block, for per-block
	// variation that must not change when the chunk is remeshed.
	int origin_x = 0, origin_y = 0, origin_z = 0;
	// Block shadows from the sun: each face is either in the sun or in shadow,
	// by whether a line from the cell in front of it towards the sun meets an
	// opaque block (see sun_reaches). The sun moves in the x-y plane: towards
	// it is (sun_x, sun_y), sun_y > 0. Marked in the vertex colour's alpha.
	bool sun_shadows = false;
	float sun_x = 0.0f, sun_y = 1.0f;
	// The 3x3 columns' topmost opaque blocks around the chunk (index
	// (dz + 1) * 3 + (dx + 1)), for shadows from above the light region.
	const ColumnTops *const *tops = nullptr;
};

struct Surface {
	std::vector<float> positions; // xyz, chunk-local
	std::vector<float> normals;   // xyz
	std::vector<float> uvs;       // uv
	// rgba: r = sky light, g = block light (0..1), b = corner occlusion (1 = none),
	// a = 1 - 0.5 (green varies: grass, leaves) - 0.25 (in a block's shadow).
	std::vector<float> colors;
	std::vector<int32_t> indices;

	bool empty() const { return indices.empty(); }
};

// neighbours: FACE_* order; nullptr means "outside the world" (above: air, below: solid).
// light: per-face light is taken from the cell in front of each face; nullptr = full light.
// hood: the 3x3x3 chunk neighbourhood (neighbourhood_index), or nullptr; fluid
// surfaces use its diagonal chunks so their corners match across chunk corners.
void mesh_chunk(const ChunkData &chunk, const ChunkData *const neighbours[FACE_COUNT],
		const ChunkData *const hood[27], const std::vector<BlockInfo> &blocks, const AtlasLayout &atlas, const LightRegion *light,
		const MeshOptions &options, Surface &opaque, Surface &cutout, Surface &fluid);

} // namespace gocube
