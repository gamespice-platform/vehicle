extends "res://examples/vehicle_selftest_replication.gd"

## Proves the handover holds, the exit sweep refuses a wall, and nothing leaks.
##
## [codeblock]
## godot --headless --path . res://examples/vehicle_selftest.tscn
## [/codeblock]
##
## [b]The tests that matter are the ones about getting out.[/b] Driving is where the
## prior art is; the handover is where the bugs are, and every one of them is a state a
## player can reach and a suite can only reach on purpose: a seat with two people in it,
## an exit into a wall, a vehicle destroyed with three riders aboard, a disconnect
## halfway through a corner. All of those are here, with real bodies in a real physics
## world, because a placement test against no colliders would pass anywhere.

const DriverTests := preload("vehicle_selftest_driver.gd")

const CHECKS := 231

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 33


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-vehicle self-test")
	print("")

	_world = Node3D.new()
	add_child(_world)

	var driver_tests := DriverTests.new(self)
	_test_seats()
	_test_tunables()
	_test_steering_falloff()
	_test_road_profile()
	_test_definitions()
	_test_catalogue()
	_test_commands()
	_test_spawning()
	_test_adopting()
	_test_authority()
	_test_budgets()
	_test_chassis()
	await _test_driving()
	await _test_brakes()
	driver_tests.test_driver_steering()
	driver_tests.test_driver_route()
	driver_tests.test_driver_stuck()
	driver_tests.test_driver_drives_a_car()
	_test_entering()
	_test_seat_rules()
	await _test_exit_placement()
	_test_exit_rules()
	await _test_carrying_the_rider()
	_test_destruction()
	_test_disconnects()
	_test_rider_freed_aboard()
	await _test_no_leaked_nodes()
	_test_net_sync()
	_test_damage_model()
	await _test_breakage()
	await _test_wreck()
	await _test_deferred_queries()
	_test_space_query_audit()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


# --- Data ---------------------------------------------------------------------

func _test_seats() -> void:
	_section("seats")

	var seat := DotVehicleSeat.make(&"driver", true)
	_check(seat.validate().ok, "a seat validates")
	_check(seat.drives, "and a driving seat drives")
	_check(not seat.may_fire, "and a driver does not fire by default")
	_check(DotVehicleSeat.make(&"gunner").may_fire, "and a passenger does")

	var trapped := DotVehicleSeat.make(&"trapped")
	trapped.exit_offsets = []
	_check(
		not trapped.validate().ok,
		"a seat with no exit offsets is refused",
		"the moment a player finds one is the moment they are already in it"
	)

	var round_tripped := DotVehicleSeat.from_dictionary(seat.to_dictionary())
	_check(round_tripped.id == seat.id and round_tripped.drives, "a seat round trips")
	_check(
		round_tripped.exit_offsets.size() == seat.exit_offsets.size(),
		"including its exits"
	)
	_done()


func _test_tunables() -> void:
	_section("tunables")

	var tuning := DotVehicleTunables.new()
	_check(tuning.validate().ok, "the defaults are usable")

	tuning.brake_force = 10.0
	_check(
		not tuning.validate().ok,
		"a vehicle that cannot out-brake its own engine is refused",
		"it reads as having no brakes, and gets reported as a physics bug"
	)

	var configured := DotVehicleTunables.new()
	configured.apply_dictionary({"top_speed": 50.0, "mass": 1400.0})
	_check(
		configured.top_speed == 50.0 and configured.mass == 1400.0,
		"and it is a DotConfig, so a server retunes handling in a file"
	)
	_done()


func _test_steering_falloff() -> void:
	_section("steering")

	var tuning := DotVehicleTunables.new()
	tuning.steering_limit_deg = 30.0
	tuning.steering_speed_falloff = 0.4
	tuning.top_speed = 30.0

	var at_rest := tuning.steering_limit_at(0.0)
	var at_speed := tuning.steering_limit_at(30.0)

	_check(
		absf(rad_to_deg(at_rest) - 30.0) < 0.01,
		"full lock is available at a standstill",
		"%.1f deg" % rad_to_deg(at_rest)
	)
	_check(
		absf(rad_to_deg(at_speed) - 12.0) < 0.01,
		"and a fraction of it at the top speed",
		"%.1f deg" % rad_to_deg(at_speed)
	)
	_check(
		tuning.steering_limit_at(200.0) >= at_speed,
		"and it stops falling above the top speed",
		"a vehicle off a cliff would otherwise land unsteerable"
	)
	_done()


## [DotRoadProfile]: a camber of 0 is the plain banked deck to the last bit, a crown falls
## both ways on a straight, and a bank as steep as the camber swallows it.
func _test_road_profile() -> void:
	_section("road profile")

	var half := 5.0
	var flat_same := true

	for deg: float in [-12.0, -3.0, 0.0, 0.5, 7.0, 12.0]:
		var e := DotRoadProfile.bank_slope_of(deg)
		for side: float in [-1.0, 1.0]:
			var before := -side * tan(deg_to_rad(deg)) * half
			flat_same = flat_same and is_equal_approx(DotRoadProfile.height_at(side * half, e, 0.0), before)
		flat_same = flat_same and not DotRoadProfile.crowned(e, 0.0)
		flat_same = flat_same and DotRoadProfile.cross_section(-half, half, e, 0.0).size() == 2

	_check(flat_same, "a camber of 0 is the banked deck there was, with no crown vertex")

	var c := DotRoadProfile.camber_slope_of(2.0)
	_check(is_equal_approx(c, 0.02), "a camber is given in percent")
	_check(
		is_equal_approx(DotRoadProfile.height_at(-half, 0.0, c), -0.1)
			and is_equal_approx(DotRoadProfile.height_at(half, 0.0, c), -0.1),
		"a 2% crown on a straight drops both edges of a 10 m road by 10 cm",
		"%.3f / %.3f" % [DotRoadProfile.height_at(-half, 0.0, c), DotRoadProfile.height_at(half, 0.0, c)]
	)
	_check(DotRoadProfile.height_at(0.0, 0.0, c) == 0.0, "and leaves the centreline where it was")

	var section := DotRoadProfile.cross_section(-half, half, 0.0, c)
	_check(section.size() == 3 and section[1] == Vector2.ZERO, "so the deck has a crown vertex on the centreline")
	_check(
		DotRoadProfile.cross_section(0.5, half, 0.0, c).size() == 2,
		"but not on a strip that does not reach the centreline (a washout's kept side)"
	)

	var steep := DotRoadProfile.bank_slope_of(6.0)
	_check(
		not DotRoadProfile.crowned(steep, c) and not DotRoadProfile.crowned(-steep, c)
			and is_equal_approx(DotRoadProfile.height_at(-half, steep, c), steep * half),
		"a bank steeper than the camber is the plain banked deck"
	)

	# The runout: halfway to the camber the high half is level, the low half keeps the crown.
	var mid := DotRoadProfile.half_slopes(c * 0.5, c)
	var mid_left := DotRoadProfile.half_slopes(-c * 0.5, c)
	_check(
		is_zero_approx(mid.x) and is_equal_approx(mid.y, c) and is_zero_approx(mid_left.y) and is_equal_approx(mid_left.x, -c),
		"half a camber's bank levels the high half and keeps the low half's fall, either way round",
		"%s %s" % [mid, mid_left]
	)

	var big := DotRoadProfile.half_slopes(0.0, 0.5)
	_check(is_equal_approx(big.y, 0.5) and is_equal_approx(big.x, -0.5), "and no camber is too steep to draw as asked")
	_check(
		DotRoadProfile.check_camber(-0.01) != "" and DotRoadProfile.check_camber(NAN) != ""
			and DotRoadProfile.check_camber(INF) != "" and DotRoadProfile.check_camber(0.0) == "",
		"a negative or non-finite camber is refused by name"
	)
	_done()


func _test_definitions() -> void:
	_section("definitions")

	var jeep := _jeep()
	_check(jeep.validate().ok, "a definition validates")
	_check(jeep.driver_seats().size() == 1, "and it has a driving seat")

	var scenery := DotVehicleDef.make(&"statue", CAR)
	_check(
		not scenery.validate().ok, "a vehicle with no seats is refused", "it is scenery"
	)

	var undriveable := DotVehicleDef.make(&"trailer", CAR)
	undriveable.seats = [DotVehicleSeat.make(&"passenger")]
	_check(
		not undriveable.validate().ok,
		"and so is one with no driving seat",
		"nobody could ever move it"
	)

	var clashing := DotVehicleDef.make(&"twin", CAR)
	clashing.seats = [
		DotVehicleSeat.make(&"driver", true), DotVehicleSeat.make(&"driver")
	]
	_check(
		not clashing.validate().ok,
		"and so are two seats sharing an id",
		"the second is unreachable, so the vehicle quietly holds one fewer person"
	)

	var by_class := DotVehicleDef.make(&"jeep", CAR)
	by_class.seats = [DotVehicleSeat.make(&"driver", true)]
	by_class.chassis_script_path = "MyChassis"
	_check(
		not by_class.validate().ok,
		"a chassis named by class rather than by path is refused"
	)

	var round_tripped := DotVehicleDef.from_dictionary(jeep.to_dictionary())
	_check(round_tripped.id == jeep.id, "a definition survives a round trip")
	_check(round_tripped.seat_count() == 2, "with its seats")
	_check(
		round_tripped.tuning().mass == 800.0,
		"and its handling",
		"%.0f" % round_tripped.tuning().mass
	)
	_done()


func _test_catalogue() -> void:
	_section("catalogue")

	var cat := _catalogue()
	_check(cat.size() == 5, "a catalogue holds what was added", "%d" % cat.size())
	_check(cat.get_vehicle(&"jeep") != null, "and finds by id")
	_check(cat.seating_at_least(2).size() == 2, "and can be asked for room for two")

	var rejected := PackedStringArray()
	var reloaded := DotVehicleCatalogue.from_dictionary({
		"vehicles": [
			{"id": "good", "scene": CAR, "seats": [{"id": "driver", "drives": true}]},
			{"id": "seatless", "scene": CAR},
		]
	}, rejected)

	_check(
		reloaded.size() == 1 and rejected.size() == 1,
		"one bad entry does not condemn the file",
		"%d kept, %d rejected" % [reloaded.size(), rejected.size()]
	)
	_done()


func _test_commands() -> void:
	_section("commands")

	var cmd := DotVehicleCommand.make(40.0, -9.0, 3.0)
	cmd.sanitise()
	_check(
		cmd.throttle == 1.0 and cmd.steer == -1.0 and cmd.brake == 1.0,
		"a command out of range is clamped",
		"a client is a program the player can edit"
	)

	var poisoned := DotVehicleCommand.new()
	poisoned.throttle = NAN
	poisoned.steer = NAN
	poisoned.aim_yaw = NAN
	poisoned.sanitise()
	_check(
		not is_nan(poisoned.throttle) and not is_nan(poisoned.steer),
		"and a NaN is refused rather than clamped",
		"clampf(NAN) is NAN, and one NaN ends a vehicle's transform for the round"
	)

	_check(DotVehicleCommand.new().is_idle(), "an empty command is idle")

	# One key to slow down and to reverse. A direction each way, because "it braked" alone
	# would pass for a helper that braked a vehicle trying to reverse from a standstill.
	var rolling := DotVehicleCommand.make(-1.0).brake_then_reverse(12.0)
	_check(rolling.throttle == 0.0 and rolling.brake == 1.0,
		"back while rolling forward is the brake, not reverse thrust",
		"throttle %.2f, brake %.2f" % [rolling.throttle, rolling.brake])
	var stopped := DotVehicleCommand.make(-1.0).brake_then_reverse(0.3)
	_check(stopped.throttle == -1.0 and stopped.brake == 0.0,
		"and once (nearly) stopped it reverses",
		"throttle %.2f, brake %.2f" % [stopped.throttle, stopped.brake])
	var reversing := DotVehicleCommand.make(0.6).brake_then_reverse(-5.0)
	_check(reversing.throttle == 0.0 and is_equal_approx(reversing.brake, 0.6),
		"and forward while rolling backwards brakes first, as hard as the key is pressed",
		"throttle %.2f, brake %.2f" % [reversing.throttle, reversing.brake])
	_done()


# --- Spawning -----------------------------------------------------------------

func _test_spawning() -> void:
	_section("spawning")

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0), &"alice")

	_check(jeep != null, "a vehicle spawns")
	_check(jeep.is_alive(), "and is alive")
	_check(jeep.def.seat_count() == 2, "with its seats")
	_check(jeep.is_empty(), "and nobody in it")
	_check(spawner.world_count() == 1, "and the spawner knows about it")

	_check(
		jeep.body().mass == 800.0,
		"and the tunables' mass is written ONTO the body",
		"dot-props' bug: a catalogue saying one thing over a scene saying another"
	)

	_check(spawner.spawn(&"nothing", Vector3.ZERO) == null, "an unknown id is refused")

	spawner.queue_free()
	_done()


## A body created by somebody else, made a vehicle.
##
## The case that put this method here is game-playlot, where every spawnable is a
## `DotPropInstance` so that a gravity gun can punt it — so the body exists, in the
## world, before anything knows it is a car.
func _test_adopting() -> void:
	_section("adopting")

	var spawner := _spawner()

	var scene: PackedScene = load(CAR)
	var body := scene.instantiate() as Node3D
	_world.add_child(body)
	body.global_position = Vector3(0, 1, 40)

	var jeep := spawner.adopt(body, &"jeep", &"alice")

	_check(jeep != null, "a body somebody else made becomes a vehicle")
	_check(jeep.node == body, "over the node it was given, not a second one")
	_check(jeep.chassis is DotVehicleWheeled, "with its chassis attached")
	_check(spawner.world_count() == 1, "and it counts against the world budget")
	_check(
		jeep.position().distance_to(Vector3(0, 1, 40)) < 0.5,
		"and it is left where its host put it",
		"adopt places nothing: whoever made the body already decided"
	)

	_check(
		spawner.adopt(body, &"jeep", &"alice") == null,
		"the same body is refused a second time",
		"two chassis over one rigid body is twice the engine force, silently"
	)

	# The half that only fails on the deployment this exists for: dot-props frees the
	# node from its own undo stack, so this spawner must not free it as well.
	spawner.remove(jeep.instance_id)
	_check(is_instance_valid(body), "removing an adopted vehicle leaves its node alone")
	_check(spawner.world_count() == 0, "but the spawner has let go of it")

	body.queue_free()
	spawner.queue_free()
	_done()


func _test_authority() -> void:
	_section("authority")

	var client := DotVehicleSpawner.new()
	client.catalogue = _catalogue()
	client.authoritative = false
	_world.add_child(client)

	_check(client.spawn(&"jeep", Vector3.ZERO) == null, "a client may not spawn")
	_check(client.world_count() == 0, "and nothing appeared")

	client.queue_free()
	_done()


func _test_budgets() -> void:
	_section("budgets")

	var spawner := _spawner(10)

	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"alice") != null, "one fits")
	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"alice") != null, "and a second")
	_check(
		spawner.spawn(&"jeep", Vector3.ZERO, &"alice") == null,
		"and a third is over the world budget",
		"counted in cost, not in bodies"
	)

	spawner.per_player_budget = 4
	spawner.world_budget = 0
	spawner.clear_all()

	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"bob") != null, "bob gets one")
	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"bob") == null, "and not a second")
	_check(spawner.spawn(&"jeep", Vector3.ZERO, &"carol") != null, "and carol is not affected")

	spawner.queue_free()
	_done()


func _test_chassis() -> void:
	_section("chassis")

	var spawner := _spawner()

	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0))
	_check(jeep.chassis is DotVehicleWheeled, "a wheeled definition gets Godot's wheels")

	var skiff := spawner.spawn(&"skiff", Vector3(0, 1, 20))
	_check(skiff.chassis is DotVehicleHover, "a hover definition gets the hover chassis")

	var scripted := spawner.spawn(&"scripted", Vector3(0, 1, 40))
	_check(
		scripted.chassis != null and scripted.chassis is DotVehicleChassis,
		"and a definition naming a script by PATH gets that",
		"the shape a delivered chassis must have"
	)

	var broken := spawner.spawn(&"broken", Vector3(0, 1, 60))
	_check(broken != null, "a vehicle whose chassis is not a chassis still spawns",
		"deleting it would hide which script was wrong")
	_check(
		broken.chassis == null,
		"but is not given one",
		"or the tick after the spawn calls drive() on something with no such method"
	)

	var custom := spawner.spawn(&"wreckable", Vector3(0, 1, 80))
	_check(
		custom.chassis == null,
		"and a CUSTOM vehicle is deliberately given none"
	)

	# A wheeled definition over a scene with no wheels: the refusal that matters,
	# because the alternative is something that looks like a car for four seconds.
	var wrong := DotVehicleDef.make(&"wrong", SKIFF)
	wrong.seats = [DotVehicleSeat.make(&"driver", true)]
	spawner.catalogue.add(wrong)

	var mismatched := spawner.spawn(&"wrong", Vector3(0, 1, 100))
	_check(
		mismatched.chassis == null,
		"a wheeled definition over a scene with no VehicleBody3D is refused",
		"a body driven by central force looks like a car and behaves like a crate"
	)

	spawner.queue_free()
	_done()


func _test_driving() -> void:
	_section("driving")

	var spawner := _spawner()
	var ground := _wall(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1.0, 0))
	var rider := _rider()

	spawner.ride.enter(jeep, &"alice", rider)

	var before := jeep.position()

	spawner.set_command(jeep.instance_id, &"alice", DotVehicleCommand.make(1.0))

	for i in 90:
		spawner.tick(1.0 / 60.0)
		await get_tree().physics_frame

	var travelled := jeep.position().distance_to(before)

	_check(travelled > 1.0, "a vehicle with the throttle down moves",
		"%.2f m in 90 ticks" % travelled)
	_check(
		jeep.forward_speed() > 0.5,
		"and it moves FORWARD",
		"%.2f m/s" % jeep.forward_speed()
	)

	# The command is held, not consumed: a driver's input arrives at their frame rate
	# and the vehicle is simulated at the server's, so a consumed command gives a
	# vehicle that accelerates in stutters on any client below the tick rate.
	_check(jeep.command != null, "and the command is held rather than consumed")

	# Which way +1 steers. Godot's own sign is the opposite of this family's and the
	# translation lives in one place; a check that only measured "it turned" would pass
	# for a car that turns the wrong way, which is the bug the sign flip exists for.
	var heading_before := -jeep.node.global_transform.basis.z
	spawner.set_command(jeep.instance_id, &"alice", DotVehicleCommand.make(1.0, 1.0))

	for i in 150:
		spawner.tick(1.0 / 60.0)
		await get_tree().physics_frame

	var heading_after := -jeep.node.global_transform.basis.z
	var turned := atan2(heading_after.x, -heading_after.z) - atan2(heading_before.x, -heading_before.z)

	_check(
		turned > deg_to_rad(1.0),
		"and steering +1 turns RIGHT",
		"%.1f deg" % rad_to_deg(turned)
	)

	var passenger_cmd := DotVehicleCommand.make(1.0)
	_check(
		not spawner.set_command(jeep.instance_id, &"bob", passenger_cmd).ok,
		"somebody who is not driving cannot send a command",
		"or a passenger drives from the back seat"
	)

	ground.queue_free()
	spawner.queue_free()
	_done()


## Brakes are forces. Godot reads a wheel's `brake` as an impulse per physics step, and
## the chassis handed it newtons until 2026-10: a car stopped from 50 km/h in 5.5 m and a
## loaded truck in 0.7 m, and a heavier vehicle stopped exactly as soon as a light one.
## Measured on real bodies, at two tick rates, because both bugs are about the step.
func _test_brakes() -> void:
	_section("brakes")

	var rate_was := Engine.physics_ticks_per_second
	var ground := _wall(Vector3(1000, -0.5, -150), Vector3(30, 1, 400))

	var at_60: float = await _stopping_distance(800.0, 60, Vector3(995, 1.0, 0))
	var at_120: float = await _stopping_distance(800.0, 120, Vector3(1000, 1.0, 0))
	var heavy: float = await _stopping_distance(1600.0, 60, Vector3(1005, 1.0, 0))

	Engine.physics_ticks_per_second = rate_was

	# 8100 N on 800 kg is 10.1 m/s², so 13.9 m/s stops in about 9.5 m. The wall it used
	# to be was 5.5 m; a figure under 7 m is the impulse again.
	_check(
		at_60 > 7.0 and at_60 < 13.0,
		"a car brakes from 50 km/h in the distance its brake force says, not a wall",
		"%.2f m; 8100 N on 800 kg is about 9.5 m" % at_60
	)
	_check(
		absf(at_120 - at_60) < at_60 * 0.1,
		"and the same distance at 120 ticks as at 60",
		"%.2f m against %.2f m" % [at_120, at_60]
	)
	_check(
		heavy > at_60 * 1.6,
		"and twice the mass stops in about twice the distance",
		"%.2f m against %.2f m" % [heavy, at_60]
	)

	# The brake values on the wheels, which is where the step goes in.
	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(1000, 1.0, -300))
	var wheels: Array[VehicleWheel3D] = []
	for child in jeep.node.get_children():
		if child is VehicleWheel3D:
			wheels.append(child)

	var both := DotVehicleCommand.make(0.0, 0.0, 1.0)
	both.handbrake = true
	jeep.chassis.drive(both, 1.0 / 60.0)

	var step := (jeep.chassis as DotVehicleWheeled).step_seconds()
	var front := wheels[0].brake
	var rear := wheels[3].brake
	_check(
		is_equal_approx(front, 8100.0 * step / 4.0),
		"a wheel's brake is its share of the force times the physics step",
		"%.3f N·s at a %.4f s step" % [front, step]
	)
	_check(
		is_equal_approx(rear, front + 12000.0 * step / 2.0),
		"and the handbrake adds to the foot brake on the rear wheels rather than replacing it"
	)

	var body := jeep.node as RigidBody3D
	_check(
		body.linear_damp_mode == RigidBody3D.DAMP_MODE_REPLACE and is_equal_approx(body.linear_damp, 0.1),
		"the tunables' damping is written onto the body, replacing the project's",
		"mode %d, %.2f" % [body.linear_damp_mode, body.linear_damp]
	)

	var coasting := DotVehicleCommand.make()
	jeep.chassis.drive(coasting, 1.0 / 60.0)
	_check(wheels[0].brake == 0.0 and wheels[3].brake == 0.0, "and letting go takes every brake off")

	# The handbrake's grip. 1.0 by default, so the rear tyres keep theirs and nothing tuned
	# before it moved; under 1.0 the rear tyres let go while it is held and get their grip
	# back when it is released (the slide is measured in mg-buses-from-hell, on a bus).
	var rear_grip := 3.2 * 0.9
	jeep.chassis.drive(both, 1.0 / 60.0)
	_check(is_equal_approx(wheels[3].wheel_friction_slip, rear_grip),
		"by default the handbrake leaves the rear tyres' grip alone",
		"%.2f" % wheels[3].wheel_friction_slip)
	jeep.chassis.tunables.handbrake_grip_fraction = 0.25
	jeep.chassis.drive(both, 1.0 / 60.0)
	_check(is_equal_approx(wheels[3].wheel_friction_slip, rear_grip * 0.25)
			and is_equal_approx(wheels[0].wheel_friction_slip, 3.2),
		"with handbrake_grip_fraction the rear tyres let go while it is held, and only the rear",
		"rear %.2f, front %.2f" % [wheels[3].wheel_friction_slip, wheels[0].wheel_friction_slip])
	jeep.chassis.drive(coasting, 1.0 / 60.0)
	_check(is_equal_approx(wheels[3].wheel_friction_slip, rear_grip),
		"and get it back the tick it is released",
		"%.2f" % wheels[3].wheel_friction_slip)
	jeep.chassis.tunables.handbrake_grip_fraction = 1.0

	ground.queue_free()
	spawner.queue_free()
	await get_tree().physics_frame
	_done()


## Metres a jeep of [param mass] takes to stop from 50 km/h at [param rate] physics ticks.
func _stopping_distance(mass: float, rate: int, at: Vector3) -> float:
	Engine.physics_ticks_per_second = rate
	await get_tree().physics_frame

	var spawner := _spawner()
	var def := _jeep()
	def.id = &"weighed"
	def.tunables.mass = mass
	spawner.catalogue.add(def)

	var car := spawner.spawn(&"weighed", at)
	var chassis := car.chassis as DotVehicleChassis
	var dt := 1.0 / float(rate)
	var go := DotVehicleCommand.make(1.0)
	var stop := DotVehicleCommand.make(0.0, 0.0, 1.0)

	var guard := rate * 15
	while car.forward_speed() < 13.89 and guard > 0:
		chassis.drive(go, dt)
		await get_tree().physics_frame
		guard -= 1

	var start := car.position()
	guard = rate * 15
	while car.speed() > 0.2 and guard > 0:
		chassis.drive(stop, dt)
		await get_tree().physics_frame
		guard -= 1

	var distance := car.position().distance_to(start)
	spawner.queue_free()
	await get_tree().physics_frame
	return distance


func _test_no_leaked_nodes() -> void:
	_section("no leaks")

	var holder := Node3D.new()
	_world.add_child(holder)

	var spawner := DotVehicleSpawner.new()
	spawner.catalogue = _catalogue()
	spawner.authoritative = true
	spawner.world_budget = 0
	spawner.per_player_budget = 0
	spawner.spawn_interval = 0.0
	spawner.world_ref = DotNodeRef.of_self()
	holder.add_child(spawner)

	for i in 6:
		spawner.spawn(&"jeep", Vector3(0, 1, float(i) * 20.0))

	# A real count of the tree, not of the dictionary: a budget that counted its own
	# bookkeeping would pass while leaking bodies.
	_check(spawner.get_child_count() == 6, "six vehicles are six nodes",
		"%d" % spawner.get_child_count())

	spawner.clear_all()
	await get_tree().process_frame
	await get_tree().process_frame

	_check(spawner.get_child_count() == 0, "and clearing them frees every one",
		"%d left" % spawner.get_child_count())

	holder.queue_free()
	_done()
