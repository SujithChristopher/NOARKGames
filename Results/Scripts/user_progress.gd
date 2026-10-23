extends Control


@onready var chart: LineChart = $Chart
@onready var pname_label: Label = $PName
@onready var hid_label: Label = $HID
@onready var session_list: ItemList = $SessionList
@onready var area_calc := preload("res://Games/assessment/workspace.gd").new()
@onready var ddl = $DirectionDetailsLabel
@export var workspace_data = []

var active_areas = []
var inflated_areas = []
var date_labels = []
var x_dates = []

func _ready():
    var current_id = GlobalSignals.current_patient_id
    var all_patients = PatientDB.list_all_patients()

    for patient in all_patients:
        if patient["hospital_id"] == current_id:
            pname_label.text = "Patient: " + patient["name"]
            hid_label.text = "HID: " + patient["hospital_id"]
            break

    # Load workspace data
    var parser = preload("res://Results/Scripts/parse_files.gd").new()
    parser._ready()
    workspace_data = parser.get_parsed_data()
    
    if workspace_data.size() == 0:
        print("No data to plot")
        return
    
    var x_values: Array = []
    for i in workspace_data.size():
        var data = workspace_data[i]
        var parts = data.date.split("-")
        var date_str = "%s-%s-%s" % [parts[2], parts[1], parts[0]]  
        var date_mm = "%s-%s" % [parts[2], parts[1]]
        date_labels.append(date_str)
        x_dates.append(date_mm)
        session_list.add_item(date_str)
        x_values.append(i)

    
    # Prepare data for plotting
    var axdir_values = []
    var azdir_values = []
    var txdir_values = []
    var tzdir_values = []
    
    
    
    var tick_labels := []
    for data in workspace_data:
        var parts = data.date.split("-")  
        tick_labels.append(parts[1] + "-" + parts[2])  
    
    
    for data in workspace_data:
        axdir_values.append(data.axdir)
        azdir_values.append(data.azdir)
        txdir_values.append(data.txdir)
        tzdir_values.append(data.tzdir)
        
        
        var active_area = area_calc.calculate_polygon_area(data["active_poly"])
        var inflated_area = area_calc.calculate_polygon_area(data["inflated_poly"])
        active_areas.append(active_area)
        inflated_areas.append(inflated_area)
        print("active", active_area)
        print("inflated", inflated_area)
        
        
    
    chart.title = "Workspace Area"
    chart.x_label = "Session Date"
    chart.y_label = "Area of Polygon"
    chart.plot(x_dates, [
        {"name": "Active area", "values": active_areas, "color": Color.GREEN},
        {"name": "Inflated area", "values": inflated_areas, "color": Color.ORANGE},
    ])

func _on_logout_pressed() -> void:
    get_tree().change_scene_to_file("res://Main_screen/Scenes/main.tscn")

func _on_session_list_item_selected(index: int) -> void:
    var data = workspace_data[index]
    var details: String = "Date: " + date_labels[index] + "\n"
    details += "axdir: %.2f\n" % data.axdir
    details += "azdir: %.2f\n" % data.azdir
    details += "txdir: %.2f\n" % data.txdir
    details += "tzdir: %.2f" % data.tzdir
    ddl.text = details
    
