extends SceneTree

const Content = preload("res://src/data/game_content.gd")
const Settings = preload("res://src/world3d/resources/world_generation_settings.gd")
const Generator = preload("res://src/world3d/generator/hex_world_generator.gd")
const DevelopmentScene = preload("res://scenes/hex_world_development.tscn")


func _init() -> void:
	var settings := Settings.new()
	settings.seed = 10
	settings.map_size_profile = "small"
	var first := Generator.generate(settings)
	var second := Generator.generate(settings)

	if first.tiles.size() != 50 * 32:
		push_error("Small profile generated %d tiles instead of 1600." % first.tiles.size())
		quit(1)
		return
	if first.deterministic_signature() != second.deterministic_signature():
		push_error("Identical settings did not produce an identical world.")
		quit(1)
		return
	var development_scene := DevelopmentScene.instantiate()
	if development_scene == null:
		push_error("The development scene could not be instantiated.")
		quit(1)
		return
	development_scene.free()
	if Content.map_size_profile_ids().size() != 4:
		push_error("Expected all four map size profiles.")
		quit(1)
		return

	print("Godot Test smoke test passed.")
	quit()
