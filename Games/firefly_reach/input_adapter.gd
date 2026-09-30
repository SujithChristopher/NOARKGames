extends RefCounted

# The clinic game's view of the tracker, over this repo's GlobalScript.
# The clinic build had its own UDP receiver that buffered every tracker sample
# (~100 Hz, camera capture clock). GlobalScript keeps only the latest position,
# so a sample here is one per frame, timed by the wall clock: holds are judged
# at frame rate and movement times carry that much jitter.
# Mouse fallback (round_runner.gd) when no packet has ever arrived.


# One sample per frame, in the shape round_runner.gd reads:
# [arrival, screen_x, screen_y, tracker_x, tracker_y, tracker_z, capture]
static func take_samples() -> Array:
	if not connected():
		return []
	var now := Time.get_unix_time_from_system()
	# With a table defined the hand is in real metres from the table centre;
	# without one raw_x / raw_z are the origin-lock metres.
	var hx: float = GlobalScript.table_r.x if GlobalScript.table_set else GlobalScript.raw_x
	var hz: float = GlobalScript.table_r.y if GlobalScript.table_set else GlobalScript.raw_z
	return [[now, 0.0, 0.0, hx, GlobalScript.raw_y, hz, now]]


# A packet has been seen since the game started.
static func connected() -> bool:
	return GlobalScript.last_packet_ms > 0


# A packet arrived within max_age_ms.
static func is_fresh(max_age_ms: int = 1500) -> bool:
	return connected() and Time.get_ticks_msec() - GlobalScript.last_packet_ms <= max_age_ms


static func packets_per_sec() -> int:
	return GlobalScript.packets_per_second
