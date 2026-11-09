shader_type sky;
// The sky: a colour gradient, a square pixel sun and moon, stars at night and a
// drifting layer of blocky clouds. Everything is driven by DayCycle.apply().
// The radiance (ambient light) pass only gets the gradient, so stars and
// clouds don't make the lighting flicker.

uniform vec3 top_color : source_color = vec3(0.32, 0.52, 0.86);
uniform vec3 horizon_color : source_color = vec3(0.68, 0.79, 0.92);
uniform vec3 ground_color : source_color = vec3(0.35, 0.33, 0.30);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);   // towards the sun
uniform float day = 1.0;                       // 0 night .. 1 day
uniform float dusk = 0.0;                      // 1 at sunrise / sunset
uniform float sky_angle = 0.0;                 // the sky's turn (stars move with it)
uniform vec2 cloud_offset = vec2(0.0);         // drifting clouds, in cloud cells

const float SUN_SIZE = 0.075;   // half-width, in the sun's tangent plane
const float MOON_SIZE = 0.055;
const float CLOUD_SCALE = 22.0; // cells across one unit of the cloud plane

float hash3(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

float hash2(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Smooth value noise, sampled at whole cells by the caller (so clouds are blocky).
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash2(i), b = hash2(i + vec2(1, 0)), c = hash2(i + vec2(0, 1)), d = hash2(i + vec2(1, 1));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Where `dir` hits the square around `center` (in its tangent plane): -1..1 per
// axis, or outside (|value| > 1).
vec2 square_uv(vec3 dir, vec3 center, float size) {
	vec3 up_ref = abs(center.z) < 0.99 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 u = normalize(cross(up_ref, center));
	vec3 v = cross(center, u);
	float d = dot(dir, center);
	if (d <= 0.0) {
		return vec2(9.0);
	}
	vec3 p = dir / d - center;  // onto the plane touching the sky at `center`
	return vec2(dot(p, u), dot(p, v)) / size;
}

vec3 rotate_z(vec3 p, float a) {
	float c = cos(a), s = sin(a);
	return vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z);
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float h = dir.y;

	// Gradient: horizon colour near h = 0, top colour overhead, ground below.
	vec3 col = mix(horizon_color, top_color, smoothstep(0.0, 0.55, h));
	col = mix(col, ground_color, smoothstep(0.0, -0.25, h));
	// A warm glow on the sun's side of the horizon at sunrise / sunset.
	float sun_side = max(dot(normalize(dir.xz + 1e-4), normalize(sun_dir.xz + 1e-4)), 0.0);
	col += vec3(0.35, 0.12, 0.02) * dusk * pow(sun_side, 3.0) * (1.0 - smoothstep(0.0, 0.35, abs(h)));

	if (AT_CUBEMAP_PASS) {
		COLOR = col;
	} else {
		// Stars: fixed to the turning sky, only at night and above the horizon.
		float night = pow(1.0 - day, 2.0);
		if (night > 0.01 && h > 0.0) {
			vec3 sd = rotate_z(dir, -sky_angle) * 140.0;
			vec3 cell = floor(sd);
			float r = hash3(cell);
			if (r > 0.9965) {
				float dist = length(fract(sd) - 0.5);
				float size = 0.18 + 0.12 * hash3(cell + 7.0);
				float twinkle = 0.75 + 0.25 * sin(TIME * (1.5 + 3.0 * r) + r * 40.0);
				float star = step(dist, size) * twinkle * smoothstep(0.0, 0.25, h);
				col += vec3(0.85, 0.9, 1.0) * star * night;
			}
		}

		// Sun: a bright square with a soft glow around it.
		vec2 su = square_uv(dir, sun_dir, SUN_SIZE);
		float sun_vis = smoothstep(-0.12, 0.02, sun_dir.y);
		if (max(abs(su.x), abs(su.y)) < 1.0) {
			col = mix(col, vec3(1.0, 0.96, 0.78), sun_vis);
		}
		float glow = max(dot(dir, sun_dir), 0.0);
		col += vec3(1.0, 0.8, 0.5) * pow(glow, 60.0) * 0.5 * sun_vis;

		// Moon: opposite the sun, an 8x8 pixel disc with darker craters.
		vec3 moon_dir = -sun_dir;
		vec2 mu = square_uv(dir, moon_dir, MOON_SIZE);
		if (max(abs(mu.x), abs(mu.y)) < 1.0 && moon_dir.y > -0.1) {
			vec2 px = floor((mu * 0.5 + 0.5) * 8.0);  // 0..7
			vec2 c = px - 3.5;
			if (length(c) < 4.2) {
				float crater = step(0.72, hash2(px + 3.0));
				vec3 moon = mix(vec3(0.86, 0.88, 0.92), vec3(0.62, 0.64, 0.7), crater);
				col = mix(col, moon, smoothstep(-0.1, 0.05, moon_dir.y));
			}
		}
		col += vec3(0.6, 0.7, 0.9) * pow(max(dot(dir, moon_dir), 0.0), 120.0) * 0.25 * (1.0 - day);

		// Clouds: a flat layer above, blocky cells from smooth noise, drifting.
		if (h > 0.0) {
			vec2 plane = dir.xz / h;  // where the view ray meets a layer at height 1
			vec2 cell = floor(plane * CLOUD_SCALE + cloud_offset);
			float n = vnoise(cell * 0.085) * 0.7 + vnoise(cell * 0.23 + 17.0) * 0.3;
			float cloud = step(0.6, n);
			float core = step(0.7, n);
			float fade = smoothstep(0.06, 0.32, h);  // thin out towards the horizon
			vec3 lit = mix(vec3(0.018, 0.02, 0.032), vec3(1.0), day);  // linear colour
			lit = mix(lit, vec3(1.0, 0.72, 0.55), dusk * 0.6);
			vec3 cloud_col = mix(lit * 0.86, lit, core);
			col = mix(col, cloud_col, cloud * fade * 0.92);
		}
		COLOR = col;
	}
}
