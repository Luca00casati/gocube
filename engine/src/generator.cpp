#include "generator.h"
#include "noise.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace gocube {

void Generator::configure(uint32_t seed, const GeneratorIds &ids, const std::vector<OreKind> &ores,
		const std::vector<TreeKind> &trees) {
	_seed = seed;
	_ids = ids;
	_ores = ores;
	_trees = trees;
}

void Generator::set_biomes(const std::vector<BiomeKind> &biomes) {
	_biomes = biomes;
}

// The biome used when none are configured (worlds from before biomes): the
// original grass land with every tree kind at its own chance.
const BiomeKind &Generator::biome(int index) const {
	if (!_biomes.empty()) {
		return _biomes[std::clamp(index, 0, int(_biomes.size()) - 1)];
	}
	static thread_local BiomeKind legacy;
	legacy.surface = _ids.grass;
	legacy.filler = _ids.dirt;
	legacy.height = AMPLITUDE;
	return legacy;
}

void Generator::climate(int x, int z, float &temperature, float &humidity) const {
	constexpr float F = 0.0016f, J = 0.045f;
	temperature = fbm2(x * F, z * F, _seed + 311u, 3) * 1.7f + fbm2(x * J, z * J, _seed + 313u, 2) * 0.05f;
	humidity = fbm2(x * F, z * F, _seed + 317u, 3) * 1.7f + fbm2(x * J, z * J, _seed + 319u, 2) * 0.05f;
}

int Generator::biome_at(int x, int z) const {
	if (_biomes.size() < 2) {
		return 0;
	}
	float t, h;
	climate(x, z, t, h);
	int best = 0;
	float best_d = INFINITY;
	for (size_t i = 0; i < _biomes.size(); i++) {
		const float dt = t - _biomes[i].temperature, dh = h - _biomes[i].humidity;
		const float d = dt * dt + dh * dh;
		if (d < best_d) {
			best_d = d;
			best = int(i);
		}
	}
	return best;
}

int Generator::terrain_height(int x, int z) const {
	int biome_index;
	return column(x, z, biome_index);
}

// Terrain height and biome of a column, from one climate lookup.
int Generator::column(int x, int z, int &biome_index) const {
	const float n = fbm2(x * HEIGHT_FREQUENCY, z * HEIGHT_FREQUENCY, _seed, 4);
	biome_index = 0;
	if (_biomes.empty()) {
		return static_cast<int>(std::floor(n * AMPLITUDE));
	}
	// Hill height and base blended by closeness in climate space; the biome is
	// the closest one.
	float t, h;
	climate(x, z, t, h);
	float wsum = 0.0f, amp = 0.0f, base = 0.0f, best = INFINITY;
	for (size_t i = 0; i < _biomes.size(); i++) {
		const BiomeKind &b = _biomes[i];
		const float dt = t - b.temperature, dh = h - b.humidity;
		const float d = dt * dt + dh * dh;
		if (d < best) {
			best = d;
			biome_index = int(i);
		}
		const float e = d + 0.02f;
		const float w = 1.0f / (e * e * e);
		wsum += w;
		amp += w * b.height;
		base += w * b.base;
	}
	return static_cast<int>(std::floor(n * amp / wsum + base / wsum));
}

int Generator::height_at(int x, int z) const {
	int level, bottom;
	const int h = terrain_height(x, z);
	if (lake_at(x, z, level, bottom)) {
		return bottom;
	}
	return h;
}

bool Generator::lake_at(int x, int z, int &level, int &bottom) const {
	if (_biomes.empty()) {
		return false;
	}
	auto cell_floor = [](int v) { return v >= 0 ? v / LAKE_CELL : -((-v + LAKE_CELL - 1) / LAKE_CELL); };
	const int ccx = cell_floor(x), ccz = cell_floor(z);
	for (int cz = ccz - 1; cz <= ccz + 1; cz++) {
		for (int cx = ccx - 1; cx <= ccx + 1; cx++) {
			const uint32_t r = hash_point(cx, 13, cz, _seed + 991u);
			const int px = cx * LAKE_CELL + 10 + int(r % uint32_t(LAKE_CELL - 20));
			const int pz = cz * LAKE_CELL + 10 + int((r >> 8) % uint32_t(LAKE_CELL - 20));
			const float radius = 4.0f + float((r >> 16) % 5u);
			const float dx = float(x - px), dz = float(z - pz);
			const float dist = std::sqrt(dx * dx + dz * dz);
			if (dist > radius * 1.3f) {
				continue; // cheap test first
			}
			if (int((r >> 20) % 100u) >= biome(biome_at(px, pz)).lakes) {
				continue;
			}
			const float edge = radius * (1.0f + 0.25f * noise2(x * 0.21f, z * 0.21f, _seed + 993u));
			if (dist >= edge) {
				continue;
			}
			// Only on fairly flat land above the sea.
			const int lv = terrain_height(px, pz);
			if (lv <= SEA_LEVEL + 2) {
				continue;
			}
			const int ri = int(radius);
			bool flat = true;
			const int probe[4][2] = { { ri, 0 }, { -ri, 0 }, { 0, ri }, { 0, -ri } };
			for (const auto &pr : probe) {
				flat = flat && std::abs(terrain_height(px + pr[0], pz + pr[1]) - lv) <= 3;
			}
			if (!flat) {
				continue;
			}
			level = lv;
			bottom = lv - std::max(1, int(std::round((1.0f - dist / edge) * 4.0f)));
			return true;
		}
	}
	return false;
}

bool Generator::is_cave(int x, int y, int z) const {
	const float s = 1.0f / CAVE_PERIOD;
	const float ys = y * CAVE_Y_SQUASH * s;
	const float a = noise3(x * s, ys, z * s, _seed + 101u);
	const float b = noise3(x * s, ys, z * s, _seed + 202u);
	if (std::fabs(a) + std::fabs(b) < CAVE_WIDTH) {
		return true;
	}
	// Big caverns deep down (new worlds).
	if (!_biomes.empty() && y < CAVERN_MAX_Y) {
		const float c = 1.0f / CAVERN_PERIOD;
		const float n = noise3(x * c, y * 1.5f * c, z * c, _seed + 404u);
		const float fade = std::clamp((CAVERN_MAX_Y - y) / 14.0f, 0.0f, 1.0f);
		return n * fade > 0.36f;
	}
	return false;
}

void Generator::trees_near(int x0, int z0, int x1, int z1, std::vector<Tree> &out) const {
	const int reach = _biomes.empty() ? 3 : TREE_REACH;
	auto cell_floor = [](int v) { return v >= 0 ? v / TREE_CELL : -((-v + TREE_CELL - 1) / TREE_CELL); };
	for (int cz = cell_floor(z0 - reach); cz <= cell_floor(z1 + reach); cz++) {
		for (int cx = cell_floor(x0 - reach); cx <= cell_floor(x1 + reach); cx++) {
			const uint32_t r = hash_point(cx, 7, cz, _seed + 77u);
			const int tx = cx * TREE_CELL + 1 + static_cast<int>((r >> 8) % (TREE_CELL - 2));
			const int tz = cz * TREE_CELL + 1 + static_cast<int>((r >> 12) % (TREE_CELL - 2));
			// Pick a tree kind by cumulative chance; most cells get none.
			int roll = static_cast<int>(r % 100u), kind = -1;
			if (_biomes.empty()) {
				for (size_t k = 0; k < _trees.size(); k++) {
					if (roll < _trees[k].chance) {
						kind = static_cast<int>(k);
						break;
					}
					roll -= _trees[k].chance;
				}
			} else {
				for (const auto &bt : biome(biome_at(tx, tz)).trees) {
					if (roll < bt.second) {
						kind = bt.first;
						break;
					}
					roll -= bt.second;
				}
			}
			if (kind < 0 || kind >= int(_trees.size())) {
				continue;
			}
			const TreeKind &tk = _trees[kind];
			int level, bottom;
			if (lake_at(tx, tz, level, bottom)) {
				continue;
			}
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
	const bool v2 = !_biomes.empty();

	// Column heights, lakes and biomes for this chunk.
	int heights[CHUNK_AREA];
	int lake_level[CHUNK_AREA]; // INT_MIN: no lake
	int biomes[CHUNK_AREA];
	int min_h = 1 << 30, max_h = -(1 << 30);
	for (int z = 0; z < CHUNK; z++) {
		for (int x = 0; x < CHUNK; x++) {
			const int i = z * CHUNK + x;
			int biome_index;
			int h = column(ox + x, oz + z, biome_index);
			int level, bottom;
			lake_level[i] = INT32_MIN;
			if (lake_at(ox + x, oz + z, level, bottom)) {
				lake_level[i] = level;
				h = bottom;
			}
			heights[i] = h;
			biomes[i] = biome_index;
			min_h = std::min(min_h, h);
			max_h = std::max(max_h, std::max(h, lake_level[i]));
		}
	}

	const int top_y = oy + CHUNK - 1;
	const int tree_room = v2 ? 18 : 12;
	const bool above_everything = oy > std::max(max_h, SEA_LEVEL) + tree_room;
	if (above_everything) {
		return; // uniform air
	}
	const int cave_min = v2 ? CAVE_MIN_Y : -60;
	const bool below_caves = top_y < cave_min && top_y < min_h - DIRT_DEPTH;
	if (below_caves) {
		chunk.uniform_value = _ids.stone; // all stone, apart from ore veins
		place_ores(chunk, ox, oy, oz);
		chunk.compact();
		return;
	}

	for (int z = 0; z < CHUNK; z++) {
		for (int x = 0; x < CHUNK; x++) {
			const int i = z * CHUNK + x;
			const int h = heights[i];
			const int lake = lake_level[i];
			const BiomeKind &bm = biome(biomes[i]);
			const bool beach = h <= SEA_LEVEL + 1 && lake == INT32_MIN;
			const bool caves_allowed_column = h > SEA_LEVEL + 2 && lake == INT32_MIN;
			const int wx = ox + x, wz = oz + z;
			const int water_top = lake != INT32_MIN ? lake : SEA_LEVEL;
			for (int y = 0; y < CHUNK; y++) {
				const int wy = oy + y;
				const int d = wy - h;
				BlockId b;
				if (d > 0) {
					b = wy <= water_top ? _ids.water : AIR;
					if (b == _ids.water && wy == water_top && bm.frozen && _ids.ice) {
						b = _ids.ice;
					}
				} else if (d == 0) {
					b = beach || lake != INT32_MIN ? (bm.filler == _ids.dirt || !bm.filler ? _ids.sand : bm.filler) : bm.surface;
				} else if (d > -bm.filler_depth) {
					b = beach ? _ids.sand : bm.filler;
				} else if (bm.under && d > -(bm.filler_depth + bm.under_depth)) {
					b = bm.under;
				} else {
					b = _ids.stone;
				}
				// Caves: on land columns, or deep under the sea floor, not too deep.
				if (d <= 0 && wy > cave_min && (caves_allowed_column || wy < h - 5) && is_cave(wx, wy, wz)) {
					b = v2 && wy <= LAVA_LEVEL && _ids.lava ? _ids.lava : AIR;
				}
				if (b != AIR) {
					chunk.set(x, y, z, b);
				}
			}
			// Ground plants: tall grass, flowers, dead bushes.
			if (v2 && lake == INT32_MIN && !beach && h + 1 >= oy && h + 1 < oy + CHUNK && h >= oy &&
					chunk.get(x, h - oy, z) == bm.surface && !bm.plants.empty()) {
				int roll = int(hash_point(wx, 5, wz, _seed + 55u) % 1000u);
				for (const auto &pl : bm.plants) {
					if (roll < pl.second) {
						chunk.set(x, h + 1 - oy, z, pl.first);
						break;
					}
					roll -= pl.second;
				}
			}
		}
	}

	place_ores(chunk, ox, oy, oz);

	// Trees can cross chunk borders, so every chunk places the parts it contains.
	if (oy <= max_h + tree_room && top_y >= SEA_LEVEL + 2) {
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
	const TreeKind &k = _trees[t.kind];
	const int base = t.ground + 1;
	auto put = [&](int wx, int wy, int wz, BlockId id, bool only_air) {
		const int x = wx - ox, y = wy - oy, z = wz - oz;
		if (id == AIR || x < 0 || y < 0 || z < 0 || x >= CHUNK || y >= CHUNK || z >= CHUNK) {
			return;
		}
		const BlockId here = chunk.get(x, y, z);
		if (only_air && here != AIR) {
			return;
		}
		chunk.set(x, y, z, id);
	};
	auto leaf = [&](int x, int y, int z) { put(x, y, z, k.leaves, true); };
	// A rough ball of leaves (a little ragged, from the position hash).
	auto blob = [&](int cx, int cy, int cz, float r) {
		const int ri = int(std::ceil(r));
		for (int dy = -ri; dy <= ri; dy++) {
			for (int dz = -ri; dz <= ri; dz++) {
				for (int dx = -ri; dx <= ri; dx++) {
					const float d = float(dx * dx + dz * dz) + dy * dy * 1.5f;
					const float jitter = (hash_point(cx + dx, cy + dy, cz + dz, _seed + 61u) % 100u) / 100.0f;
					if (d <= r * r - jitter * r) {
						leaf(cx + dx, cy + dy, cz + dz);
					}
				}
			}
		}
	};
	const uint32_t h = hash_point(t.x, t.ground, t.z, _seed + 63u);
	switch (k.style) {
		case TREE_CACTUS: {
			for (int dy = 0; dy < t.trunk; dy++) {
				put(t.x, base + dy, t.z, k.log, true);
			}
			return;
		}
		case TREE_SPRUCE: {
			// A tall cone: rings that widen downwards, with a step back every
			// other layer so it looks layered.
			const int top = base + t.trunk;
			leaf(t.x, top, t.z);
			leaf(t.x, top + 1, t.z);
			for (int y = top - 1; y >= base + 2; y--) {
				const int i = top - y;
				int r = std::min(3, 1 + i / 3);
				if (i % 2 == 0) {
					r = std::max(1, r - 1);
				}
				for (int dz = -r; dz <= r; dz++) {
					for (int dx = -r; dx <= r; dx++) {
						if (dx * dx + dz * dz <= r * r + (r > 1 ? 1 : 0)) {
							leaf(t.x + dx, y, t.z + dz);
						}
					}
				}
			}
			for (int dy = 0; dy < t.trunk; dy++) {
				put(t.x, base + dy, t.z, k.log, false);
			}
			return;
		}
		case TREE_BIG_OAK: {
			// A tall trunk with 2-3 branches, each ending in a ball of leaves,
			// and a big crown on top.
			const int branches = 2 + int(h % 2u);
			for (int b = 0; b < branches; b++) {
				const float angle = (h >> (4 + b * 5)) % 360u * 0.01745f + b * 2.1f;
				const int start = base + t.trunk / 2 + b;
				float bx = float(t.x), bz = float(t.z);
				int by = start;
				for (int s = 1; s <= 3; s++) {
					bx += std::cos(angle);
					bz += std::sin(angle);
					if (s % 2 == 0) {
						by++;
					}
					put(int(std::round(bx)), by, int(std::round(bz)), k.log, false);
				}
				blob(int(std::round(bx)), by + 1, int(std::round(bz)), 2.3f);
			}
			blob(t.x, base + t.trunk, t.z, 2.8f);
			for (int dy = 0; dy < t.trunk; dy++) {
				put(t.x, base + dy, t.z, k.log, false);
			}
			return;
		}
		case TREE_BIRCH: {
			// Slim: two wide layers, then a narrow top.
			for (int dy = t.trunk - 3; dy <= t.trunk + 1; dy++) {
				const int radius = dy < t.trunk - 1 ? 2 : 1;
				for (int dz = -radius; dz <= radius; dz++) {
					for (int dx = -radius; dx <= radius; dx++) {
						if (std::abs(dx) == radius && std::abs(dz) == radius && (radius == 2 || dy > t.trunk)) {
							continue; // round off the corners
						}
						leaf(t.x + dx, base + dy, t.z + dz);
					}
				}
			}
			for (int dy = 0; dy < t.trunk; dy++) {
				put(t.x, base + dy, t.z, k.log, false);
			}
			return;
		}
		default:
			break;
	}
	// Oak: two wide layers around the top of the trunk, two narrow ones above.
	for (int dy = t.trunk - 2; dy < t.trunk + 2; dy++) {
		const int radius = dy < t.trunk ? 2 : 1;
		for (int dz = -radius; dz <= radius; dz++) {
			for (int dx = -radius; dx <= radius; dx++) {
				if (radius == 2 && std::abs(dx) == 2 && std::abs(dz) == 2) {
					continue; // round off the corners
				}
				leaf(t.x + dx, base + dy, t.z + dz);
			}
		}
	}
	for (int dy = 0; dy < t.trunk; dy++) {
		put(t.x, base + dy, t.z, k.log, false);
	}
}

} // namespace gocube
