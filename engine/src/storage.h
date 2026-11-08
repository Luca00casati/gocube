// Saving and loading edited chunks: one small file per chunk, run-length
// encoded block ids. Pure C++; safe to call from worker threads for different
// files.
#pragma once

#include "chunk.h"

#include <string>

namespace gocube {

std::string chunk_file_path(const std::string &dir, int cx, int cy, int cz);

// Writes atomically (temp file + rename). Returns false on I/O error.
bool save_chunk_file(const std::string &path, const ChunkData &chunk);

// Returns false if the file is missing or invalid (then `chunk` is untouched).
bool load_chunk_file(const std::string &path, ChunkData &chunk);

} // namespace gocube
