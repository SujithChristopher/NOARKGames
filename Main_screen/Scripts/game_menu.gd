extends Control
## What the 2D and 3D game menus (select_game.tscn, 3d_games.tscn) share: the
## header (patient, 2D/3D switch, training hand), the Progress card kept apart
## from the games, Log out / Exit, and the hand question for patients who train
## both hands. Each menu extends this with its own games and their colours.

const GameButton := preload("res://Main_screen/Scripts/game_button.gd")
const MenuIcons := preload("res://Main_screen/Scripts/menu_icons.gd")
const AssessmentGate = preload("res://Main_screen/Scripts/assessment_gate.gd")
const RESULTS = "res://Results/scenes/user_progress.tscn"
const MENU_2D = "res://Main_screen/Scenes/select_game.tscn"
const MENU_3D = "res://Main_screen/Scenes/3d_games.tscn"
const MAIN = "res://Main_screen/Scenes/main.tscn"
const PROGRESS_ICONS := {"Assessment": "assessment", "Results": "results", "TrunkAngles": "trunk"}

@onready var logged_in_as: Label = %LoggedInAs
@onready var training_label: Label = %TrainingLabel
@onready var hand_popup: Control = %HandSelectionPopup


## "2D" or "3D": which menu this is.
func _mode() -> String:
	return "2D"


## [button, colour, picture] for each game tile.
func _game_tiles() -> Array:
	return []


func _ready() -> void:
	GlobalSignals.selected_game_mode = _mode()
	_style()
	logged_in_as.text = "Patient: " + PatientDB.current_patient_id
	add_child(preload("res://Main_screen/Scripts/dose_progress.gd").new())
	add_child(preload("res://Main_screen/Scripts/trunk_panel.gd").new())
	match GlobalSignals.affected_hand:
		"Left", "Right":
			_set_hand(GlobalSignals.affected_hand)
		"Both":
			if GlobalSignals.selected_training_hand == "":
				hand_popup.show()
				GlobalSignals.enable_game_buttons(false)
			else:
				_set_hand(GlobalSignals.selected_training_hand)
	# No hand known: keep the chip's place so the 2D/3D switch stays centred.
	%HandChip.modulate.a = 0.0 if training_label.text.is_empty() else 1.0


func _style() -> void:
	GameButton.style_card(%GamesCard)
	GameButton.style_card(%ProgressCard)
	GameButton.style_card(%HandCard, 24, 28, 0.92)
	for chip in [%PatientChip, %HandChip]:
		GameButton.style_card(chip, 23, 10)
	GameButton.style_label(%GamesTitle, 22)
	GameButton.style_label(%ProgressTitle, 22)
	GameButton.style_label(logged_in_as, 17)
	GameButton.style_label(training_label, 17)
	GameButton.style_label(%HandQuestion, 24)
	for tile in _game_tiles():
		GameButton.apply(tile[0], tile[1], 20)
		GameButton.set_icon(tile[0], tile[2], true, 160)
	for button in %ProgressButtons.get_children():
		GameButton.apply(button, GameButton.SLATE, 17)
		GameButton.set_icon(button, MenuIcons.svg(PROGRESS_ICONS[button.name]), false, 34)
	_style_switch(%Mode2D, _mode() == "2D")
	_style_switch(%Mode3D, _mode() == "3D")
	GameButton.apply(%Logout, GameButton.SLATE, 19)
	GameButton.set_icon(%Logout, MenuIcons.svg("logout"), false, 26)
	GameButton.apply(%Exit, GameButton.RED, 20)
	GameButton.set_icon(%Exit, MenuIcons.svg("power"), false, 26)
	GameButton.apply(%LeftButton, GameButton.BLUE, 22)
	GameButton.apply(%RightButton, GameButton.ORANGE, 22)


## This menu's side of the 2D/3D switch is lit and inert; the other leads there.
func _style_switch(button: Button, active: bool) -> void:
	GameButton.apply(button, GameButton.GREEN if active else GameButton.SLATE, 19)
	if active:
		button.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.focus_mode = Control.FOCUS_NONE


func _set_hand(hand: String) -> void:
	GlobalSignals.selected_training_hand = hand
	training_label.text = "Training: %s hand" % hand


func _choose_hand(hand: String) -> void:
	_set_hand(hand)
	%HandChip.modulate.a = 1.0
	hand_popup.hide()
	GlobalSignals.enable_game_buttons(true)


func _on_left_button_pressed() -> void:
	_choose_hand("Left")


func _on_right_button_pressed() -> void:
	_choose_hand("Right")


func _on_mode_2d_pressed() -> void:
	get_tree().change_scene_to_file(MENU_2D)


func _on_mode_3d_pressed() -> void:
	get_tree().change_scene_to_file(MENU_3D)


func _on_assessment_pressed() -> void:
	AssessmentGate.assess(get_tree())


func _on_results_pressed() -> void:
	get_tree().change_scene_to_packed(AssessmentGate.scene(RESULTS))


func _on_logout_pressed() -> void:
	MusicManager.play_music("main")
	GlobalSignals.selected_training_hand = ""
	GlobalSignals.affected_hand = ""
	get_tree().change_scene_to_file(MAIN)


## GlobalScript ends the session, waits for the upload, then quits.
func _on_exit_pressed() -> void:
	GlobalScript._notification(NOTIFICATION_WM_CLOSE_REQUEST)
