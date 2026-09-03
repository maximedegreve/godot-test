// Animated seaweed adapted from UnionBytes' MIT-licensed Realistic Water demo.
//
// The imported mesh remains static in CPU memory. Render-only sway is applied
// in the vertex shader with a per-instance deterministic phase supplied through
// MultiMesh custom data, so every plant moves differently without per-frame
// script work.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_sampler : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_sampler : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D roughness_sampler : hint_default_white, filter_linear_mipmap_anisotropic;
uniform float sway_speed : hint_range(0.0, 3.0) = 0.75;
uniform float sway_strength : hint_range(0.0, 1.0) = 0.34;
uniform vec2 sway_direction = vec2(0.82, 0.42);

varying vec3 instance_tint;


void vertex() {
	vec2 direction = normalize(sway_direction);
	vec3 world_origin = MODEL_MATRIX[3].xyz;
	float height_factor = clamp((VERTEX.y + 0.05) / 2.85, 0.0, 1.0);
	float phase = (
		INSTANCE_CUSTOM.a * 6.2831853
		+ dot(world_origin.xz, vec2(0.37, 0.61))
	);
	float primary = sin(TIME * sway_speed + phase);
	float secondary = cos(TIME * sway_speed * 0.63 + phase * 1.71);
	float sway = (primary * 0.72 + secondary * 0.28) * sway_strength;
	VERTEX.xz += direction * sway * pow(height_factor, 1.65);
	instance_tint = INSTANCE_CUSTOM.rgb;
}


void fragment() {
	vec4 albedo_sample = texture(albedo_sampler, UV);
	if (albedo_sample.a < 0.55) {
		discard;
	}
	ALBEDO = albedo_sample.rgb * instance_tint;
	ROUGHNESS = 0.46 + texture(roughness_sampler, UV).r * 0.44;
	SPECULAR = 0.36;
	NORMAL_MAP = texture(normal_sampler, UV).rgb;
	NORMAL_MAP_DEPTH = 0.68;
}
