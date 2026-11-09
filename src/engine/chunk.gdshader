shader_type spatial;
// Chunk material for the native engine (GoCubeWorld). Classic block lighting:
// flat face shading by normal, times the light the engine bakes into the
// vertex colour: r = sky light, g = block light (0..1 = levels 0..15),
// b = corner occlusion (smooth lighting; 1 = none).
render_mode unshaded;

uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap;
uniform vec4 face_light = vec4(1.0, 0.8, 0.6, 0.5);  // top, north/south, east/west, bottom
uniform float daylight : hint_range(0.0, 1.0) = 1.0;  // scales sky light (day/night)
uniform vec3 block_light_color : source_color = vec3(1.0, 0.85, 0.62);
uniform float min_light = 0.035;  // so pitch-dark caves aren't fully black
// Lights carried by players (a torch in hand): xyz position, w level 0..15,
// one level less per block of distance, like placed block light.
const int MAX_HAND_LIGHTS = 8;
uniform vec4 hand_lights[MAX_HAND_LIGHTS];
uniform int hand_light_count = 0;

varying vec3 v_normal;
varying vec3 v_world;

// Each level is 80% as bright as the one above; level 0 is dark.
float light_curve(float level01) {
	return level01 <= 0.0 ? 0.0 : pow(0.8, 15.0 - level01 * 15.0);
}

void vertex() {
	v_normal = NORMAL;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 n = v_normal;
	float face = n.y > 0.5 ? face_light.x
			: (n.y < -0.5 ? face_light.w : (abs(n.z) > 0.5 ? face_light.y : face_light.z));
	vec3 light = max(vec3(light_curve(COLOR.r) * daylight), block_light_color * light_curve(COLOR.g));
	for (int i = 0; i < hand_light_count; i++) {
		float level = clamp(hand_lights[i].w - distance(v_world, hand_lights[i].xyz), 0.0, 15.0) / 15.0;
		light = max(light, block_light_color * light_curve(level));
	}
	light = max(light, vec3(min_light));
	vec4 tex = texture(albedo_texture, UV);
	if (tex.a < 0.5) {
		discard;  // see-through pixels: glass, torches, ladders, plants
	}
	ALBEDO = tex.rgb * face * light * COLOR.b;
}
