// Shared by the terrain and fluid shaders (chunk.gdshader, chunk_fluid.gdshader):
// the light curve, smooth noise, and cloud shadows on the ground.

// Each light level is 80% as bright as the one above; level 0 is dark.
float light_curve(float level01) {
	return level01 <= 0.0 ? 0.0 : pow(0.8, 15.0 - level01 * 15.0);
}

float hash2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1, 0)), f.x), mix(hash2(i + vec2(0, 1)), hash2(i + vec2(1, 1)), f.x), f.y);
}

// Cloud shadows: soft patches from the same kind of noise as the sky's
// clouds, drifting with them (offset: DayCycle's cloud offset, in cloud cells).
const float CLOUD_CELL = 9.0;      // metres per cloud cell on the ground
const float CLOUD_SHADE = 0.85;    // how much of the sun a cloud blocks

// 0 clear .. 1 under a cloud, soft-edged.
float cloud_cover(vec2 xz, vec2 offset) {
	vec2 c = xz / CLOUD_CELL + offset;
	float n = vnoise(c * 0.085) * 0.7 + vnoise(c * 0.23 + 17.0) * 0.3;
	return smoothstep(0.56, 0.64, n);
}
