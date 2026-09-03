class_name GameContent
extends RefCounted

const DEFAULT_MAP_SIZE_PROFILE := "large"
const MAP_SIZE_PROFILES := {
	"small": {
		"label": "Small",
		"province_count": 48,
		"hex_grid_size": Vector2i(50, 32),
		"hex_continent_count": 3,
	},
	"medium": {
		"label": "Medium",
		"province_count": 96,
		"hex_grid_size": Vector2i(70, 46),
		"hex_continent_count": 4,
	},
	"large": {
		"label": "Large",
		"province_count": 192,
		"hex_grid_size": Vector2i(100, 64),
		"hex_continent_count": 5,
	},
	"ultra": {
		"label": "Ultra",
		"province_count": 320,
		"hex_grid_size": Vector2i(129, 84),
		"hex_continent_count": 7,
	},
}


static func map_size_profile_ids() -> Array[String]:
	var profile_ids: Array[String] = []
	profile_ids.assign(MAP_SIZE_PROFILES.keys())
	return profile_ids


static func is_valid_map_size_profile(profile_id: String) -> bool:
	return MAP_SIZE_PROFILES.has(profile_id)


static func map_size_profile(profile_id: String) -> Dictionary:
	if not MAP_SIZE_PROFILES.has(profile_id):
		push_error("Unknown map size profile: %s" % profile_id)
		return {}
	return (MAP_SIZE_PROFILES[profile_id] as Dictionary).duplicate(true)
