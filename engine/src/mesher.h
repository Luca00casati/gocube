// Turns a chunk (plus its 6 neighbours, for faces on the border) into vertex
// arrays: one opaque surface and one fluid surface. Pure C++, thread-safe.
#pragma once

#include "chunk.h"

#include <vector>

namespace gocube {

struct AtlasLayout {
	int cols = 1, rows = 1; // tiles in the atlas grid
	int cell = 4;           // each tile owns a cell x cell area of repeated copies
	int face_x = 1, face_y = 1; // which copy inside the cell faces use
};

struct Surface {
	std::vector<float> positions; // xyz, chunk-local
	std::vector<float> normals;   // xyz
	std::vector<float> uvs;       // uv
	std::vector<float> colors;    // rgba (light; white for now)
	std::vector<int32_t> indices;

	bool empty() const { return indices.empty(); }
};

// neighbours: FACE_* order; nullptr means "outside the world" (above: air, below: solid).
void mesh_chunk(const ChunkData &chunk, const ChunkData *const neighbours[FACE_COUNT],
		const std::vector<BlockInfo> &blocks, const AtlasLayout &atlas,
		Surface &opaque, Surface &fluid);

} // namespace gocube
