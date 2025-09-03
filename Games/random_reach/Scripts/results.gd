extends Control
var interpreter_path = ""
var pyscript_path = r"D:\CMC\ArmBo_games\OSKAR_GAME_v3\pyfiles\analysis.py"
var rom = ""
@onready var my_texture = $TextureRect2


# Called when the node enters the scene tree for the first time.
func _ready():
    var rom_val = $rom_value
    var max_x = $max_x_value
    var max_y = $max_y_value
    var output = []
    interpreter_path = r"D:\CMC\py_env\venv\Scripts\python.exe"
    OS.execute(interpreter_path, [pyscript_path], output)
    print(output)
    rom = String(output[0]).split('\r\n')[0]
    rom_val.text = rom
    
    max_x.text = String(output[0]).split('\r\n')[2]
    max_y.text = String(output[0]).split('\r\n')[3]
    my_texture.texture = load("res://analysis.png")
    
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
    if Input.is_action_just_pressed("ui_left"):
        my_texture.texture = load("res://analysis.png")
        print('key pressed')
