extends Control

const GameButton := preload("res://Main_screen/Scripts/game_button.gd")
const MenuIcons := preload("res://Main_screen/Scripts/menu_icons.gd")


func _ready() -> void:
	GameButton.style_label(%Title, 40)
	GameButton.style_label(%Patient, 20)
	GameButton.apply(%Games2D, GameButton.BLUE, 32)
	GameButton.set_icon(%Games2D, MenuIcons.svg("flat"), true, 90)
	GameButton.apply(%Games3D, GameButton.PURPLE, 32)
	GameButton.set_icon(%Games3D, MenuIcons.svg("cube"), true, 90)
	GameButton.apply(%MainMenu, GameButton.SLATE, 20)
	%Patient.text = "Patient: " + PatientDB.current_patient_id


func _on_2d_games_pressed() -> void:
	# Set global flag for 2D mode before transitioning
	GlobalSignals.selected_game_mode = "2D"
	get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")


func _on_3d_games_pressed() -> void:
	# Set global flag for 3D mode before transitioning
	GlobalSignals.selected_game_mode = "3D"
	get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")


func _on_main_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://Main_screen/Scenes/main.tscn")
