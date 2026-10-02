extends Button

@onready var patient_name: String = ""
@onready var hosp_id: String = ""
@onready var popup = $"../Warning"
@onready var patient_notfound = $"../Patient_notfound"
@onready var hosp_id_edit: LineEdit = $"../TextureRect/HospID"
@onready var sync_status: Label = $"../TextureRect/SyncStatus"
@onready var loading_dialog: AcceptDialog = AcceptDialog.new()
const DoseDialog = preload("res://Main_screen/Scripts/dose_dialog.gd")
var endgame : bool

# Fetches patients.json from the server when the main screen opens. The
# sender only uses the standard library, so any python3 runs it.
const SENDER_SCRIPT = "sender_raspberryPI.py"
var sync_thread := Thread.new()

# The patient box is a combo box: typing filters the ids shown under it,
# clicking it lists them all. Godot has none built in, so this ItemList
# is laid over the screen below the LineEdit.
const SUGGEST_ROWS = 6
const SUGGEST_ROW_HEIGHT = 34
var suggestions := ItemList.new()


func _ready() -> void:
    _build_suggestions()
    sync_thread.start(_sync_patients)


func _exit_tree() -> void:
    if sync_thread.is_started():
        sync_thread.wait_to_finish()


func _sync_patients() -> void:
    var python: String = GlobalScript.interpreter_path
    if not FileAccess.file_exists(python):
        python = "python3"
    var script := GlobalScript._project_root().path_join(SENDER_SCRIPT)
    var output := []
    var code := OS.execute(python, [script, "--sync"], output, true)
    print("[sync] ", "".join(output).strip_edges())
    _on_sync_done.call_deferred(code)


func _on_sync_done(code: int) -> void:
    sync_thread.wait_to_finish()
    PatientDB.load_database()
    if suggestions.visible:
        _show_suggestions()
    var count := PatientDB.patient_register.size()
    if code == 0:
        sync_status.text = "%d patients from the server (v%d)" % [count, PatientDB.version]
    elif count > 0:
        sync_status.text = "Server unreachable - %d saved patients" % count
    else:
        sync_status.text = "Server unreachable - no patients yet"


func _build_suggestions() -> void:
    # Never takes focus, so the LineEdit keeps it and typing carries on.
    suggestions.focus_mode = Control.FOCUS_NONE
    suggestions.visible = false
    suggestions.theme = hosp_id_edit.theme
    suggestions.add_theme_font_override("font", hosp_id_edit.get_theme_font("font"))
    suggestions.add_theme_font_size_override("font_size", 18)
    suggestions.z_index = 10
    # Last child of the screen root, so it draws over the buttons below the box.
    get_parent().add_child.call_deferred(suggestions)
    suggestions.item_clicked.connect(func(index, _pos, _button): _pick(index))
    hosp_id_edit.text_changed.connect(func(_text): _show_suggestions())
    hosp_id_edit.focus_entered.connect(_show_suggestions)
    hosp_id_edit.focus_exited.connect(suggestions.hide)
    hosp_id_edit.gui_input.connect(_on_hosp_id_gui_input)


# Ids containing the typed text, case-insensitive; those starting with it first.
func _matches(text: String) -> Array:
    var typed := text.strip_edges().to_lower()
    var starts := []
    var contains := []
    for id in PatientDB.patient_ids():
        var lower: String = id.to_lower()
        if typed == "" or lower.begins_with(typed):
            starts.append(id)
        elif typed in lower:
            contains.append(id)
    return starts + contains


func _show_suggestions() -> void:
    var ids := _matches(hosp_id_edit.text)
    # Nothing to offer, or the box already holds the one exact id.
    if ids.is_empty() or (ids.size() == 1 and ids[0] == hosp_id_edit.text.strip_edges()):
        suggestions.hide()
        return
    suggestions.clear()
    for id in ids:
        suggestions.add_item(id)
    suggestions.global_position = hosp_id_edit.global_position + Vector2(0, hosp_id_edit.size.y)
    suggestions.size = Vector2(hosp_id_edit.size.x, min(ids.size(), SUGGEST_ROWS) * SUGGEST_ROW_HEIGHT + 8)
    suggestions.show()


func _pick(index: int) -> void:
    hosp_id_edit.text = suggestions.get_item_text(index)
    hosp_id_edit.caret_column = hosp_id_edit.text.length()
    suggestions.hide()


# Up/Down move through the list, Enter takes the highlighted id, Esc closes it.
func _on_hosp_id_gui_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
        _show_suggestions()
        return
    if not (event is InputEventKey and event.pressed) or not suggestions.visible:
        return
    var count := suggestions.item_count
    var selected := suggestions.get_selected_items()
    var current: int = selected[0] if selected.size() > 0 else -1
    match event.keycode:
        KEY_DOWN:
            current = (current + 1) % count
        KEY_UP:
            current = count - 1 if current <= 0 else current - 1
        KEY_ENTER, KEY_KP_ENTER:
            if current < 0:
                return   # nothing highlighted: Enter logs in with the typed id
            _pick(current)
            hosp_id_edit.accept_event()
            return
        KEY_ESCAPE:
            suggestions.hide()
            hosp_id_edit.accept_event()
            return
        _:
            return
    suggestions.select(current)
    suggestions.ensure_current_is_visible()
    hosp_id_edit.accept_event()


func _on_exit_button_pressed():
    GlobalScript._notification(NOTIFICATION_WM_CLOSE_REQUEST)
    GlobalSignals.SignalBus.emit()
    get_tree().quit()

func _on_pressed():
    _login()


func _on_window_close_requested() -> void:
    popup.hide()


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
    _login()


func _login() -> void:
    hosp_id = hosp_id_edit.text.strip_edges()
    if hosp_id == "":
        popup.show()
        return
    var patient = PatientDB.get_patient(hosp_id)
    if not patient:
        patient_notfound.show()
        return
    PatientDB.current_patient_id = hosp_id
    GlobalScript.change_patient()
    GlobalSignals.current_patient_id = hosp_id
    GlobalSignals.affected_hand = patient.get("affected_hand", "")
    # Confirm today's dose, then the session starts and the 2D/3D choice opens.
    var dose := DoseDialog.new()
    dose.confirmed_dose.connect(func():
        SessionLog.start_session(hosp_id)
        get_tree().change_scene_to_file("res://Main_screen/Scenes/mode.tscn"))
    dose.open(get_tree().current_scene, hosp_id)
