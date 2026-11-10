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

// How a block is drawn and collides.
enum Shape : uint8_t {
	SHAPE_CUBE,  // a full cube (the fast path)
	SHAPE_BOXES, // a list of boxes inside the cell (slabs, stairs, torches, doors...)
	SHAPE_CROSS, // two crossed quads (plants)
	SHAPE_FENCE, // a post with rails towards fences and solid blocks next to it
};

// An axis-aligned box in block-local coordinates (0..1; collision may reach
// higher, e.g. fences are 1.5 tall).
struct Box {
	float mn[3];
	float mx[3];
	float ty = 0.0f; // texture offset up: side faces are textured as if the box sat ty lower
};

struct BlockInfo {
	bool solid = false;   // collides
	bool opaque = false;  // hides neighbour faces, blocks skylight
	bool fluid = false;   // drawn on the transparent fluid surface
	uint8_t emit = 0;     // block light it gives off (0..15)
	uint8_t fluid_level = 8; // fluids: 8 = source (full), 1..7 = flowing (lower surface)
	bool random_rotation = false; // top/bottom texture turned 0/90/180/270 degrees by position
	bool tint = false;    // green parts vary in colour across the land (grass, leaves)
	uint8_t shape = SHAPE_CUBE;
	std::vector<Box> model;       // SHAPE_BOXES: what is drawn
	std::vector<Box> collision;   // what movement bumps into (empty: nothing)
	std::array<int, FACE_COUNT> tiles{}; // atlas tile per face
};

// Fence geometry. Connections: towards -z (north), +x (east), +z (south), -x (west).
inline void fence_boxes(bool north, bool east, bool south, bool west, bool for_collision, std::vector<Box> &out) {
	const float top = for_collision ? 1.5f : 1.0f;
	const float a = 6.0f / 16.0f, b = 10.0f / 16.0f;
	out.push_back({ { a, 0.0f, a }, { b, top, b } });
	const bool dirs[4] = { north, east, south, west };
	for (int d = 0; d < 4; d++) {
		if (!dirs[d]) {
			continue;
		}
		// Extent along the connection: from the post to the cell edge.
		float lo[3], hi[3];
		const float w0 = for_collision ? a : 7.0f / 16.0f, w1 = for_collision ? b : 9.0f / 16.0f;
		lo[0] = w0; hi[0] = w1; lo[2] = w0; hi[2] = w1;
		if (d == 0) { lo[2] = 0.0f; hi[2] = a; }
		if (d == 1) { lo[0] = b; hi[0] = 1.0f; }
		if (d == 2) { lo[2] = b; hi[2] = 1.0f; }
		if (d == 3) { lo[0] = 0.0f; hi[0] = a; }
		if (for_collision) {
			out.push_back({ { lo[0], 0.0f, lo[2] }, { hi[0], top, hi[2] } });
		} else {
			for (float y0 : { 6.0f / 16.0f, 12.0f / 16.0f }) {
				out.push_back({ { lo[0], y0, lo[2] }, { hi[0], y0 + 3.0f / 16.0f, hi[2] } });
			}
		}
	}
}

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
