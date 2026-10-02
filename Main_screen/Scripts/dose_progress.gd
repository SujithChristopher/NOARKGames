extends CanvasLayer
## Game-select banner: today's minutes of play per movement against the
## patient's daily dose, from session.csv MoveTime. Display only, never blocks.

const FONT_SIZE := 26


func _ready() -> void:
	var label := Label.new()
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	label.position.y = 12
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)
	label.text = _text(PatientDB.current_patient_id)
	add_child(label)


static func _text(pid: String) -> String:
	var dose := SessionLog.latest_dose(pid)
	var done := SessionLog.today_minutes(pid)
	var parts := PackedStringArray()
	for m in SessionLog.MOVEMENTS:
		if dose.is_empty():
			parts.append("%s %.0f min" % [m, done[m]])
		else:
			parts.append("%s %.0f / %s min" % [m, done[m], dose.get(m, "0")])
	return "Today:  " + "   ·   ".join(parts)
