extends Control
## Picks an experiment, from the main menu's Experiments button. A new experiment is a
## row here and its own scene; the tracker writes what it measures (pyscripts/experiment.py).

const Style := preload("res://Main_screen/Scripts/settings_style.gd")
const MAIN_SCREEN := "res://Main_screen/Scenes/main.tscn"

const EXPERIMENTS := [
	{
		"title": "Static grid",
		"about": "Take the device to each point of a grid on the table. At each one, every " \
			+ "camera frame is saved: the pose and the images.",
		"scene": "res://Experiments/static_grid.tscn",
	},
]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = Style.make_theme()
	var bg := ColorRect.new()
	bg.color = Style.GROUND
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	margin.add_child(col)

	var back := Button.new()
	back.text = "Back"
	back.icon = Style.icon("back")
	back.theme_type_variation = "QuietButton"
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(_back)
	col.add_child(back)
	col.add_child(Style.label("Experiments", "Title"))

	for experiment in EXPERIMENTS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 20)
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_child(Style.label(experiment["title"]))
		text.add_child(Style.wrapped(experiment["about"], "Helper"))
		row.add_child(text)
		var open := Button.new()
		open.text = "Open"
		open.theme_type_variation = "PrimaryButton"
		open.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		open.pressed.connect(func(): get_tree().change_scene_to_file(experiment["scene"]))
		row.add_child(open)
		col.add_child(Style.card(row))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_back()


func _back() -> void:
	get_tree().change_scene_to_file(MAIN_SCREEN)
