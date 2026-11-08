#include "storage.h"

#include <cstdio>
#include <cstring>
#include <vector>

namespace gocube {

namespace {

// File layout (little-endian):
//   "GCC1"                     magic + format version
//   u8   uniform               1 = every block is `value`
//   u16  value                 (uniform only)
//   u32  run_count             (non-uniform only)
//   run_count x { u16 length, u16 id }   runs over ChunkData::index order
constexpr char MAGIC[4] = { 'G', 'C', 'C', '1' };

template <typename T>
bool write_raw(FILE *f, T v) {
	return std::fwrite(&v, sizeof(T), 1, f) == 1;
}

template <typename T>
bool read_raw(FILE *f, T &v) {
	return std::fread(&v, sizeof(T), 1, f) == 1;
}

} // namespace

std::string chunk_file_path(const std::string &dir, int cx, int cy, int cz) {
	char name[64];
	std::snprintf(name, sizeof(name), "/c.%d.%d.%d.bin", cx, cy, cz);
	return dir + name;
}

bool save_chunk_file(const std::string &path, const ChunkData &chunk) {
	const std::string tmp = path + ".tmp";
	FILE *f = std::fopen(tmp.c_str(), "wb");
	if (!f) {
		return false;
	}
	bool ok = std::fwrite(MAGIC, 1, 4, f) == 4;
	ok = ok && write_raw<uint8_t>(f, chunk.uniform ? 1 : 0);
	if (chunk.uniform) {
		ok = ok && write_raw<uint16_t>(f, chunk.uniform_value);
	} else {
		std::vector<uint16_t> runs; // pairs: length, id
		uint16_t current = chunk.blocks[0];
		uint16_t length = 0;
		for (BlockId b : chunk.blocks) {
			if (b == current && length < 0xFFFF) {
				length++;
			} else {
				runs.push_back(length);
				runs.push_back(current);
				current = b;
				length = 1;
			}
		}
		runs.push_back(length);
		runs.push_back(current);
		ok = ok && write_raw<uint32_t>(f, static_cast<uint32_t>(runs.size() / 2));
		ok = ok && std::fwrite(runs.data(), sizeof(uint16_t), runs.size(), f) == runs.size();
	}
	ok = (std::fclose(f) == 0) && ok;
	if (!ok) {
		std::remove(tmp.c_str());
		return false;
	}
	return std::rename(tmp.c_str(), path.c_str()) == 0;
}

bool load_chunk_file(const std::string &path, ChunkData &chunk) {
	FILE *f = std::fopen(path.c_str(), "rb");
	if (!f) {
		return false;
	}
	ChunkData result;
	char magic[4];
	uint8_t uniform = 0;
	bool ok = std::fread(magic, 1, 4, f) == 4 && std::memcmp(magic, MAGIC, 4) == 0 && read_raw(f, uniform);
	if (ok && uniform) {
		uint16_t value = 0;
		ok = read_raw(f, value);
		result.uniform = true;
		result.uniform_value = value;
	} else if (ok) {
		uint32_t count = 0;
		ok = read_raw(f, count) && count > 0 && count <= CHUNK_VOLUME;
		std::vector<uint16_t> runs(ok ? count * 2 : 0);
		ok = ok && std::fread(runs.data(), sizeof(uint16_t), runs.size(), f) == runs.size();
		if (ok) {
			result.uniform = false;
			result.blocks.reserve(CHUNK_VOLUME);
			for (uint32_t i = 0; i < count && ok; i++) {
				const uint16_t length = runs[i * 2], id = runs[i * 2 + 1];
				ok = result.blocks.size() + length <= CHUNK_VOLUME;
				result.blocks.insert(result.blocks.end(), length, id);
			}
			ok = ok && result.blocks.size() == CHUNK_VOLUME;
		}
	}
	std::fclose(f);
	if (ok) {
		chunk = std::move(result);
	}
	return ok;
}

} // namespace gocube
