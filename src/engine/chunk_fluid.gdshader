shader_type spatial;
// Fluid surface for the native engine: flat colour, see-through, lit like the
// terrain (chunk.gdshader): everything but the sun is EMISSION, the sun's
// share comes in light() times Godot's shadow, so water lies in the shade of
// hills and clouds like the shore does.
render_mode blend_mix, cull_disabled, depth_draw_opaque, ambient_light_disabled, specular_disabled;

uniform vec4 fluid_color : source_color = vec4(0.25, 0.46, 0.84, 0.7);
// The terrain atlas: each fluid's tile gives its colour and transparency
// (water: see-through blue, lava: opaque and glowing).
uniform sampler2D albedo_texture : source_color, filter_nearest;
uniform bool use_atlas = false;
uniform float daylight : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sky_tint : source_color = vec3(1.0);  // see chunk.gdshaderinc
uniform float sun_amount = 1.0;                    // see chunk.gdshaderinc
uniform vec2 cloud_offset = vec2(0.0);
const float SHADE = 0.55;                          // as in chunk.gdshaderinc
uniform vec3 block_light_color : source_color = vec3(1.0, 0.85, 0.62);
uniform float min_light = 0.02;
uniform vec3 underside_color : source_color = vec3(0.72, 0.88, 1.0);
uniform float underside_alpha = 0.82;
// Torches held in hand: a light level per block (r * 255 = 0..15), spread
// like placed light by World.set_hand_lights, in the cube of
// HAND_LIGHT_SIZE blocks from hand_light_origin (slices by height: x, z, y).
// Each face takes the level of
// the block in front of it, so held light falls in whole blocks too.
uniform highp sampler3D hand_light_volume : filter_nearest;
uniform vec3 hand_light_origin = vec3(0.0);
const float HAND_LIGHT_SIZE = 48.0;  // World.HAND_LIGHT_SIZE
uniform int hand_light_count = 0;

varying vec3 v_world;
varying vec3 v_normal;
varying vec3 v_sun;  // what the sun adds where it reaches (fragment -> light)

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_normal = NORMAL;
}

// Gentle moving ripples (0..1), from world position and time.
float ripples(vec2 p) {
	float a = sin(p.x * 1.7 + TIME * 0.9) * sin(p.y * 1.3 - TIME * 0.7);
	float b = sin((p.x + p.y) * 2.3 - TIME * 1.3);
	return 0.5 + 0.25 * a + 0.25 * b;
}

#include "res://src/engine/block_light.gdshaderinc"

void fragment() {
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
	float r = ripples(v_world.xz);
	vec4 base = use_atlas ? texture(albedo_texture, UV) : fluid_color;
	vec3 color = base.rgb * (0.92 + 0.16 * r);
	float alpha = base.a;
	vec3 full = max(sky, blk);
	vec3 shade = max(sky * (1.0 - SHADE * sun_amount), blk);
	if (!FRONT_FACING && alpha < 0.99) {
		// Seen from underneath (you're in the water): a bright, nearly opaque
		// ceiling, so the surface is clearly visible from below.
		color = mix(base.rgb, underside_color, 0.45 + 0.3 * r);
		alpha = underside_alpha;
		shade = full;  // (no sun or shadows on it)
	}
	ALBEDO = vec3(1.0);
	EMISSION = color * shade;
	float sunlit = COLOR.a > 0.875 ? 1.0 : 0.0;  // 0.75: in a block's shadow (see chunk.gdshaderinc)
	v_sun = color * (full - shade) * sunlit * (1.0 - CLOUD_SHADE * cloud_cover(v_world.xz, cloud_offset));
	ALPHA = alpha;
}

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += v_sun * smoothstep(0.1, 0.7, ATTENUATION);  // as in chunk.gdshaderinc
	}
}
