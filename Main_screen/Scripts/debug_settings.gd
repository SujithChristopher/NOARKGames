extends Node

var debug_mode: bool = false
var config: Dictionary = {}

func _ready() -> void:
    load_settings()

func load_settings():
    config = Settings.data
    debug_mode = Settings.get_value("debug", false)
