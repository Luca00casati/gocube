#include "mesher.h"

namespace gocube {

namespace {

struct FaceDef {
	int dx, dy, dz;          // normal / direction to the neighbour
	float corners[4][3];     // quad corners relative to the block's min corner
	float st[4][2];          // texture coords (0..1 inside the tile) per corner
	int order[6];            // triangle indices giving clockwise (front) winding
};

// Builds the 6 face definitions once. Corners go around the face in (u, v)
// tangent order; the winding is then chosen so triangles are clockwise when
// seen from outside, which is what Godot treats as front-facing.
struct FaceTable {
	FaceDef f[FACE_COUNT];

	FaceTable() {
		const int normals[FACE_COUNT][3] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
		for (int i = 0; i < FACE_COUNT; i++) {
			FaceDef &d = f[i];
			d.dx = normals[i][0];
			d.dy = normals[i][1];
			d.dz = normals[i][2];
			const int axis = d.dx ? 0 : (d.dy ? 1 : 2);
			const float plane = (d.dx + d.dy + d.dz) > 0 ? 1.0f : 0.0f;
			// Tangents: X faces -> (z, y); Y faces -> (x, z); Z faces -> (x, y).
			const int ua = axis == 0 ? 2 : 0;
			const int va = axis == 1 ? 2 : 1;
			const float uv[4][2] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } };
			for (int c = 0; c < 4; c++) {
				float p[3] = { 0, 0, 0 };
				p[axis] = plane;
				p[ua] = uv[c][0];
				p[va] = uv[c][1];
				d.corners[c][0] = p[0];
				d.corners[c][1] = p[1];
				d.corners[c][2] = p[2];
				if (axis == 1) {
					d.st[c][0] = uv[c][0]; // top/bottom: u along x, v along z
					d.st[c][1] = uv[c][1];
				} else {
					d.st[c][0] = uv[c][0]; // sides: u horizontal, v from the top down
					d.st[c][1] = 1.0f - uv[c][1];
				}
			}
			// Winding: (c1 - c0) x (c2 - c0) must point away from the normal.
			float e1[3], e2[3];
			for (int k = 0; k < 3; k++) {
				e1[k] = d.corners[1][k] - d.corners[0][k];
				e2[k] = d.corners[2][k] - d.corners[0][k];
			}
			const float cx = e1[1] * e2[2] - e1[2] * e2[1];
			const float cy = e1[2] * e2[0] - e1[0] * e2[2];
			const float cz = e1[0] * e2[1] - e1[1] * e2[0];
			const bool ccw_from_outside = cx * d.dx + cy * d.dy + cz * d.dz > 0.0f;
			const int cw[6] = { 0, 2, 1, 0, 3, 2 };
			const int ccw[6] = { 0, 1, 2, 0, 2, 3 };
			for (int k = 0; k < 6; k++) {
				d.order[k] = ccw_from_outside ? cw[k] : ccw[k];
			}
		}
	}
};

const FaceTable &faces() {
	static const FaceTable table;
	return table;
}

// Block at chunk-local coordinates that may be one step outside the chunk.
inline BlockId sample(const ChunkData &c, const ChunkData *const nb[FACE_COUNT], const std::vector<BlockInfo> &blocks,
		int x, int y, int z, BlockId solid_fallback) {
	if (x >= 0 && y >= 0 && z >= 0 && x < CHUNK && y < CHUNK && z < CHUNK) {
		return c.get(x, y, z);
	}
	const ChunkData *n = nullptr;
	if (x >= CHUNK) {
		n = nb[FACE_PX];
		x -= CHUNK;
	} else if (x < 0) {
		n = nb[FACE_NX];
		x += CHUNK;
	} else if (y >= CHUNK) {
		if (!nb[FACE_PY]) {
			return AIR; // above the world
		}
		n = nb[FACE_PY];
		y -= CHUNK;
	} else if (y < 0) {
		n = nb[FACE_NY];
		y += CHUNK;
	} else if (z >= CHUNK) {
		n = nb[FACE_PZ];
		z -= CHUNK;
	} else {
		n = nb[FACE_NZ];
		z += CHUNK;
	}
	return n ? n->get(x, y, z) : solid_fallback;
}

void emit_face(Surface &s, const FaceDef &d, float bx, float by, float bz, const AtlasLayout &atlas, int tile) {
	const int base = static_cast<int>(s.positions.size() / 3);
	const float tw = 1.0f / (atlas.cols * atlas.cell);
	const float th = 1.0f / (atlas.rows * atlas.cell);
	const int col = tile % atlas.cols;
	const int row = tile / atlas.cols;
	const float u0 = (col * atlas.cell + atlas.face_x) * tw;
	const float v0 = (row * atlas.cell + atlas.face_y) * th;
	for (int c = 0; c < 4; c++) {
		s.positions.push_back(bx + d.corners[c][0]);
		s.positions.push_back(by + d.corners[c][1]);
		s.positions.push_back(bz + d.corners[c][2]);
		s.normals.push_back(static_cast<float>(d.dx));
		s.normals.push_back(static_cast<float>(d.dy));
		s.normals.push_back(static_cast<float>(d.dz));
		s.uvs.push_back(u0 + d.st[c][0] * tw);
		s.uvs.push_back(v0 + d.st[c][1] * th);
		s.colors.insert(s.colors.end(), { 1.0f, 1.0f, 1.0f, 1.0f });
	}
	for (int k = 0; k < 6; k++) {
		s.indices.push_back(base + d.order[k]);
	}
}

} // namespace

void mesh_chunk(const ChunkData &chunk, const ChunkData *const neighbours[FACE_COUNT],
		const std::vector<BlockInfo> &blocks, const AtlasLayout &atlas,
		Surface &opaque, Surface &fluid) {
	if (chunk.uniform && chunk.uniform_value == AIR) {
		return;
	}
	const FaceTable &table = faces();
	const BlockId count = static_cast<BlockId>(blocks.size());
	// Find any opaque block id to stand in for "solid ground" below the world.
	BlockId solid_fallback = AIR;
	for (BlockId i = 1; i < count; i++) {
		if (blocks[i].opaque) {
			solid_fallback = i;
			break;
		}
	}

	for (int y = 0; y < CHUNK; y++) {
		for (int z = 0; z < CHUNK; z++) {
			for (int x = 0; x < CHUNK; x++) {
				const BlockId id = chunk.get(x, y, z);
				if (id == AIR || id >= count) {
					continue;
				}
				const BlockInfo &info = blocks[id];
				for (int f = 0; f < FACE_COUNT; f++) {
					const FaceDef &d = table.f[f];
					const BlockId nid = sample(chunk, neighbours, blocks, x + d.dx, y + d.dy, z + d.dz, solid_fallback);
					const BlockInfo *n = nid < count ? &blocks[nid] : nullptr;
					const bool n_opaque = n && n->opaque;
					if (info.fluid) {
						// Fluid faces only towards air (not other fluid, not solid blocks).
						if (nid != AIR) {
							continue;
						}
						emit_face(fluid, d, x, y, z, atlas, info.tiles[f]);
					} else {
						// Opaque faces are hidden by opaque neighbours; see-through
						// blocks (e.g. glass) also hide faces against the same block.
						if (n_opaque || (!info.opaque && nid == id)) {
							continue;
						}
						emit_face(opaque, d, x, y, z, atlas, info.tiles[f]);
					}
				}
			}
		}
	}
}

} // namespace gocube
