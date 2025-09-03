extends Node


var json = JSON.new()
var path = "res://debug.json"
var debug:bool


func _ready():
    debug = JSON.parse_string(FileAccess.get_file_as_string(path))['debug']

func create_game_log_file(game, p_id):

    if debug:
        p_id = 'vvv'

    if p_id:
        print(GlobalSignals.data_path)
        print(game, p_id)

    var base_path = GlobalSignals.data_path + '//' + p_id + '//' + 'GameData'
    if not DirAccess.dir_exists_absolute(base_path):
        DirAccess.make_dir_recursive_absolute(base_path)

    var session_id = GlobalScript.session_id
    var trial_id = GlobalScript.get_next_trial_id(game)
    var date = GlobalScript.get_date_string()  

    var game_path = "%s_S%d_T%d_%s.csv" % [game, session_id, trial_id, date]
    var game_file_path = base_path + '//' + game_path

    # Open the file (overwrite or create new)
    if FileAccess.file_exists(game_file_path):
        print('File already exists')
        var game_file = FileAccess.open(game_file_path, FileAccess.WRITE_READ)
        return game_file
    else:
        var game_file = FileAccess.open(game_file_path, FileAccess.WRITE)
        game_file.store_line("headerrows,7")
        game_file.store_line("game_name,%s" % game)
        game_file.store_line("h_id,%s" % GlobalSignals.current_patient_id)
        game_file.store_line("device_location,PMR")
        game_file.store_line("device_version,NOARK-0.1.0")
        game_file.store_line("protocol_version,0.1.0")
        game_file.store_line("start_time,%s" % Time.get_datetime_string_from_system())
        return game_file
        
