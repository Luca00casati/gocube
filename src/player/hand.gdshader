shader_type spatial;
// The first-person hand and held item: unlit like the world, drawn on top of
// everything (so it never pokes into walls).
render_mode unshaded, depth_test_disabled, cull_back;

uniform sampler2D tex : source_color, filter_nearest;
uniform bool use_tex = false;
uniform vec4 tint : source_color = vec4(1.0);
uniform float light = 1.0;

varying vec3 local_normal;

void vertex() {
	local_normal = NORMAL;
}

void fragment() {
	vec4 c = use_tex ? texture(tex, UV) : tint;
	if (c.a < 0.5) discard;
	vec3 n = abs(local_normal);
	float shade = local_normal.y > 0.5 ? 1.0 : (local_normal.y < -0.5 ? 0.55 : (n.x > 0.5 ? 0.8 : 0.7));
	ALBEDO = c.rgb * shade * light;
}
