extends Node

## The counters, the check and the builders behind vehicle_selftest: a jeep, the catalogue, a spawner, a rider, a wall.

const CAR := "res://fixtures/car.tscn"
const SKIFF := "res://fixtures/skiff.tscn"
const RIDER := "res://fixtures/rider.tscn"
const CRATE := "res://fixtures/crate.tscn"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _world: Node3D = null


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


func _jeep() -> GSVehicleDef:
	var def := GSVehicleDef.make(&"jeep", CAR)
	def.category = &"car"
	def.cost = 4

	var driver := GSVehicleSeat.make(&"driver", true)
	driver.seat_offset = Vector3(-0.4, 0.9, -0.4)

	var passenger := GSVehicleSeat.make(&"passenger")
	passenger.seat_offset = Vector3(0.4, 0.9, -0.4)

	def.seats = [driver, passenger]

	var tuning := GSVehicleTunables.new()
	tuning.mass = 800.0
	tuning.max_exit_speed = 4.0
	def.tunables = tuning

	return def


func _catalogue() -> GSVehicleCatalogue:
	var cat := GSVehicleCatalogue.new()
	cat.add(_jeep())

	var skiff := GSVehicleDef.make(&"skiff", SKIFF)
	skiff.kind = GSVehicleDef.Kind.HOVER
	skiff.category = &"boat"
	skiff.seats = [GSVehicleSeat.make(&"driver", true)]
	cat.add(skiff)

	var scripted := GSVehicleDef.make(&"scripted", SKIFF)
	scripted.chassis_script_path = "res://fixtures/reverse_chassis.gd"
	scripted.seats = [GSVehicleSeat.make(&"driver", true)]
	cat.add(scripted)

	var broken := GSVehicleDef.make(&"broken", SKIFF)
	broken.chassis_script_path = "res://fixtures/not_a_chassis.gd"
	broken.seats = [GSVehicleSeat.make(&"driver", true)]
	cat.add(broken)

	var wreckable := GSVehicleDef.make(&"wreckable", SKIFF)
	wreckable.kind = GSVehicleDef.Kind.CUSTOM
	wreckable.max_health = 200.0
	wreckable.seats = [
		GSVehicleSeat.make(&"driver", true), GSVehicleSeat.make(&"passenger")
	]
	cat.add(wreckable)

	return cat


func _spawner(budget: int = 0) -> GSVehicleSpawner:
	var spawner := GSVehicleSpawner.new()
	spawner.catalogue = _catalogue()
	spawner.authoritative = true
	spawner.world_budget = budget
	spawner.per_player_budget = 0
	spawner.spawn_interval = 0.0
	_world.add_child(spawner)
	return spawner


func _rider() -> CharacterBody3D:
	var scene: PackedScene = load(RIDER)
	var node := scene.instantiate() as CharacterBody3D
	_world.add_child(node)
	return node


## A static box in the world, for the exit sweep to be blocked by.
func _wall(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_world.add_child(body)
	body.global_position = at
	return body
