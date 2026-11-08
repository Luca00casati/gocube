// World generation: hills, beaches, sea, caves and trees.
// All methods are const and thread-safe once configured.
#pragma once

#include "chunk.h"

#include <vector>

namespace gocube {

// Terrain blocks the base shape is made of.
struct GeneratorIds {
	BlockId stone = 0, dirt = 0, grass = 0, sand = 0, water = 0;
};

// One kind of ore (defined by mods): veins are random walks through `replaces`.
struct OreKind {
	BlockId id;
	BlockId replaces;        // usually stone
	int min_y, max_y;        // vein starting points lie in this range
	int veins_per_chunk;     // attempts per 32^3 chunk
	int min_size, max_size;  // blocks per vein (before clipping)
	uint32_t salt;           // from the ore's id, so adding mods doesn't move veins
};

// One kind of tree (defined by mods).
struct TreeKind {
	BlockId log, leaves;
	int min_trunk, max_trunk;
	int chance;              // percent of tree cells that get this tree
};

struct Tree {
	int x, z, ground, trunk;
	int kind;                // index into the tree kinds
};

class Generator {
public:
	static constexpr float AMPLITUDE = 24.0f;
	static constexpr float HEIGHT_FREQUENCY = 0.008f;
	static constexpr int DIRT_DEPTH = 3;
	static constexpr int SEA_LEVEL = -4;
	static constexpr float CAVE_WIDTH = 0.11f;
	static constexpr float CAVE_PERIOD = 48.0f;
	static constexpr float CAVE_Y_SQUASH = 1.6f;
	static constexpr int CAVE_MIN_Y = -60;
	static constexpr int TREE_CELL = 8;


	void configure(uint32_t seed, const GeneratorIds &ids, const std::vector<OreKind> &ores,
			const std::vector<TreeKind> &trees);

	// Surface height (y of the topmost terrain block) at a column.
	int height_at(int x, int z) const;
	bool is_cave(int x, int y, int z) const;
	// Trees whose leaves may reach columns [x0, x1) x [z0, z1).
	void trees_near(int x0, int z0, int x1, int z1, std::vector<Tree> &out) const;

	// Fills a chunk whose minimum corner is `origin` (in blocks).
	void generate(ChunkData &chunk, int ox, int oy, int oz) const;

private:
	uint32_t _seed = 0;
	GeneratorIds _ids;

	std::vector<OreKind> _ores;
	std::vector<TreeKind> _trees;

	void place_tree(ChunkData &chunk, int ox, int oy, int oz, const Tree &t) const;
	void place_ores(ChunkData &chunk, int ox, int oy, int oz) const;
};

} // namespace gocube
