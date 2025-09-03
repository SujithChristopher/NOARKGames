extends Node

var debug_mode: bool = false
var config: Dictionary = {}

func _ready() -> void:
    load_settings()

func load_settings():
    var path = "res://debug.json"
    if FileAccess.file_exists(path):
        var json_text = FileAccess.get_file_as_string(path)
        var parsed = JSON.parse_string(json_text)
        if typeof(parsed) == TYPE_DICTIONARY:
            config = parsed
            debug_mode = config.get("debug", false)
        else:
            push_error("debug.json is not a valid dictionary")
    else:
        push_error("debug.json not found!")
