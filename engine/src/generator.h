// World generation: biomes, hills, beaches, sea, lakes, caves, lava and trees.
// All methods are const and thread-safe once configured.
#pragma once

#include "chunk.h"

#include <vector>

namespace gocube {

// Terrain blocks the base shape is made of.
struct GeneratorIds {
	BlockId stone = 0, dirt = 0, grass = 0, sand = 0, water = 0, lava = 0, ice = 0;
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

// Tree shapes.
enum TreeStyle : uint8_t { TREE_OAK, TREE_BIG_OAK, TREE_BIRCH, TREE_SPRUCE, TREE_CACTUS };

// One kind of tree (defined by mods).
struct TreeKind {
	BlockId log, leaves;     // leaves may be 0 (cactus)
	int min_trunk, max_trunk;
	int chance;              // percent of tree cells (when no biome lists trees)
	uint8_t style = TREE_OAK;
};

// One biome (defined by mods): where it is in climate space, its ground and
// what grows there. The nearest biome to a column's climate wins; hill height
// is blended between biomes so borders don't make cliffs.
struct BiomeKind {
	float temperature = 0.0f, humidity = 0.0f; // roughly -1..1
	float height = 20.0f;                      // hill amplitude (blocks)
	float base = 0.0f;                         // raises or lowers the land
	BlockId surface = 0, filler = 0;           // top block and the ones under it
	int filler_depth = 3;
	BlockId under = 0;                         // optional layer below the filler (sandstone)
	int under_depth = 0;
	std::vector<std::pair<int, int>> trees;    // tree kind, percent of tree cells
	std::vector<std::pair<BlockId, int>> plants; // block, per mille of surface columns
	bool frozen = false;                       // ice on water
	int lakes = 20;                            // percent of lake cells with a lake
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
	static constexpr int CAVE_MIN_Y = -92;
	static constexpr int LAVA_LEVEL = -76;       // caves below this are full of lava
	static constexpr float CAVERN_PERIOD = 40.0f;
	static constexpr int CAVERN_MAX_Y = -18;     // big caverns only deep down
	static constexpr int TREE_CELL = 8;
	static constexpr int TREE_REACH = 5;         // how far a tree's leaves spread
	static constexpr int LAKE_CELL = 48;


	void configure(uint32_t seed, const GeneratorIds &ids, const std::vector<OreKind> &ores,
			const std::vector<TreeKind> &trees);
	void set_biomes(const std::vector<BiomeKind> &biomes);

	// The biome of a column (index into the biomes; 0 if none are configured).
	int biome_at(int x, int z) const;
	// A lake at this column: true, with its water level and the bottom.
	bool lake_at(int x, int z, int &level, int &bottom) const;

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
	std::vector<BiomeKind> _biomes;

	void climate(int x, int z, float &temperature, float &humidity) const;
	const BiomeKind &biome(int index) const;
	int terrain_height(int x, int z) const; // before lakes
	int column(int x, int z, int &biome_index) const;
	void place_tree(ChunkData &chunk, int ox, int oy, int oz, const Tree &t) const;
	void place_ores(ChunkData &chunk, int ox, int oy, int oz) const;
};

} // namespace gocube
