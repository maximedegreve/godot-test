class_name HexTileData
extends RefCounted

var coordinate := Vector2i.ZERO
var offset_coordinate := Vector2i.ZERO
var position := Vector3.ZERO
var elevation_level := 0
var elevation := 0.0
var terrain_type: StringName = &"ocean"
var biome: StringName = &"unassigned"
var temperature := 0.0
var moisture := 0.0
var ocean_moisture := 0.0
var is_water := true
var is_ocean := false
var effective_elevation := 0
var flow_direction := -1
var runoff := 0
var flow_accumulation := 0
var watershed_id := -1
var lake_id := -1
var lake_outlet_direction := -1
var river_connections := PackedByteArray([0, 0, 0, 0, 0, 0])
var river_selected_connections := PackedByteArray([0, 0, 0, 0, 0, 0])
var river_flow := PackedInt32Array([0, 0, 0, 0, 0, 0])
var region_id := -1
var continent_id := -1
var movement_cost := 1.0
var resource_type: StringName = &""
var feature_type: StringName = &""
var vegetation_density := 0.0
var freshwater_access := 0.0
var exclusion_flags := 0


func stable_signature() -> String:
	return "%d,%d:%d:%s:%d" % [
		coordinate.x,
		coordinate.y,
		elevation_level,
		terrain_type,
		continent_id,
	]


func climate_signature() -> String:
	return "%d,%d:%.5f:%.5f:%s" % [
		coordinate.x,
		coordinate.y,
		temperature,
		moisture,
		biome,
	]


func hydrology_signature() -> String:
	var edge_flows := PackedStringArray()
	for flow in river_flow:
		edge_flows.append(str(flow))
	return "%d,%d:%d:%d:%d:%d:%d:%d:%d:%s:%s:%s" % [
		coordinate.x,
		coordinate.y,
		effective_elevation,
		flow_direction,
		runoff,
		flow_accumulation,
		watershed_id,
		lake_id,
		lake_outlet_direction,
		river_connections.hex_encode(),
		river_selected_connections.hex_encode(),
		",".join(edge_flows),
	]


func ecology_signature() -> String:
	return "%d,%d:%.5f:%s:%s:%d" % [
		coordinate.x,
		coordinate.y,
		vegetation_density,
		feature_type,
		resource_type,
		exclusion_flags,
	]
