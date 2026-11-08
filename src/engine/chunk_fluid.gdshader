shader_type spatial;
// Fluid surface for the native engine: flat colour, see-through, lit like terrain.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_opaque;

uniform vec4 fluid_color : source_color = vec4(0.25, 0.46, 0.84, 0.7);
uniform float daylight : hint_range(0.0, 1.0) = 1.0;
uniform vec3 block_light_color : source_color = vec3(1.0, 0.85, 0.62);
uniform float min_light = 0.035;

float light_curve(float level01) {
	return level01 <= 0.0 ? 0.0 : pow(0.8, 15.0 - level01 * 15.0);
}

void fragment() {
	vec3 light = max(vec3(light_curve(COLOR.r) * daylight), block_light_color * light_curve(COLOR.g));
	ALBEDO = fluid_color.rgb * max(light, vec3(min_light));
	ALPHA = fluid_color.a;
}
