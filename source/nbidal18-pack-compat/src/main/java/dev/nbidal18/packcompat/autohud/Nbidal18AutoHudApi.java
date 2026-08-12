package dev.nbidal18.packcompat.autohud;

import com.github.thedeathlycow.thermoo.api.temperature.TemperatureAware;
import immersive_aircraft.entity.EngineVehicle;
import immersive_aircraft.entity.VehicleEntity;
import mod.crend.autohud.api.AutoHudApi;
import mod.crend.autohud.component.Components;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.world.entity.Entity;

public final class Nbidal18AutoHudApi implements AutoHudApi {
    private final AircraftHudState aircraft = new AircraftHudState();

    @Override
    public String modId() {
        return "nbidal18_pack_compat";
    }

    @Override
    public void tickState(LocalPlayer player) {
        revealTemperature(player);
        revealAircraftChanges(player.getVehicle());
    }

    private static void revealTemperature(LocalPlayer player) {
        TemperatureAware temperature = (TemperatureAware) player;
        int visibleTemperatureHearts = Math.round(
                Math.abs(temperature.thermoo$getTemperatureScale()) * player.getMaxHealth()
        );
        if (visibleTemperatureHearts > 0) {
            Components.Health.revealCombined();
        }
    }

    private void revealAircraftChanges(Entity vehicle) {
        Object identity = vehicle == null ? null : vehicle.getUUID();
        float health = vehicle instanceof VehicleEntity aircraftVehicle
                ? aircraftVehicle.getHealth()
                : Float.NaN;
        float engineTarget = vehicle instanceof EngineVehicle engineVehicle
                ? engineVehicle.getEngineTarget()
                : Float.NaN;
        AircraftHudState.Change change = aircraft.observe(identity, health, engineTarget);
        switch (change) {
            case MOUNTED, HEALTH_AND_ENGINE -> {
                Components.Health.revealCombined();
                Components.ExperienceLevel.revealCombined();
            }
            case HEALTH -> Components.Health.revealCombined();
            case ENGINE -> Components.ExperienceLevel.revealCombined();
            case NONE -> {
            }
        }
    }
}
