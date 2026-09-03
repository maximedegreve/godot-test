class_name HexWorldSerializer
extends RefCounted

## Phase 5 versioned serialization for the logical 3D hex world.
##
## The payload stores every logical field that the Phase 1-4 deterministic
## signatures consume, so a save/load round-trip is signature-preserving rather
## than merely visually similar. Floating point fields are stored as IEEE
## doubles because the climate and ecology signatures format them to five
## decimals and a lossy float32 round-trip could flip a tie.
##
## This is prototype persistence for the isolated 3D world. It does not read,
## write, or migrate production campaign saves.

const HexCoordinatesScript = preload("res://src/world3d/hex/hex_coordinates.gd")

const MAGIC := "TLCHEX3D"
const SCHEMA_VERSION := 1
## Oldest payload this build can still read. Bump only alongside a migration.
const MINIMUM_SUPPORTED_VERSION := 1
const FILE_EXTENSION := "tlchex"

const _INT_FIELDS := [
	"elevation_level",
	"effective_elevation",
	"flow_direction",
	"runoff",
	"flow_accumulation",
	"watershed_id",
	"lake_id",
	"lake_outlet_direction",
	"region_id",
	"continent_id",
	"exclusion_flags",
]
const _DOUBLE_FIELDS := [
	"elevation",
	"temperature",
	"moisture",
	"ocean_moisture",
	"vegetation_density",
	"freshwater_access",
	"movement_cost",
]
const _STRING_FIELDS := [
	"terrain_type",
	"biome",
	"resource_type",
	"feature_type",
]


static func serialize(world: HexWorldData) -> Dictionary:
	var interner := _StringInterner.new()
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	for tile in world.tiles:
		buffer.put_32(tile.coordinate.x)
		buffer.put_32(tile.coordinate.y)
		buffer.put_32(tile.offset_coordinate.x)
		buffer.put_32(tile.offset_coordinate.y)
		for field in _INT_FIELDS:
			buffer.put_32(int(tile.get(field)))
		for field in _DOUBLE_FIELDS:
			buffer.put_double(float(tile.get(field)))
		for field in _STRING_FIELDS:
			buffer.put_u16(interner.index_of(String(tile.get(field))))
		buffer.put_u8((1 if tile.is_water else 0) | (2 if tile.is_ocean else 0))
		buffer.put_data(_padded_bytes(tile.river_connections, 6))
		buffer.put_data(_padded_bytes(tile.river_selected_connections, 6))
		for direction in range(6):
			buffer.put_32(
				tile.river_flow[direction] if direction < tile.river_flow.size() else 0
			)
	return {
		"magic": MAGIC,
		"schema_version": SCHEMA_VERSION,
		"seed": world.seed,
		"profile_id": String(world.profile_id),
		"width": world.width,
		"height": world.height,
		"hex_size": world.hex_size,
		"tile_count": world.tiles.size(),
		"string_table": interner.table(),
		"tiles": buffer.data_array,
		"metadata": world.metadata.duplicate(true),
		"signatures": {
			"deterministic": world.deterministic_signature(),
			"climate": world.climate_signature(),
			"hydrology": world.hydrology_signature(),
			"ecology": world.ecology_signature(),
		},
	}


static func deserialize(payload: Variant) -> Dictionary:
	if not payload is Dictionary:
		return _failure("The 3D hex world payload is not a dictionary.")
	var data: Dictionary = payload
	if String(data.get("magic", "")) != MAGIC:
		return _failure("The payload is not a 3D hex world save.")
	if not data.has("schema_version"):
		return _failure("The 3D hex world payload has no schema version.")
	var version := int(data["schema_version"])
	if version > SCHEMA_VERSION:
		return _failure(
			"3D hex world schema version %d is newer than this build supports (%d)."
			% [version, SCHEMA_VERSION]
		)
	if version < MINIMUM_SUPPORTED_VERSION:
		return _failure(
			"3D hex world schema version %d is older than the supported minimum (%d)."
			% [version, MINIMUM_SUPPORTED_VERSION]
		)
	for required in ["seed", "profile_id", "width", "height", "tile_count", "tiles"]:
		if not data.has(required):
			return _failure("The 3D hex world payload is missing '%s'." % required)
	var tile_count := int(data["tile_count"])
	var bytes: PackedByteArray = data["tiles"]
	var expected_bytes := tile_count * record_size()
	if bytes.size() != expected_bytes:
		return _failure(
			"The 3D hex world payload has %d tile bytes but %d were expected."
			% [bytes.size(), expected_bytes]
		)
	var string_table := PackedStringArray(data.get("string_table", PackedStringArray()))
	var world := HexWorldData.new()
	world.seed = int(data["seed"])
	world.profile_id = StringName(String(data["profile_id"]))
	world.width = int(data["width"])
	world.height = int(data["height"])
	world.hex_size = float(data.get("hex_size", 1.0))
	world.metadata = (data.get("metadata", {}) as Dictionary).duplicate(true)
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.data_array = bytes
	for _index in range(tile_count):
		var tile := HexTileData.new()
		tile.coordinate = Vector2i(buffer.get_32(), buffer.get_32())
		tile.offset_coordinate = Vector2i(buffer.get_32(), buffer.get_32())
		tile.position = HexCoordinatesScript.axial_to_world(tile.coordinate, world.hex_size)
		for field in _INT_FIELDS:
			tile.set(field, buffer.get_32())
		for field in _DOUBLE_FIELDS:
			tile.set(field, buffer.get_double())
		for field in _STRING_FIELDS:
			var string_index := buffer.get_u16()
			if string_index >= string_table.size():
				return _failure("The 3D hex world payload references an unknown string.")
			tile.set(field, StringName(string_table[string_index]))
		var flags := buffer.get_u8()
		tile.is_water = (flags & 1) != 0
		tile.is_ocean = (flags & 2) != 0
		tile.river_connections = buffer.get_data(6)[1]
		tile.river_selected_connections = buffer.get_data(6)[1]
		var flows := PackedInt32Array()
		for _direction in range(6):
			flows.append(buffer.get_32())
		tile.river_flow = flows
		world.add_tile(tile)
	var signatures: Dictionary = data.get("signatures", {})
	var mismatches := PackedStringArray()
	if signatures.has("deterministic") and String(signatures["deterministic"]) != world.deterministic_signature():
		mismatches.append("deterministic")
	if signatures.has("climate") and String(signatures["climate"]) != world.climate_signature():
		mismatches.append("climate")
	if signatures.has("hydrology") and String(signatures["hydrology"]) != world.hydrology_signature():
		mismatches.append("hydrology")
	if signatures.has("ecology") and String(signatures["ecology"]) != world.ecology_signature():
		mismatches.append("ecology")
	if not mismatches.is_empty():
		return _failure(
			"The restored 3D hex world does not reproduce its %s signature(s)."
			% ", ".join(mismatches)
		)
	return {"ok": true, "world": world, "schema_version": version, "error": ""}


static func record_size() -> int:
	return (
		4 * 4
		+ _INT_FIELDS.size() * 4
		+ _DOUBLE_FIELDS.size() * 8
		+ _STRING_FIELDS.size() * 2
		+ 1
		+ 12
		+ 6 * 4
	)


static func save_to_file(world: HexWorldData, path: String) -> Dictionary:
	var directory := path.get_base_dir()
	if not directory.is_empty():
		var directory_error := DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(directory)
		)
		if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
			return _failure("Could not create the 3D hex world save directory.")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _failure(
			"Could not open %s for writing: %s"
			% [path, error_string(FileAccess.get_open_error())]
		)
	var encoded := var_to_bytes(serialize(world))
	file.store_buffer(encoded)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		return _failure("Could not finish the 3D hex world save: %s" % error_string(write_error))
	return {"ok": true, "error": "", "bytes": encoded.size(), "path": path}


static func load_from_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _failure("No 3D hex world save exists at %s." % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure(
			"Could not open %s for reading: %s"
			% [path, error_string(FileAccess.get_open_error())]
		)
	var encoded := file.get_buffer(file.get_length())
	file.close()
	if encoded.is_empty():
		return _failure("The 3D hex world save at %s is empty." % path)
	var payload: Variant = bytes_to_var(encoded)
	if payload == null:
		return _failure("The 3D hex world save at %s is corrupt." % path)
	return deserialize(payload)


static func _padded_bytes(source: PackedByteArray, length: int) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(length)
	for index in range(length):
		result[index] = source[index] if index < source.size() else 0
	return result


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "world": null, "error": message}


class _StringInterner extends RefCounted:
	var _indices: Dictionary = {}
	var _values := PackedStringArray()

	func index_of(value: String) -> int:
		if _indices.has(value):
			return int(_indices[value])
		var index := _values.size()
		_values.append(value)
		_indices[value] = index
		return index

	func table() -> PackedStringArray:
		return _values
