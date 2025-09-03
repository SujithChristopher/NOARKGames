extends Control
@onready var score_texture = %Score/ScoreTexture
@onready var score_label = %Score/ScoreLabel

var player_node: Node

func _ready():
	# Find the player node (adjust path as needed)
	player_node = $"../../Player" # Adjust this path to your player
	
func _process(_delta):
	if player_node:
		score_label.text = "x %d" % player_node.score
