extends Node

signal SignalBus

@export var selected_training_hand: String = ""
@export var affected_hand: String = ""
@export var global_scalar_x:float = 1.0
@export var global_scalar_y:float = 1.0
@export var assessment_done: bool = false
@export var selected_game_mode: String = "2D"

@export var inflated_workspace: PackedVector2Array

@export var current_patient_id:String = ""
@export var data_path:String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "//NOARK//data"


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
