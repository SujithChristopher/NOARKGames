extends "res://Main_screen/Scripts/game_menu.gd"
## The 3D game menu.

# Loaded in the background once the menu is up (AssessmentGate.warm), not
# preloaded: preloading every game here held the menu back 10-15 s.
const RANDOM_REACH = "res://Games/random_reach/scenes/random_reach.tscn"
const FLY_THROUGH = "res://Games/flappy_bird/Scenes/flappy_main.tscn"
const JUMPIFY = "res://Games/Jumpify/Scenes/Levels/Level_01.tscn"


func _mode() -> String:
	return "3D"


func _ready() -> void:
	AssessmentGate.warm([RANDOM_REACH, FLY_THROUGH, JUMPIFY, RESULTS])
	super()


func _game_tiles() -> Array:
	return [
		[%RandomReach3D, GameButton.GREEN, MenuIcons.art(MenuIcons.RANDOM_REACH)],
		[%FlyThrough3D, GameButton.BLUE, MenuIcons.art(MenuIcons.FLY_THROUGH)],
		[%Jumpify, GameButton.TEAL, MenuIcons.art(MenuIcons.JUMPIFY, MenuIcons.JUMPIFY_FRAME)],
	]


func _on_random_reach_3d_pressed() -> void:
	MusicManager.play_music("rr_bgm")
	AssessmentGate.play(get_tree(), AssessmentGate.scene(RANDOM_REACH))


func _on_fly_through_3d_pressed() -> void:
	MusicManager.play_music("ft_bgm")
	AssessmentGate.play(get_tree(), AssessmentGate.scene(FLY_THROUGH))


func _on_jumpify_pressed() -> void:
	MusicManager.play_music("jy_bgm")
	AssessmentGate.play(get_tree(), AssessmentGate.scene(JUMPIFY))
