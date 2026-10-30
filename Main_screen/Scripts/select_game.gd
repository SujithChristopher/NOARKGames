extends "res://Main_screen/Scripts/game_menu.gd"
## The 2D game menu.

# Loaded in the background once the menu is up (AssessmentGate.warm), not
# preloaded: preloading every game here held the menu back 10-15 s.
const RANDOM_REACH = "res://Games/random_reach/scenes/random_reach.tscn"
const FLAPPY = "res://Games/flappy_bird/Scenes/flappy_main.tscn"
const PINGPONG = "res://Games/ping_pong/Scenes/PingPong.tscn"
const FRUIT_CATCHER = "res://Games/fruit_catcher/Scenes/Game/Game.tscn"
const FIREFLY_REACH = "res://Games/firefly_reach/firefly_main.tscn"
const CANNON_DEFENSE = "res://Games/cannon_defense/cannon_defense.tscn"


func _ready() -> void:
	AssessmentGate.warm([RANDOM_REACH, FLAPPY, PINGPONG, FRUIT_CATCHER, FIREFLY_REACH, CANNON_DEFENSE, RESULTS])
	super()


func _game_tiles() -> Array:
	return [
		[%RandomReach, GameButton.GREEN, MenuIcons.art(MenuIcons.RANDOM_REACH)],
		[%FlyThrough, GameButton.BLUE, MenuIcons.art(MenuIcons.FLY_THROUGH)],
		[%PingPong, GameButton.ORANGE, MenuIcons.svg("pingpong")],
		[%FruitCatcher, GameButton.PINK, MenuIcons.art(MenuIcons.FRUIT_CATCHER)],
		[%FireflyReach, GameButton.PURPLE, MenuIcons.svg("firefly")],
		[%CannonDefense, GameButton.TEAL, MenuIcons.svg("cannon")],
	]


func _on_game_reach_pressed() -> void:
	MusicManager.play_music("rr_bgm")
	AssessmentGate.play(get_tree(), AssessmentGate.scene(RANDOM_REACH))


func _on_game_flappy_pressed() -> void:
	MusicManager.play_music("ft_bgm")
	AssessmentGate.play(get_tree(), AssessmentGate.scene(FLAPPY))


func _on_game_pingpong_pressed() -> void:
	MusicManager.play_music("pp_bgm")
	AssessmentGate.play(get_tree(), AssessmentGate.scene(PINGPONG))


func _on_fruit_catcher_pressed() -> void:
	MusicManager.play_music("fc_bgm")
	AssessmentGate.play(get_tree(), AssessmentGate.scene(FRUIT_CATCHER))


func _on_firefly_reach_pressed() -> void:
	AssessmentGate.play(get_tree(), AssessmentGate.scene(FIREFLY_REACH))


func _on_cannon_defense_pressed() -> void:
	MusicManager.play_music("rr_bgm")
	AssessmentGate.play(get_tree(), AssessmentGate.scene(CANNON_DEFENSE))


func _on_trunk_angles_pressed() -> void:
	get_tree().change_scene_to_file("res://Main_screen/Scenes/trunk_view.tscn")
