shader_type spatial;
// Fluid surface for the native engine: flat colour, see-through, lit like terrain.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_opaque;

uniform vec4 fluid_color : source_color = vec4(0.25, 0.46, 0.84, 0.7);
// The terrain atlas: each fluid's tile gives its colour and transparency
// (water: see-through blue, lava: opaque and glowing).
uniform sampler2D albedo_texture : source_color, filter_nearest;
uniform bool use_atlas = false;
uniform float daylight : hint_range(0.0, 1.0) = 1.0;
uniform vec3 block_light_color : source_color = vec3(1.0, 0.85, 0.62);
uniform float min_light = 0.035;
uniform vec3 underside_color : source_color = vec3(0.72, 0.88, 1.0);
uniform float underside_alpha = 0.82;
const int MAX_HAND_LIGHTS = 8;  // as in chunk.gdshader
uniform vec4 hand_lights[MAX_HAND_LIGHTS];
uniform int hand_light_count = 0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Gentle moving ripples (0..1), from world position and time.
float ripples(vec2 p) {
	float a = sin(p.x * 1.7 + TIME * 0.9) * sin(p.y * 1.3 - TIME * 0.7);
	float b = sin((p.x + p.y) * 2.3 - TIME * 1.3);
	return 0.5 + 0.25 * a + 0.25 * b;
}

float light_curve(float level01) {
	return level01 <= 0.0 ? 0.0 : pow(0.8, 15.0 - level01 * 15.0);
}

void fragment() {
	vec3 light = max(vec3(light_curve(COLOR.r) * daylight), block_light_color * light_curve(COLOR.g));
	for (int i = 0; i < hand_light_count; i++) {
		float level = clamp(hand_lights[i].w - distance(v_world, hand_lights[i].xyz), 0.0, 15.0) / 15.0;
		light = max(light, block_light_color * light_curve(level));
	}
	float r = ripples(v_world.xz);
	vec4 base = use_atlas ? texture(albedo_texture, UV) : fluid_color;
	vec3 color = base.rgb * (0.92 + 0.16 * r);
	float alpha = base.a;
	if (!FRONT_FACING && alpha < 0.99) {
		// Seen from underneath (you're in the water): a bright, nearly opaque
		// ceiling, so the surface is clearly visible from below.
		color = mix(base.rgb, underside_color, 0.45 + 0.3 * r);
		alpha = underside_alpha;
	}
	ALBEDO = color * max(light, vec3(min_light));
	ALPHA = alpha;
}
