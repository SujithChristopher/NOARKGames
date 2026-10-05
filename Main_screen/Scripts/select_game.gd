extends Control

@onready var logged_in_as = $Logo/LoggedInAs
@onready var training_label = $TrainingLabel

# Loaded in the background once the menu is up (AssessmentGate.warm), not
# preloaded: preloading every game here held the menu back 10-15 s.
const RANDOM_REACH = "res://Games/random_reach/scenes/random_reach.tscn"
const FLAPPY = "res://Games/flappy_bird/Scenes/flappy_main.tscn"
const PINGPONG = "res://Games/ping_pong/Scenes/PingPong.tscn"
const FRUIT_CATCHER = "res://Games/fruit_catcher/Scenes/Game/Game.tscn"
const FIREFLY_REACH = "res://Games/firefly_reach/firefly_main.tscn"
const RESULTS = "res://Results/scenes/user_progress.tscn"
const AssessmentGate = preload("res://Main_screen/Scripts/assessment_gate.gd")
var endgame : bool



func _ready() -> void:
    AssessmentGate.warm([RANDOM_REACH, FLAPPY, PINGPONG, FRUIT_CATCHER, FIREFLY_REACH, RESULTS])
    logged_in_as.text = "Patient: " + PatientDB.current_patient_id
    add_child(preload("res://Main_screen/Scripts/dose_progress.gd").new())
    add_child(preload("res://Main_screen/Scripts/trunk_panel.gd").new())
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
    MusicManager.play_music("rr_bgm")
    AssessmentGate.play(get_tree(), AssessmentGate.scene(RANDOM_REACH))

func _on_game_flappy_pressed() -> void:
    MusicManager.play_music("ft_bgm")
    AssessmentGate.play(get_tree(), AssessmentGate.scene(FLAPPY))

func _on_game_pingpong_pressed() -> void:
    MusicManager.play_music("pp_bgm")
    AssessmentGate.play(get_tree(), AssessmentGate.scene(PINGPONG))
    

func _on_assessment_pressed() -> void:
    AssessmentGate.assess(get_tree())

func _on_trunk_angles_pressed() -> void:
    get_tree().change_scene_to_file("res://Main_screen/Scenes/trunk_view.tscn")

func _on_results_pressed() -> void:
    get_tree().change_scene_to_packed(AssessmentGate.scene(RESULTS))

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
    MusicManager.play_music("fc_bgm")
    AssessmentGate.play(get_tree(), AssessmentGate.scene(FRUIT_CATCHER))


func _on_switch_3d_toggled(toggled_on: bool) -> void:
    GlobalSignals.selected_game_mode = "3D"
    get_tree().change_scene_to_file("res://Main_screen/Scenes/3d_games.tscn")

func _on_firefly_reach_pressed() -> void:
    AssessmentGate.play(get_tree(), AssessmentGate.scene(FIREFLY_REACH))

