shader_type spatial;
// Creatures and player figures: unlit like the terrain (chunk.gdshader), with the same kind of
// per-face shading. Parts are either a flat colour or a block texture tiled once
// per metre (picked by the face's axis), so they look made of that block.
render_mode unshaded, cull_back;

uniform sampler2D tex : source_color, filter_nearest;
uniform bool use_tex = false;
uniform vec4 tint : source_color = vec4(1.0);
// The light where this creature or player is (World.light_for, set each
// frame): day or night sky, placed lights, held torches.
instance uniform vec3 lit : source_color = vec3(1.0);
uniform float glow = 0.0;    // light-emitting blocks never go darker than this
instance uniform float flash = 0.0;  // hurt: a red tint (per creature or player, 0..1)

varying vec3 local_pos;
varying vec3 local_normal;

void vertex() {
	local_pos = VERTEX;
	local_normal = NORMAL;
}

void fragment() {
	vec3 n = abs(local_normal);
	vec2 uv = n.y > 0.5 ? local_pos.xz : (n.x > 0.5 ? local_pos.zy : local_pos.xy);
	vec4 c = use_tex ? texture(tex, fract(vec2(uv.x, -uv.y) + 0.5)) * tint : tint;
	if (c.a < 0.5) discard;
	float shade = local_normal.y > 0.5 ? 1.0 : (local_normal.y < -0.5 ? 0.55 : (n.x > 0.5 ? 0.8 : 0.7));
	ALBEDO = mix(c.rgb * shade * max(lit, vec3(glow)), vec3(0.85, 0.08, 0.06), flash * 0.6);
}
