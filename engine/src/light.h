// Block-by-block light: sky light (0..15, from the open sky) and block light
// (0..15, from glowing blocks). Computed for one chunk at a time over the chunk
// plus a margin of LIGHT_MAX blocks, which is as far as light can travel, so a
// chunk's light only depends on its 27-chunk neighbourhood. Thread-safe.
#pragma once

#include "chunk.h"

#include <array>
#include <cstdint>
#include <vector>

namespace gocube {

constexpr int LIGHT_MAX = 15;

// World y of the topmost opaque block for each (x, z) of a chunk column, or NO_TOP.
using ColumnTops = std::array<int16_t, CHUNK_AREA>;
constexpr int16_t NO_TOP = -32768;

// Index into the 3x3x3 chunk neighbourhood; (0, 0, 0) is the chunk itself.
inline int neighbourhood_index(int dx, int dy, int dz) {
	return ((dy + 1) * 3 + (dz + 1)) * 3 + (dx + 1);
}

struct LightRegion {
	static constexpr int MARGIN = LIGHT_MAX;
	static constexpr int SIZE = CHUNK + 2 * MARGIN;

	std::vector<uint8_t> sky, block, opaque;

	static inline int index(int x, int y, int z) {
		return (y * SIZE + z) * SIZE + x;
	}
	// Chunk-local coordinates, valid from -MARGIN to CHUNK + MARGIN - 1.
	inline uint8_t sky_at(int x, int y, int z) const {
		return sky[index(x + MARGIN, y + MARGIN, z + MARGIN)];
	}
	inline uint8_t block_at(int x, int y, int z) const {
		return block[index(x + MARGIN, y + MARGIN, z + MARGIN)];
	}
	inline bool opaque_at(int x, int y, int z) const {
		return opaque[index(x + MARGIN, y + MARGIN, z + MARGIN)] != 0;
	}
};

// chunks: 27 entries (neighbourhood_index); nullptr = outside the world's
// vertical range (above: open air, below: solid).
// tops: 9 entries, index (dz + 1) * 3 + (dx + 1), for the surrounding columns.
void compute_light(LightRegion &out, const ChunkData *const chunks[27], const ColumnTops *const tops[9],
		int chunk_y, const std::vector<BlockInfo> &blocks);

// Topmost opaque local y per column inside one chunk, or -1.
void chunk_local_tops(const ChunkData &chunk, const std::vector<BlockInfo> &blocks, std::array<int8_t, CHUNK_AREA> &out);

} // namespace gocube
