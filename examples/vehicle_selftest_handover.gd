extends "res://examples/vehicle_selftest_damage.gd"

## Getting in, getting out, seat rules, destruction and disconnects, run from vehicle_selftest.


# --- The handover -------------------------------------------------------------
func _test_entering() -> void:
	_section("getting in")

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0))

	var seated: Array[StringName] = []
	# A captured Array rather than a counter: a GDScript lambda captures locals by
	# VALUE, so a counter incremented in a callback stays zero outside it.
	spawner.ride.on_seated = func(rider: StringName, _v: DotVehicleInstance, _s: DotVehicleSeat) -> void:
		seated.append(rider)

	var entered := spawner.ride.enter(jeep, &"alice", _rider())
	_check(entered.ok, "a rider gets in")
	_check(
		(entered.value as DotVehicleSeat).id == &"driver",
		"and an empty vehicle seats them as the driver",
		"definition order, which is what everybody expects and nobody specifies"
	)
	_check(jeep.driver() == &"alice", "and they are driving")
	_check(seated.size() == 1, "and the game is told, so it can stop their controller")

	_check(
		not spawner.ride.enter(jeep, &"bob", _rider(), &"driver").ok,
		"a second rider cannot take a taken seat"
	)

	var second := spawner.ride.enter(jeep, &"bob", _rider())
	_check(second.ok and (second.value as DotVehicleSeat).id == &"passenger",
		"but is seated in the next free one")
	_check(jeep.is_full(), "and the vehicle is full")

	_check(
		not spawner.ride.enter(jeep, &"carol", _rider()).ok,
		"and a third is refused"
	)

	spawner.queue_free()
	_done()


func _test_seat_rules() -> void:
	_section("seat rules")

	var spawner := _spawner()
	var one := spawner.spawn(&"jeep", Vector3(0, 1, 0))
	var two := spawner.spawn(&"jeep", Vector3(0, 1, 30))

	spawner.ride.enter(one, &"alice", _rider())

	_check(
		not spawner.ride.enter(two, &"alice", _rider()).ok,
		"somebody already riding cannot get into a second vehicle",
		"silently moving them teleports a player out of a moving car"
	)
	_check(spawner.ride.is_riding(&"alice"), "and they are still in the first")
	_check(
		spawner.vehicle_of_rider(&"alice") == one,
		"and the reverse lookup agrees"
	)

	_check(
		spawner.nearest_free(Vector3(0, 1, 29), 5.0) == two,
		"the nearest vehicle with a free seat is what a use prompt finds"
	)

	spawner.queue_free()
	_done()


func _test_exit_placement() -> void:
	_section("getting out: the sweep")

	var spawner := _spawner()
	var ground := _wall(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	var jeep := spawner.spawn(&"jeep", Vector3(0, 0.5, 0))
	var rider := _rider()

	spawner.ride.enter(jeep, &"alice", rider)

	await get_tree().physics_frame

	var seat := jeep.def.get_seat(&"driver")
	var open := spawner.ride.find_exit_position(jeep, seat)

	_check(open.ok, "an exit into open ground is found")
	_check(
		(open.value as Vector3).distance_to(jeep.position()) < 4.0,
		"and it is beside the vehicle"
	)

	# Walls on the first two candidates: the sweep must fall through to the third
	# rather than putting the player in the rock.
	var left := _wall(Vector3(-2.0, 1.0, 0.0), Vector3(1.5, 3, 6))
	var right := _wall(Vector3(2.0, 1.0, 0.0), Vector3(1.5, 3, 6))

	await get_tree().physics_frame

	var squeezed := spawner.ride.find_exit_position(jeep, seat)
	_check(squeezed.ok, "with both sides blocked, a later candidate is used")
	_check(
		absf((squeezed.value as Vector3).x - jeep.position().x) < 1.0,
		"and it is not one of the blocked ones",
		"x = %.2f" % (squeezed.value as Vector3).x
	)

	# Boxed in on every side. Refusing is the correct answer: teleporting the player
	# anyway is how they get outside a map.
	var back := _wall(Vector3(0.0, 1.0, -3.0), Vector3(6, 3, 1.5))
	var above := _wall(Vector3(0.0, 3.0, 0.0), Vector3(6, 1.5, 6))

	await get_tree().physics_frame

	var boxed := spawner.ride.find_exit_position(jeep, seat)
	_check(
		not boxed.ok,
		"and with every candidate blocked, the exit is REFUSED",
		"every game that teleports the player anyway has this bug"
	)

	var attempted := spawner.ride.exit(jeep, &"alice")
	_check(not attempted.ok, "so the rider stays in")
	_check(jeep.driver() == &"alice", "and is still driving")

	var forced := spawner.ride.exit(jeep, &"alice", true)
	_check(
		forced.ok,
		"but a forced exit still puts them somewhere",
		"a destroyed vehicle has to empty even when there is no room"
	)

	for wall in [left, right, back, above, ground]:
		wall.queue_free()

	spawner.queue_free()
	_done()


func _test_exit_rules() -> void:
	_section("getting out: the rules")

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0))
	spawner.ride.enter(jeep, &"alice", _rider())

	var body := jeep.body()
	body.linear_velocity = Vector3(0, 0, -30)

	_check(
		not spawner.ride.may_exit(jeep).ok,
		"a rider may not get out at 30 m/s"
	)

	body.linear_velocity = Vector3.ZERO
	_check(spawner.ride.may_exit(jeep).ok, "and may when it has stopped")

	# Upside down AND moving. The inversion rule has to win, or the one state a player
	# cannot drive out of is the one they cannot leave.
	body.linear_velocity = Vector3(0, 0, -30)
	jeep.node.global_transform = Transform3D(
		Basis(Vector3.FORWARD, PI), jeep.node.global_position
	)

	_check(jeep.is_inverted(), "an overturned vehicle knows it is overturned")
	_check(
		spawner.ride.may_exit(jeep).ok,
		"and a rider may always leave one, whatever its speed",
		"a rule that kept them in is a rule that kills them"
	)

	spawner.queue_free()
	_done()


func _test_carrying_the_rider() -> void:
	_section("carrying the rider")

	# Two frames, and 400 metres away from everything else in this file.
	#
	# `queue_free` is DEFERRED, so the walls the exit-placement test boxed a vehicle in
	# with are still in the physics space for the rest of the frame — and the first
	# version of this test spawned its vehicle at the same origin and found every exit
	# blocked by scenery a previous test thought it had removed. It read exactly like a
	# broken ejection.
	await get_tree().physics_frame
	await get_tree().physics_frame

	var spawner := _spawner()
	var ground := _wall(Vector3(400, -0.5, 0), Vector3(200, 1, 200))
	var jeep := spawner.spawn(&"jeep", Vector3(400, 0.5, 0))
	var rider := _rider()
	var original_parent := rider.get_parent()

	var layer_before := rider.collision_layer

	spawner.ride.enter(jeep, &"alice", rider)

	_check(
		rider.get_parent() == jeep.node,
		"the rider's node is parented into the vehicle",
		"the only thing that survives a vehicle rolling over"
	)
	_check(
		rider.collision_layer == 0 and rider.collision_mask == 0,
		"and taken out of the physics world",
		"a rider still colliding shoves the vehicle they are riding in"
	)

	var got_out := spawner.ride.exit(jeep, &"alice")

	_check(got_out.ok, "and they get out again")
	_check(
		rider.get_parent() == original_parent,
		"back into the world they came from"
	)
	_check(
		rider.collision_layer == layer_before,
		"with their collision restored",
		"a rider left on layer 0 walks through the map for the rest of the round"
	)
	_check(
		rider.get_parent() != jeep.node
			and rider.global_position.distance_to(jeep.position()) > 1.0,
		"and standing beside the vehicle rather than inside it",
		"%.2f m" % rider.global_position.distance_to(jeep.position())
	)
	_check(not spawner.ride.is_riding(&"alice"), "and the bookkeeping is undone")

	ground.queue_free()
	spawner.queue_free()
	_done()


func _test_destruction() -> void:
	_section("destruction")

	var spawner := _spawner()
	var wreckable := spawner.spawn(&"wreckable", Vector3(0, 1, 0))
	var alice := _rider()
	var bob := _rider()

	spawner.ride.enter(wreckable, &"alice", alice)
	spawner.ride.enter(wreckable, &"bob", bob)

	_check(wreckable.occupant_count() == 2, "two riders aboard")

	_check(spawner.damage(wreckable.instance_id, 50.0) == 50.0, "it takes damage")
	_check(wreckable.health == 150.0, "and health comes off")

	var wrecked: Array[StringName] = []
	spawner.destroyed.connect(func(_v: DotVehicleInstance, by: StringName) -> void:
		wrecked.append(by))

	spawner.damage(wreckable.instance_id, 500.0, &"alice")
	_check(wreckable.is_alive() and spawner.pending_count() == 1,
		"an overkill with riders aboard waits for the physics step")
	spawner.tick(1.0 / 60.0)

	_check(wrecked.size() == 1, "an overkill destroys it")
	_check(not wreckable.is_alive(), "and it is gone")
	_check(
		not spawner.ride.is_riding(&"alice") and not spawner.ride.is_riding(&"bob"),
		"and EVERYBODY is put down first",
		"a rider in a freed vehicle is parented to nothing: invisible and unkillable"
	)
	_check(
		is_instance_valid(alice) and alice.get_parent() != null,
		"with their nodes back in a real parent"
	)

	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 30))
	_check(
		spawner.damage(jeep.instance_id, 9999.0) == 0.0,
		"and a vehicle with no max_health is indestructible",
		"a real answer a sandbox wants, not an oversight"
	)
	_check(jeep.is_alive(), "and survives")

	spawner.queue_free()
	_done()


func _test_disconnects() -> void:
	_section("disconnects")

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0), &"alice")
	spawner.ride.enter(jeep, &"bob", _rider())

	_check(spawner.owner_left(&"alice") == 0,
		"a disconnect does not remove the owner's vehicle by default",
		"it would delete the car its passengers are riding in")
	_check(jeep.is_alive(), "so bob keeps driving")
	_check(spawner.vehicles_of(&"alice").is_empty(),
		"but it is disowned, so a departed player's budget is not held")

	spawner.clean_up_on_leave = true
	var second := spawner.spawn(&"jeep", Vector3(0, 1, 40), &"carol")
	_check(spawner.owner_left(&"carol") == 1, "a server that wants the other rule gets it")
	_check(not second.is_alive(), "and the vehicle goes")

	spawner.queue_free()
	_done()
