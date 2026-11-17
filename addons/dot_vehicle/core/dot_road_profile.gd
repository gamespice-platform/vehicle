class_name DotRoadProfile
extends RefCounted

## A road's cross-section: its bank (superelevation, the whole deck tilted toward the inside
## of a bend) and its camber (a crown: both halves falling away from the centreline so water
## runs off a straight). Pure maths, no nodes: a game that builds a road mesh asks this where
## each point across the deck stands, and the collision follows the same numbers.
##
## [b]Units.[/b] [code]x[/code] is metres right of the centreline (negative is left). Slopes
## are rise over run, so 0.02 is a 2% crown; [method bank_slope_of] and
## [method camber_slope_of] turn degrees and percent into them. A positive bank falls to the
## right. Heights are relative to the centreline, which neither bank nor camber moves: a
## crown lowers the edges rather than raising the middle, so whatever a game already put on
## the centreline (a spawn, a dashed line, a gate) stays where it was.
##
## [b]How a crown meets a bank.[/b] The road engineer's runout: as the bank grows from 0 to
## the camber, the low half keeps the camber's fall and the high half turns from falling
## outward, through level, until it is in line with the low half; from there on the deck is
## one plane at the bank. So a bank at least as steep as the camber is exactly the plain
## banked deck, and a camber of 0 is exactly the deck without one, in every case.
##
## [b]Limits.[/b] None: any finite camber of 0 or more is drawn as asked. A negative or
## non-finite camber is refused by [method check_camber]; [method half_slopes] reports it with
## [method @GlobalScope.push_error] and draws the deck uncrowned, never a guessed shape.


## Rise over run of a bank of [param degrees] (positive falls to the right).
static func bank_slope_of(degrees: float) -> float:
	return tan(deg_to_rad(degrees))


## Rise over run of a camber of [param percent] (2.0 is a 2% crown).
static func camber_slope_of(percent: float) -> float:
	return percent / 100.0


## Why [param camber_slope] cannot be a camber, or empty when it can.
static func check_camber(camber_slope: float) -> String:
	if is_nan(camber_slope) or is_inf(camber_slope):
		return "camber %s is not a number" % camber_slope

	if camber_slope < 0.0:
		return "camber %s is below 0; a crown falls away from the centreline" % camber_slope

	return ""


## Each half's fall to the right, rise over run: x the left half's, y the right half's. A
## plain banked deck has both equal to [param bank_slope].
static func half_slopes(bank_slope: float, camber_slope: float) -> Vector2:
	var why := check_camber(camber_slope)

	if why != "":
		push_error("DotRoadProfile: %s" % why)
		return Vector2(bank_slope, bank_slope)

	var e := bank_slope
	var c := camber_slope

	if e >= 0.0:
		# Falls to the right: the right half is the low one.
		return Vector2(e if e >= c else 2.0 * e - c, maxf(e, c))

	return Vector2(minf(e, -c), e if e <= -c else 2.0 * e + c)


## Whether the deck has a ridge at the centreline (its halves differ), so a mesh needs a
## vertex there. False for every camber of 0 and every bank at least as steep as the camber.
static func crowned(bank_slope: float, camber_slope: float) -> bool:
	var s := half_slopes(bank_slope, camber_slope)
	return s.x != s.y


## Height of the deck [param x] metres right of the centreline, relative to the centreline.
static func height_at(x: float, bank_slope: float, camber_slope: float) -> float:
	var s := half_slopes(bank_slope, camber_slope)
	return -(s.y if x >= 0.0 else s.x) * x


## The deck from [param left_x] to [param right_x] (metres right of the centreline, left
## first) as (x, height) points: the two ends, and the crown between them when the deck has
## one there. A mesh joins consecutive points; two points is one flat strip.
static func cross_section(left_x: float, right_x: float, bank_slope: float, camber_slope: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.append(Vector2(left_x, height_at(left_x, bank_slope, camber_slope)))

	if left_x < 0.0 and right_x > 0.0 and crowned(bank_slope, camber_slope):
		out.append(Vector2.ZERO)

	out.append(Vector2(right_x, height_at(right_x, bank_slope, camber_slope)))
	return out
