package dev.nbidal18.packcompat.autohud;

import java.util.Objects;

final class AircraftHudState {
    private Object vehicleIdentity;
    private float health = Float.NaN;
    private float engineTarget = Float.NaN;

    Change observe(Object nextVehicleIdentity, float nextHealth, float nextEngineTarget) {
        if (!Objects.equals(vehicleIdentity, nextVehicleIdentity)) {
            vehicleIdentity = nextVehicleIdentity;
            health = nextHealth;
            engineTarget = nextEngineTarget;
            return nextVehicleIdentity == null ? Change.NONE : Change.MOUNTED;
        }
        if (nextVehicleIdentity == null) {
            return Change.NONE;
        }
        boolean healthChanged = Float.compare(health, nextHealth) != 0;
        boolean engineTargetChanged = Float.compare(engineTarget, nextEngineTarget) != 0;
        health = nextHealth;
        engineTarget = nextEngineTarget;
        if (healthChanged && engineTargetChanged) {
            return Change.HEALTH_AND_ENGINE;
        }
        if (healthChanged) {
            return Change.HEALTH;
        }
        if (engineTargetChanged) {
            return Change.ENGINE;
        }
        return Change.NONE;
    }

    enum Change {
        NONE,
        MOUNTED,
        HEALTH,
        ENGINE,
        HEALTH_AND_ENGINE
    }
}
