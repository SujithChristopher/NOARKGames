extends Node
# var current_patient_id = GlobalSignals.current_patient_id
var parsed_data = []
@onready var area = $"."

func _ready() -> void:
    
    parse_workspace_files()

func parse_workspace_files() -> void:
    
    var path = GlobalSignals.data_path + "//" + GlobalSignals.current_patient_id
    print("Parsing files in: " + path)
    var dir = DirAccess.open(path)
    if dir:
        dir.list_dir_begin()
        var file_name = dir.get_next()
        while file_name != "":
            if !dir.current_is_dir() and file_name.ends_with(".json"):
                var file_data = parse_workspace_file(path + "/" + file_name)
                if file_data:
                    parsed_data.append(file_data)
            file_name = dir.get_next()
        parsed_data.sort_custom(func(a, b): return a.date < b.date)
    else:
        print("An error occurred when trying to access the path.")

func parse_workspace_file(file_path: String) -> Dictionary:
    var file = FileAccess.open(file_path, FileAccess.READ)
    if file:
        var content = file.get_as_text()
        file.close()
        
        var json = JSON.new()
        var error = json.parse(content)
        
        if error == OK:
            var data = json.get_data()
            print("File: " + file_path.get_file())
            
            if data.has("active_workspace") and data.has("axdir") and data.has("azdir") and \
               data.has("inflated_workspace") and data.has("txdir") and data.has("tzdir"):
                
                # Extract date from filename (assuming format: workspace-YYYY-MM-DD.json)
                var date_str = file_path.get_file().trim_prefix("workspace-").trim_suffix(".json")
                
                print("  Active workspace:")
                print("    axdir: " + str(data["axdir"]))
                print("    azdir: " + str(data["azdir"]))
                
                print("  Inflated workspace:")
                print("    txdir: " + str(data["txdir"]))
                print("    tzdir: " + str(data["tzdir"]))
                
                # Optional: Parse the polygon string to Vector2 array
                var active_poly = parse_polygon_string(data["active_workspace"])
                var inflated_poly = parse_polygon_string(data["inflated_workspace"])
                
                return {
                    "filename": file_path.get_file(),
                    "date": date_str,
                    "axdir": data["axdir"],
                    "azdir": data["azdir"],
                    "txdir": data["txdir"],
                    "tzdir": data["tzdir"],
                    "active_poly": active_poly,
                    "inflated_poly": inflated_poly
                }
            else:
                print("  Missing required workspace data")
        else:
            print("  JSON Parse Error: " + str(error) + " at line " + str(json.get_error_line()))
    else:
        print("  Failed to open file: " + file_path)
    
    return {}

func parse_polygon_string(polygon_string: String) -> Array[Vector2]:
    var result: Array[Vector2] = []
    
    # Remove the brackets and split by commas
    polygon_string = polygon_string.trim_prefix("[").trim_suffix("]")
    var points = polygon_string.split("), (")
    
    for point in points:
        # Clean up the string
        point = point.replace("(", "").replace(")", "")
        var coords = point.split(", ")
        
        if coords.size() == 2:
            var x = float(coords[0])
            var y = float(coords[1])
            result.append(Vector2(x, y))
    
    return result
    

func get_parsed_data() -> Array:
    return parsed_data
