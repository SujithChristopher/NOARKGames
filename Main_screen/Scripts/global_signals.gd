extends Node

signal SignalBus
signal origin_set

@export var selected_training_hand: String = ""
@export var affected_hand: String = ""
@export var global_scalar_x:float = 1.0
@export var global_scalar_y:float = 1.0
@export var assessment_done: bool = false
@export var selected_game_mode: String = "2D"
var pending_game: PackedScene = null   # chosen game waiting on today's reach scan (AssessmentGate)

@export var inflated_workspace: PackedVector2Array

@export var current_patient_id:String = ""
@export var data_path:String = (OS.get_user_data_dir() if OS.get_name() == "Android" else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join("NOARK")).path_join("data")


@export var ball_position: Vector2

var hit_ground = Vector2.ZERO
var hit_top = Vector2.ZERO
var hit_left = Vector2.ZERO
var hit_right = Vector2.ZERO
var hit_player = Vector2.ZERO
var hit_computer = Vector2.ZERO

func enable_game_buttons(enable: bool) -> void:
	for button in get_tree().get_nodes_in_group("GameButtons"):
		button.disabled = not enable
