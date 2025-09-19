extends Control

@onready var patient_db: PatientDetails = load("res://Main_screen/patient_register.tres")
@onready var logged_in_as = $LoggedInAs
@onready var training_label = $TrainingLabel

# Preload all scenes at start (loads into memory for faster switching)
var random_reach_scene = preload("res://Games/random_reach/scenes/random_reach.tscn")
var flappy_scene = preload("res://Games/flappy_bird/Scenes/flappy_main.tscn")
var pingpong_scene = preload("res://Games/ping_pong/Scenes/PingPong.tscn")
var fruit_catcher = preload("res://Games/fruit_catcher/Scenes/Game/Game.tscn")
var assessment_scene = preload("res://Games/assessment/workspace.tscn")
var results_scene = preload("res://Results/scenes/user_progress.tscn")
var main_menu_scene = preload("res://Main_screen/Scenes/main.tscn")
var endgame : bool


func _ready() -> void:
    logged_in_as.text = "Patient: " + patient_db.current_patient_id
    var affected_hand = GlobalSignals.affected_hand
    
    if affected_hand == "Left":
        training_label.text = "Training for left hand"
        GlobalSignals.selected_training_hand = "Left"
    elif affected_hand == "Right":
        training_label.text = "Training for right  hand"
        GlobalSignals.selected_training_hand = "Right"
    elif affected_hand == "Both":
        if GlobalSignals.selected_training_hand == "":
            $HandSelectionPopup.visible = true
            GlobalSignals.enable_game_buttons(false)
        else:
            training_label.text = "Training for %s hand" % GlobalSignals.selected_training_hand
        
        
func _on_LeftButton_pressed():
    GlobalSignals.selected_training_hand = "Left"
    $HandSelectionPopup.hide()
    $TrainingLabel.text = "Training for Left Hand"
    GlobalSignals.enable_game_buttons(true)

func _on_RightButton_pressed():
    GlobalSignals.selected_training_hand = "Right"
    $HandSelectionPopup.hide()
    $TrainingLabel.text = "Training for Right Hand"
    GlobalSignals.enable_game_buttons(true)


func _process(delta: float) -> void:
    pass


func _on_game_reach_pressed() -> void:
    get_tree().change_scene_to_packed(random_reach_scene)

func _on_game_flappy_pressed() -> void:
    get_tree().change_scene_to_packed(flappy_scene)

func _on_game_pingpong_pressed() -> void:
    get_tree().change_scene_to_packed(pingpong_scene)

func _on_assessment_pressed() -> void:
    get_tree().change_scene_to_packed(assessment_scene)

func _on_results_pressed() -> void:
    get_tree().change_scene_to_packed(results_scene)

func _on_logout_pressed() -> void:
    GlobalSignals.selected_training_hand == ""
    GlobalSignals.affected_hand = ""
    get_tree().change_scene_to_file("res://Main_screen/Scenes/main.tscn")
    
func _on_exit_button_pressed() -> void:
    GlobalScript._notification(NOTIFICATION_WM_CLOSE_REQUEST)
    GlobalSignals.selected_training_hand == ""
    GlobalSignals.affected_hand = ""
    get_tree().quit()

func _on_fruit_catcher_pressed() -> void:
    get_tree().change_scene_to_packed(fruit_catcher)


func _on_switch_3d_toggled(toggled_on: bool) -> void:
    GlobalSignals.selected_game_mode = "3D"
    get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")
