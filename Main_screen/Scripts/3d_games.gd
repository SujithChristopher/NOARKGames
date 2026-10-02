extends Node2D

@onready var logged_in_as = $Logo/LoggedInAs
@onready var training_label = $TrainingLabel
@onready var left_button = $HandSelectionPopup/HBoxContainer/LeftButton
@onready var right_button = $HandSelectionPopup/HBoxContainer/RightButton


# Loaded in the background once the menu is up (AssessmentGate.warm), not
# preloaded: preloading every game here held the menu back 10-15 s.
const RANDOM_REACH = "res://Games/random_reach/scenes/random_reach.tscn"
const FLY_THROUGH = "res://Games/flappy_bird/Scenes/flappy_main.tscn"
const JUMPIFY = "res://Games/Jumpify/Scenes/Levels/Level_01.tscn"
const RESULTS = "res://Results/scenes/user_progress.tscn"
const AssessmentGate = preload("res://Main_screen/Scripts/assessment_gate.gd")


func _ready() -> void:
    AssessmentGate.warm([RANDOM_REACH, FLY_THROUGH, JUMPIFY, RESULTS])
    logged_in_as.text = "Patient: " + PatientDB.current_patient_id
    add_child(preload("res://Main_screen/Scripts/dose_progress.gd").new())
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
    MusicManager.play_music("rr_bgm")
    AssessmentGate.play(get_tree(), AssessmentGate.scene(RANDOM_REACH))

func _on_fly_through_3d_pressed() -> void:
   MusicManager.play_music("ft_bgm")
   AssessmentGate.play(get_tree(), AssessmentGate.scene(FLY_THROUGH))

func _on_jumpify_pressed() -> void:
  MusicManager.play_music("jy_bgm")
  AssessmentGate.play(get_tree(), AssessmentGate.scene(JUMPIFY))

func _on_assessment_pressed() -> void:
   AssessmentGate.assess(get_tree())

func _on_results_pressed() -> void:
    get_tree().change_scene_to_packed(AssessmentGate.scene(RESULTS))
    
func _on_exit_pressed() -> void:
   GlobalScript._notification(NOTIFICATION_WM_CLOSE_REQUEST)
   GlobalSignals.selected_training_hand == ""
   GlobalSignals.affected_hand = ""
   get_tree().quit()

func _on_logout_pressed() -> void:
    MusicManager.play_music("main")
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
