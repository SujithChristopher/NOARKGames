extends RefCounted

# The handle's rotation as the cannon's aim. The tracker sends the rigid body's
# orientation (ROTATION rvec, camera frame); this turns it into one signed angle:
# the twist about the axis the patient actually turns about, measured from their
# relaxed middle pose.
#
# The axis is not assumed. Calibration asks for a relaxed middle, then as far
# left and as far right as is comfortable, and the axis is the one that carries
# the left pose onto the right one. So the same game trains forearm rotation,
# wrist deviation or turning a dial, whichever the therapist asks for, with any
# grip on the handle. The two sides are the patient's range for that movement
# and each maps onto its half of the cannon's arc on its own: the range after a
# stroke is rarely symmetric.

enum Step { MIDDLE, LEFT, RIGHT, DONE }

const HOLD_S := 1.0          # held this still for this long = a pose is captured
const STILL_DEG := 2.0       # "still": within this of where the hold began
const MIN_TURN_DEG := 6.0    # a side's hold only counts this far from the middle
const MIN_SIDE_DEG := 4.0    # each side's twist about the found axis, at least

var step: int = Step.MIDDLE
var hold_progress := 0.0     # 0..1 of HOLD_S, for the on-screen ring
var axis := Vector3.ZERO     # camera frame, unit; set once calibrated
var left_deg := 0.0          # twist of the left pose, negative
var right_deg := 0.0         # twist of the right pose, positive
var problem := ""            # why the last right pose was refused, for the prompt

var _middle := Basis.IDENTITY
var _left := Basis.IDENTITY
var _anchor := Basis.IDENTITY
var _anchor_ms := -1


func reset() -> void:
	step = Step.MIDDLE
	hold_progress = 0.0
	problem = ""
	_anchor_ms = -1


func calibrated() -> bool:
	return step == Step.DONE


## One frame of calibration with the handle's rotation now. True when this
## frame captured a step's pose.
func feed(r: Basis) -> bool:
	if step == Step.DONE:
		return false
	var now := Time.get_ticks_msec()
	var far_enough := _far_enough(r)
	if not far_enough or _anchor_ms < 0 or angle_between(_anchor, r) > STILL_DEG:
		_anchor = r
		_anchor_ms = now
	hold_progress = clampf((now - _anchor_ms) / (HOLD_S * 1000.0), 0.0, 1.0) if far_enough else 0.0
	if hold_progress < 1.0:
		return false
	hold_progress = 0.0
	_anchor_ms = -1
	match step:
		Step.MIDDLE:
			_middle = r
			step = Step.LEFT
		Step.LEFT:
			_left = r
			step = Step.RIGHT
			problem = ""
		Step.RIGHT:
			_finish(r)
	return true


# A side's hold counts only away from the middle, and the right one only past
# it: the patient is still holding the left pose when the right is asked for.
func _far_enough(r: Basis) -> bool:
	match step:
		Step.LEFT:
			return angle_between(_middle, r) >= MIN_TURN_DEG
		Step.RIGHT:
			return angle_between(_middle, r) >= MIN_TURN_DEG \
				and angle_between(_left, r) > angle_between(_left, _middle)
	return true


# The axis that carries the left pose onto the right one; refused (and the
# right pose asked again) unless the two sit either side of the middle.
func _finish(right: Basis) -> void:
	var q := (right * _left.inverse()).get_rotation_quaternion()
	if q.w < 0.0:
		q = -q
	var v := Vector3(q.x, q.y, q.z)
	if v.length() < 1e-6:
		problem = "Turn the other way, past the middle"
		return
	var a := v.normalized()
	var l := twist_deg(_left * _middle.inverse(), a)
	var r := twist_deg(right * _middle.inverse(), a)
	if l > -MIN_SIDE_DEG or r < MIN_SIDE_DEG:
		problem = "Turn the other way, past the middle"
		return
	axis = a
	left_deg = l
	right_deg = r
	problem = ""
	step = Step.DONE


## How far the handle is turned from the middle, about the calibrated axis
## (degrees, positive towards the right pose).
func angle_deg(r: Basis) -> float:
	return twist_deg(r * _middle.inverse(), axis)


## The cannon's angle for rotation r: each side of the patient's range onto its
## half of +-arc_deg, clamped at the ends.
func aim_deg(r: Basis, arc_deg: float) -> float:
	var t := angle_deg(r)
	var span := right_deg if t >= 0.0 else -left_deg
	return clampf(t / span * arc_deg, -arc_deg, arc_deg)


## How far the handle has turned from the middle pose, any axis (calibration's
## live readout).
func turned_from_middle(r: Basis) -> float:
	return angle_between(_middle, r)


## Angle (degrees) of the rotation that takes a onto b.
static func angle_between(a: Basis, b: Basis) -> float:
	var q := (b * a.inverse()).get_rotation_quaternion()
	return rad_to_deg(2.0 * acos(clampf(absf(q.w), 0.0, 1.0)))


## Twist (degrees) of rotation r about unit axis `about`: the swing-twist split,
## so tilting the handle the other way does not move the cannon.
static func twist_deg(r: Basis, about: Vector3) -> float:
	var q := r.get_rotation_quaternion()
	var p := Vector3(q.x, q.y, q.z).dot(about)
	return rad_to_deg(wrapf(2.0 * atan2(p, q.w), -PI, PI))
