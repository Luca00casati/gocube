#include "storage.h"

#include <array>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <vector>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace gocube {

namespace {

// Paths come from Godot as UTF-8; on Windows they must become wide paths, or
// folders with non-ASCII names (a user called Ëlla) can't be opened.
std::filesystem::path native_path(const std::string &utf8) {
	return std::filesystem::u8path(utf8);
}

// Replaces `to` with `from` in one step. std::rename can't on Windows when
// `to` exists (every save after the first).
bool replace_file(const std::string &from, const std::string &to) {
#ifdef _WIN32
	return MoveFileExW(native_path(from).c_str(), native_path(to).c_str(),
			MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
#else
	return std::rename(from.c_str(), to.c_str()) == 0;
#endif
}

// File layout (little-endian):
//   "GCC1"                     magic + format version
//   u8   uniform               1 = every block is `value`
//   u16  value                 (uniform only)
//   u32  run_count             (non-uniform only)
//   run_count x { u16 length, u16 id }   runs over ChunkData::index order
constexpr char MAGIC[4] = { 'G', 'C', 'C', '1' };

} // namespace

std::string chunk_file_path(const std::string &dir, int cx, int cy, int cz) {
	char name[64];
	std::snprintf(name, sizeof(name), "/c.%d.%d.%d.bin", cx, cy, cz);
	return dir + name;
}

std::vector<uint8_t> encode_chunk(const ChunkData &chunk) {
	std::vector<uint8_t> out(MAGIC, MAGIC + 4);
	auto put16 = [&](uint16_t v) { out.push_back(v & 0xFF); out.push_back(v >> 8); };
	auto put32 = [&](uint32_t v) { put16(v & 0xFFFF); put16(v >> 16); };
	out.push_back(chunk.uniform ? 1 : 0);
	if (chunk.uniform) {
		put16(chunk.uniform_value);
		return out;
	}
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
	put32(static_cast<uint32_t>(runs.size() / 2));
	for (uint16_t v : runs) {
		put16(v);
	}
	return out;
}

bool decode_chunk(const uint8_t *data, size_t size, ChunkData &chunk) {
	size_t pos = 0;
	auto get16 = [&](uint16_t &v) {
		if (pos + 2 > size) return false;
		v = uint16_t(data[pos] | (data[pos + 1] << 8));
		pos += 2;
		return true;
	};
	if (size < 5 || std::memcmp(data, MAGIC, 4) != 0) {
		return false;
	}
	pos = 4;
	ChunkData result;
	const uint8_t uniform = data[pos++];
	if (uniform) {
		uint16_t value = 0;
		if (!get16(value)) return false;
		result.uniform = true;
		result.uniform_value = value;
	} else {
		uint16_t lo = 0, hi = 0;
		if (!get16(lo) || !get16(hi)) return false;
		const uint32_t count = lo | (uint32_t(hi) << 16);
		if (count == 0 || count > CHUNK_VOLUME) return false;
		result.uniform = false;
		result.blocks.reserve(CHUNK_VOLUME);
		for (uint32_t i = 0; i < count; i++) {
			uint16_t length = 0, id = 0;
			if (!get16(length) || !get16(id) || result.blocks.size() + length > CHUNK_VOLUME) return false;
			result.blocks.insert(result.blocks.end(), length, id);
		}
		if (result.blocks.size() != CHUNK_VOLUME) return false;
	}
	chunk = std::move(result);
	return true;
}

bool save_chunk_file(const std::string &path, const ChunkData &chunk) {
	const std::vector<uint8_t> bytes = encode_chunk(chunk);
	const std::string tmp = path + ".tmp";
	{
		std::ofstream f(native_path(tmp), std::ios::binary | std::ios::trunc);
		if (!f) {
			return false;
		}
		f.write(reinterpret_cast<const char *>(bytes.data()), std::streamsize(bytes.size()));
		f.close();
		if (!f) {
			std::error_code ec;
			std::filesystem::remove(native_path(tmp), ec);
			return false;
		}
	}
	return replace_file(tmp, path);
}

bool load_chunk_file(const std::string &path, ChunkData &chunk) {
	std::ifstream f(native_path(path), std::ios::binary);
	if (!f) {
		return false;
	}
	std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	return decode_chunk(bytes.data(), bytes.size(), chunk);
}

std::vector<std::array<int, 3>> list_chunk_files(const std::string &dir) {
	std::vector<std::array<int, 3>> out;
	std::error_code ec;
	for (const auto &entry : std::filesystem::directory_iterator(native_path(dir), ec)) {
		int x, y, z;
		const std::string name = entry.path().filename().string();
		char tail = 0;
		if (std::sscanf(name.c_str(), "c.%d.%d.%d.bi%c", &x, &y, &z, &tail) == 4 && tail == 'n' &&
				name.size() > 4 && name.compare(name.size() - 4, 4, ".bin") == 0) {
			out.push_back({ x, y, z });
		}
	}
	return out;
}

} // namespace gocube
