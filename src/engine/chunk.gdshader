shader_type spatial;
// Chunk material for the native engine (GoCubeWorld). Classic block lighting:
// flat face shading by normal, times the light the engine bakes into the
// vertex colour (white until the light engine lands).
render_mode unshaded;

uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap;
uniform vec4 face_light = vec4(1.0, 0.8, 0.6, 0.5);  // top, north/south, east/west, bottom

varying vec3 v_normal;

void vertex() {
	v_normal = NORMAL;
}

void fragment() {
	vec3 n = v_normal;
	float face = n.y > 0.5 ? face_light.x
			: (n.y < -0.5 ? face_light.w : (abs(n.z) > 0.5 ? face_light.y : face_light.z));
	ALBEDO = texture(albedo_texture, UV).rgb * COLOR.rgb * face;
}
