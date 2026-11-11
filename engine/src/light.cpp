#include "light.h"

#include <algorithm>

namespace gocube {

namespace {

// Breadth-first flood: each step into a non-opaque cell loses one level.
void flood(std::vector<uint8_t> &light, std::vector<int32_t> &queue, const std::vector<uint8_t> &opaque) {
	constexpr int S = LightRegion::SIZE;
	constexpr int SS = S * S;
	size_t head = 0;
	while (head < queue.size()) {
		const int32_t i = queue[head++];
		const uint8_t l = light[i];
		if (l <= 1) {
			continue;
		}
		const uint8_t next = l - 1;
		const int x = i % S;
		const int z = (i / S) % S;
		const int y = i / SS;
		auto visit = [&](int32_t j) {
			if (!opaque[j] && light[j] < next) {
				light[j] = next;
				queue.push_back(j);
			}
		};
		if (x > 0) visit(i - 1);
		if (x < S - 1) visit(i + 1);
		if (z > 0) visit(i - S);
		if (z < S - 1) visit(i + S);
		if (y > 0) visit(i - SS);
		if (y < S - 1) visit(i + SS);
	}
}

// Whether the region around chunk_y is all open sky (see compute_light).
bool open_sky(const ChunkData *const chunks[27], const ColumnTops *const tops[9], int chunk_y,
		const std::vector<BlockInfo> &blocks) {
	const BlockId count = static_cast<BlockId>(blocks.size());
	for (int dy = -1; dy <= 1; dy++) {
		for (int dz = -1; dz <= 1; dz++) {
			for (int dx = -1; dx <= 1; dx++) {
				const ChunkData *c = chunks[neighbourhood_index(dx, dy, dz)];
				if (!c) {
					if (dy < 0) {
						return false; // below the world: solid
					}
					continue; // above it: air
				}
				if (!c->uniform || c->uniform_value >= count) {
					return false;
				}
				const BlockInfo &b = blocks[c->uniform_value];
				if (b.opaque || b.emit > 0) {
					return false;
				}
			}
		}
	}
	const int bottom = chunk_y * CHUNK - LightRegion::MARGIN; // world y of the region's lowest cells
	for (int i = 0; i < 9; i++) {
		if (!tops[i]) {
			continue;
		}
		for (int16_t top : *tops[i]) {
			if (top >= bottom) {
				return false;
			}
		}
	}
	return true;
}

} // namespace

void compute_light(LightRegion &out, const ChunkData *const chunks[27], const ColumnTops *const tops[9],
		int chunk_y, const std::vector<BlockInfo> &blocks) {
	constexpr int S = LightRegion::SIZE;
	constexpr int M = LightRegion::MARGIN;
	constexpr int N = S * S * S;
	// Open sky (the common case above the land): nothing opaque or glowing in
	// the whole neighbourhood and every column's top below the region, so
	// sky light is full everywhere and there is no block light to spread.
	if (open_sky(chunks, tops, chunk_y, blocks)) {
		out.sky.assign(N, LIGHT_MAX);
		out.block.assign(N, 0);
		out.opaque.assign(N, 0);
		return;
	}
	out.sky.assign(N, 0);
	out.block.assign(N, 0);
	out.opaque.assign(N, 0);
	std::vector<uint8_t> &opaque = out.opaque;

	// Region coordinate -> (which neighbour chunk, local coordinate), per axis.
	int chunk_offset[S], local[S];
	for (int r = 0; r < S; r++) {
		const int l = r - M;
		chunk_offset[r] = l < 0 ? -1 : (l >= CHUNK ? 1 : 0);
		local[r] = l - chunk_offset[r] * CHUNK;
	}

	// Opaque cells and glowing blocks, one neighbour chunk's part of the region
	// at a time (a uniform one in whole rows). Region range per chunk offset:
	// -1: [0, M), 0: [M, M + CHUNK), 1: [M + CHUNK, S).
	std::vector<int32_t> block_queue;
	const BlockId count = static_cast<BlockId>(blocks.size());
	auto lo = [](int o) { return o < 0 ? 0 : (o == 0 ? M : M + CHUNK); };
	auto hi = [](int o) { return o < 0 ? M : (o == 0 ? M + CHUNK : S); };
	for (int oy = -1; oy <= 1; oy++) {
		for (int oz = -1; oz <= 1; oz++) {
			for (int ox = -1; ox <= 1; ox++) {
				const ChunkData *c = chunks[neighbourhood_index(ox, oy, oz)];
				const int x0 = lo(ox), x1 = hi(ox);
				if (!c || c->uniform) {
					// Below the world: solid; above it: air.
					const BlockId id = c ? c->uniform_value : AIR;
					const bool solid = c ? (id < count && blocks[id].opaque) : oy < 0;
					const uint8_t emit = c && id < count ? blocks[id].emit : 0;
					if (!solid && emit == 0) {
						continue; // (already clear)
					}
					for (int y = lo(oy); y < hi(oy); y++) {
						for (int z = lo(oz); z < hi(oz); z++) {
							const int row = LightRegion::index(x0, y, z);
							if (solid) {
								std::fill(opaque.begin() + row, opaque.begin() + row + (x1 - x0), uint8_t(1));
							}
							if (emit > 0) {
								for (int i = row; i < row + (x1 - x0); i++) {
									out.block[i] = emit;
									block_queue.push_back(i);
								}
							}
						}
					}
					continue;
				}
				for (int y = lo(oy); y < hi(oy); y++) {
					for (int z = lo(oz); z < hi(oz); z++) {
						const BlockId *src = &c->blocks[ChunkData::index(local[x0], local[y], local[z])];
						int i = LightRegion::index(x0, y, z);
						for (int x = x0; x < x1; x++, i++, src++) {
							const BlockId id = *src;
							if (id >= count) {
								continue;
							}
							const BlockInfo &b = blocks[id];
							opaque[i] = b.opaque;
							if (b.emit > 0) {
								out.block[i] = b.emit;
								block_queue.push_back(i);
							}
						}
					}
				}
			}
		}
	}

	// Sky: full light straight down each column until its topmost opaque block.
	std::vector<int32_t> sky_queue;
	sky_queue.reserve(N / 4);
	for (int z = 0; z < S; z++) {
		for (int x = 0; x < S; x++) {
			const ColumnTops *t = tops[(chunk_offset[z] + 1) * 3 + (chunk_offset[x] + 1)];
			const int top = t ? (*t)[local[z] * CHUNK + local[x]] : NO_TOP;
			for (int y = S - 1; y >= 0; y--) {
				const int wy = chunk_y * CHUNK + y - M;
				const int i = LightRegion::index(x, y, z);
				if (wy <= top || opaque[i]) {
					break;
				}
				out.sky[i] = LIGHT_MAX;
				sky_queue.push_back(i);
			}
		}
	}
	flood(out.sky, sky_queue, opaque);
	flood(out.block, block_queue, opaque);
}

void chunk_local_tops(const ChunkData &chunk, const std::vector<BlockInfo> &blocks, std::array<int8_t, CHUNK_AREA> &out) {
	const BlockId count = static_cast<BlockId>(blocks.size());
	auto is_opaque = [&](BlockId id) { return id < count && blocks[id].opaque; };
	if (chunk.uniform) {
		out.fill(is_opaque(chunk.uniform_value) ? CHUNK - 1 : -1);
		return;
	}
	for (int z = 0; z < CHUNK; z++) {
		for (int x = 0; x < CHUNK; x++) {
			int8_t top = -1;
			for (int y = CHUNK - 1; y >= 0; y--) {
				if (is_opaque(chunk.get(x, y, z))) {
					top = static_cast<int8_t>(y);
					break;
				}
			}
			out[z * CHUNK + x] = top;
		}
	}
}

} // namespace gocube
