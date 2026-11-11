// Chunk materials for the native engine (GoCubeWorld): chunk.gdshader for
// blocks whose textures are fully solid, chunk_cutout.gdshader (CUTOUT) for
// those with see-through pixels (leaves, glass, plants, torches). Only the
// latter discard pixels: a shader that can discard makes the GPU run it in the
// depth prepass and shadow pass and loses early depth testing, which cost
// about 13% of the GPU's frame when every block used it.
// Block lighting baked by
// the engine into the vertex colour: r = sky light, g = block light (0..1 =
// levels 0..15), b = corner occlusion (smooth lighting; 1 = none), a = 1,
// less 0.5 on faces whose green varies across the land (grass, leaves), less
// 0.25 on faces in a block's shadow (block shadows: the engine works out which
// faces the sun reaches; Godot's shadow map is off then).
//
// The sun on top of that: everything that doesn't come from the sun (block
// light, torches, the sky's light in shade, moonlight) is EMISSION; the
// sun's share is added in light(), times Godot's shadow (ATTENUATION), so
// hills, trees and buildings cast real shadows, faces turned away from the
// sun are in shade, and cloud shadows drift over the land. At night the sun
// is off and all of it is emission, unchanged.
render_mode ambient_light_disabled, specular_disabled;

uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap;
uniform vec4 face_light = vec4(1.0, 0.78, 0.6, 0.45);  // top, north/south, east/west, bottom
uniform float daylight : hint_range(0.0, 1.0) = 1.0;  // scales sky light (day/night)
// Sky light's colour: white by day, a cool moonlight blue at night.
uniform vec3 sky_tint : source_color = vec3(1.0);
// How much the sun shines (0 at night): in shade, sky light keeps
// 1 - SHADE * sun_amount of its strength.
uniform float sun_amount = 1.0;
const float SHADE = 0.55;
// Cloud shadows drift with the sky's clouds (DayCycle's offset, in cloud cells).
uniform vec2 cloud_offset = vec2(0.0);
uniform vec3 block_light_color : source_color = vec3(1.0, 0.85, 0.62);
uniform float min_light = 0.02;  // so pitch-dark caves aren't fully black
// Lights carried by players (a torch in hand): xyz position, w level 0..15,
// one level less per block of distance, like placed block light.
// Torches held in hand: a light level per block (r * 255 = 0..15), spread
// like placed light by World.set_hand_lights, in the cube of
// HAND_LIGHT_SIZE blocks from hand_light_origin (slices by height: x, z, y).
// Each face takes the level of
// the block in front of it, so held light falls in whole blocks too.
uniform highp sampler3D hand_light_volume : filter_nearest;
uniform vec3 hand_light_origin = vec3(0.0);
const float HAND_LIGHT_SIZE = 48.0;  // World.HAND_LIGHT_SIZE
uniform int hand_light_count = 0;

varying vec3 v_normal;
varying vec3 v_world;
varying vec3 v_sun;  // what the sun adds where it reaches (fragment -> light)

#include "res://src/engine/block_light.gdshaderinc"

// The green of grass and leaves drifts slowly across the land: yellower in
// places, deeper in others.
vec3 green_variation(vec2 xz) {
	float v = vnoise(xz / 41.0) * 0.65 + vnoise(xz / 13.0 + 5.0) * 0.35;
	return mix(vec3(0.8, 0.94, 0.78), vec3(1.14, 1.08, 0.8), v);
}

void vertex() {
	v_normal = NORMAL;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
#ifdef CUTOUT
	if (tex.a < 0.5) {
		discard;  // see-through pixels: glass, torches, ladders, plants
	}
#endif
	vec3 n = v_normal;
	float face = n.y > 0.5 ? face_light.x
			: (n.y < -0.5 ? face_light.w : (abs(n.z) > 0.5 ? face_light.y : face_light.z));
	vec3 base = tex.rgb;
	float marks = round(COLOR.a * 4.0);  // 4, 3 (shadow), 2 (tinted), 1 (tinted, shadow)
	float sunlit = 1.0 - mod(marks, 2.0);
	if (marks < 2.5) {  // grass, leaves: vary only the green pixels (not a grass side's dirt)
		float green = smoothstep(0.02, 0.08, tex.g - max(tex.r, tex.b));
		base *= mix(vec3(1.0), green_variation(v_world.xz), green);
	}
	base *= face * COLOR.b;

	vec3 sky = light_curve(COLOR.r) * daylight * sky_tint;
	vec3 blk = block_light_color * light_curve(COLOR.g);
	if (hand_light_count > 0) {
		vec3 cell = floor(v_world + v_normal * 0.5) - hand_light_origin;  // the block in front of the face
		if (all(greaterThanEqual(cell, vec3(0.0))) && all(lessThan(cell, vec3(HAND_LIGHT_SIZE)))) {
			float level = round(texture(hand_light_volume, (cell.xzy + 0.5) / HAND_LIGHT_SIZE).r * 255.0) / 15.0;
			blk = max(blk, block_light_color * light_curve(level));
		}
	}
	blk = max(blk, vec3(min_light));
	vec3 full = max(sky, blk);
	vec3 shade = max(sky * (1.0 - SHADE * sun_amount), blk);
	ALBEDO = vec3(1.0);
	EMISSION = base * shade;
	v_sun = base * (full - shade) * sunlit * (1.0 - CLOUD_SHADE * cloud_cover(v_world.xz, cloud_offset));
}

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		// Faces turned towards the sun get its share (softly, from edge-on);
		// shadows and faces turned away don't.
		float facing = smoothstep(0.0, 0.25, dot(NORMAL, LIGHT));
		// Soft shadow filtering leaves ATTENUATION around 0.8 in full sun: count
		// that as sunlit, so lit and shaded ground differ as much as they should.
		DIFFUSE_LIGHT += v_sun * facing * smoothstep(0.1, 0.7, ATTENUATION);
	}
}
