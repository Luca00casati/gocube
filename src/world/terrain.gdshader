shader_type spatial;
// Classic block-game lighting, no real-time lights or shadow maps:
//  - flat face shading: top brightest, sides darker, bottom darkest;
//  - column skylight: a face is in shadow when the air in front of it lies
//    below the highest opaque block of that column (sky_tops, see SkyLight).
render_mode unshaded;

uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap;
// R32F, one texel per world column: first air y above the highest opaque block.
uniform sampler2D sky_tops : filter_nearest, repeat_disable;
uniform vec2 sky_origin;            // world (x, z) of texel (0, 0)
uniform float sky_size = 0.0;       // texels per side; 0 = no skylight data yet
uniform float shadow = 0.55;        // brightness in shadow
uniform vec4 face_light = vec4(1.0, 0.8, 0.6, 0.5);  // top, north/south, east/west, bottom
uniform bool use_vertex_ao = false;  // the mesher's per-corner occlusion (smoother look)

varying vec3 v_world;
varying vec3 v_normal;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = v_normal;
	float face = n.y > 0.5 ? face_light.x
			: (n.y < -0.5 ? face_light.w : (abs(n.z) > 0.5 ? face_light.y : face_light.z));

	// The air voxel this face looks into decides whether it is lit.
	vec3 p = v_world + n * 0.5;
	vec2 cell = floor(p.xz) - sky_origin;
	float light = 1.0;
	if (cell.x >= 0.0 && cell.y >= 0.0 && cell.x < sky_size && cell.y < sky_size) {
		float top = texelFetch(sky_tops, ivec2(cell), 0).r;
		// "- 1.0": the cell just below `top` is the opaque block itself, so air
		// can only be there if the column estimate is one too high; treat as lit.
		if (floor(p.y) < top - 1.0) {
			light = shadow;
		}
	}

	vec3 ao = use_vertex_ao ? COLOR.rgb : vec3(1.0);
	ALBEDO = texture(albedo_texture, UV).rgb * ao * face * light;
}
