shader_type spatial;
// Dropped items: unlit like the terrain, with per-face shading (by the mesh's
// own normal) and the time of day.
render_mode unshaded, cull_disabled;

uniform sampler2D tex : source_color, filter_nearest;
uniform float light = 1.0;  // set by ItemDrop.set_daylight

varying vec3 local_normal;

void vertex() {
	local_normal = NORMAL;
}

void fragment() {
	vec4 c = texture(tex, UV);
	if (c.a < 0.5) discard;
	vec3 n = abs(local_normal);
	float shade = local_normal.y > 0.5 ? 1.0 : (local_normal.y < -0.5 ? 0.55 : (n.x > 0.5 ? 0.8 : 0.7));
	ALBEDO = c.rgb * shade * light;
}
