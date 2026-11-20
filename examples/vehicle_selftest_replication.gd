extends "res://examples/vehicle_selftest_handover.gd"

## Replication, the damage and wreck sections and the physics-query audits, run from vehicle_selftest.


# --- Replication --------------------------------------------------------------

func _test_net_sync() -> void:
	_section("replication")

	var specs := DotVehicleNetSync.specs()
	_check(specs.size() == 8, "there is a spec for what crosses the wire",
		"%d" % specs.size())

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(3, 1, -4))
	spawner.ride.enter(jeep, &"alice", _rider())

	var probe := _NetProbe.new()

	# Rolled over onto its side: the case a yaw-only wire format cannot carry, and the
	# reason this one sends a whole quaternion.
	var rolled := Basis(Vector3.FORWARD, deg_to_rad(70.0))
	jeep.node.global_transform = Transform3D(rolled, Vector3(3, 1, -4))

	DotVehicleNetSync.pull(jeep, probe)

	_check(probe.net_x == 3.0 and probe.net_z == -4.0, "a pull copies the position")
	_check(probe.net_health == 100, "and an indestructible vehicle reads as full health",
		"a client cannot tell 'no health' from 'not destructible'")

	var node := Node3D.new()
	_world.add_child(node)
	DotVehicleNetSync.apply(node, probe)

	var received := node.global_transform.basis.get_rotation_quaternion()
	var sent := rolled.get_rotation_quaternion()

	_check(
		received.angle_to(sent) < deg_to_rad(1.0),
		"and the whole orientation survives the wire",
		"%.2f deg out" % rad_to_deg(received.angle_to(sent))
	)
	_check(
		absf(node.global_transform.basis.get_scale().x - 1.0) < 0.01,
		"without the vehicle changing size",
		"four independently quantised components do not make a unit quaternion"
	)

	_check(
		DotVehicleNetSync.is_seat_occupied(probe.net_occupancy, 0),
		"the driver's seat reads as occupied"
	)
	_check(
		not DotVehicleNetSync.is_seat_occupied(probe.net_occupancy, 1),
		"and the empty one does not"
	)

	for degrees in [-30.0, 0.0, 12.5, 32.0]:
		var back := DotVehicleNetSync.dequantise_steering(
			DotVehicleNetSync.quantise_steering(deg_to_rad(degrees))
		)
		_check(
			absf(rad_to_deg(back) - degrees) < 1.0,
			"steering survives quantisation at %.1f degrees" % degrees,
			"%.2f deg out" % absf(rad_to_deg(back) - degrees)
		)

	node.queue_free()
	spawner.queue_free()
	_done()


## The receiving half of a replication, without GameSpice Net in the project.
class _NetProbe:
	extends RefCounted

	var net_x: float = 0.0
	var net_y: float = 0.0
	var net_z: float = 0.0
	var net_orientation: Quaternion = Quaternion.IDENTITY
	var net_speed: int = 0
	var net_steering: int = 0
	var net_health: int = 0
	var net_occupancy: int = 0


# --- Damage -------------------------------------------------------------------


## An engine error is the only symptom: the sweep and the eject carry on without the dead
## rider, so a value assertion alone passes on the unguarded code.
class ErrorCatcher extends Logger:
	var errors: Array[String] = []

	func _log_error(function: String, _file: String, _line: int, code: String,
			rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtraces: Array) -> void:
		errors.append("%s %s %s" % [code, rationale, function])


func _test_rider_freed_aboard() -> void:
	_section("a rider freed while seated")

	var spawner := _spawner()
	var jeep := spawner.spawn(&"jeep", Vector3(0, 1, 0))
	var alice := _rider()
	spawner.ride.enter(jeep, &"alice", alice)
	spawner.ride.enter(jeep, &"bob", _rider())

	alice.free()
	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var got_out := spawner.ride.exit(jeep, &"bob", true)
	spawner.ride.exit(jeep, &"alice", true)
	OS.remove_logger(catcher)

	_check(got_out.ok, "the other rider still gets out")
	_check(not spawner.ride.is_riding(&"bob"), "and is no longer riding")
	_check(not spawner.ride.is_riding(&"alice"), "the dead rider's seat is released")
	_check(catcher.errors.is_empty(), "and none of that raised an engine error", str(catcher.errors))

	spawner.queue_free()
	_done()


## Every file that asks the physics space a question. A new one fails here until it is added and
## listed in GameSpice Physics docs/threading.md, because with physics on its own thread each caller
## must run inside the physics step.
const QUERY_FILES: Array[String] = ["runtime/dot_vehicle_hover.gd", "runtime/dot_vehicle_ride.gd"]
const QUERY_NEEDLES: Array[String] = ["direct_space_state", "space.intersect_", "space.cast_motion(", "space.get_rest_info("]
const TICK_ENTRY_NEEDLES: Array[String] = ["func _process(", "func _input(", "func _unhandled_input(", "call_deferred(", "await "]


func _audit_scripts(dir: String, out: Array[String]) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_audit_scripts(dir.path_join(d), out)


func _test_deferred_queries() -> void:
	_section("space queries wait for the physics step")

	var spawner := _spawner()
	_wall(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	var jeep := spawner.spawn(&"jeep", Vector3(0, 0.5, 0))
	var rider := _rider()
	spawner.ride.enter(jeep, &"alice", rider)
	await get_tree().physics_frame

	var cmd := DotVehicleCommand.make(0.0)
	cmd.exit_requested = true
	var reply := spawner.set_command(jeep.instance_id, &"alice", cmd)
	_check(reply.ok, "an exit request is accepted between ticks")
	_check(spawner.ride.is_riding(&"alice") and spawner.pending_count() == 1,
		"but nobody has moved and the sweep has not run")
	spawner.tick(1.0 / 60.0)
	_check(not spawner.ride.is_riding(&"alice") and spawner.pending_count() == 0,
		"the next tick puts them down")

	var refusals: Array[String] = []
	spawner.ride.refused.connect(func(_r: StringName, _v: StringName, why: String) -> void:
		refusals.append(why))
	var boxed := spawner.spawn(&"jeep", Vector3(50, 0.5, 0))
	var boxed_rider := _rider()
	spawner.ride.enter(boxed, &"bob", boxed_rider)
	await get_tree().physics_frame
	var _roof := _wall(Vector3(50, 1.0, 0), Vector3(14, 3, 14))
	await get_tree().physics_frame
	var blocked := DotVehicleCommand.make(0.0)
	blocked.exit_requested = true
	spawner.set_command(boxed.instance_id, &"bob", blocked)
	_check(refusals.is_empty(), "a refusal is not reported before the tick")
	spawner.tick(1.0 / 60.0)
	_check(spawner.ride.is_riding(&"bob") and refusals.size() == 1,
		"the tick reports the refusal through the same signal")

	var second := spawner.spawn(&"jeep", Vector3(-50, 0.5, 0))
	spawner.ride.enter(second, &"carol", _rider())
	_check(spawner.remove(second.instance_id), "removing an occupied vehicle is accepted")
	_check(second.is_alive() and spawner.pending_count() == 1, "and waits for the tick")
	spawner.tick(1.0 / 60.0)
	_check(not second.is_alive() and not spawner.ride.is_riding(&"carol"),
		"the tick evacuates and removes it")

	var empty := spawner.spawn(&"jeep", Vector3(-80, 0.5, 0))
	_check(spawner.remove(empty.instance_id) and not empty.is_alive() and spawner.pending_count() == 0,
		"an empty vehicle needs no sweep, so it goes at once")

	spawner.queue_free()
	_done()


func _test_space_query_audit() -> void:
	_section("space-query audit")
	var scripts: Array[String] = []
	_audit_scripts("res://addons/dot_vehicle", scripts)
	var found: Array[String] = []
	var in_tick_entry: Array[String] = []

	for path in scripts:
		var text := FileAccess.get_file_as_string(path)
		var queries := false
		for n in QUERY_NEEDLES:
			if text.contains(n):
				queries = true
		if not queries:
			continue
		var rel := path.trim_prefix("res://addons/dot_vehicle/")
		found.append(rel)
		for n in TICK_ENTRY_NEEDLES:
			if text.contains(n):
				in_tick_entry.append("%s: %s" % [rel, n])

	found.sort()
	var expected := QUERY_FILES.duplicate()
	expected.sort()
	_check(scripts.size() > 5, "the audit found the addon's scripts")
	_check(found == expected, "the files that query the space are exactly the documented ones", str(found))
	_check(in_tick_entry.is_empty(), "no querying file has a frame, input, deferred or awaited entry point", str(in_tick_entry))
	_check(FileAccess.get_file_as_string("res://addons/dot_vehicle/runtime/dot_vehicle_spawner.gd").contains("func _process(") == false, "the spawner that drives and exits vehicles has no frame callback")
	_done()
