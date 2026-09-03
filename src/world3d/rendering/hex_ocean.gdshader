// Depth-aware refractive water for the continuous 3D hex terrain surface.
//
// Terrain chunks continue beneath this plane. Scene depth therefore measures
// the real water column: shallow coastal slopes reveal the sandy seabed while
// open water becomes progressively darker and more opaque. The optical model
// adapts UnionBytes' MIT-licensed Realistic Water texture workflow for the
// shared ocean and elevated-lake material.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D uv_sampler : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D normalmap_a_sampler : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D normalmap_b_sampler : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D foam_sampler : repeat_enable, filter_linear_mipmap;
uniform sampler2D caustic_sampler : repeat_enable, filter_linear_mipmap;
uniform vec3 shore_color : source_color = vec3(0.015, 0.55, 0.62);
uniform vec3 shallow_color : source_color = vec3(0.025, 0.34, 0.50);
uniform vec3 deep_color : source_color = vec3(0.02, 0.16, 0.31);
uniform float shallow_depth = 0.18;
uniform float deep_depth = 1.65;
uniform float absorption_strength : hint_range(0.1, 4.0) = 1.35;
uniform float refraction_strength : hint_range(0.0, 0.05) = 0.012;
uniform vec2 sampler_scale = vec2(0.18);
uniform vec2 sampler_direction = vec2(0.018, 0.014);
uniform float uv_sampler_scale = 0.37;
uniform float uv_sampler_strength : hint_range(0.0, 0.2) = 0.055;
uniform float normal_strength : hint_range(0.0, 1.0) = 0.38;
uniform float foam_strength : hint_range(0.0, 1.0) = 0.42;
uniform float foam_texture_scale = 0.82;
uniform float caustic_scale = 0.24;
uniform float caustic_strength : hint_range(0.0, 1.0) = 0.16;
uniform float opacity_scale : hint_range(0.0, 1.0) = 1.0;
uniform float edge_fade : hint_range(0.0, 1.0) = 0.0;

varying vec3 world_position;
varying vec2 surface_uv;


vec3 reconstruct_world_position(
	vec2 screen_uv,
	float raw_depth,
	mat4 inverse_projection,
	mat4 inverse_view
) {
	vec3 ndc = vec3(screen_uv * 2.0 - 1.0, raw_depth);
	vec4 scene_view = inverse_projection * vec4(ndc, 1.0);
	scene_view.xyz /= max(scene_view.w, 0.00001);
	return (inverse_view * vec4(scene_view.xyz, 1.0)).xyz;
}


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	surface_uv = UV;
}


void fragment() {
	vec2 base_uv = world_position.xz * sampler_scale;
	vec2 flow_offset = sampler_direction * TIME;
	vec2 distortion_uv = base_uv * uv_sampler_scale + flow_offset;
	vec2 uv_distortion = (
		texture(uv_sampler, distortion_uv).rg * 2.0 - 1.0
	) * uv_sampler_strength;
	vec2 water_uv = base_uv + uv_distortion;
	vec3 normal_a = (
		texture(normalmap_a_sampler, water_uv - flow_offset * 1.7).rgb
		* 2.0
		- 1.0
	);
	vec3 normal_b = (
		texture(
			normalmap_b_sampler,
			water_uv * 0.73 + flow_offset * 1.15 - uv_distortion * 0.6
		).rgb
		* 2.0
		- 1.0
	);
	float surface_detail_fade = 1.0 - smoothstep(
		0.012,
		0.045,
		length(fwidth(base_uv))
	);
	vec2 wave_slope = (
		normal_a.xy * 0.72 + normal_b.xy * 0.28
	) * surface_detail_fade;
	vec3 procedural_world_normal = normalize(
		vec3(
			wave_slope.x * normal_strength,
			1.0,
			wave_slope.y * normal_strength
		)
	);
	NORMAL = normalize(mat3(VIEW_MATRIX) * procedural_world_normal);

	float base_raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec3 base_scene_world = reconstruct_world_position(
		SCREEN_UV,
		base_raw_depth,
		INV_PROJECTION_MATRIX,
		INV_VIEW_MATRIX
	);
	float base_water_depth = max(world_position.y - base_scene_world.y, 0.0);
	float refraction_fade = smoothstep(0.015, shallow_depth * 0.9, base_water_depth);
	vec2 refraction_offset = (
		NORMAL.xy
		* refraction_strength
		* refraction_fade
	);
	vec2 refraction_uv = clamp(
		SCREEN_UV + refraction_offset,
		vec2(0.001),
		vec2(0.999)
	);
	float refracted_raw_depth = textureLod(depth_texture, refraction_uv, 0.0).r;
	vec3 refracted_scene_world = reconstruct_world_position(
		refraction_uv,
		refracted_raw_depth,
		INV_PROJECTION_MATRIX,
		INV_VIEW_MATRIX
	);
	float refracted_water_depth = max(
		world_position.y - refracted_scene_world.y,
		0.0
	);
	float refraction_valid = step(0.002, refracted_water_depth);
	refraction_uv = mix(SCREEN_UV, refraction_uv, refraction_valid);
	float water_depth = mix(
		base_water_depth,
		refracted_water_depth,
		refraction_valid
	);

	float depth_factor = smoothstep(shallow_depth, deep_depth, water_depth);
	float shore_factor = 1.0 - smoothstep(0.025, shallow_depth * 1.35, water_depth);
	vec3 refracted_scene = textureLod(
		screen_texture,
		refraction_uv,
		depth_factor * 1.35
	).rgb;

	vec3 water_color = mix(shallow_color, deep_color, depth_factor);
	water_color = mix(water_color, shore_color, shore_factor * 0.72);
	vec3 beer_transmittance = exp(
		-vec3(0.92, 0.42, 0.18) * water_depth * absorption_strength
	);
	vec3 color = (
		refracted_scene * beer_transmittance
		+ water_color * (vec3(1.0) - beer_transmittance)
	);
	color = mix(color, deep_color * 0.72, depth_factor * 0.55);

	float caustic_a = texture(
		caustic_sampler,
		base_uv * caustic_scale + flow_offset * 0.34 + uv_distortion
	).r;
	float caustic_b = texture(
		caustic_sampler,
		base_uv.yx * caustic_scale * vec2(-0.83, 1.17)
			- flow_offset * 0.21
			- uv_distortion * 0.7
	).r;
	float caustic = (
		pow(max(caustic_a * caustic_b, 0.0), 0.72)
		* (1.0 - depth_factor)
		* (1.0 - shore_factor * 0.25)
		* caustic_strength
	);
	color += vec3(0.24, 0.52, 0.48) * caustic;

	float foam_noise = pow(
		texture(
			foam_sampler,
			water_uv * foam_texture_scale - flow_offset * 1.8
		).r,
		8.0
	);
	float contact_foam = (
		shore_factor
		* smoothstep(0.28, 0.82, foam_noise)
		* mix(0.28, 1.0, surface_detail_fade)
	);
	float crest_foam = (
		(1.0 - depth_factor)
		* smoothstep(0.9, 1.0, foam_noise)
		* length(wave_slope)
		* 0.18
	);
	float foam = clamp((contact_foam + crest_foam) * foam_strength, 0.0, 0.72);
	color = mix(color, vec3(0.72, 0.9, 0.88), foam);

	float fresnel = pow(
		1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0),
		5.0
	);
	color = mix(color, vec3(0.42, 0.65, 0.76), fresnel * 0.28);

	ALBEDO = color;
	EMISSION = water_color * mix(0.045, 0.012, depth_factor);
	ROUGHNESS = mix(0.22, 0.31, depth_factor) + foam * 0.34;
	SPECULAR = mix(0.52, 0.74, fresnel);
	float boundary_alpha = smoothstep(0.0, 0.42, surface_uv.x);
	ALPHA = (
		(mix(0.74, 0.97, depth_factor) + fresnel * 0.025 + foam * 0.08)
		* opacity_scale
		* mix(1.0, boundary_alpha, edge_fade)
	);
}
