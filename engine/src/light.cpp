#include "light.h"

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

} // namespace

void compute_light(LightRegion &out, const ChunkData *const chunks[27], const ColumnTops *const tops[9],
		int chunk_y, const std::vector<BlockInfo> &blocks) {
	constexpr int S = LightRegion::SIZE;
	constexpr int M = LightRegion::MARGIN;
	constexpr int N = S * S * S;
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

	std::vector<int32_t> block_queue;
	const BlockId count = static_cast<BlockId>(blocks.size());
	for (int y = 0; y < S; y++) {
		for (int z = 0; z < S; z++) {
			for (int x = 0; x < S; x++) {
				const int i = LightRegion::index(x, y, z);
				const ChunkData *c = chunks[neighbourhood_index(chunk_offset[x], chunk_offset[y], chunk_offset[z])];
				if (!c) {
					opaque[i] = chunk_offset[y] < 0; // below the world: solid; above: air
					continue;
				}
				const BlockId id = c->get(local[x], local[y], local[z]);
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
