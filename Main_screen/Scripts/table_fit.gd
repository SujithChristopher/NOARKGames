extends RefCounted

# Least-squares 2D affine from hand positions (camera x-z, metres) to screen
# pixels. Four table corners give an overdetermined fit, so the error spreads
# over all of them instead of landing on one.


# src, dst: equal-length Arrays of Vector2. Returns the Transform2D that maps
# src -> dst (x column = px per metre along camera x, y column = along z), or
# null when the points are collinear or too few.
static func fit(src: Array, dst: Array) -> Variant:
	if src.size() < 3 or src.size() != dst.size():
		return null
	var n := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	var bx := [0.0, 0.0, 0.0]
	var by := [0.0, 0.0, 0.0]
	for i in src.size():
		var row := [src[i].x, src[i].y, 1.0]
		for r in 3:
			for c in 3:
				n[r][c] += row[r] * row[c]
			bx[r] += row[r] * dst[i].x
			by[r] += row[r] * dst[i].y
	var inv = _invert(n)
	if inv == null:
		return null
	var abc := _mul(inv, bx)
	var def := _mul(inv, by)
	return Transform2D(Vector2(abc[0], def[0]), Vector2(abc[1], def[1]), Vector2(abc[2], def[2]))


# Splits the linear part of a fit into its rotation (or reflection, if the
# camera axes are mirrored against the screen) and one px-per-metre scale, the
# smaller singular value, so the table fits and keeps its shape. Returns
# {"basis": Transform2D (camera x-z -> screen-aligned unit axes), "k": float}.
# A plain normalise-the-columns would lose the rotation whenever the table and
# screen aspect differ: the columns of a stretched fit are not orthogonal.
static func frame(fit: Transform2D) -> Dictionary:
	var a := fit.x.x
	var c := fit.x.y
	var b := fit.y.x
	var d := fit.y.y
	var det := a * d - b * c
	var basis: Transform2D
	if det >= 0.0:
		basis = Transform2D(atan2(c - b, a + d), Vector2.ZERO)
	else:
		var r := Transform2D(atan2(c + b, a - d), Vector2.ZERO)
		basis = Transform2D(r.x, -r.y, Vector2.ZERO)
	var f2 := a * a + b * b + c * c + d * d
	var k := (sqrt(f2 + 2.0 * absf(det)) - sqrt(maxf(f2 - 2.0 * absf(det), 0.0))) * 0.5
	return {"basis": basis, "k": k}


static func _mul(m: Array, v: Array) -> Array:
	var out := []
	for r in 3:
		out.append(m[r][0] * v[0] + m[r][1] * v[1] + m[r][2] * v[2])
	return out


static func _invert(m: Array) -> Variant:
	var a: float = m[0][0]; var b: float = m[0][1]; var c: float = m[0][2]
	var d: float = m[1][0]; var e: float = m[1][1]; var f: float = m[1][2]
	var g: float = m[2][0]; var h: float = m[2][1]; var i: float = m[2][2]
	var det := a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
	if absf(det) < 1.0e-12:
		return null
	var k := 1.0 / det
	return [
		[(e * i - f * h) * k, (c * h - b * i) * k, (b * f - c * e) * k],
		[(f * g - d * i) * k, (a * i - c * g) * k, (c * d - a * f) * k],
		[(d * h - e * g) * k, (b * g - a * h) * k, (a * e - b * d) * k],
	]
