extends Node2D

func _on_2d_games_pressed() -> void:
    # Set global flag for 2D mode before transitioning
    GlobalSignals.selected_game_mode = "2D"
    get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")
   
func _on_3d_games_pressed() -> void:
    # Set global flag for 3D mode before transitioning  
    GlobalSignals.selected_game_mode = "3D"
    get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")
