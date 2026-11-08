#include "mesher.h"

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

// Light for each of the 4 corners: {sky, block, occlusion}.
struct CornerLight {
	float sky[4], block[4], ao[4];
};

// top_height: where the face's upper corners sit (1 = full block; lower for
// flowing fluids).
void emit_face(Surface &s, const FaceDef &d, float bx, float by, float bz, const AtlasLayout &atlas, int tile,
		const CornerLight &cl, float top_height = 1.0f) {
	const int base = static_cast<int>(s.positions.size() / 3);
	const float tw = 1.0f / (atlas.cols * atlas.cell);
	const float th = 1.0f / (atlas.rows * atlas.cell);
	const int col = tile % atlas.cols;
	const int row = tile / atlas.cols;
	const float u0 = (col * atlas.cell + atlas.face_x) * tw;
	const float v0 = (row * atlas.cell + atlas.face_y) * th;
	for (int c = 0; c < 4; c++) {
		s.positions.push_back(bx + d.corners[c][0]);
		s.positions.push_back(by + (d.corners[c][1] > 0.5f ? top_height : d.corners[c][1]));
		s.positions.push_back(bz + d.corners[c][2]);
		s.normals.push_back(static_cast<float>(d.dx));
		s.normals.push_back(static_cast<float>(d.dy));
		s.normals.push_back(static_cast<float>(d.dz));
		s.uvs.push_back(u0 + d.st[c][0] * tw);
		s.uvs.push_back(v0 + d.st[c][1] * th);
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
	ao = 1.0f - 0.18f * occluders;
}

} // namespace

void mesh_chunk(const ChunkData &chunk, const ChunkData *const neighbours[FACE_COUNT],
		const std::vector<BlockInfo> &blocks, const AtlasLayout &atlas, const LightRegion *light,
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
				for (int f = 0; f < FACE_COUNT; f++) {
					const FaceDef &d = table.f[f];
					const BlockId nid = sample(chunk, neighbours, blocks, x + d.dx, y + d.dy, z + d.dz, solid_fallback);
					const BlockInfo *n = nid < count ? &blocks[nid] : nullptr;
					const bool n_opaque = n && n->opaque;
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
						// Surface height: full under more fluid, else by level (a
						// source is a little below the block top).
						const BlockId above = sample(chunk, neighbours, blocks, x, y + 1, z, solid_fallback);
						const bool covered = above < count && blocks[above].fluid;
						const float height = covered ? 1.0f : std::max(0.125f, info.fluid_level / 8.0f * 0.875f);
						// Faces towards air, and sides towards lower fluid (so steps
						// between water levels have no gaps).
						const bool lower_fluid = n && n->fluid && d.dy == 0 && n->fluid_level < info.fluid_level && !covered;
						if (nid != AIR && !lower_fluid) {
							continue;
						}
						if (d.dy > 0 && covered) {
							continue;
						}
						emit_face(fluid, d, x, y, z, atlas, info.tiles[f], cl, height);
					} else {
						// Opaque faces are hidden by opaque neighbours; see-through
						// blocks (e.g. glass) also hide faces against the same block.
						if (n_opaque || (!info.opaque && nid == id)) {
							continue;
						}
						if (info.emit > 0) {
							for (int c = 0; c < 4; c++) { // glowing blocks are lit by themselves
								cl.block[c] = info.emit / float(LIGHT_MAX);
								cl.ao[c] = 1.0f;
							}
						}
						emit_face(opaque, d, x, y, z, atlas, info.tiles[f], cl);
					}
				}
			}
		}
	}
}

} // namespace gocube
