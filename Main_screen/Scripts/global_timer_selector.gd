extends Control

# Signals to communicate with the game
signal play_pressed(countdown_time: int)
signal close_pressed()

# Constants
const ONE_MINUTE = 60
const FIVE_MINUTES = 300
const MAX_COUNTDOWN_TIME = 2700

# Node references
@onready var time_label: Label = $Window/Time
@onready var add_one_btn: Button = $Window/AddOneButton
@onready var add_five_btn: Button = $Window/AddFiveButton
@onready var sub_one_btn: Button = $Window/SubOneButton
@onready var sub_five_btn: Button = $Window/SubFiveButton
@onready var play_button: Button = $Window/PlayButton
@onready var close_button: Button = $Window/CloseButton
@onready var timer_panel: Window = $Window

# Game state
var countdown_time: int = 0

func _ready() -> void:
	_update_label()

func show_panel() -> void:
	visible = true
	timer_panel.visible = true
	_show_timer_buttons()

func hide_panel() -> void:
	visible = false
	timer_panel.visible = false

func _show_timer_buttons() -> void:
	add_one_btn.show()
	add_five_btn.show()
	sub_one_btn.show()
	sub_five_btn.show()

func _hide_timer_buttons() -> void:
	add_one_btn.hide()
	add_five_btn.hide()
	sub_one_btn.hide()
	sub_five_btn.hide()

func _modify_countdown_time(amount: int) -> void:
	countdown_time = clamp(countdown_time + amount, 0, MAX_COUNTDOWN_TIME)
	_update_label()

func _update_label() -> void:
	var minutes = countdown_time / 60
	time_label.text = "%2d m" % [minutes]

func _on_add_one_pressed() -> void:
	_modify_countdown_time(ONE_MINUTE)

func _on_add_five_pressed() -> void:
	_modify_countdown_time(FIVE_MINUTES)

func _on_sub_one_pressed() -> void:
	_modify_countdown_time(-ONE_MINUTE)

func _on_sub_five_pressed() -> void:
	_modify_countdown_time(-FIVE_MINUTES)

func _on_play_pressed() -> void:
	_hide_timer_buttons()
	play_pressed.emit(countdown_time)

func _on_close_pressed() -> void:
	_hide_timer_buttons()
	close_pressed.emit()

func reset_for_retry() -> void:
	show_panel()
	_show_timer_buttons()
