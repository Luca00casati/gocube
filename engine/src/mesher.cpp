#include "mesher.h"

#include <cstdlib>

namespace gocube {

namespace {

struct FaceDef {
	int dx, dy, dz;          // normal / direction to the neighbour
	float corners[4][3];     // quad corners relative to the block's min corner
	float st[4][2];          // texture coords (0..1 inside the tile) per corner
	int order[6];            // triangle indices giving clockwise (front) winding
	int flipped[6];          // same winding, using the other diagonal
	int ua, va;              // tangent axes
	int cu[4], cv[4];        // corner position along (ua, va): 0 or 1
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
			d.ua = ua;
			d.va = va;
			const float uv[4][2] = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } };
			for (int c = 0; c < 4; c++) {
				float p[3] = { 0, 0, 0 };
				p[axis] = plane;
				p[ua] = uv[c][0];
				p[va] = uv[c][1];
				d.cu[c] = int(uv[c][0]);
				d.cv[c] = int(uv[c][1]);
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
			const int cw_flip[6] = { 1, 3, 2, 1, 0, 3 };
			const int ccw_flip[6] = { 1, 2, 3, 1, 3, 0 };
			for (int k = 0; k < 6; k++) {
				d.order[k] = ccw_from_outside ? cw[k] : ccw[k];
				d.flipped[k] = ccw_from_outside ? cw_flip[k] : ccw_flip[k];
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

// A stable quarter-turn count (0..3) for a world block position.
static int block_rotation(int x, int y, int z) {
	uint32_t h = uint32_t(x) * 0x8da6b343u ^ uint32_t(y) * 0xd8163841u ^ uint32_t(z) * 0xcb1ab31fu;
	h ^= h >> 15;
	h *= 0x2c1b3c6du;
	h ^= h >> 12;
	return int(h >> 30);
}

// Light for each of the 4 corners: {sky, block, occlusion}.
struct CornerLight {
	float sky[4], block[4], ao[4];
};

// top_height: where the face's upper corners sit (1 = full block).
// rotation: quarter turns of the texture within the face (0..3).
// corner_tops (fluids): the height of each upper corner instead, by its
// position in the cell: [x + 2 * z] for x, z in {0, 1}.
void emit_face(Surface &s, const FaceDef &d, float bx, float by, float bz, const AtlasLayout &atlas, int tile,
		const CornerLight &cl, float top_height = 1.0f, int rotation = 0, const float *corner_tops = nullptr) {
	const int base = static_cast<int>(s.positions.size() / 3);
	const float tw = 1.0f / (atlas.cols * atlas.cell);
	const float th = 1.0f / (atlas.rows * atlas.cell);
	const int col = tile % atlas.cols;
	const int row = tile / atlas.cols;
	const float u0 = (col * atlas.cell + atlas.face_x) * tw;
	const float v0 = (row * atlas.cell + atlas.face_y) * th;
	for (int c = 0; c < 4; c++) {
		s.positions.push_back(bx + d.corners[c][0]);
		float top = top_height;
		if (corner_tops) {
			top = corner_tops[int(d.corners[c][0] + 0.5f) + 2 * int(d.corners[c][2] + 0.5f)];
		}
		s.positions.push_back(by + (d.corners[c][1] > 0.5f ? top : d.corners[c][1]));
		s.positions.push_back(bz + d.corners[c][2]);
		s.normals.push_back(static_cast<float>(d.dx));
		s.normals.push_back(static_cast<float>(d.dy));
		s.normals.push_back(static_cast<float>(d.dz));
		float su = d.st[c][0], sv = d.st[c][1];
		for (int r = 0; r < rotation; r++) {
			const float t = su;
			su = 1.0f - sv;
			sv = t;
		}
		s.uvs.push_back(u0 + su * tw);
		s.uvs.push_back(v0 + sv * th);
		s.colors.insert(s.colors.end(), { cl.sky[c], cl.block[c], cl.ao[c], 1.0f });
	}
	// Split the quad along the diagonal whose corners are more alike, so light
	// gradients don't show a crease.
	const float a = cl.ao[0] * (cl.sky[0] + cl.block[0]) + cl.ao[2] * (cl.sky[2] + cl.block[2]);
	const float b = cl.ao[1] * (cl.sky[1] + cl.block[1]) + cl.ao[3] * (cl.sky[3] + cl.block[3]);
	const int *order = a < b ? d.flipped : d.order;
	for (int k = 0; k < 6; k++) {
		s.indices.push_back(base + order[k]);
	}
}

// A quad with flat light: corners pos[4] (chunk-local), texture coords st[4]
// inside the tile, triangle order (front-facing winding).
void emit_quad(Surface &s, const float pos[4][3], const float st[4][2], const float normal[3], const AtlasLayout &atlas,
		int tile, float sky, float blk, const int order[6]) {
	const int base = static_cast<int>(s.positions.size() / 3);
	const float tw = 1.0f / (atlas.cols * atlas.cell);
	const float th = 1.0f / (atlas.rows * atlas.cell);
	const float u0 = ((tile % atlas.cols) * atlas.cell + atlas.face_x) * tw;
	const float v0 = ((tile / atlas.cols) * atlas.cell + atlas.face_y) * th;
	for (int c = 0; c < 4; c++) {
		s.positions.insert(s.positions.end(), { pos[c][0], pos[c][1], pos[c][2] });
		s.normals.insert(s.normals.end(), { normal[0], normal[1], normal[2] });
		s.uvs.push_back(u0 + st[c][0] * tw);
		s.uvs.push_back(v0 + st[c][1] * th);
		s.colors.insert(s.colors.end(), { sky, blk, 1.0f, 1.0f });
	}
	for (int k = 0; k < 6; k++) {
		s.indices.push_back(base + order[k]);
	}
}

// Smooth light at one corner of a face: average over the cell in front of the
// face and its 3 neighbours around that corner (skipping solid ones); solid
// neighbours also darken the corner.
void corner_light(const LightRegion &light, int fx, int fy, int fz, int ua, int va, int du, int dv,
		float &sky, float &blk, float &ao) {
	int p[3] = { fx, fy, fz };
	int pu[3] = { fx, fy, fz };
	int pv[3] = { fx, fy, fz };
	int puv[3] = { fx, fy, fz };
	pu[ua] += du;
	pv[va] += dv;
	puv[ua] += du;
	puv[va] += dv;
	const bool side_u = light.opaque_at(pu[0], pu[1], pu[2]);
	const bool side_v = light.opaque_at(pv[0], pv[1], pv[2]);
	// Light can't reach the diagonal cell around two solid sides.
	const bool diag = (side_u && side_v) || light.opaque_at(puv[0], puv[1], puv[2]);
	float s = light.sky_at(p[0], p[1], p[2]), b = light.block_at(p[0], p[1], p[2]);
	int n = 1;
	if (!side_u) { s += light.sky_at(pu[0], pu[1], pu[2]); b += light.block_at(pu[0], pu[1], pu[2]); n++; }
	if (!side_v) { s += light.sky_at(pv[0], pv[1], pv[2]); b += light.block_at(pv[0], pv[1], pv[2]); n++; }
	if (!diag) { s += light.sky_at(puv[0], puv[1], puv[2]); b += light.block_at(puv[0], puv[1], puv[2]); n++; }
	sky = s / (n * float(LIGHT_MAX));
	blk = b / (n * float(LIGHT_MAX));
	const int occluders = (side_u && side_v) ? 3 : int(side_u) + int(side_v) + int(diag);
	ao = 1.0f - 0.24f * occluders;
}

} // namespace

namespace {

// Everything that isn't a full cube: boxes, crossed plants, fences. Light is
// flat per face: the cell in front for faces on the block's edge, else the
// block's own cell (shaped blocks let light in).
template <typename Sample>
void emit_shape(Surface &s, const FaceTable &table, const BlockInfo &info, BlockId id, int x, int y, int z,
		const std::vector<BlockInfo> &blocks, const AtlasLayout &atlas, const LightRegion *light, Sample sample) {
	const BlockId count = static_cast<BlockId>(blocks.size());
	auto light_at = [&](int lx, int ly, int lz, float &sky, float &blk) {
		if (!light) {
			sky = 1.0f;
			blk = 0.0f;
		} else {
			sky = light->sky_at(lx, ly, lz) / float(LIGHT_MAX);
			blk = light->block_at(lx, ly, lz) / float(LIGHT_MAX);
		}
		if (info.emit > 0) {
			blk = std::max(blk, info.emit / float(LIGHT_MAX));
		}
	};
	if (info.shape == SHAPE_CROSS) {
		float sky, blk;
		light_at(x, y, z, sky, blk);
		const float a = 0.15f, b = 0.85f;
		const float quads[2][4][3] = {
			{ { a, 0, a }, { b, 0, b }, { b, 1, b }, { a, 1, a } },
			{ { a, 0, b }, { b, 0, a }, { b, 1, a }, { a, 1, b } },
		};
		const float st[4][2] = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } };
		const float normal[3] = { 0, 0, 1 }; // shaded like a north/south side
		const int front[6] = { 0, 1, 2, 0, 2, 3 };
		const int back[6] = { 0, 2, 1, 0, 3, 2 };
		for (const auto &q : quads) {
			float pos[4][3];
			for (int c = 0; c < 4; c++) {
				pos[c][0] = x + q[c][0];
				pos[c][1] = y + q[c][1];
				pos[c][2] = z + q[c][2];
			}
			emit_quad(s, pos, st, normal, atlas, info.tiles[0], sky, blk, front);
			emit_quad(s, pos, st, normal, atlas, info.tiles[0], sky, blk, back);
		}
		return;
	}
	std::vector<Box> fence;
	const std::vector<Box> *boxes = &info.model;
	if (info.shape == SHAPE_FENCE) {
		auto connects = [&](int nx, int ny, int nz) {
			const BlockId n = sample(nx, ny, nz);
			return n < count && n != AIR && (blocks[n].shape == SHAPE_FENCE || blocks[n].opaque);
		};
		fence_boxes(connects(x, y, z - 1), connects(x + 1, y, z), connects(x, y, z + 1), connects(x - 1, y, z), false, fence);
		boxes = &fence;
	}
	for (const Box &bx : *boxes) {
		for (int f = 0; f < FACE_COUNT; f++) {
			const FaceDef &d = table.f[f];
			const int axis = d.dx ? 0 : (d.dy ? 1 : 2);
			const bool positive = (d.dx + d.dy + d.dz) > 0;
			const bool on_edge = positive ? bx.mx[axis] >= 1.0f : bx.mn[axis] <= 0.0f;
			float sky, blk;
			if (on_edge) {
				const BlockId n = sample(x + d.dx, y + d.dy, z + d.dz);
				if (n < count && (blocks[n].opaque || (n == id && !info.opaque && blocks[n].shape == SHAPE_CUBE))) {
					continue; // covered by the neighbour
				}
				light_at(x + d.dx, y + d.dy, z + d.dz, sky, blk);
			} else {
				light_at(x, y, z, sky, blk);
			}
			float pos[4][3], st[4][2];
			for (int c = 0; c < 4; c++) {
				float p[3];
				for (int k = 0; k < 3; k++) {
					p[k] = d.corners[c][k] > 0.5f ? bx.mx[k] : bx.mn[k];
				}
				pos[c][0] = x + p[0];
				pos[c][1] = y + p[1];
				pos[c][2] = z + p[2];
				st[c][0] = p[d.ua];
				st[c][1] = axis == 1 ? p[d.va] : 1.0f - (p[d.va] - bx.ty);
			}
			const float normal[3] = { float(d.dx), float(d.dy), float(d.dz) };
			emit_quad(s, pos, st, normal, atlas, info.tiles[f], sky, blk, d.order);
		}
	}
}

// A block next to this chunk, also diagonally across an edge or corner of it
// (from the 3x3x3 neighbourhood; AIR if that isn't given).
BlockId sample_near(const ChunkData &c, const ChunkData *const nb[FACE_COUNT], const ChunkData *const hood[27],
		const std::vector<BlockInfo> &blocks, int x, int y, int z, BlockId solid_fallback) {
	const int dx = x < 0 ? -1 : (x >= CHUNK ? 1 : 0);
	const int dy = y < 0 ? -1 : (y >= CHUNK ? 1 : 0);
	const int dz = z < 0 ? -1 : (z >= CHUNK ? 1 : 0);
	if (std::abs(dx) + std::abs(dy) + std::abs(dz) <= 1) {
		return sample(c, nb, blocks, x, y, z, solid_fallback);
	}
	if (!hood) {
		return AIR;
	}
	const ChunkData *n = hood[neighbourhood_index(dx, dy, dz)];
	if (!n) {
		return dy > 0 ? AIR : solid_fallback; // above / below the world
	}
	return n->get(x - dx * CHUNK, y - dy * CHUNK, z - dz * CHUNK);
}

// Surface height of a fluid cell: full under more fluid, else by its level
// (a source sits a little below the block top).
float fluid_height(const ChunkData &c, const ChunkData *const nb[FACE_COUNT], const ChunkData *const hood[27],
		const std::vector<BlockInfo> &blocks, int x, int y, int z, BlockId solid_fallback, bool &covered) {
	const BlockId id = sample_near(c, nb, hood, blocks, x, y, z, solid_fallback);
	const BlockId above = sample_near(c, nb, hood, blocks, x, y + 1, z, solid_fallback);
	covered = above < blocks.size() && blocks[above].fluid;
	return covered ? 1.0f : std::max(0.125f, blocks[id].fluid_level / 8.0f * 0.875f);
}

// The height of each top corner of the fluid cell (x, y, z), [cx + 2 * cz]:
// the average surface of the fluid cells sharing that corner, or a full block
// if fluid pours into any of them from above. Neighbouring cells compute the
// same corner the same way, so their surfaces meet without steps or gaps.
void fluid_tops(const ChunkData &c, const ChunkData *const nb[FACE_COUNT], const ChunkData *const hood[27],
		const std::vector<BlockInfo> &blocks, int x, int y, int z, BlockId solid_fallback, float tops[4]) {
	for (int cz = 0; cz < 2; cz++) {
		for (int cx = 0; cx < 2; cx++) {
			float sum = 0.0f;
			int n = 0;
			bool full = false;
			for (int dz = cz - 1; dz <= cz && !full; dz++) {
				for (int dx = cx - 1; dx <= cx && !full; dx++) {
					const BlockId id = sample_near(c, nb, hood, blocks, x + dx, y, z + dz, solid_fallback);
					if (id >= blocks.size() || !blocks[id].fluid) {
						continue;
					}
					bool covered;
					const float h = fluid_height(c, nb, hood, blocks, x + dx, y, z + dz, solid_fallback, covered);
					full = covered;
					sum += h;
					n++;
				}
			}
			tops[cx + 2 * cz] = full ? 1.0f : sum / float(std::max(1, n));
		}
	}
}

} // namespace

void mesh_chunk(const ChunkData &chunk, const ChunkData *const neighbours[FACE_COUNT],
		const ChunkData *const hood[27], const std::vector<BlockInfo> &blocks, const AtlasLayout &atlas, const LightRegion *light,
		const MeshOptions &options, Surface &opaque, Surface &fluid) {
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
				if (info.shape != SHAPE_CUBE) {
					emit_shape(opaque, table, info, id, x, y, z, blocks, atlas, light,
							[&](int nx, int ny, int nz) { return sample(chunk, neighbours, blocks, nx, ny, nz, solid_fallback); });
					continue;
				}
				float tops[4];
				bool tops_done = false;
				for (int f = 0; f < FACE_COUNT; f++) {
					const FaceDef &d = table.f[f];
					const BlockId nid = sample(chunk, neighbours, blocks, x + d.dx, y + d.dy, z + d.dz, solid_fallback);
					const BlockInfo *n = nid < count ? &blocks[nid] : nullptr;
					const bool n_opaque = n && n->opaque;
					// Hidden faces first (most are): no light to work out for them.
					// Fluids: one connected surface, with faces only towards what
					// isn't fluid (and can be seen through). Opaque faces are hidden
					// by opaque neighbours; see-through blocks (e.g. glass) also hide
					// faces against the same block.
					if (info.fluid ? (nid != AIR && (!n || n->fluid || n->opaque))
								   : (n_opaque || (!info.opaque && nid == id))) {
						continue;
					}
					CornerLight cl;
					const int fx = x + d.dx, fy = y + d.dy, fz = z + d.dz; // the cell in front of the face
					for (int c = 0; c < 4; c++) {
						if (!light) {
							cl.sky[c] = 1.0f;
							cl.block[c] = 0.0f;
							cl.ao[c] = 1.0f;
						} else if (options.smooth_lighting && !info.fluid) {
							corner_light(*light, fx, fy, fz, d.ua, d.va, d.cu[c] ? 1 : -1, d.cv[c] ? 1 : -1,
									cl.sky[c], cl.block[c], cl.ao[c]);
						} else {
							cl.sky[c] = light->sky_at(fx, fy, fz) / float(LIGHT_MAX);
							cl.block[c] = light->block_at(fx, fy, fz) / float(LIGHT_MAX);
							cl.ao[c] = 1.0f;
						}
					}
					if (info.fluid) {
						// Each top corner at the height shared by the fluid cells
						// around it (see fluid_tops).
						if (!tops_done) {
							fluid_tops(chunk, neighbours, hood, blocks, x, y, z, solid_fallback, tops);
							tops_done = true;
						}
						emit_face(fluid, d, x, y, z, atlas, info.tiles[f], cl, 1.0f, 0, tops);
					} else {
						if (info.emit > 0) {
							for (int c = 0; c < 4; c++) { // glowing blocks are lit by themselves
								cl.block[c] = info.emit / float(LIGHT_MAX);
								cl.ao[c] = 1.0f;
							}
						}
						const int rot = info.random_rotation && d.dy != 0
								? block_rotation(options.origin_x + x, options.origin_y + y, options.origin_z + z)
								: 0;
						emit_face(opaque, d, x, y, z, atlas, info.tiles[f], cl, 1.0f, rot);
						if (info.tint) {
							// Vertex colour alpha 0.5 marks faces whose green varies (see chunk.gdshader).
							for (int c = 1; c <= 4; c++) {
								opaque.colors[opaque.colors.size() - 4 * c + 3] = 0.5f;
							}
						}
					}
				}
			}
		}
	}
}

} // namespace gocube
