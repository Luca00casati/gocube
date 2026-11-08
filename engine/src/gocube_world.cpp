#include "gocube_world.h"

#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

using namespace godot;

namespace gocube {

namespace {

int floor_div(int v, int d) {
	return v >= 0 ? v / d : -((-v + d - 1) / d);
}

int64_t now_us() {
	return std::chrono::duration_cast<std::chrono::microseconds>(
			std::chrono::steady_clock::now().time_since_epoch())
			.count();
}

const Vector3i FACE_DIRS[FACE_COUNT] = {
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)
};

template <typename PackedT, typename ElemT>
PackedT to_packed(const std::vector<float> &src, int components) {
	PackedT out;
	const int64_t n = static_cast<int64_t>(src.size()) / components;
	out.resize(n);
	if (n > 0) {
		std::memcpy(static_cast<void *>(out.ptrw()), src.data(), src.size() * sizeof(float));
	}
	return out;
}

Array surface_arrays(const Surface &s) {
	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = to_packed<PackedVector3Array, Vector3>(s.positions, 3);
	arrays[Mesh::ARRAY_NORMAL] = to_packed<PackedVector3Array, Vector3>(s.normals, 3);
	arrays[Mesh::ARRAY_TEX_UV] = to_packed<PackedVector2Array, Vector2>(s.uvs, 2);
	arrays[Mesh::ARRAY_COLOR] = to_packed<PackedColorArray, Color>(s.colors, 4);
	PackedInt32Array indices;
	indices.resize(static_cast<int64_t>(s.indices.size()));
	if (!s.indices.empty()) {
		std::memcpy(indices.ptrw(), s.indices.data(), s.indices.size() * sizeof(int32_t));
	}
	arrays[Mesh::ARRAY_INDEX] = indices;
	return arrays;
}

} // namespace

GoCubeWorld::GoCubeWorld() {}

GoCubeWorld::~GoCubeWorld() {
	stop_workers();
}

// --- Configuration -----------------------------------------------------------

void GoCubeWorld::configure_blocks(const TypedArray<Dictionary> &blocks) {
	ERR_FAIL_COND_MSG(_started, "configure_blocks() must be called before start()");
	_blocks.assign(blocks.size(), BlockInfo());
	for (int64_t i = 0; i < blocks.size(); i++) {
		const Dictionary d = blocks[i];
		BlockInfo &b = _blocks[i];
		b.solid = d.get("solid", false);
		b.opaque = d.get("opaque", false);
		b.fluid = d.get("fluid", false);
		const PackedInt32Array tiles = d.get("tiles", PackedInt32Array());
		for (int f = 0; f < FACE_COUNT; f++) {
			b.tiles[f] = f < tiles.size() ? tiles[f] : 0;
		}
	}
}

void GoCubeWorld::set_atlas_layout(int cols, int rows, int cell, const Vector2i &face_offset) {
	ERR_FAIL_COND_MSG(_started, "set_atlas_layout() must be called before start()");
	_atlas.cols = std::max(1, cols);
	_atlas.rows = std::max(1, rows);
	_atlas.cell = std::max(1, cell);
	_atlas.face_x = face_offset.x;
	_atlas.face_y = face_offset.y;
}

void GoCubeWorld::set_materials(const Ref<Material> &terrain, const Ref<Material> &fluid) {
	_terrain_material = terrain;
	_fluid_material = fluid;
}

void GoCubeWorld::configure_generator(int seed, const Dictionary &ids) {
	ERR_FAIL_COND_MSG(_started, "configure_generator() must be called before start()");
	GeneratorIds g;
	g.stone = static_cast<BlockId>(int(ids.get("stone", 0)));
	g.dirt = static_cast<BlockId>(int(ids.get("dirt", 0)));
	g.grass = static_cast<BlockId>(int(ids.get("grass", 0)));
	g.sand = static_cast<BlockId>(int(ids.get("sand", 0)));
	g.water = static_cast<BlockId>(int(ids.get("water", 0)));
	g.log = static_cast<BlockId>(int(ids.get("log", 0)));
	g.leaves = static_cast<BlockId>(int(ids.get("leaves", 0)));
	_generator.configure(static_cast<uint32_t>(seed), g);
}

void GoCubeWorld::start() {
	ERR_FAIL_COND_MSG(_started, "already started");
	ERR_FAIL_COND_MSG(_blocks.empty(), "configure_blocks() first");
	_started = true;
	_stop = false;
	const unsigned hw = std::thread::hardware_concurrency();
	const unsigned count = hw > 1 ? hw - 1 : 1; // leave a core for the main thread
	for (unsigned i = 0; i < count; i++) {
		_workers.emplace_back(&GoCubeWorld::worker_loop, this);
	}
	set_process(true);
}

void GoCubeWorld::set_view_distance(int blocks) {
	_view_distance = std::max(CHUNK, blocks);
	_last_viewer_chunk = Vector3i(1 << 20, 0, 0); // force a refresh
}

int GoCubeWorld::get_view_distance() const {
	return _view_distance;
}

void GoCubeWorld::set_viewer_position(const Vector3 &position) {
	_viewer = position;
}

Vector3 GoCubeWorld::get_viewer_position() const {
	return _viewer;
}

void GoCubeWorld::set_upload_budget_ms(float ms) {
	_upload_budget_ms = std::max(0.5f, ms);
}

float GoCubeWorld::get_upload_budget_ms() const {
	return _upload_budget_ms;
}

// --- Queries -------------------------------------------------------------------

int64_t GoCubeWorld::key(const Vector3i &p) {
	return (static_cast<int64_t>(p.x & 0x1FFFFF) << 42) | (static_cast<int64_t>(p.y & 0x1FFFFF) << 21) |
			static_cast<int64_t>(p.z & 0x1FFFFF);
}

Vector3i GoCubeWorld::chunk_of(const Vector3 &p) const {
	return Vector3i(floor_div(int(std::floor(p.x)), CHUNK), floor_div(int(std::floor(p.y)), CHUNK),
			floor_div(int(std::floor(p.z)), CHUNK));
}

int GoCubeWorld::radius_chunks() const {
	return (_view_distance + CHUNK - 1) / CHUNK;
}

int GoCubeWorld::get_block(const Vector3i &position) const {
	const Vector3i c(floor_div(position.x, CHUNK), floor_div(position.y, CHUNK), floor_div(position.z, CHUNK));
	auto it = _chunks.find(key(c));
	if (it == _chunks.end() || !it->second.data) {
		return 0;
	}
	return it->second.data->get(position.x - c.x * CHUNK, position.y - c.y * CHUNK, position.z - c.z * CHUNK);
}

bool GoCubeWorld::is_area_meshed(const AABB &area) const {
	const Vector3i a = chunk_of(area.position);
	const Vector3i b = chunk_of(area.position + area.size);
	for (int cy = std::max(a.y, CHUNK_Y_MIN); cy <= std::min(b.y, CHUNK_Y_MAX); cy++) {
		for (int cz = a.z; cz <= b.z; cz++) {
			for (int cx = a.x; cx <= b.x; cx++) {
				auto it = _chunks.find(key(Vector3i(cx, cy, cz)));
				if (it == _chunks.end() || !it->second.meshed) {
					return false;
				}
			}
		}
	}
	return true;
}

Dictionary GoCubeWorld::get_stats() const {
	Dictionary d;
	int generated = 0, meshed = 0;
	for (const auto &kv : _chunks) {
		generated += kv.second.data ? 1 : 0;
		meshed += kv.second.meshed ? 1 : 0;
	}
	d["chunks"] = int64_t(_chunks.size());
	d["generated"] = generated;
	d["meshed"] = meshed;
	d["pending_uploads"] = int64_t(_uploads.size());
	{
		std::lock_guard<std::mutex> lock(const_cast<std::mutex &>(_job_mutex));
		d["queued_jobs"] = int64_t(_jobs.size());
	}
	const int64_t gc = _gen_count.load(), mc = _mesh_count.load();
	d["generate_ms_avg"] = gc ? _gen_us.load() / 1000.0 / gc : 0.0;
	d["mesh_ms_avg"] = mc ? _mesh_us.load() / 1000.0 / mc : 0.0;
	d["workers"] = int64_t(_workers.size());
	return d;
}

// --- Workers --------------------------------------------------------------------

void GoCubeWorld::push_job(Job &&job) {
	{
		std::lock_guard<std::mutex> lock(_job_mutex);
		_jobs.push_back(std::move(job));
	}
	_job_cv.notify_one();
}

void GoCubeWorld::worker_loop() {
	while (true) {
		Job job;
		{
			std::unique_lock<std::mutex> lock(_job_mutex);
			_job_cv.wait(lock, [this] { return _stop || !_jobs.empty(); });
			if (_stop) {
				return;
			}
			// Nearest first (the queue is small enough for a linear scan).
			auto best = std::min_element(_jobs.begin(), _jobs.end(),
					[](const Job &a, const Job &b) { return a.priority < b.priority; });
			job = std::move(*best);
			*best = std::move(_jobs.back());
			_jobs.pop_back();
		}
		Result r;
		r.kind = job.kind;
		r.pos = job.pos;
		const int64_t t0 = now_us();
		if (job.kind == JOB_GENERATE) {
			auto data = std::make_shared<ChunkData>();
			_generator.generate(*data, job.pos.x * CHUNK, job.pos.y * CHUNK, job.pos.z * CHUNK);
			r.data = data;
			_gen_us += now_us() - t0;
			_gen_count++;
		} else {
			const ChunkData *nb[FACE_COUNT];
			for (int f = 0; f < FACE_COUNT; f++) {
				nb[f] = job.neighbours[f].get();
			}
			mesh_chunk(*job.self, nb, _blocks, _atlas, r.opaque, r.fluid);
			_mesh_us += now_us() - t0;
			_mesh_count++;
		}
		std::lock_guard<std::mutex> lock(_result_mutex);
		_results.push_back(std::move(r));
	}
}

void GoCubeWorld::stop_workers() {
	{
		std::lock_guard<std::mutex> lock(_job_mutex);
		_stop = true;
		_jobs.clear();
	}
	_job_cv.notify_all();
	for (std::thread &t : _workers) {
		if (t.joinable()) {
			t.join();
		}
	}
	_workers.clear();
}

// --- Main thread ------------------------------------------------------------------

void GoCubeWorld::_notification(int what) {
	if (what == NOTIFICATION_EXIT_TREE || what == NOTIFICATION_PREDELETE) {
		stop_workers();
		for (auto &kv : _chunks) {
			free_chunk_render(kv.second);
		}
		_chunks.clear();
		_mesh_candidates.clear();
		_uploads.clear();
		_started = false;
	}
}

void GoCubeWorld::free_chunk_render(Chunk &c) {
	RenderingServer *rs = RenderingServer::get_singleton();
	if (c.instance.is_valid()) {
		rs->free_rid(c.instance);
		c.instance = RID();
	}
	if (c.mesh.is_valid()) {
		rs->free_rid(c.mesh);
		c.mesh = RID();
	}
}

void GoCubeWorld::_process(double delta) {
	if (!_started) {
		return;
	}
	const Vector3i center = chunk_of(_viewer);
	if (center.x != _last_viewer_chunk.x || center.z != _last_viewer_chunk.z) {
		_last_viewer_chunk = center;
		update_desired(center);
	}

	// Collect finished work.
	std::vector<Result> done;
	{
		std::lock_guard<std::mutex> lock(_result_mutex);
		done.swap(_results);
	}
	for (Result &r : done) {
		auto it = _chunks.find(key(r.pos));
		if (it == _chunks.end()) {
			continue; // unloaded meanwhile
		}
		if (r.kind == JOB_GENERATE) {
			it->second.data = r.data;
			_mesh_candidates.insert(key(r.pos));
			for (const Vector3i &dir : FACE_DIRS) {
				_mesh_candidates.insert(key(r.pos + dir));
			}
		} else {
			_uploads.push_back(std::move(r));
		}
	}

	schedule_meshing(center);

	// Upload meshes within the frame budget, nearest-queued first.
	const int64_t start = now_us();
	while (!_uploads.empty() && (now_us() - start) < int64_t(_upload_budget_ms * 1000.0f)) {
		Result r = std::move(_uploads.front());
		_uploads.pop_front();
		upload(r);
	}
}

void GoCubeWorld::update_desired(const Vector3i &center) {
	const int r = radius_chunks() + 1; // one extra ring: neighbours needed for meshing
	// Unload chunks that are well out of range.
	for (auto it = _chunks.begin(); it != _chunks.end();) {
		// Recover chunk coordinates from the key (sign-extend 21-bit fields).
		const int64_t k = it->first;
		auto field = [](int64_t v) { return int((v & 0x100000) ? (v | ~int64_t(0x1FFFFF)) : v); };
		const int cx = field((k >> 42) & 0x1FFFFF), cz = field(k & 0x1FFFFF);
		const int dx = cx - center.x, dz = cz - center.z;
		if (dx * dx + dz * dz > (r + 1) * (r + 1)) {
			free_chunk_render(it->second);
			_mesh_candidates.erase(it->first);
			it = _chunks.erase(it);
		} else {
			++it;
		}
	}
	// Request missing chunks, nearest first.
	for (int dz = -r; dz <= r; dz++) {
		for (int dx = -r; dx <= r; dx++) {
			if (dx * dx + dz * dz > r * r) {
				continue;
			}
			for (int cy = CHUNK_Y_MIN; cy <= CHUNK_Y_MAX; cy++) {
				const Vector3i p(center.x + dx, cy, center.z + dz);
				const int64_t k = key(p);
				if (_chunks.count(k)) {
					continue;
				}
				_chunks.emplace(k, Chunk());
				Job job;
				job.kind = JOB_GENERATE;
				job.pos = p;
				job.priority = float(dx * dx + dz * dz) + std::abs(cy) * 0.5f;
				push_job(std::move(job));
			}
		}
	}
}

void GoCubeWorld::schedule_meshing(const Vector3i &center) {
	const int r = radius_chunks();
	for (auto it = _mesh_candidates.begin(); it != _mesh_candidates.end();) {
		auto cit = _chunks.find(*it);
		if (cit == _chunks.end()) {
			it = _mesh_candidates.erase(it);
			continue;
		}
		Chunk &c = cit->second;
		if (!c.data || c.mesh_queued) {
			it = _mesh_candidates.erase(it);
			continue;
		}
		// Recover position from the key.
		const int64_t k = *it;
		auto field = [](int64_t v) { return int((v & 0x100000) ? (v | ~int64_t(0x1FFFFF)) : v); };
		const Vector3i p(field((k >> 42) & 0x1FFFFF), field((k >> 21) & 0x1FFFFF), field(k & 0x1FFFFF));
		const int dx = p.x - center.x, dz = p.z - center.z;
		if (dx * dx + dz * dz > r * r) {
			++it; // not in view yet; keep as a candidate
			continue;
		}
		Job job;
		job.kind = JOB_MESH;
		job.pos = p;
		job.priority = float(dx * dx + dz * dz) + std::abs(p.y) * 0.5f;
		job.self = c.data;
		bool ready = true;
		for (int f = 0; f < FACE_COUNT; f++) {
			const Vector3i np = p + FACE_DIRS[f];
			if (np.y > CHUNK_Y_MAX || np.y < CHUNK_Y_MIN) {
				continue; // outside the world: mesher treats as air above / solid below
			}
			auto nit = _chunks.find(key(np));
			if (nit == _chunks.end() || !nit->second.data) {
				ready = false;
				break;
			}
			job.neighbours[f] = nit->second.data;
		}
		if (!ready) {
			++it; // a neighbour will add us back when it arrives; keep for now
			continue;
		}
		c.mesh_queued = true;
		push_job(std::move(job));
		it = _mesh_candidates.erase(it);
	}
}

void GoCubeWorld::upload(Result &r) {
	auto it = _chunks.find(key(r.pos));
	if (it == _chunks.end()) {
		return;
	}
	Chunk &c = it->second;
	free_chunk_render(c);
	c.meshed = true;
	if (r.opaque.empty() && r.fluid.empty()) {
		return;
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	c.mesh = rs->mesh_create();
	int surface = 0;
	if (!r.opaque.empty()) {
		rs->mesh_add_surface_from_arrays(c.mesh, RenderingServer::PRIMITIVE_TRIANGLES, surface_arrays(r.opaque));
		if (_terrain_material.is_valid()) {
			rs->mesh_surface_set_material(c.mesh, surface, _terrain_material->get_rid());
		}
		surface++;
	}
	if (!r.fluid.empty()) {
		rs->mesh_add_surface_from_arrays(c.mesh, RenderingServer::PRIMITIVE_TRIANGLES, surface_arrays(r.fluid));
		if (_fluid_material.is_valid()) {
			rs->mesh_surface_set_material(c.mesh, surface, _fluid_material->get_rid());
		}
	}
	Ref<World3D> world = get_world_3d();
	if (world.is_null()) {
		return;
	}
	c.instance = rs->instance_create2(c.mesh, world->get_scenario());
	rs->instance_set_transform(c.instance, get_global_transform() * Transform3D(Basis(), Vector3(r.pos * CHUNK)));
}

// --- Bindings ----------------------------------------------------------------------

void GoCubeWorld::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure_blocks", "blocks"), &GoCubeWorld::configure_blocks);
	ClassDB::bind_method(D_METHOD("set_atlas_layout", "cols", "rows", "cell", "face_offset"), &GoCubeWorld::set_atlas_layout);
	ClassDB::bind_method(D_METHOD("set_materials", "terrain", "fluid"), &GoCubeWorld::set_materials);
	ClassDB::bind_method(D_METHOD("configure_generator", "seed", "ids"), &GoCubeWorld::configure_generator);
	ClassDB::bind_method(D_METHOD("start"), &GoCubeWorld::start);
	ClassDB::bind_method(D_METHOD("get_block", "position"), &GoCubeWorld::get_block);
	ClassDB::bind_method(D_METHOD("is_area_meshed", "area"), &GoCubeWorld::is_area_meshed);
	ClassDB::bind_method(D_METHOD("get_stats"), &GoCubeWorld::get_stats);

	ClassDB::bind_method(D_METHOD("set_view_distance", "blocks"), &GoCubeWorld::set_view_distance);
	ClassDB::bind_method(D_METHOD("get_view_distance"), &GoCubeWorld::get_view_distance);
	ClassDB::bind_method(D_METHOD("set_viewer_position", "position"), &GoCubeWorld::set_viewer_position);
	ClassDB::bind_method(D_METHOD("get_viewer_position"), &GoCubeWorld::get_viewer_position);
	ClassDB::bind_method(D_METHOD("set_upload_budget_ms", "ms"), &GoCubeWorld::set_upload_budget_ms);
	ClassDB::bind_method(D_METHOD("get_upload_budget_ms"), &GoCubeWorld::get_upload_budget_ms);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "view_distance"), "set_view_distance", "get_view_distance");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "viewer_position"), "set_viewer_position", "get_viewer_position");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upload_budget_ms"), "set_upload_budget_ms", "get_upload_budget_ms");
}

} // namespace gocube
