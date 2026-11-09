#include "gocube_world.h"
#include "storage.h"

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
		b.emit = static_cast<uint8_t>(std::clamp(int(d.get("light", 0)), 0, LIGHT_MAX));
		b.fluid_level = static_cast<uint8_t>(std::clamp(int(d.get("fluid_level", 8)), 1, 8));
		b.random_rotation = d.get("random_rotation", false);
		b.shape = static_cast<uint8_t>(std::clamp(int(d.get("shape", 0)), 0, int(SHAPE_FENCE)));
		auto read_boxes = [](const PackedFloat32Array &a, std::vector<Box> &out) {
			for (int64_t k = 0; k + 6 < a.size(); k += 7) {
				out.push_back({ { a[k], a[k + 1], a[k + 2] }, { a[k + 3], a[k + 4], a[k + 5] }, a[k + 6] });
			}
		};
		read_boxes(d.get("model", PackedFloat32Array()), b.model);
		if (d.has("collision")) {
			read_boxes(d.get("collision", PackedFloat32Array()), b.collision);
		} else if (b.solid) {
			b.collision.push_back({ { 0, 0, 0 }, { 1, 1, 1 } });
		}
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

// Biomes for new worlds (call before configure_generator; none = the original
// generator). Each: temperature, humidity, height, base, surface, filler,
// filler_depth, under, under_depth, trees [[kind index, percent]], plants
// [[block, per mille]], frozen, lakes (percent).
void GoCubeWorld::configure_biomes(const TypedArray<Dictionary> &biomes) {
	ERR_FAIL_COND_MSG(_started, "configure_biomes() must be called before start()");
	auto block = [&](const Variant &v) {
		const int id = v;
		return static_cast<BlockId>(id > 0 && id < int(_blocks.size()) ? id : 0);
	};
	_biome_kinds.clear();
	for (int64_t i = 0; i < biomes.size(); i++) {
		const Dictionary d = biomes[i];
		BiomeKind b;
		b.temperature = float(d.get("temperature", 0.0));
		b.humidity = float(d.get("humidity", 0.0));
		b.height = float(d.get("height", 20.0));
		b.base = float(d.get("base", 0.0));
		b.surface = block(d.get("surface", 0));
		b.filler = block(d.get("filler", 0));
		b.filler_depth = std::clamp(int(d.get("filler_depth", 3)), 1, 16);
		b.under = block(d.get("under", 0));
		b.under_depth = std::clamp(int(d.get("under_depth", 0)), 0, 16);
		b.frozen = d.get("frozen", false);
		b.lakes = std::clamp(int(d.get("lakes", 20)), 0, 100);
		b.mountains = std::clamp(float(d.get("mountains", 0.0)), 0.0f, 60.0f);
		b.rock = block(d.get("rock", 0));
		b.rock_above = int(d.get("rock_above", 1 << 20));
		b.cap = block(d.get("cap", 0));
		b.cap_above = int(d.get("cap_above", 1 << 20));
		b.cover = block(d.get("cover", 0));
		b.cover_above = int(d.get("cover_above", 1 << 20));
		const Array trees = d.get("trees", Array());
		for (int64_t k = 0; k < trees.size(); k++) {
			const Array e = trees[k];
			b.trees.push_back({ int(e[0]), int(e[1]) });
		}
		const Array plants = d.get("plants", Array());
		for (int64_t k = 0; k < plants.size(); k++) {
			const Array e = plants[k];
			b.plants.push_back({ block(e[0]), int(e[1]) });
		}
		if (b.surface && b.filler) {
			_biome_kinds.push_back(b);
		}
	}
}

Array GoCubeWorld::tree_blocks(int kind, const Vector3i &ground) const {
	std::vector<TreeBlock> blocks;
	_generator.tree_blocks(kind, ground.x, ground.y, ground.z, blocks);
	Array out;
	for (const TreeBlock &b : blocks) {
		Array e;
		e.append(Vector3i(b.x, b.y, b.z));
		e.append(int(b.id));
		e.append(b.only_air);
		out.append(e);
	}
	return out;
}

int GoCubeWorld::generated_height(int x, int z) const {
	return _generator.height_at(x, z);
}

int GoCubeWorld::biome_at(int x, int z) const {
	return _generator.biome_at(x, z);
}

void GoCubeWorld::configure_generator(int seed, const Dictionary &ids, const TypedArray<Dictionary> &ores,
		const TypedArray<Dictionary> &trees) {
	ERR_FAIL_COND_MSG(_started, "configure_generator() must be called before start()");
	auto block = [&](const Dictionary &d, const char *k) {
		const int v = d.get(k, 0);
		return static_cast<BlockId>(v > 0 && v < int(_blocks.size()) ? v : 0);
	};
	GeneratorIds g;
	g.stone = block(ids, "stone");
	g.dirt = block(ids, "dirt");
	g.grass = block(ids, "grass");
	g.sand = block(ids, "sand");
	g.water = block(ids, "water");
	g.lava = block(ids, "lava");
	g.ice = block(ids, "ice");
	std::vector<OreKind> ore_kinds;
	for (int64_t i = 0; i < ores.size(); i++) {
		const Dictionary d = ores[i];
		OreKind k;
		k.id = block(d, "block");
		k.replaces = d.has("replaces") ? block(d, "replaces") : g.stone;
		k.min_y = d.get("min_y", -96);
		k.max_y = d.get("max_y", 0);
		k.veins_per_chunk = std::clamp(int(d.get("veins_per_chunk", 4)), 0, 256);
		k.min_size = std::max(1, int(d.get("min_size", 3)));
		k.max_size = std::max(k.min_size, int(d.get("max_size", 6)));
		k.salt = static_cast<uint32_t>(int64_t(d.get("salt", i * 911 + 1)));
		if (k.id != 0 && k.replaces != 0) {
			ore_kinds.push_back(k);
		}
	}
	std::vector<TreeKind> tree_kinds;
	for (int64_t i = 0; i < trees.size(); i++) {
		const Dictionary d = trees[i];
		TreeKind t;
		t.log = block(d, "log");
		t.leaves = block(d, "leaves");
		t.min_trunk = std::clamp(int(d.get("min_trunk", 4)), 2, 20);
		t.max_trunk = std::clamp(int(d.get("max_trunk", 6)), t.min_trunk, 20);
		t.chance = std::clamp(int(d.get("chance", 30)), 0, 100);
		t.style = static_cast<uint8_t>(std::clamp(int(d.get("style", 0)), 0, int(TREE_ROUND_OAK)));
		tree_kinds.push_back(t); // every kind, so biomes can refer to them by index
	}
	_generator.set_biomes(_biome_kinds);
	_generator.configure(static_cast<uint32_t>(seed), g, ore_kinds, tree_kinds);
}

void GoCubeWorld::start() {
	ERR_FAIL_COND_MSG(_started, "already started");
	ERR_FAIL_COND_MSG(_blocks.empty(), "configure_blocks() first");
	_started = true;
	_stop = false;
	const unsigned count = static_cast<unsigned>(effective_worker_threads());
	for (unsigned i = 0; i < count; i++) {
		_workers.emplace_back(&GoCubeWorld::worker_loop, this);
	}
	set_process(true);
}

void GoCubeWorld::set_worker_threads(int count) {
	ERR_FAIL_COND_MSG(_started, "set worker_threads before start()");
	_worker_threads = std::clamp(count, 0, MAX_WORKERS);
}

int GoCubeWorld::get_worker_threads() const {
	return _worker_threads;
}

// 0 = automatic: one per core, leaving one for the main thread, at most
// AUTO_WORKERS (more adds little: the main thread uploading meshes limits).
int GoCubeWorld::effective_worker_threads() const {
	if (_worker_threads > 0) {
		return _worker_threads;
	}
	const int hw = static_cast<int>(std::thread::hardware_concurrency());
	return std::clamp(hw - 1, 1, AUTO_WORKERS);
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

void GoCubeWorld::set_smooth_lighting(bool enabled) {
	if (_smooth_lighting.exchange(enabled) == enabled) {
		return;
	}
	for (auto &kv : _chunks) {
		if (kv.second.data && kv.second.meshed) {
			kv.second.mesh_version++;
			kv.second.mesh_queued = false;
			_mesh_candidates.insert(kv.first); // not urgent: nearest first, within the budget
		}
	}
}

bool GoCubeWorld::get_smooth_lighting() const {
	return _smooth_lighting.load();
}

void GoCubeWorld::set_upload_budget_ms(float ms) {
	_upload_budget_ms = std::max(0.5f, ms);
}

float GoCubeWorld::get_upload_budget_ms() const {
	return _upload_budget_ms;
}

void GoCubeWorld::set_save_directory(const String &dir) {
	ERR_FAIL_COND_MSG(_started, "set_save_directory() must be called before start()");
	_save_dir = dir.utf8().get_data();
}

bool GoCubeWorld::save_chunk(const Vector3i &pos, Chunk &c) {
	if (_save_dir.empty() || !c.dirty || !c.data) {
		return true;
	}
	if (!save_chunk_file(chunk_file_path(_save_dir, pos.x, pos.y, pos.z), *c.data)) {
		UtilityFunctions::push_error("GoCubeWorld: failed to save chunk ", pos);
		return false;
	}
	c.dirty = false;
	return true;
}

int GoCubeWorld::save_modified() {
	int saved = 0;
	for (auto &kv : _chunks) {
		if (kv.second.dirty && save_chunk(pos_of(kv.first), kv.second)) {
			saved++;
		}
	}
	return saved;
}

Dictionary GoCubeWorld::get_edited_chunks() const {
	Dictionary out;
	auto put = [&](const Vector3i &p, const std::vector<uint8_t> &bytes) {
		PackedByteArray a;
		a.resize(int64_t(bytes.size()));
		std::memcpy(a.ptrw(), bytes.data(), bytes.size());
		out[p] = a;
	};
	if (!_save_dir.empty()) {
		for (const auto &c : list_chunk_files(_save_dir)) {
			const Vector3i p(c[0], c[1], c[2]);
			auto it = _chunks.find(key(p));
			if (it != _chunks.end() && it->second.dirty) {
				continue; // newer data in memory, added below
			}
			ChunkData data;
			if (load_chunk_file(chunk_file_path(_save_dir, p.x, p.y, p.z), data)) {
				put(p, encode_chunk(data));
			}
		}
	}
	for (const auto &kv : _chunks) {
		if (kv.second.dirty && kv.second.data) {
			put(pos_of(kv.first), encode_chunk(*kv.second.data));
		}
	}
	return out;
}

bool GoCubeWorld::is_chunk_loaded(const Vector3i &chunk_pos) const {
	auto it = _chunks.find(key(chunk_pos));
	return it != _chunks.end() && it->second.data;
}

PackedByteArray GoCubeWorld::get_chunk_bytes(const Vector3i &chunk_pos) const {
	std::vector<uint8_t> bytes;
	auto it = _chunks.find(key(chunk_pos));
	if (it != _chunks.end() && it->second.data) {
		bytes = encode_chunk(*it->second.data);
	} else if (!_save_dir.empty()) {
		ChunkData data;
		if (load_chunk_file(chunk_file_path(_save_dir, chunk_pos.x, chunk_pos.y, chunk_pos.z), data)) {
			bytes = encode_chunk(data);
		}
	}
	PackedByteArray out;
	out.resize(int64_t(bytes.size()));
	if (!bytes.empty()) {
		std::memcpy(out.ptrw(), bytes.data(), bytes.size());
	}
	return out;
}

bool GoCubeWorld::set_chunk_override(const Vector3i &chunk_pos, const PackedByteArray &bytes) {
	auto data = std::make_shared<ChunkData>();
	if (!decode_chunk(bytes.ptr(), size_t(bytes.size()), *data)) {
		return false;
	}
	{
		std::lock_guard<std::mutex> lock(_override_mutex);
		_overrides[key(chunk_pos)] = data;
	}
	auto it = _chunks.find(key(chunk_pos));
	if (it != _chunks.end() && it->second.data) {
		it->second.data = data;
		chunk_local_tops(*data, _blocks, it->second.local_tops);
		update_column_tops(chunk_pos.x, chunk_pos.z);
		// Its blocks and its column's sky may have changed: relight around it.
		relight_around(chunk_pos * CHUNK + Vector3i(CHUNK / 2, 0, CHUNK / 2),
				CHUNK_Y_MIN * CHUNK, (CHUNK_Y_MAX + 1) * CHUNK - 1);
	}
	return true;
}

// --- Queries -------------------------------------------------------------------

Vector3i GoCubeWorld::pos_of(int64_t k) {
	auto field = [](int64_t v) { return int((v & 0x100000) ? (v | ~int64_t(0x1FFFFF)) : v); };
	return Vector3i(field((k >> 42) & 0x1FFFFF), field((k >> 21) & 0x1FFFFF), field(k & 0x1FFFFF));
}

const ChunkData *GoCubeWorld::chunk_data_at(const Vector3i &block, Vector3i &local) const {
	const Vector3i c(floor_div(block.x, CHUNK), floor_div(block.y, CHUNK), floor_div(block.z, CHUNK));
	auto it = _chunks.find(key(c));
	if (it == _chunks.end() || !it->second.data) {
		return nullptr;
	}
	local = block - c * CHUNK;
	return it->second.data.get();
}

// Unloaded chunks count as solid, so nothing falls out of the loaded world.
// Above and below the world's vertical range is open.
bool GoCubeWorld::solid_at(int x, int y, int z) const {
	const int cy = floor_div(y, CHUNK);
	if (cy > CHUNK_Y_MAX || cy < CHUNK_Y_MIN) {
		return false;
	}
	Vector3i local;
	const ChunkData *d = chunk_data_at(Vector3i(x, y, z), local);
	if (!d) {
		return true;
	}
	const BlockId id = d->get(local.x, local.y, local.z);
	return id < _blocks.size() && _blocks[id].solid;
}

bool GoCubeWorld::set_block(const Vector3i &position, int id) {
	ERR_FAIL_COND_V(id < 0 || id >= int(_blocks.size()), false);
	const Vector3i c(floor_div(position.x, CHUNK), floor_div(position.y, CHUNK), floor_div(position.z, CHUNK));
	auto it = _chunks.find(key(c));
	if (it == _chunks.end() || !it->second.data) {
		return false;
	}
	Chunk &chunk = it->second;
	const Vector3i l = position - c * CHUNK;
	if (chunk.data->get(l.x, l.y, l.z) == id) {
		return true;
	}
	// Copy-on-write: mesh jobs may still be reading the old snapshot.
	auto copy = std::make_shared<ChunkData>(*chunk.data);
	copy->set(l.x, l.y, l.z, static_cast<BlockId>(id));
	copy->compact();
	chunk.data = copy;
	chunk.dirty = true;

	// Column top within this chunk, then for the whole column.
	const int column = l.z * CHUNK + l.x;
	int8_t local_top = -1;
	for (int y = CHUNK - 1; y >= 0; y--) {
		const BlockId b = copy->get(l.x, y, l.z);
		if (b < _blocks.size() && _blocks[b].opaque) {
			local_top = static_cast<int8_t>(y);
			break;
		}
	}
	const int64_t ckey = key(Vector3i(c.x, 0, c.z));
	auto tit = _column_tops.find(ckey);
	const int old_top = tit != _column_tops.end() ? (*tit->second)[column] : NO_TOP;
	chunk.local_tops[column] = local_top;
	update_column_tops(c.x, c.z);
	tit = _column_tops.find(ckey);
	const int new_top = tit != _column_tops.end() ? (*tit->second)[column] : NO_TOP;

	// Everything light can reach from here, plus everything below a column
	// whose sky exposure changed.
	int y_low = position.y, y_high = position.y;
	if (old_top != new_top) {
		y_low = std::min({ y_low, old_top, new_top });
		y_high = std::max({ y_high, old_top, new_top });
		y_low = std::max(y_low, CHUNK_Y_MIN * CHUNK);
	}
	relight_around(position, y_low, y_high);
	return true;
}

void GoCubeWorld::relight_around(const Vector3i &block, int y_low, int y_high) {
	const Vector3i a(floor_div(block.x - LIGHT_MAX, CHUNK), floor_div(y_low - LIGHT_MAX, CHUNK), floor_div(block.z - LIGHT_MAX, CHUNK));
	const Vector3i b(floor_div(block.x + LIGHT_MAX, CHUNK), floor_div(y_high + LIGHT_MAX, CHUNK), floor_div(block.z + LIGHT_MAX, CHUNK));
	for (int cy = std::max(a.y, CHUNK_Y_MIN); cy <= std::min(b.y, CHUNK_Y_MAX); cy++) {
		for (int cz = a.z; cz <= b.z; cz++) {
			for (int cx = a.x; cx <= b.x; cx++) {
				request_remesh(Vector3i(cx, cy, cz));
			}
		}
	}
}

void GoCubeWorld::update_column_tops(int cx, int cz) {
	const int64_t ckey = key(Vector3i(cx, 0, cz));
	auto tops = std::make_shared<ColumnTops>();
	tops->fill(NO_TOP);
	for (int cy = CHUNK_Y_MAX; cy >= CHUNK_Y_MIN; cy--) {
		auto it = _chunks.find(key(Vector3i(cx, cy, cz)));
		if (it == _chunks.end() || !it->second.data) {
			_column_tops.erase(ckey); // column incomplete: no sky information yet
			return;
		}
		for (int i = 0; i < CHUNK_AREA; i++) {
			if ((*tops)[i] == NO_TOP && it->second.local_tops[i] >= 0) {
				(*tops)[i] = static_cast<int16_t>(cy * CHUNK + it->second.local_tops[i]);
			}
		}
	}
	_column_tops[ckey] = tops;
}

void GoCubeWorld::request_remesh(const Vector3i &chunk_pos) {
	auto it = _chunks.find(key(chunk_pos));
	if (it == _chunks.end() || !it->second.data) {
		return;
	}
	it->second.mesh_version++;
	it->second.mesh_queued = false;
	_mesh_candidates.insert(it->first);
	_urgent.insert(it->first);
}

Dictionary GoCubeWorld::raycast(const Vector3 &origin, const Vector3 &direction, float max_distance) const {
	Dictionary result;
	result["hit"] = false;
	const Vector3 dir = direction.normalized();
	if (dir.is_zero_approx()) {
		return result;
	}
	// Voxel traversal: step to whichever cell boundary the ray reaches first.
	Vector3i cell(int(std::floor(origin.x)), int(std::floor(origin.y)), int(std::floor(origin.z)));
	Vector3i previous = cell;
	Vector3i normal;
	int step[3];
	float t_max[3], t_delta[3];
	for (int a = 0; a < 3; a++) {
		const float d = dir[a];
		step[a] = d > 0 ? 1 : (d < 0 ? -1 : 0);
		t_delta[a] = d != 0 ? std::fabs(1.0f / d) : INFINITY;
		const float boundary = d > 0 ? std::floor(origin[a]) + 1.0f : std::floor(origin[a]);
		t_max[a] = d != 0 ? (boundary - origin[a]) / d : INFINITY;
	}
	float t = 0.0f;
	while (t <= max_distance) {
		Vector3i local;
		const ChunkData *data = chunk_data_at(cell, local);
		if (!data) {
			return result; // left the loaded world
		}
		const BlockId id = data->get(local.x, local.y, local.z);
		if (id != AIR && id < _blocks.size() && !_blocks[id].fluid) {
			if (_blocks[id].shape == SHAPE_CUBE) {
				result["hit"] = true;
				result["position"] = cell;
				result["previous"] = previous;
				result["normal"] = normal;
				result["block"] = int(id);
				result["distance"] = t;
				return result;
			}
			// Shaped block: the nearest of its boxes along the ray, if any.
			std::vector<Box> boxes;
			block_boxes(cell.x, cell.y, cell.z, id, false, boxes);
			float best = INFINITY;
			Vector3i best_normal;
			for (const Box &bx : boxes) {
				float t0 = 0.0f, t1 = max_distance;
				int axis = -1;
				bool miss = false;
				for (int k = 0; k < 3 && !miss; k++) {
					if (dir[k] == 0.0f) {
						miss = origin[k] < bx.mn[k] || origin[k] > bx.mx[k];
						continue;
					}
					float ta = (bx.mn[k] - origin[k]) / dir[k], tb = (bx.mx[k] - origin[k]) / dir[k];
					if (ta > tb) {
						std::swap(ta, tb);
					}
					if (ta > t0) {
						t0 = ta;
						axis = k;
					}
					t1 = std::min(t1, tb);
					miss = t0 > t1;
				}
				if (!miss && t0 < best) {
					best = t0;
					best_normal = Vector3i();
					if (axis >= 0) {
						best_normal[axis] = dir[axis] > 0 ? -1 : 1;
					}
				}
			}
			if (best <= max_distance) {
				result["hit"] = true;
				result["position"] = cell;
				result["previous"] = cell + best_normal; // the cell on the side we hit
				result["normal"] = best_normal;
				result["block"] = int(id);
				result["distance"] = best;
				return result;
			}
		}
		const int a = (t_max[0] < t_max[1]) ? (t_max[0] < t_max[2] ? 0 : 2) : (t_max[1] < t_max[2] ? 1 : 2);
		previous = cell;
		cell[a] += step[a];
		t = t_max[a];
		t_max[a] += t_delta[a];
		normal = Vector3i();
		normal[a] = -step[a];
	}
	return result;
}

int GoCubeWorld::block_id_at(int x, int y, int z) const {
	const int cy = floor_div(y, CHUNK);
	if (cy > CHUNK_Y_MAX || cy < CHUNK_Y_MIN) {
		return AIR;
	}
	Vector3i local;
	const ChunkData *d = chunk_data_at(Vector3i(x, y, z), local);
	return d ? d->get(local.x, local.y, local.z) : -1;
}

bool GoCubeWorld::fence_connects(int x, int y, int z) const {
	const int id = block_id_at(x, y, z);
	return id > 0 && id < int(_blocks.size()) && (_blocks[id].shape == SHAPE_FENCE || _blocks[id].opaque);
}

void GoCubeWorld::block_boxes(int x, int y, int z, int id, bool collision, std::vector<Box> &out) const {
	const size_t first = out.size();
	if (id < 0) {
		out.push_back({ { 0, 0, 0 }, { 1, 1, 1 } }); // unloaded: solid
	} else if (id == AIR || id >= int(_blocks.size())) {
		return;
	} else {
		const BlockInfo &b = _blocks[id];
		if (b.shape == SHAPE_FENCE) {
			fence_boxes(fence_connects(x, y, z - 1), fence_connects(x + 1, y, z), fence_connects(x, y, z + 1),
					fence_connects(x - 1, y, z), collision, out);
		} else if (collision) {
			out.insert(out.end(), b.collision.begin(), b.collision.end());
		} else if (b.fluid) {
			return;
		} else if (b.shape == SHAPE_BOXES && !b.model.empty()) {
			out.insert(out.end(), b.model.begin(), b.model.end());
		} else if (b.shape == SHAPE_CROSS) {
			out.push_back({ { 0.15f, 0.0f, 0.15f }, { 0.85f, 0.8f, 0.85f } });
		} else {
			out.push_back({ { 0, 0, 0 }, { 1, 1, 1 } });
		}
	}
	for (size_t i = first; i < out.size(); i++) {
		for (int k = 0; k < 3; k++) {
			const float o = float(k == 0 ? x : (k == 1 ? y : z));
			out[i].mn[k] += o;
			out[i].mx[k] += o;
		}
	}
}

// Collision boxes of every block that could touch [mn, mx] (one cell lower
// too: fences reach 1.5 blocks up).
void GoCubeWorld::collect_collision(const float mn[3], const float mx[3], std::vector<Box> &out) const {
	constexpr float EPS = 1e-3f;
	const int x0 = int(std::floor(mn[0] + EPS)), x1 = int(std::floor(mx[0] - EPS));
	const int y0 = int(std::floor(mn[1] + EPS)) - 1, y1 = int(std::floor(mx[1] - EPS));
	const int z0 = int(std::floor(mn[2] + EPS)), z1 = int(std::floor(mx[2] - EPS));
	for (int y = y0; y <= y1; y++) {
		for (int z = z0; z <= z1; z++) {
			for (int x = x0; x <= x1; x++) {
				const size_t first = out.size();
				block_boxes(x, y, z, block_id_at(x, y, z), true, out);
				// Keep only boxes that reach into the region.
				for (size_t i = out.size(); i-- > first;) {
					const Box &b = out[i];
					bool touches = true;
					for (int k = 0; k < 3; k++) {
						touches = touches && b.mx[k] > mn[k] + EPS && b.mn[k] < mx[k] - EPS;
					}
					if (!touches) {
						out.erase(out.begin() + i);
					}
				}
			}
		}
	}
}

Dictionary GoCubeWorld::move_box(const Vector3 &position, const Vector3 &size, const Vector3 &motion, float step_height) const {
	// Moves y, then x, then z, each clipped against the blocks' collision
	// boxes. Returns the final feet position and contacts.
	constexpr float EPS = 1e-3f;
	std::vector<Box> boxes;
	auto simulate = [&](Vector3 p, const Vector3 &m, bool &on_floor, bool &ceiling, bool &wall) {
		// Everything within reach of this whole move.
		float rmn[3] = { p.x - size.x * 0.5f, p.y, p.z - size.z * 0.5f };
		float rmx[3] = { p.x + size.x * 0.5f, p.y + size.y, p.z + size.z * 0.5f };
		for (int k = 0; k < 3; k++) {
			rmn[k] += std::min(0.0f, m[k]) - 1.0f;
			rmx[k] += std::max(0.0f, m[k]) + 1.0f;
		}
		boxes.clear();
		collect_collision(rmn, rmx, boxes);
		const int order[3] = { 1, 0, 2 };
		for (int a : order) {
			const float mn[3] = { p.x - size.x * 0.5f, p.y, p.z - size.z * 0.5f };
			const float mx[3] = { p.x + size.x * 0.5f, p.y + size.y, p.z + size.z * 0.5f };
			const int u = (a + 1) % 3, v = (a + 2) % 3;
			float allowed = m[a];
			for (const Box &b : boxes) {
				if (b.mx[u] <= mn[u] + EPS || b.mn[u] >= mx[u] - EPS || b.mx[v] <= mn[v] + EPS || b.mn[v] >= mx[v] - EPS) {
					continue; // not in the way on the other two axes
				}
				if (allowed > 0.0f && b.mn[a] >= mx[a] - EPS) {
					allowed = std::min(allowed, std::max(0.0f, b.mn[a] - mx[a] - EPS));
				} else if (allowed < 0.0f && b.mx[a] <= mn[a] + EPS) {
					allowed = std::max(allowed, std::min(0.0f, b.mx[a] - mn[a] + EPS));
				}
			}
			if (allowed != m[a]) {
				if (a == 1) {
					(m[a] < 0 ? on_floor : ceiling) = true;
				} else {
					wall = true;
				}
			}
			p[a] += allowed;
		}
		return p;
	};
	bool on_floor = false, ceiling = false, wall = false;
	Vector3 end = simulate(position, motion, on_floor, ceiling, wall);

	// Step up: if walking on the ground into something, try going over it.
	if (step_height > 0.0f && wall) {
		bool f2 = false, c2 = false, w2 = false;
		const bool grounded = !is_box_free(position - Vector3(0, 0.05f, 0), size) || on_floor;
		if (grounded) {
			Vector3 up = simulate(position, Vector3(0, step_height, 0), f2, c2, w2);
			Vector3 across = simulate(up, Vector3(motion.x, 0, motion.z), f2, c2, w2);
			bool f3 = false, c3 = false, w3 = false;
			Vector3 down = simulate(across, Vector3(0, -step_height + std::min(0.0f, motion.y), 0), f3, c3, w3);
			const float flat = Vector2(end.x - position.x, end.z - position.z).length();
			const float stepped = Vector2(down.x - position.x, down.z - position.z).length();
			if (stepped > flat + 1e-3f) {
				end = down;
				on_floor = f3;
				wall = w2;
			}
		}
	}
	Dictionary r;
	r["position"] = end;
	r["on_floor"] = on_floor;
	r["hit_ceiling"] = ceiling;
	r["hit_wall"] = wall;
	return r;
}

bool GoCubeWorld::is_box_free(const Vector3 &position, const Vector3 &size) const {
	const float mn[3] = { position.x - size.x * 0.5f, position.y, position.z - size.z * 0.5f };
	const float mx[3] = { position.x + size.x * 0.5f, position.y + size.y, position.z + size.z * 0.5f };
	std::vector<Box> boxes;
	collect_collision(mn, mx, boxes); // only boxes overlapping the region are kept
	return boxes.empty();
}


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
	int generated = 0, meshed = 0, dirty = 0;
	for (const auto &kv : _chunks) {
		generated += kv.second.data ? 1 : 0;
		meshed += kv.second.meshed ? 1 : 0;
		dirty += kv.second.dirty ? 1 : 0;
	}
	d["dirty"] = dirty;
	d["pending_remesh"] = int64_t(_urgent.size());
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
	d["mesh_ms_avg"] = mc ? _mesh_us.load() / 1000.0 / mc : 0.0; // includes light
	d["light_ms_avg"] = mc ? _light_us.load() / 1000.0 / mc : 0.0;
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

void GoCubeWorld::drop_stale_jobs() {
	std::lock_guard<std::mutex> lock(_job_mutex);
	_jobs.erase(std::remove_if(_jobs.begin(), _jobs.end(), [this](const Job &j) {
		auto it = _chunks.find(key(j.pos));
		return it == _chunks.end() || it->second.serial != j.serial;
	}), _jobs.end());
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
		r.version = job.version;
		r.serial = job.serial;
		r.urgent = job.urgent;
		const int64_t t0 = now_us();
		if (job.kind == JOB_GENERATE) {
			std::shared_ptr<const ChunkData> from_host;
			{
				std::lock_guard<std::mutex> lock(_override_mutex);
				auto oit = _overrides.find(key(job.pos));
				if (oit != _overrides.end()) {
					from_host = oit->second;
				}
			}
			if (from_host) {
				r.data = from_host;
			} else {
				auto data = std::make_shared<ChunkData>();
				const bool loaded = !_save_dir.empty() &&
						load_chunk_file(chunk_file_path(_save_dir, job.pos.x, job.pos.y, job.pos.z), *data);
				if (!loaded) {
					_generator.generate(*data, job.pos.x * CHUNK, job.pos.y * CHUNK, job.pos.z * CHUNK);
				}
				r.data = data;
			}
			chunk_local_tops(*r.data, _blocks, r.local_tops);
			_gen_us += now_us() - t0;
			_gen_count++;
		} else {
			const ChunkData *hood[27];
			for (int i = 0; i < 27; i++) {
				hood[i] = job.neighbourhood[i].get();
			}
			const ColumnTops *tops[9];
			for (int i = 0; i < 9; i++) {
				tops[i] = job.tops[i].get();
			}
			LightRegion light;
			compute_light(light, hood, tops, job.pos.y, _blocks);
			_light_us += now_us() - t0;
			const ChunkData *nb[FACE_COUNT] = {
				hood[neighbourhood_index(1, 0, 0)], hood[neighbourhood_index(-1, 0, 0)],
				hood[neighbourhood_index(0, 1, 0)], hood[neighbourhood_index(0, -1, 0)],
				hood[neighbourhood_index(0, 0, 1)], hood[neighbourhood_index(0, 0, -1)]
			};
			MeshOptions options;
			options.smooth_lighting = _smooth_lighting.load();
			options.origin_x = job.pos.x * CHUNK;
			options.origin_y = job.pos.y * CHUNK;
			options.origin_z = job.pos.z * CHUNK;
			mesh_chunk(*job.self, nb, _blocks, _atlas, &light, options, r.opaque, r.fluid);
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
			save_chunk(pos_of(kv.first), kv.second);
			free_chunk_render(kv.second);
		}
		_urgent.clear();
		_column_tops.clear();
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
		if (it == _chunks.end() || it->second.serial != r.serial) {
			continue; // unloaded meanwhile (and maybe loaded again since: a newer job is on its way)
		}
		if (r.kind == JOB_GENERATE) {
			if (it->second.data) {
				continue; // the host's copy arrived first (set_chunk_override)
			}
			{
				// The host's copy arrived while this was being generated: it wins.
				std::lock_guard<std::mutex> lock(_override_mutex);
				auto oit = _overrides.find(key(r.pos));
				if (oit != _overrides.end() && oit->second != r.data) {
					r.data = oit->second;
					chunk_local_tops(*r.data, _blocks, r.local_tops);
				}
			}
			it->second.data = r.data;
			it->second.local_tops = r.local_tops;
			update_column_tops(r.pos.x, r.pos.z);
			// Light needs the whole 3x3x3 neighbourhood, so any of them may now be ready.
			for (int dy = -1; dy <= 1; dy++) {
				for (int dz = -1; dz <= 1; dz++) {
					for (int dx = -1; dx <= 1; dx++) {
						_mesh_candidates.insert(key(r.pos + Vector3i(dx, dy, dz)));
					}
				}
			}
		} else if (r.urgent) {
			_uploads.push_front(std::move(r));
		} else {
			_uploads.push_back(std::move(r));
		}
	}

	schedule_meshing(center);

	// Upload meshes within the frame budget, nearest-queued first.
	const int64_t start = now_us();
	while (!_uploads.empty() &&
			(_uploads.front().urgent || (now_us() - start) < int64_t(_upload_budget_ms * 1000.0f))) {
		Result r = std::move(_uploads.front());
		_uploads.pop_front();
		upload(r);
	}
}

void GoCubeWorld::update_desired(const Vector3i &center) {
	const int r = radius_chunks() + 1; // one extra ring: neighbours needed for meshing
	// Unload chunks that are well out of range.
	bool unloaded = false;
	for (auto it = _chunks.begin(); it != _chunks.end();) {
		// Recover chunk coordinates from the key (sign-extend 21-bit fields).
		const int64_t k = it->first;
		auto field = [](int64_t v) { return int((v & 0x100000) ? (v | ~int64_t(0x1FFFFF)) : v); };
		const int cx = field((k >> 42) & 0x1FFFFF), cz = field(k & 0x1FFFFF);
		const int dx = cx - center.x, dz = cz - center.z;
		if (dx * dx + dz * dz > (r + 1) * (r + 1)) {
			save_chunk(pos_of(it->first), it->second);
			free_chunk_render(it->second);
			_mesh_candidates.erase(it->first);
			_urgent.erase(it->first);
			_column_tops.erase(key(Vector3i(cx, 0, cz)));
			it = _chunks.erase(it);
			unloaded = true;
		} else {
			++it;
		}
	}
	if (unloaded) {
		drop_stale_jobs();
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
				Chunk &c = _chunks.emplace(k, Chunk()).first->second;
				c.serial = _next_serial++;
				Job job;
				job.kind = JOB_GENERATE;
				job.pos = p;
				job.serial = c.serial;
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
		const Vector3i p = pos_of(*it);
		const int dx = p.x - center.x, dz = p.z - center.z;
		const bool urgent = _urgent.count(*it) > 0;
		if (!urgent && dx * dx + dz * dz > r * r) {
			++it; // not in view yet; keep as a candidate
			continue;
		}
		Job job;
		job.kind = JOB_MESH;
		job.pos = p;
		job.priority = float(dx * dx + dz * dz) + std::abs(p.y) * 0.5f - (urgent ? 1e6f : 0.0f);
		job.version = c.mesh_version;
		job.serial = c.serial;
		job.urgent = urgent;
		job.self = c.data;
		bool ready = true;
		for (int dy = -1; dy <= 1 && ready; dy++) {
			for (int dz = -1; dz <= 1 && ready; dz++) {
				for (int dx = -1; dx <= 1 && ready; dx++) {
					const Vector3i np = p + Vector3i(dx, dy, dz);
					if (np.y > CHUNK_Y_MAX || np.y < CHUNK_Y_MIN) {
						continue; // outside the world: air above / solid below
					}
					auto nit = _chunks.find(key(np));
					if (nit == _chunks.end() || !nit->second.data) {
						ready = false;
						break;
					}
					job.neighbourhood[neighbourhood_index(dx, dy, dz)] = nit->second.data;
				}
			}
		}
		for (int dz = -1; dz <= 1 && ready; dz++) {
			for (int dx = -1; dx <= 1 && ready; dx++) {
				auto tit = _column_tops.find(key(Vector3i(p.x + dx, 0, p.z + dz)));
				if (tit == _column_tops.end()) {
					ready = false; // a column isn't fully loaded: sky light unknown
					break;
				}
				job.tops[(dz + 1) * 3 + (dx + 1)] = tit->second;
			}
		}
		if (!ready) {
			++it; // a neighbour will add us back when it arrives; keep for now
			continue;
		}
		c.mesh_queued = true;
		_urgent.erase(*it);
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
	if (r.serial != c.serial || r.version != c.mesh_version) {
		return; // a newer mesh for this chunk is on its way
	}
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
	ClassDB::bind_method(D_METHOD("is_chunk_loaded", "chunk_pos"), &GoCubeWorld::is_chunk_loaded);
	ClassDB::bind_method(D_METHOD("tree_blocks", "kind", "ground"), &GoCubeWorld::tree_blocks);
	ClassDB::bind_method(D_METHOD("configure_generator", "seed", "ids", "ores", "trees"), &GoCubeWorld::configure_generator);
	ClassDB::bind_method(D_METHOD("configure_biomes", "biomes"), &GoCubeWorld::configure_biomes);
	ClassDB::bind_method(D_METHOD("biome_at", "x", "z"), &GoCubeWorld::biome_at);
	ClassDB::bind_method(D_METHOD("generated_height", "x", "z"), &GoCubeWorld::generated_height);
	ClassDB::bind_method(D_METHOD("start"), &GoCubeWorld::start);
	ClassDB::bind_method(D_METHOD("get_block", "position"), &GoCubeWorld::get_block);
	ClassDB::bind_method(D_METHOD("set_block", "position", "id"), &GoCubeWorld::set_block);
	ClassDB::bind_method(D_METHOD("raycast", "origin", "direction", "max_distance"), &GoCubeWorld::raycast);
	ClassDB::bind_method(D_METHOD("move_box", "position", "size", "motion", "step_height"), &GoCubeWorld::move_box);
	ClassDB::bind_method(D_METHOD("is_box_free", "position", "size"), &GoCubeWorld::is_box_free);
	ClassDB::bind_method(D_METHOD("set_save_directory", "dir"), &GoCubeWorld::set_save_directory);
	ClassDB::bind_method(D_METHOD("save_modified"), &GoCubeWorld::save_modified);
	ClassDB::bind_method(D_METHOD("get_edited_chunks"), &GoCubeWorld::get_edited_chunks);
	ClassDB::bind_method(D_METHOD("get_chunk_bytes", "chunk_pos"), &GoCubeWorld::get_chunk_bytes);
	ClassDB::bind_method(D_METHOD("set_chunk_override", "chunk_pos", "bytes"), &GoCubeWorld::set_chunk_override);
	ClassDB::bind_method(D_METHOD("is_area_meshed", "area"), &GoCubeWorld::is_area_meshed);
	ClassDB::bind_method(D_METHOD("get_stats"), &GoCubeWorld::get_stats);

	ClassDB::bind_method(D_METHOD("set_view_distance", "blocks"), &GoCubeWorld::set_view_distance);
	ClassDB::bind_method(D_METHOD("get_view_distance"), &GoCubeWorld::get_view_distance);
	ClassDB::bind_method(D_METHOD("set_viewer_position", "position"), &GoCubeWorld::set_viewer_position);
	ClassDB::bind_method(D_METHOD("get_viewer_position"), &GoCubeWorld::get_viewer_position);
	ClassDB::bind_method(D_METHOD("set_worker_threads", "count"), &GoCubeWorld::set_worker_threads);
	ClassDB::bind_method(D_METHOD("get_worker_threads"), &GoCubeWorld::get_worker_threads);
	ClassDB::bind_method(D_METHOD("effective_worker_threads"), &GoCubeWorld::effective_worker_threads);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "worker_threads"), "set_worker_threads", "get_worker_threads");
	ClassDB::bind_method(D_METHOD("set_smooth_lighting", "enabled"), &GoCubeWorld::set_smooth_lighting);
	ClassDB::bind_method(D_METHOD("get_smooth_lighting"), &GoCubeWorld::get_smooth_lighting);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "smooth_lighting"), "set_smooth_lighting", "get_smooth_lighting");
	ClassDB::bind_method(D_METHOD("set_upload_budget_ms", "ms"), &GoCubeWorld::set_upload_budget_ms);
	ClassDB::bind_method(D_METHOD("get_upload_budget_ms"), &GoCubeWorld::get_upload_budget_ms);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "view_distance"), "set_view_distance", "get_view_distance");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "viewer_position"), "set_viewer_position", "get_viewer_position");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "upload_budget_ms"), "set_upload_budget_ms", "get_upload_budget_ms");
}

} // namespace gocube
