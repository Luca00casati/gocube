#include "generator.h"
#include "noise.h"

#include <algorithm>
#include <cmath>

namespace gocube {

void Generator::configure(uint32_t seed, const GeneratorIds &ids, const std::vector<OreKind> &ores,
		const std::vector<TreeKind> &trees) {
	_seed = seed;
	_ids = ids;
	_ores = ores;
	_trees = trees;
}

int Generator::height_at(int x, int z) const {
	const float n = fbm2(x * HEIGHT_FREQUENCY, z * HEIGHT_FREQUENCY, _seed, 4);
	return static_cast<int>(std::floor(n * AMPLITUDE));
}

bool Generator::is_cave(int x, int y, int z) const {
	const float s = 1.0f / CAVE_PERIOD;
	const float ys = y * CAVE_Y_SQUASH * s;
	const float a = noise3(x * s, ys, z * s, _seed + 101u);
	const float b = noise3(x * s, ys, z * s, _seed + 202u);
	return std::fabs(a) + std::fabs(b) < CAVE_WIDTH;
}

void Generator::trees_near(int x0, int z0, int x1, int z1, std::vector<Tree> &out) const {
	const int reach = 3; // leaves extend 2 blocks from the trunk
	auto cell_floor = [](int v) { return v >= 0 ? v / TREE_CELL : -((-v + TREE_CELL - 1) / TREE_CELL); };
	for (int cz = cell_floor(z0 - reach); cz <= cell_floor(z1 + reach); cz++) {
		for (int cx = cell_floor(x0 - reach); cx <= cell_floor(x1 + reach); cx++) {
			const uint32_t r = hash_point(cx, 7, cz, _seed + 77u);
			// Pick a tree kind by cumulative chance; most cells get none.
			int roll = static_cast<int>(r % 100u), kind = -1;
			for (size_t k = 0; k < _trees.size(); k++) {
				if (roll < _trees[k].chance) {
					kind = static_cast<int>(k);
					break;
				}
				roll -= _trees[k].chance;
			}
			if (kind < 0) {
				continue;
			}
			const TreeKind &tk = _trees[kind];
			const int tx = cx * TREE_CELL + 1 + static_cast<int>((r >> 8) % (TREE_CELL - 2));
			const int tz = cz * TREE_CELL + 1 + static_cast<int>((r >> 12) % (TREE_CELL - 2));
			const int ground = height_at(tx, tz);
			if (ground <= SEA_LEVEL + 1 || is_cave(tx, ground, tz)) {
				continue; // beach, sea or a cave mouth
			}
			const int span = std::max(1, tk.max_trunk - tk.min_trunk + 1);
			out.push_back(Tree{ tx, tz, ground, tk.min_trunk + static_cast<int>((r >> 16) % uint32_t(span)), kind });
		}
	}
}

void Generator::generate(ChunkData &chunk, int ox, int oy, int oz) const {
	chunk = ChunkData();

	// Column heights for this chunk.
	int heights[CHUNK_AREA];
	int min_h = 1 << 30, max_h = -(1 << 30);
	for (int z = 0; z < CHUNK; z++) {
		for (int x = 0; x < CHUNK; x++) {
			const int h = height_at(ox + x, oz + z);
			heights[z * CHUNK + x] = h;
			min_h = std::min(min_h, h);
			max_h = std::max(max_h, h);
		}
	}

	const int top_y = oy + CHUNK - 1;
	const bool above_everything = oy > std::max(max_h, SEA_LEVEL) + 12; // +12: tree tops
	if (above_everything) {
		return; // uniform air
	}
	const bool below_caves = top_y < CAVE_MIN_Y && top_y < min_h - DIRT_DEPTH;
	if (below_caves) {
		chunk.uniform_value = _ids.stone; // all stone, apart from ore veins
		place_ores(chunk, ox, oy, oz);
		chunk.compact();
		return;
	}

	for (int z = 0; z < CHUNK; z++) {
		for (int x = 0; x < CHUNK; x++) {
			const int h = heights[z * CHUNK + x];
			const bool beach = h <= SEA_LEVEL + 1;
			const bool caves_allowed_column = h > SEA_LEVEL + 2;
			const int wx = ox + x, wz = oz + z;
			for (int y = 0; y < CHUNK; y++) {
				const int wy = oy + y;
				const int d = wy - h;
				BlockId b;
				if (d > 0) {
					b = wy <= SEA_LEVEL ? _ids.water : AIR;
				} else if (d == 0) {
					b = beach ? _ids.sand : _ids.grass;
				} else if (d > -DIRT_DEPTH) {
					b = beach ? _ids.sand : _ids.dirt;
				} else {
					b = _ids.stone;
				}
				// Caves: on land columns, or deep under the sea floor, not too deep.
				if (d <= 0 && wy > CAVE_MIN_Y && (caves_allowed_column || wy < h - 5) && is_cave(wx, wy, wz)) {
					b = AIR;
				}
				if (b != AIR) {
					chunk.set(x, y, z, b);
				}
			}
		}
	}

	place_ores(chunk, ox, oy, oz);

	// Trees can cross chunk borders, so every chunk places the parts it contains.
	if (oy <= max_h + 10 && top_y >= SEA_LEVEL + 2) {
		std::vector<Tree> trees;
		trees_near(ox, oz, ox + CHUNK, oz + CHUNK, trees);
		for (const Tree &t : trees) {
			place_tree(chunk, ox, oy, oz, t);
		}
	}
	chunk.compact();
}

// Veins start in some chunk and wander up to ~max_size blocks, so they can reach
// into neighbours: each chunk replays the veins of its 3x3x3 neighbourhood and
// keeps the blocks that land inside it. Only stone is replaced.
void Generator::place_ores(ChunkData &chunk, int ox, int oy, int oz) const {
	if (_ores.empty() || (chunk.uniform && chunk.uniform_value == AIR)) {
		return;
	}
	static const int STEPS[6][3] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
	const int ccx = ox / CHUNK, ccy = oy / CHUNK, ccz = oz / CHUNK; // origins are multiples of CHUNK
	for (int dy = -1; dy <= 1; dy++) {
		for (int dz = -1; dz <= 1; dz++) {
			for (int dx = -1; dx <= 1; dx++) {
				const int sx = (ccx + dx) * CHUNK, sy = (ccy + dy) * CHUNK, sz = (ccz + dz) * CHUNK;
				for (size_t k = 0; k < _ores.size(); k++) {
					const OreKind &ore = _ores[k];
					if (sy > ore.max_y || sy + CHUNK <= ore.min_y) {
						continue;
					}
					for (int v = 0; v < ore.veins_per_chunk; v++) {
						uint32_t h = hash_point(ccx + dx, (ccy + dy) * 64 + v, ccz + dz, _seed + ore.salt);
						int x = sx + int(h % CHUNK), y = sy + int((h >> 5) % CHUNK), z = sz + int((h >> 10) % CHUNK);
						if (y < ore.min_y || y > ore.max_y) {
							continue;
						}
						const int size = ore.min_size + int((h >> 15) % uint32_t(ore.max_size - ore.min_size + 1));
						for (int s = 0; s < size; s++) {
							const int lx = x - ox, ly = y - oy, lz = z - oz;
							if (lx >= 0 && ly >= 0 && lz >= 0 && lx < CHUNK && ly < CHUNK && lz < CHUNK &&
									chunk.get(lx, ly, lz) == ore.replaces) {
								chunk.set(lx, ly, lz, ore.id);
							}
							h = hash_point(x, y, z, h);
							const int *step = STEPS[h % 6];
							x += step[0];
							y += step[1];
							z += step[2];
						}
					}
				}
			}
		}
	}
}

void Generator::place_tree(ChunkData &chunk, int ox, int oy, int oz, const Tree &t) const {
	const int base = t.ground + 1;
	auto put = [&](int wx, int wy, int wz, BlockId id, bool only_air) {
		const int x = wx - ox, y = wy - oy, z = wz - oz;
		if (x < 0 || y < 0 || z < 0 || x >= CHUNK || y >= CHUNK || z >= CHUNK) {
			return;
		}
		if (only_air && chunk.get(x, y, z) != AIR) {
			return;
		}
		chunk.set(x, y, z, id);
	};
	// Leaves: two wide layers around the top of the trunk, two narrow ones above.
	for (int dy = t.trunk - 2; dy < t.trunk + 2; dy++) {
		const int radius = dy < t.trunk ? 2 : 1;
		for (int dz = -radius; dz <= radius; dz++) {
			for (int dx = -radius; dx <= radius; dx++) {
				if (radius == 2 && std::abs(dx) == 2 && std::abs(dz) == 2) {
					continue; // round off the corners
				}
				put(t.x + dx, base + dy, t.z + dz, _trees[t.kind].leaves, true);
			}
		}
	}
	for (int dy = 0; dy < t.trunk; dy++) {
		put(t.x, base + dy, t.z, _trees[t.kind].log, false);
	}
}

} // namespace gocube
