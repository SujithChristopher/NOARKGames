extends Node2D

@onready var patient_db: PatientDetails = load("res://Main_screen/patient_register.tres")
@onready var logged_in_as = $LoggedInAs
@onready var training_label = $TrainingLabel
@onready var left_button = $HandSelectionPopup/HBoxContainer/LeftButton
@onready var right_button = $HandSelectionPopup/HBoxContainer/RightButton


var random_reach3D = preload("res://Games/random_reach/scenes/random_reach.tscn")
var fly_through3D = preload("res://Games/flappy_bird/Scenes/flappy_main.tscn")
var jumpify = preload("res://Games/Jumpify/Scenes/Levels/Level_01.tscn")
var assesment = preload("res://Games/assessment/workspace.tscn")
var results = preload("res://Results/scenes/user_progress.tscn")


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

func _on_random_reach_3d_pressed() -> void:
    get_tree().change_scene_to_packed(random_reach3D)

func _on_fly_through_3d_pressed() -> void:
   get_tree().change_scene_to_packed(fly_through3D)

func _on_jumpify_pressed() -> void:
  get_tree().change_scene_to_packed(jumpify)

func _on_assessment_pressed() -> void:
   get_tree().change_scene_to_packed(assesment)

func _on_results_pressed() -> void:
    get_tree().change_scene_to_packed(results)
    
func _on_exit_pressed() -> void:
   GlobalScript._notification(NOTIFICATION_WM_CLOSE_REQUEST)
   GlobalSignals.selected_training_hand == ""
   GlobalSignals.affected_hand = ""
   get_tree().quit()

func _on_logout_pressed() -> void:
    GlobalSignals.selected_training_hand == ""
    GlobalSignals.affected_hand = ""
    get_tree().change_scene_to_file("res://Main_screen/Scenes/main.tscn")

func _on_2d_mode_toggled(toggled_on: bool) -> void:
   GlobalSignals.selected_game_mode = "2D"
   get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")


func _on_left_button_pressed() -> void:
   GlobalSignals.selected_training_hand = "Left"
   $HandSelectionPopup.hide()
   $TrainingLabel.text = "Training for Left Hand"
   GlobalSignals.enable_game_buttons(true)


func _on_right_button_pressed() -> void:
    GlobalSignals.selected_training_hand = "Right"
    $HandSelectionPopup.hide()
    $TrainingLabel.text = "Training for Right Hand"
    GlobalSignals.enable_game_buttons(true)
