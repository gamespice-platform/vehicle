@tool
extends Node

## The lookup half of [DotVehicleSpawner]: which vehicles exist, whose they are, and what they cost.
## The spawner extends this; use the spawner.

## Getting in and getting out. Built here so a game has one to wire callbacks onto.
var ride: DotVehicleRide = null

## Instance id -> DotVehicleInstance.
var _vehicles: Dictionary = {}

## Owner id -> Array[int] of instance ids.
var _by_owner: Dictionary = {}

## Simulated seconds. Advanced by [method tick], never a wall clock.
var _now: float = 0.0


func get_vehicle(instance_id: int) -> DotVehicleInstance:
	var found: Variant = _vehicles.get(instance_id)
	return found if found is DotVehicleInstance else null


## The vehicle a node belongs to, or null. For a shot, or a "press use" trace.
func vehicle_for_node(node: Node) -> DotVehicleInstance:
	if node == null:
		return null

	# Walks up, because a query hits a collider that may be a child of the vehicle's
	# root — a wheel, a door, a turret.
	var walk := node

	while walk != null:
		var found: Variant = _vehicles.get(walk.get_instance_id())

		if found is DotVehicleInstance:
			return found

		walk = walk.get_parent()

	return null


## What [param rider_id] is riding in, or null.
func vehicle_of_rider(rider_id: StringName) -> DotVehicleInstance:
	return get_vehicle(ride.vehicle_id_of(rider_id))


## The nearest vehicle to [param point] with a free seat, within [param radius]: what a "press use to get in" prompt asks.
## Nearest rather than first, because a player standing between two cars means the one they are looking at,
## and nearest is the cheapest approximation of that which does not need their camera.
func nearest_free(point: Vector3, radius: float) -> DotVehicleInstance:
	var best: DotVehicleInstance = null
	var best_sq := radius * radius

	for id in _vehicles:
		var vehicle: DotVehicleInstance = _vehicles[id]

		if not vehicle.is_alive() or vehicle.is_full():
			continue

		var d_sq := vehicle.position().distance_squared_to(point)

		if d_sq <= best_sq:
			best_sq = d_sq
			best = vehicle

	return best


func world_count() -> int:
	return _vehicles.size()


func world_cost() -> int:
	var total := 0

	for id in _vehicles:
		total += (_vehicles[id] as DotVehicleInstance).def.cost

	return total


func owner_cost(owner_id: StringName) -> int:
	var found: Variant = _by_owner.get(owner_id)

	if not (found is Array):
		return 0

	var total := 0

	for id in (found as Array):
		var vehicle: Variant = _vehicles.get(int(id))

		if vehicle is DotVehicleInstance:
			total += (vehicle as DotVehicleInstance).def.cost

	return total


## Every live vehicle. A copy, because callers walk it to decide what to remove.
func all_vehicles() -> Array[DotVehicleInstance]:
	var out: Array[DotVehicleInstance] = []

	for id in _vehicles:
		var vehicle: DotVehicleInstance = _vehicles[id]

		if vehicle.is_alive():
			out.append(vehicle)

	return out


func vehicles_of(owner_id: StringName) -> Array[DotVehicleInstance]:
	var out: Array[DotVehicleInstance] = []
	var found: Variant = _by_owner.get(owner_id, [])

	if not (found is Array):
		return out

	for id in (found as Array):
		var vehicle: Variant = _vehicles.get(int(id))

		if vehicle is DotVehicleInstance:
			out.append(vehicle)

	return out


func now() -> float:
	return _now
