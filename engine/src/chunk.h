// Chunk storage and block type table shared by the generator, mesher and world.
#pragma once

#include <array>
#include <cstdint>
#include <vector>

namespace gocube {

constexpr int CHUNK = 32;
constexpr int CHUNK_AREA = CHUNK * CHUNK;
constexpr int CHUNK_VOLUME = CHUNK * CHUNK * CHUNK;

using BlockId = uint16_t;
constexpr BlockId AIR = 0;

// Face order used everywhere: +X, -X, +Y, -Y, +Z, -Z.
enum Face { FACE_PX, FACE_NX, FACE_PY, FACE_NY, FACE_PZ, FACE_NZ, FACE_COUNT };

struct BlockInfo {
	bool solid = false;   // collides
	bool opaque = false;  // hides neighbour faces, blocks skylight
	bool fluid = false;   // drawn on the transparent fluid surface
	uint8_t emit = 0;     // block light it gives off (0..15)
	std::array<int, FACE_COUNT> tiles{}; // atlas tile per face
};

// 32^3 block ids. Uniform chunks (all air, all stone...) store a single value.
struct ChunkData {
	bool uniform = true;
	BlockId uniform_value = AIR;
	std::vector<BlockId> blocks;

	static inline int index(int x, int y, int z) {
		return (y * CHUNK + z) * CHUNK + x;
	}

	inline BlockId get(int x, int y, int z) const {
		return uniform ? uniform_value : blocks[index(x, y, z)];
	}

	inline void set(int x, int y, int z, BlockId v) {
		if (uniform) {
			if (v == uniform_value) {
				return;
			}
			blocks.assign(CHUNK_VOLUME, uniform_value);
			uniform = false;
		}
		blocks[index(x, y, z)] = v;
	}

	// Collapse back to a single value if every block is the same.
	void compact() {
		if (uniform) {
			return;
		}
		const BlockId first = blocks[0];
		for (BlockId b : blocks) {
			if (b != first) {
				return;
			}
		}
		uniform = true;
		uniform_value = first;
		blocks.clear();
		blocks.shrink_to_fit();
	}
};

} // namespace gocube
