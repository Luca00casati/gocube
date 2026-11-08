// Turns a chunk (plus its 6 neighbours, for faces on the border) into vertex
// arrays: one opaque surface and one fluid surface. Pure C++, thread-safe.
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
};

struct Surface {
	std::vector<float> positions; // xyz, chunk-local
	std::vector<float> normals;   // xyz
	std::vector<float> uvs;       // uv
	std::vector<float> colors;    // rgba: r = sky light, g = block light (0..1), b = corner occlusion (1 = none)
	std::vector<int32_t> indices;

	bool empty() const { return indices.empty(); }
};

// neighbours: FACE_* order; nullptr means "outside the world" (above: air, below: solid).
// light: per-face light is taken from the cell in front of each face; nullptr = full light.
void mesh_chunk(const ChunkData &chunk, const ChunkData *const neighbours[FACE_COUNT],
		const std::vector<BlockInfo> &blocks, const AtlasLayout &atlas, const LightRegion *light,
		const MeshOptions &options, Surface &opaque, Surface &fluid);

} // namespace gocube
