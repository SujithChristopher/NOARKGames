extends RefCounted

# The handle's rotation as the cannon's aim. The tracker sends the rigid body's
# orientation (ROTATION rvec, camera frame); this turns it into one angle: the
# twist about the axis the patient actually turns about, measured from where the
# turn starts.
#
# Calibration captures two poses: where the turn starts and as far as it goes.
# Both are usually extremes of what the arm allows (a right hand cannot turn
# further right than where it starts), so there is no middle with a side either
# way. That one range is the cannon's whole arc: initial at one end, max at the
# other.
#
# The axis is not assumed: it is the one that carries initial onto max. So the
# same game trains forearm rotation, wrist deviation or turning a dial, whichever
# the therapist asks for, with any grip on the handle.

enum Step { INITIAL, MAX, DONE }

const MIN_RANGE_DEG := 8.0   # the whole arc hangs on this range; any less and noise would aim

var step: int = Step.INITIAL
var start_side := 1          # the end of the arc initial sits at: 1 right, -1 left
var axis := Vector3.ZERO     # camera frame, unit; set once calibrated
var range_deg := 0.0         # the turn from initial to max
var problem := ""            # why the last max pose was refused, for the prompt

var _initial := Basis.IDENTITY


func reset() -> void:
	step = Step.INITIAL
	problem = ""


func calibrated() -> bool:
	return step == Step.DONE


## Takes rotation r as this step's pose. A max too close to initial is refused:
## `problem` says why and the step stays, so the next capture tries again.
func capture(r: Basis) -> void:
	match step:
		Step.INITIAL:
			_initial = r
			step = Step.MAX
		Step.MAX:
			_finish(r)


func _finish(furthest: Basis) -> void:
	var turned := angle_between(_initial, furthest)
	if turned < MIN_RANGE_DEG:
		problem = "Turn further, at least %d°" % roundi(MIN_RANGE_DEG)
		return
	var q := (furthest * _initial.inverse()).get_rotation_quaternion()
	if q.w < 0.0:
		q = -q
	axis = Vector3(q.x, q.y, q.z).normalized()
	range_deg = turned
	problem = ""
	step = Step.DONE


## How far the handle is turned from initial, about the calibrated axis (degrees,
## positive towards max). Twist wraps at 180°; this puts the wrap as far from the
## range as it can go, so turning past either end does not read as the other end.
func angle_deg(r: Basis) -> float:
	var half := range_deg / 2.0
	return wrapf(twist_deg(r * _initial.inverse(), axis) - half, -180.0, 180.0) + half


## The cannon's angle for rotation r: initial at start_side's end of +-arc_deg,
## max at the other, clamped at both.
func aim_deg(r: Basis, arc_deg: float) -> float:
	var t := clampf(angle_deg(r) / range_deg, 0.0, 1.0)
	return start_side * arc_deg * (1.0 - 2.0 * t)


## How far the handle has turned from the initial pose, any axis (calibration's
## live readout).
func turned_from_initial(r: Basis) -> float:
	return angle_between(_initial, r)


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
