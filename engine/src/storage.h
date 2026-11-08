// Saving and loading edited chunks: one small file per chunk, run-length
// encoded block ids. Pure C++; safe to call from worker threads for different
// files.
#pragma once

#include "chunk.h"

#include <cstdint>
#include <string>
#include <vector>

namespace gocube {

std::string chunk_file_path(const std::string &dir, int cx, int cy, int cz);

// The same format in memory (used to send chunks over the network).
std::vector<uint8_t> encode_chunk(const ChunkData &chunk);
bool decode_chunk(const uint8_t *data, size_t size, ChunkData &chunk);

// Chunk positions of every chunk file in `dir`.
std::vector<std::array<int, 3>> list_chunk_files(const std::string &dir);

// Writes atomically (temp file + rename). Returns false on I/O error.
bool save_chunk_file(const std::string &path, const ChunkData &chunk);

// Returns false if the file is missing or invalid (then `chunk` is untouched).
bool load_chunk_file(const std::string &path, ChunkData &chunk);

} // namespace gocube
