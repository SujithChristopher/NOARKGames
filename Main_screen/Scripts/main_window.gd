extends Button

@onready var patient_name: String = ""
@onready var hosp_id: String = ""
@onready var popup = $"../Warning"
@onready var patient_notfound = $"../Patient_notfound"
@onready var loading_dialog: AcceptDialog = AcceptDialog.new()
var registry_scene = preload("res://Main_screen/Scenes/registry.tscn")
var endgame : bool




func _on_exit_button_pressed():
    GlobalScript._notification(NOTIFICATION_WM_CLOSE_REQUEST)
    GlobalSignals.SignalBus.emit()
    get_tree().quit()
    
func _on_pressed():
    hosp_id = $"../TextureRect/HospID".text
    if patient_name == "" and hosp_id == "":
        popup.show()
    else:
        if PatientDB.get_patient(hosp_id):
            PatientDB.current_patient_id = hosp_id
            PatientDB.save_database()
            get_tree().change_scene_to_packed(registry_scene)
        else:
            patient_notfound.show()


func _on_window_close_requested() -> void:
    popup.hide()

func _on_new_patient_pressed() -> void:
    get_tree().change_scene_to_file("res://Main_screen/Scenes/registry.tscn") 
    

func _on_set_origin_pressed() -> void:
    GlobalScript.set_origin()


func _on_assess_button_pressed() -> void:
    PatientDB.save_database()


func _on_patient_nf_ok_pressed() -> void:
    patient_notfound.hide()


func _on_hosp_id_text_submitted(new_text: String) -> void:
    hosp_id = $"../TextureRect/HospID".text
    if patient_name == "" and hosp_id == "":
        popup.show()
    else:
        if PatientDB.get_patient(hosp_id):
            PatientDB.current_patient_id = hosp_id
            GlobalScript.change_patient()
            GlobalSignals.current_patient_id = hosp_id
            PatientDB.save_database()
            get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn")
        else:
            patient_notfound.show()
            
