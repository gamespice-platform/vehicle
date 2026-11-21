extends "res://examples/vehicle_selftest_base.gd"

## The damage model, breakage and wrecks, run from vehicle_selftest.


## The model alone: no body, no physics.
func _test_damage_model() -> void:
	_section("damage: the model")

	var d := GSVehicleDamage.new()
	var _a := d.add_part(&"bumper", &"bumper", Vector3(0, 0.4, -2.0), 4.0, 1.0, 30.0)
	var _b := d.add_part(&"tailgate", &"door", Vector3(0, 0.8, 2.0), 6.0, 1.0)
	var refused := d.add_part(&"bumper", &"bumper", Vector3.ZERO, 4.0)
	_check(not refused.ok, "a second part with the same id is refused")
	var _w0 := d.add_wheel(Vector3(-0.9, 0.0, -1.4), 7.0, 12.0)

	# A scrape is a hit under the floor: it wears a part (fatigue) but never takes it off.
	for i in 20:
		var _s := d.hit(Vector3(0, 0.4, -2.0), 1.0)
	var worn_health := (d.parts[&"bumper"] as GSVehicleDamage.Part).health
	_check(worn_health < 0.95 and worn_health > 0.5 and not (d.parts[&"bumper"] as GSVehicleDamage.Part).lost,
		"twenty scrapes below a part's floor wear it but do not take it off", "%.2f" % worn_health)
	d.repair()

	var first := d.hit(Vector3(0, 0.4, -2.0), 3.0)
	var second := d.hit(Vector3(0, 0.4, -2.0), 3.0)
	_check(first.is_empty() and second.size() == 1 and second[0]["id"] == &"bumper",
		"two 3 m/s knocks take off a 4 m/s bumper, the second one does",
		"%s then %s" % [first, second])
	_check(not (d.parts[&"tailgate"] as GSVehicleDamage.Part).lost and is_equal_approx((d.parts[&"tailgate"] as GSVehicleDamage.Part).health, 1.0),
		"and the tailgate four metres away felt none of it")
	_check(is_equal_approx(d.mass_lost(), 30.0), "the bumper's mass is the mass lost", "%.1f" % d.mass_lost())

	var wheel := d.hit_wheel(0, 13.0)
	_check(wheel.size() == 2 and wheel[0]["kind"] == "popped" and wheel[1]["kind"] == "lost",
		"one hit past the hub's strength bursts the tyre and takes the wheel, in that order", str(wheel))
	_check(d.grip_of(0) == d.hub_grip, "and the corner grips like a hub")

	var other := GSVehicleDamage.new()
	var _c := other.add_part(&"bumper", &"bumper", Vector3(0, 0.4, -2.0), 4.0)
	var _d := other.add_part(&"tailgate", &"door", Vector3(0, 0.8, 2.0), 6.0)
	var _w1 := other.add_wheel(Vector3(-0.9, 0.0, -1.4), 7.0, 12.0)
	var shown := other.apply_dict(d.to_dict())
	_check(shown.size() == 3 and other.lost_parts() == [&"bumper"] and other.wheel_state(0) == GSVehicleDamage.Wheel.LOST,
		"a mirror told the server's state shows the same losses as events", str(shown))
	_check(other.apply_dict(d.to_dict()).is_empty(), "and told it again shows nothing twice")

	d.repair()
	_check(d.lost_parts().is_empty() and d.wheel_state(0) == GSVehicleDamage.Wheel.INTACT and d.mass_lost() == 0.0,
		"a repair makes it whole")
	_done()


func _damaged_jeep(spawner: GSVehicleSpawner, at: Vector3, debris: GSVehicleDebris = null) -> Array:
	var jeep := spawner.spawn(&"jeep", at)
	var body := jeep.node as VehicleBody3D
	var bumper := MeshInstance3D.new()
	bumper.name = "Bumper"
	var shape := BoxMesh.new()
	shape.size = Vector3(1.8, 0.3, 0.2)
	bumper.mesh = shape
	body.add_child(bumper)
	bumper.position = Vector3(0, 0.4, -2.0)
	var damage := GSVehicleDamage.new()
	var _p := damage.add_part(&"bumper", &"bumper", Vector3(0, 0.4, -2.0), 4.0, 1.5, 100.0, NodePath("Bumper"))
	var _q := damage.add_part(&"tailgate", &"door", Vector3(0, 0.8, 2.0), 6.0, 1.0)
	var breakage := GSVehicleBreakage.new()
	breakage.debris = debris
	body.add_child(breakage)
	var _s := breakage.setup(body, damage, jeep.chassis as GSVehicleWheeled)
	return [jeep, breakage]


## The losses on a real body: what each does to the drive.
func _test_breakage() -> void:
	_section("damage: on a body")

	var spawner := _spawner()
	var ground := _wall(Vector3(2000, -0.5, -150), Vector3(60, 1, 400))
	var debris := GSVehicleDebris.new()
	_world.add_child(debris)

	# A burst tyre: smaller, less grip, and a change of road grip does not hand it back.
	var pair := _damaged_jeep(spawner, Vector3(1985, 1.0, 0), debris)
	var jeep: GSVehicleInstance = pair[0]
	var breakage: GSVehicleBreakage = pair[1]
	var chassis := jeep.chassis as GSVehicleWheeled
	var wheel := chassis.wheels()[0]
	var radius := wheel.wheel_radius
	var grip_before := wheel.wheel_friction_slip
	breakage._show(breakage.damage.pop(0), Vector3.ZERO, 0.0)
	chassis._apply_wheel_tunables()
	_check(wheel.wheel_radius < radius and absf(wheel.wheel_friction_slip - grip_before * breakage.damage.popped_grip) < 0.01,
		"a burst tyre rolls lower with less grip, and keeps it through a grip change",
		"radius %.2f -> %.2f, grip %.2f -> %.2f" % [radius, wheel.wheel_radius, grip_before, wheel.wheel_friction_slip])

	# The bumper: thrown as a copy, hidden on the body, and its mass taken off.
	var mass := (jeep.node as RigidBody3D).mass
	var events := breakage.hit(Vector3(0, 0.4, -2.0), 5.0)
	var node := breakage.part_node(&"bumper")
	_check(events.size() == 1 and not node.visible and debris.live_count() == 1,
		"a 5 m/s hit on the bumper takes it off: hidden on the body, a loose piece in the world",
		"%d events, visible %s, %d pieces" % [events.size(), node.visible, debris.live_count()])
	_check(absf((jeep.node as RigidBody3D).mass - (mass - 100.0)) < 0.01, "and its mass leaves the body",
		"%.0f -> %.0f kg" % [mass, (jeep.node as RigidBody3D).mass])
	var piece := debris.get_child(0) as RigidBody3D
	_check(piece != null and piece.linear_velocity.y > 0.0, "the piece is kicked away from what hit it")

	breakage.repair()
	_check(node.visible and is_equal_approx(wheel.wheel_radius, radius) and absf((jeep.node as RigidBody3D).mass - mass) < 0.01,
		"a repair shows the bumper, refits the tyre and gives the mass back")
	spawner.remove(jeep.instance_id)

	# A lost rear wheel drags: driven straight, the car pulls toward that side.
	var straight := await _drift(spawner, Vector3(1995, 1.0, 0), -1)
	var pulled := await _drift(spawner, Vector3(2005, 1.0, 0), 3)
	_check(pulled["yaw"] > straight["yaw"] + 3.0, "a lost rear-right wheel pulls the car to the right",
		"yaw %.1f against %.1f degrees" % [pulled["yaw"], straight["yaw"]])
	_check(pulled["dist"] < straight["dist"] * 0.95, "and drags it: less distance on the same throttle",
		"%.1f against %.1f m" % [pulled["dist"], straight["dist"]])
	_check(pulled["drop"] > 0.08, "and that corner sits lower, on its hub", "%.2f m" % pulled["drop"])
	_check(pulled["sparks"] > 10, "and it scrapes: sparks to show", "%d steps" % pulled["sparks"])

	await _hit_walls(spawner, debris)

	# A client's mirror: told the state, it shows the losses with the server's velocities.
	pair = _damaged_jeep(spawner, Vector3(2025, 1.0, 0), debris)
	jeep = pair[0]
	breakage = pair[1]
	breakage.simulate = false
	var shown := breakage.apply_state({"lost": ["bumper"], "wheels": [0, 2, 0, 0]}, {"bumper": Vector3(0, 3, -9)})
	var fast := debris.get_children().filter(func(c: Node) -> bool: return c is RigidBody3D and (c as RigidBody3D).linear_velocity.z < -8.0)
	_check(shown.size() == 3 and not breakage.part_node(&"bumper").visible and fast.size() == 1,
		"a mirror shows what the server lost, thrown at the server's velocity", str(shown.size()))

	# The budget: never more than it allows, the oldest going first.
	debris.budget = 2
	for i in 3:
		var _x := debris.spawn_box(Transform3D(Basis(), Vector3(2030, 2.0 + i, 0)), Vector3.ONE * 0.4, null, Vector3.ZERO)
	_check(debris.live_count() == 2, "the debris keeps to its budget", "%d live" % debris.live_count())

	_check_carving()

	debris.queue_free()
	spawner.queue_free()
	ground.queue_free()
	await get_tree().physics_frame
	_done()


## Two walls: one driven into, one struck hard in a single step; the front comes off, not the back.
func _hit_walls(spawner: GSVehicleSpawner, debris: GSVehicleDebris) -> void:
	# A wall at speed: the contact is felt, and the front comes off, not the back.
	var pair := _damaged_jeep(spawner, Vector3(2015, 1.0, 0), debris)
	var jeep: GSVehicleInstance = pair[0]
	var breakage: GSVehicleBreakage = pair[1]
	var wall := _wall(Vector3(2015, 1.0, -40.0), Vector3(8, 3, 1))
	var guard := 600
	while guard > 0 and not breakage.damage.lost_parts().has(&"bumper"):
		jeep.chassis.drive(GSVehicleCommand.make(1.0), 1.0 / 60.0)
		await get_tree().physics_frame
		guard -= 1
	_check(breakage.damage.lost_parts() == [&"bumper"], "driven into a wall, the contact takes the bumper off and leaves the tailgate",
		"hit %.1f m/s at %s, lost %s" % [breakage.last_hit, breakage.last_hit_at, breakage.damage.lost_parts()])
	spawner.remove(jeep.instance_id)
	wall.queue_free()

	# A hard stop in one step (Jolt reports no impulse for it): the nose is where it hit.
	pair = _damaged_jeep(spawner, Vector3(2015, 1.0, 0), debris)
	jeep = pair[0]
	breakage = pair[1]
	wall = _wall(Vector3(2015, 1.0, -30.0), Vector3(8, 3, 1))
	var thrown_before := debris.live_count()
	(jeep.node as RigidBody3D).continuous_cd = true
	(jeep.node as RigidBody3D).mass = 6000.0
	(jeep.node as RigidBody3D).linear_velocity = Vector3(0, 0, -26.0)
	guard = 240
	while guard > 0 and breakage.last_hit < 8.0:
		await get_tree().physics_frame
		guard -= 1
	_check(breakage.last_hit >= 10.0 and breakage.last_hit_at.z < -0.5, "a 26 m/s strike is felt in full, at the nose and not the tail",
		"%.1f m/s at %s" % [breakage.last_hit, breakage.last_hit_at])
	_check(breakage.damage.lost_parts().has(&"bumper") and not breakage.damage.lost_parts().has(&"tailgate") and debris.live_count() > thrown_before,
		"and it sheds the front part as loose debris", "lost %s, %d pieces" % [breakage.damage.lost_parts(), debris.live_count()])
	spawner.remove(jeep.instance_id)
	wall.queue_free()


## Carving: a part of a one-piece mesh made a node of its own.
func _check_carving() -> void:
	var whole := MeshInstance3D.new()
	var box := BoxMesh.new()
	whole.mesh = box
	_world.add_child(whole)
	var tris := (whole.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	var cut := GSVehicleDebris.carve(whole, AABB(Vector3(-1, -1, 0.4), Vector3(2, 2, 1)))
	var left := (whole.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
	_check(cut != null and left < tris and left + (cut.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() == tris,
		"carving moves the triangles in a region to a node of their own, and no others", "%d -> %d" % [tris, left])
	_check(GSVehicleDebris.carve(whole, AABB(Vector3(5, 5, 5), Vector3.ONE)) == null, "and a region with nothing in it carves nothing")

	whole.queue_free()


## Tyre wear, fatigue, and a wreck: a crash that tears a vehicle apart and ends in an explosion.
func _test_wreck() -> void:
	_section("wear and wreck")

	var d := GSVehicleDamage.new()
	var _a := d.add_part(&"bumper", &"bumper", Vector3(0, 0.4, -2.0), 4.0, 1.0, 30.0)
	var _w := d.add_wheel(Vector3(-0.9, 0.0, -1.4), 7.0, 12.0)
	var grip_new := d.grip_of(0)
	var worn_events := 0
	for i in 25:
		for e in d.hit_wheel(0, 2.0):
			worn_events += 1 if e["kind"] == "worn" else 0
	_check(d.wear_of(0) > 0.1 and d.grip_of(0) < grip_new and d.wheel_state(0) == GSVehicleDamage.Wheel.INTACT,
		"small knocks wear a tyre: less grip, still not burst", "wear %.2f grip %.2f" % [d.wear_of(0), d.grip_of(0)])
	_check(worn_events > 0, "and each quarter of wear is an event, so the drive can follow", str(worn_events))
	var other := GSVehicleDamage.new()
	var _b := other.add_part(&"bumper", &"bumper", Vector3(0, 0.4, -2.0), 4.0, 1.0, 30.0)
	var _x := other.add_wheel(Vector3(-0.9, 0.0, -1.4), 7.0, 12.0)
	var _shown := other.apply_dict(d.to_dict())
	_check(absf(other.wear_of(0) - d.wear_of(0)) < 0.02, "wear crosses the wire to a mirror")
	var before := d.distress()
	var _l := d.lose_part(&"bumper")
	_check(d.distress() > before and d.distress() <= 1.0, "distress rises with what is lost", "%.2f -> %.2f" % [before, d.distress()])

	var spawner := _spawner()
	var ground := _wall(Vector3(2100, -0.5, 0), Vector3(80, 1, 80))
	var pair := _damaged_jeep(spawner, Vector3(2100, 6.0, 0))
	var jeep: GSVehicleInstance = pair[0]
	var breakage: GSVehicleBreakage = pair[1]
	var wreck := GSVehicleWreck.new()
	wreck.draws = false
	wreck.fuse = 3.0
	(jeep.node as Node).add_child(wreck)
	var set_up := wreck.setup(jeep.node as RigidBody3D, breakage)
	var blasts := [0]
	wreck.exploded.connect(func(_at: Vector3, _v: Vector3) -> void: blasts[0] += 1)
	(jeep.node as RigidBody3D).linear_velocity = Vector3(0, 0, -14)
	wreck.crash()
	var guard := 400
	while guard > 0 and wreck.phase != GSVehicleWreck.Phase.BURNING:
		await get_tree().physics_frame
		guard -= 1
	_check(set_up.ok and blasts[0] == 1 and wreck.is_wrecked(), "a crashed vehicle ends in one explosion", "%d blasts, %d frames left" % [blasts[0], guard])
	_check(breakage.damage.lost_parts().size() == breakage.damage.parts.size(), "and everything is off it by then", str(breakage.damage.lost_parts()))
	var all_lost := true
	for i in breakage.damage.wheels.size():
		all_lost = all_lost and breakage.damage.wheel_state(i) == GSVehicleDamage.Wheel.LOST
	_check(all_lost, "wheels included")
	wreck.reset()
	breakage.repair()
	_check(not wreck.is_wrecked() and breakage.hit_scale == 1.0, "a reset makes it whole again")

	var boom := GSVehicleExplosion.spawn(_world, Vector3(2100, 2, 0), 1.0)
	_check(boom != null and boom.get_child_count() >= 4, "an explosion is a fireball, smoke, sparks and a flash")
	boom.queue_free()

	spawner.remove(jeep.instance_id)
	spawner.queue_free()
	ground.queue_free()
	await get_tree().physics_frame
	_done()


## Drives straight for two seconds with wheel [param lose] gone (-1 for none): yaw (+ right), distance, how far that corner sank, steps with sparks.
func _drift(spawner: GSVehicleSpawner, at: Vector3, lose: int) -> Dictionary:
	var pair := _damaged_jeep(spawner, at)
	var jeep: GSVehicleInstance = pair[0]
	var breakage: GSVehicleBreakage = pair[1]
	var body := jeep.node as VehicleBody3D
	var sparks := [0]
	breakage.scraping.connect(func(_w: int, _at: Vector3, _s: float) -> void: sparks[0] += 1)

	for i in 30:
		jeep.chassis.drive(GSVehicleCommand.make(0.0, 0.0, 1.0), 1.0 / 60.0)
		await get_tree().physics_frame

	var heading := -body.global_basis.z
	var start := body.global_position
	var drop := 0.0

	if lose >= 0:
		breakage._show(breakage.damage.lose_wheel(lose), Vector3.ZERO, 0.0)

	# Three seconds at full throttle: the fixture is slow off the line, and under 2 m/s a hub
	# makes no sparks.
	for i in 180:
		jeep.chassis.drive(GSVehicleCommand.make(1.0), 1.0 / 60.0)
		await get_tree().physics_frame

	var yaw := rad_to_deg(heading.signed_angle_to(-body.global_basis.z, Vector3.DOWN))
	var dist := body.global_position.distance_to(start)
	if lose >= 0:
		drop = _corner_drop(body, chassis_wheel(jeep, lose))
	spawner.remove(jeep.instance_id)
	await get_tree().physics_frame
	return {"yaw": yaw, "dist": dist, "drop": drop, "sparks": sparks[0]}


func chassis_wheel(jeep: GSVehicleInstance, i: int) -> VehicleWheel3D:
	return (jeep.chassis as GSVehicleWheeled).wheels()[i]


## How much lower [param wheel]'s hardpoint sits than the other corners' average, metres. Against
## the other corners rather than the ride before: the body is still settling off its drop then.
func _corner_drop(body: VehicleBody3D, wheel: VehicleWheel3D) -> float:
	var others := 0.0
	var n := 0
	for w in (body.get_children()):
		if w is VehicleWheel3D and w != wheel:
			others += body.to_global(w.position).y - w.position.y
			n += 1
	return others / maxf(n, 1) - (body.to_global(wheel.position).y - wheel.position.y)
