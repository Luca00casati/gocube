// GoCubeWorld: streams voxel chunks around a viewer. Generation and meshing run
// on worker threads; meshes are uploaded to the RenderingServer on the main
// thread within a per-frame time budget.
#pragma once

#include "chunk.h"
#include "generator.h"
#include "light.h"
#include "mesher.h"

#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <array>
#include <string>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace gocube {

class GoCubeWorld : public godot::Node3D {
	GDCLASS(GoCubeWorld, godot::Node3D)

public:
	// Vertical extent of the world, in chunks (y = -96 .. 127).
	static constexpr int CHUNK_Y_MIN = -3;
	static constexpr int CHUNK_Y_MAX = 3;

	GoCubeWorld();
	~GoCubeWorld() override;

	// Setup, before start(). blocks[i] = {solid, opaque, fluid, tiles: PackedInt32Array(6)}.
	void configure_blocks(const godot::TypedArray<godot::Dictionary> &blocks);
	void set_atlas_layout(int cols, int rows, int cell, const godot::Vector2i &face_offset);
	void set_materials(const godot::Ref<godot::Material> &terrain, const godot::Ref<godot::Material> &fluid);
	// ids: terrain blocks {stone, dirt, grass, sand, water}.
	// ores: [{block, replaces, min_y, max_y, veins_per_chunk, min_size, max_size, salt}]
	// trees: [{log, leaves, min_trunk, max_trunk, chance}]
	void configure_generator(int seed, const godot::Dictionary &ids, const godot::TypedArray<godot::Dictionary> &ores,
			const godot::TypedArray<godot::Dictionary> &trees);
	void configure_biomes(const godot::TypedArray<godot::Dictionary> &biomes);
	int biome_at(int x, int z) const;
	// Height of the generated ground at a column (before any edits; lakes count
	// as their bottom), without loading it.
	int generated_height(int x, int z) const;
	// Whether a chunk's blocks are in memory (generated or loaded).
	bool is_chunk_loaded(const godot::Vector3i &chunk_pos) const;
	// A tree of kind `kind` (index into the configured trees) growing on the
	// block at `ground`: [[Vector3i position, block id, only_into_air], ...].
	godot::Array tree_blocks(int kind, const godot::Vector3i &ground) const;
	void start();

	void set_view_distance(int blocks);
	int get_view_distance() const;
	void set_viewer_position(const godot::Vector3 &position);
	godot::Vector3 get_viewer_position() const;
	// Smooth (per-corner) lighting; changing it rebuilds every chunk's mesh.
	// Generation/meshing threads; 0 = automatic. Set before start().
	void set_worker_threads(int count);
	int get_worker_threads() const;
	int effective_worker_threads() const;
	void set_smooth_lighting(bool enabled);
	bool get_smooth_lighting() const;
	void set_upload_budget_ms(float ms);
	float get_upload_budget_ms() const;

	// Saving: edited chunks go to `dir` (an absolute path); chunks found there
	// are loaded instead of generated. Set before start().
	void set_save_directory(const godot::String &dir);
	int save_modified(); // writes all edited chunks; returns how many

	// Multiplayer: the generator is deterministic, so peers generate terrain
	// themselves and only edited chunks are sent.
	// Every edited chunk (saved files + unsaved edits): {Vector3i chunk: PackedByteArray}.
	godot::Dictionary get_edited_chunks() const;
	// One chunk's current data (loaded, or saved on disk); empty if neither.
	godot::PackedByteArray get_chunk_bytes(const godot::Vector3i &chunk_pos) const;
	// Use this data for a chunk instead of loading/generating it (also replaces
	// it if already loaded). Returns false if the bytes are invalid.
	bool set_chunk_override(const godot::Vector3i &chunk_pos, const godot::PackedByteArray &bytes);

	int get_block(const godot::Vector3i &position) const;
	// Changes one block (main thread). Returns false if its chunk isn't loaded.
	bool set_block(const godot::Vector3i &position, int id);
	// First targetable (non-air, non-fluid) block along a ray:
	// {hit, position, previous, normal, block, distance}; {hit: false} if none.
	godot::Dictionary raycast(const godot::Vector3 &origin, const godot::Vector3 &direction, float max_distance) const;
	// Moves a box (feet at `position`, size = width x height x depth) by `motion`
	// against solid blocks, one axis at a time. With step_height > 0 it climbs
	// steps that high when walking into them on the ground.
	// Returns {position, on_floor, hit_ceiling, hit_wall}.
	godot::Dictionary move_box(const godot::Vector3 &position, const godot::Vector3 &size,
			const godot::Vector3 &motion, float step_height) const;
	// True when the box overlaps no solid block (unloaded chunks count as solid).
	bool is_box_free(const godot::Vector3 &position, const godot::Vector3 &size) const;
	bool is_area_meshed(const godot::AABB &area) const;
	godot::Dictionary get_stats() const;

	void _process(double delta) override;

protected:
	static void _bind_methods();
	void _notification(int what);

private:
	struct Chunk {
		std::shared_ptr<const ChunkData> data; // null until generated
		bool mesh_queued = false;
		bool meshed = false;
		bool dirty = false;        // edited since last saved
		uint32_t mesh_version = 0; // bumped on every remesh request; stale meshes are dropped
		uint32_t serial = 0;       // this load of the chunk: results for an earlier load are dropped
		std::array<int8_t, CHUNK_AREA> local_tops{}; // topmost opaque local y per column, or -1
		godot::RID mesh;
		godot::RID instance;
	};

	enum JobKind { JOB_GENERATE, JOB_MESH };

	struct Job {
		JobKind kind;
		godot::Vector3i pos;
		float priority; // lower runs first
		uint32_t version = 0;
		uint32_t serial = 0; // Chunk::serial when queued
		bool urgent = false;
		std::shared_ptr<const ChunkData> self;
		std::array<std::shared_ptr<const ChunkData>, 27> neighbourhood; // neighbourhood_index()
		std::array<std::shared_ptr<const ColumnTops>, 9> tops;
	};

	struct Result {
		JobKind kind;
		godot::Vector3i pos;
		std::shared_ptr<const ChunkData> data;
		std::array<int8_t, CHUNK_AREA> local_tops{};
		Surface opaque, fluid;
		uint32_t version = 0;
		uint32_t serial = 0;
		bool urgent = false;
	};

	// Configuration (read-only once started).
	std::vector<BlockInfo> _blocks;
	AtlasLayout _atlas;
	std::atomic<bool> _smooth_lighting{ false };
	int _worker_threads = 0; // 0 = automatic
	static constexpr int MAX_WORKERS = 64;
	static constexpr int AUTO_WORKERS = 8;
	Generator _generator;
	godot::Ref<godot::Material> _terrain_material, _fluid_material;
	int _view_distance = 128;
	std::string _save_dir;
	std::mutex _override_mutex; // workers read overrides while generating
	std::unordered_map<int64_t, std::shared_ptr<const ChunkData>> _overrides;
	float _upload_budget_ms = 4.0f;

	// Main thread state.
	godot::Vector3 _viewer;
	godot::Vector3i _last_viewer_chunk{ 1 << 20, 0, 0 };
	std::unordered_map<int64_t, Chunk> _chunks;
	uint32_t _next_serial = 1; // for Chunk::serial
	std::unordered_set<int64_t> _mesh_candidates;
	std::unordered_set<int64_t> _urgent; // remesh after an edit: jump the queues
	// Per chunk column (key with y = 0): topmost opaque world y per (x, z).
	// Present only while every chunk of the column is loaded.
	std::unordered_map<int64_t, std::shared_ptr<const ColumnTops>> _column_tops;
	std::deque<Result> _uploads;
	bool _started = false;

	// Worker threads.
	std::vector<std::thread> _workers;
	std::mutex _job_mutex;
	std::condition_variable _job_cv;
	std::vector<Job> _jobs;
	std::mutex _result_mutex;
	std::vector<Result> _results;
	std::atomic<bool> _stop{ false };

	// Stats.
	std::atomic<int64_t> _gen_us{ 0 }, _gen_count{ 0 }, _mesh_us{ 0 }, _mesh_count{ 0 }, _light_us{ 0 };

	static int64_t key(const godot::Vector3i &p);
	godot::Vector3i chunk_of(const godot::Vector3 &p) const;
	static godot::Vector3i pos_of(int64_t key);
	const ChunkData *chunk_data_at(const godot::Vector3i &block, godot::Vector3i &local) const;
	bool solid_at(int x, int y, int z) const;
	void request_remesh(const godot::Vector3i &chunk_pos);
	void update_column_tops(int cx, int cz);
	void relight_around(const godot::Vector3i &block, int y_low, int y_high);
	bool save_chunk(const godot::Vector3i &pos, Chunk &c);
	std::vector<BiomeKind> _biome_kinds;
	// Block id at a world position: -1 if its chunk isn't loaded, 0 (air)
	// above or below the world's vertical range.
	int block_id_at(int x, int y, int z) const;
	bool fence_connects(int x, int y, int z) const;
	// A block's boxes in world space: its collision boxes, or (collision ==
	// false) what a ray can hit. Unloaded chunks are one solid cube.
	void block_boxes(int x, int y, int z, int id, bool collision, std::vector<Box> &out) const;
	void collect_collision(const float mn[3], const float mx[3], std::vector<Box> &out) const;
	int radius_chunks() const;

	void worker_loop();
	void push_job(Job &&job);
	void drop_stale_jobs(); // jobs for chunks unloaded since they were queued
	void stop_workers();
	void free_chunk_render(Chunk &c);
	void update_desired(const godot::Vector3i &center);
	void schedule_meshing(const godot::Vector3i &center);
	void upload(Result &r);
};

} // namespace gocube
