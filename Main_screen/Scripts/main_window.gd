extends Button

@onready var patient_name: String = ""
@onready var hosp_id: String = ""
@onready var popup = $"../Warning"
@onready var patient_notfound = $"../Patient_notfound"
@onready var loading_dialog: AcceptDialog = AcceptDialog.new()
var registry_scene = preload("res://Main_screen/Scenes/registry.tscn")
const DoseDialog = preload("res://Main_screen/Scripts/dose_dialog.gd")
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


func _on_define_table_pressed() -> void:
    var overlay: Control = load("res://Main_screen/Scripts/table_overlay.gd").new()
    var layer := CanvasLayer.new()
    layer.layer = 50
    layer.add_child(overlay)
    overlay.tree_exited.connect(layer.queue_free)
    get_tree().current_scene.add_child(layer)


func _on_assess_button_pressed() -> void:
    PatientDB.save_database()


func _on_patient_nf_ok_pressed() -> void:
    patient_notfound.hide()


func _on_hosp_id_text_submitted(new_text: String) -> void:
    hosp_id = $"../TextureRect/HospID".text
    if patient_name == "" and hosp_id == "":
        popup.show()
    else:
        var patient = PatientDB.get_patient(hosp_id)
        if patient:
            PatientDB.current_patient_id = hosp_id
            GlobalScript.change_patient()
            GlobalSignals.current_patient_id = hosp_id
            GlobalSignals.affected_hand = patient.get("affected_hand", "")
            PatientDB.save_database()
            # Same dose check as the registry login, then the session starts.
            var dose := DoseDialog.new()
            dose.confirmed_dose.connect(func():
                SessionLog.start_session(hosp_id)
                get_tree().change_scene_to_file("res://Main_screen/Scenes/select_game.tscn"))
            dose.open(get_tree().current_scene, hosp_id)
        else:
            patient_notfound.show()
            
