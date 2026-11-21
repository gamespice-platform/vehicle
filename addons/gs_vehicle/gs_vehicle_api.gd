extends RefCounted

## GameSpice Vehicle's API level. The rule for bumping it is on [GSAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: the baseline (2026-09-26): GSVehicleDef, GSVehicleCatalogue, GSVehicleSeat,
#    GSVehicleTunables, GSVehicleCommand, GSVehicleInstance, GSVehicleSpawner,
#    GSVehicleRide, GSVehicleChassis, GSVehicleWheeled, GSVehicleHover, GSVehicleDriver,
#    GSVehicleNetSync.
# 2: brakes are forces (brake_force and handbrake_force are newtons times the physics step on
#    each wheel; before, Godot read them as an impulse per step); GSVehicleTunables.linear_damp,
#    written onto the body in REPLACE mode; GSVehicleWheeled.step_seconds();
#    GSVehicleCommand.brake_then_reverse() and STOPPED_BELOW (one key to brake and reverse,
#    opt-in); GSVehicleTunables.handbrake_grip_fraction (1.0, no change, by default). OLDEST
#    stays 1: a pack built before compiles and runs, with brakes that now mean their figures.
# 3: what comes off: GSVehicleDamage (parts and wheels as data, to_dict/apply_dict for the
#    wire), GSVehicleBreakage (feels contact and landing hits, burst tyres and lost wheels
#    that drag and pull, mass taken off with a load), GSVehicleDebris (budgeted loose pieces,
#    carve() for a one-piece model), GSVehicleBreakage.harm_gate; GSVehicleWheeled.wheels(), set_wheel_grip(), wheel_grip().
const LEVEL := 3
const OLDEST := 1
