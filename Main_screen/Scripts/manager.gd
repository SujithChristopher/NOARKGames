extends Node


var json = JSON.new()
var debug:bool


func _ready():
    debug = Settings.get_value("debug", false)

# Opens a trial's raw data file. SessionLog picks the name
# (GameData/raw-sessNN-trialNNN-{Game}-{Mode}.csv) and logs the trial's row in
# sessions.csv when it ends.
func create_game_log_file(game, p_id):
    var game_file_path = SessionLog.begin_trial(game, p_id)
    var game_file = FileAccess.open(game_file_path, FileAccess.WRITE)
    if game_file == null:
        push_error("Cannot create %s (error %d)" % [game_file_path, FileAccess.get_open_error()])
        return null
    game_file.store_line("headerrows,7")
    game_file.store_line("game_name,%s" % game)
    game_file.store_line("h_id,%s" % SessionLog.patient_id)
    game_file.store_line("device_location,%s" % Settings.get_value("location", ""))
    game_file.store_line("device_version,NOARK-0.1.0")
    game_file.store_line("protocol_version,0.1.0")
    game_file.store_line("start_time,%s" % Time.get_datetime_string_from_system())
    return game_file
