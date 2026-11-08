// Gradient noise (2D/3D) and fractal sums, deterministic per seed.
// Self-contained: no external noise library.
#pragma once

#include <cmath>
#include <cstdint>

namespace gocube {

// Integer hash of a lattice point; well mixed, cheap.
inline uint32_t hash_point(int32_t x, int32_t y, int32_t z, uint32_t seed) {
	uint32_t h = seed * 0x9E3779B1u;
	h ^= static_cast<uint32_t>(x) * 0x85EBCA77u;
	h = (h << 13) | (h >> 19);
	h ^= static_cast<uint32_t>(y) * 0xC2B2AE3Du;
	h = (h << 17) | (h >> 15);
	h ^= static_cast<uint32_t>(z) * 0x27D4EB2Fu;
	h ^= h >> 16;
	h *= 0x7FEB352Du;
	h ^= h >> 15;
	h *= 0x846CA68Bu;
	h ^= h >> 16;
	return h;
}

inline float smooth5(float t) {
	return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

inline float mixf(float a, float b, float t) {
	return a + (b - a) * t;
}

// Dot product of the offset with one of 8 unit directions picked by hash.
inline float grad2(uint32_t h, float x, float y) {
	constexpr float d = 0.70710678f;
	switch (h & 7u) {
		case 0: return x;
		case 1: return -x;
		case 2: return y;
		case 3: return -y;
		case 4: return (x + y) * d;
		case 5: return (x - y) * d;
		case 6: return (-x + y) * d;
		default: return (-x - y) * d;
	}
}

// Dot product with one of 12 directions towards cube edge midpoints.
inline float grad3(uint32_t h, float x, float y, float z) {
	switch (h % 12u) {
		case 0: return x + y;
		case 1: return -x + y;
		case 2: return x - y;
		case 3: return -x - y;
		case 4: return x + z;
		case 5: return -x + z;
		case 6: return x - z;
		case 7: return -x - z;
		case 8: return y + z;
		case 9: return -y + z;
		case 10: return y - z;
		default: return -y - z;
	}
}

// Roughly in [-1, 1].
inline float noise2(float x, float y, uint32_t seed) {
	const float fx = std::floor(x), fy = std::floor(y);
	const int32_t ix = static_cast<int32_t>(fx), iy = static_cast<int32_t>(fy);
	const float dx = x - fx, dy = y - fy;
	const float n00 = grad2(hash_point(ix, iy, 0, seed), dx, dy);
	const float n10 = grad2(hash_point(ix + 1, iy, 0, seed), dx - 1.0f, dy);
	const float n01 = grad2(hash_point(ix, iy + 1, 0, seed), dx, dy - 1.0f);
	const float n11 = grad2(hash_point(ix + 1, iy + 1, 0, seed), dx - 1.0f, dy - 1.0f);
	const float u = smooth5(dx), v = smooth5(dy);
	return mixf(mixf(n00, n10, u), mixf(n01, n11, u), v) * 1.4f;
}

// Roughly in [-1, 1].
inline float noise3(float x, float y, float z, uint32_t seed) {
	const float fx = std::floor(x), fy = std::floor(y), fz = std::floor(z);
	const int32_t ix = static_cast<int32_t>(fx), iy = static_cast<int32_t>(fy), iz = static_cast<int32_t>(fz);
	const float dx = x - fx, dy = y - fy, dz = z - fz;
	float c[8];
	for (int i = 0; i < 8; i++) {
		const int ox = i & 1, oy = (i >> 1) & 1, oz = (i >> 2) & 1;
		c[i] = grad3(hash_point(ix + ox, iy + oy, iz + oz, seed), dx - ox, dy - oy, dz - oz);
	}
	const float u = smooth5(dx), v = smooth5(dy), w = smooth5(dz);
	const float x00 = mixf(c[0], c[1], u), x10 = mixf(c[2], c[3], u);
	const float x01 = mixf(c[4], c[5], u), x11 = mixf(c[6], c[7], u);
	return mixf(mixf(x00, x10, v), mixf(x01, x11, v), w) * 0.95f;
}

// Fractal sum normalised to roughly [-1, 1].
inline float fbm2(float x, float y, uint32_t seed, int octaves) {
	float sum = 0.0f, amp = 1.0f, norm = 0.0f;
	for (int i = 0; i < octaves; i++) {
		sum += noise2(x, y, seed + static_cast<uint32_t>(i) * 1013u) * amp;
		norm += amp;
		amp *= 0.5f;
		x *= 2.0f;
		y *= 2.0f;
	}
	return sum / norm;
}

} // namespace gocube
