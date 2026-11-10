shader_type spatial;
// The first-person hand and held item: unlit like the world, and drawn in
// front of everything (so it never pokes into walls). Their depth is squeezed
// into a thin slice right in front of the camera, so they are still depth
// tested among themselves: each part (arm, hand, item) gets its own slice,
// the item's in front, and its faces sort correctly within it.
render_mode unshaded, cull_back;

uniform sampler2D tex : source_color, filter_nearest;
uniform bool use_tex = false;
uniform vec4 tint : source_color = vec4(1.0);
uniform vec3 light = vec3(1.0);  // World.light_for at the eyes (set by Hand)
uniform int layer = 0; // 0 arm, 1 hand, 2 held item: higher is drawn in front

varying vec3 local_normal;

void vertex() {
	local_normal = NORMAL;
	POSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	// Each layer gets a thin slice of depth from 0.80 of the way to the near
	// plane, far closer than any wall could be (within ~1.25x the near plane).
	// Godot uses reverse Z in every renderer: depth 1 at the near plane.
	POSITION.z = POSITION.w * (0.80 + 0.06 * float(layer)) + POSITION.z * 0.04;
}

void fragment() {
	vec4 c = use_tex ? texture(tex, UV) : tint;
	if (c.a < 0.5) discard;
	vec3 n = abs(local_normal);
	float shade = local_normal.y > 0.5 ? 1.0 : (local_normal.y < -0.5 ? 0.55 : (n.x > 0.5 ? 0.8 : 0.7));
	ALBEDO = c.rgb * shade * light;
}
