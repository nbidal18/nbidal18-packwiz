package dev.nbidal18.packcompat.autohud.mixin;

import dev.nbidal18.packcompat.autohud.AutoHudRenderGate;
import immersive_aircraft.client.OverlayRenderer;
import immersive_aircraft.entity.EngineVehicle;
import immersive_aircraft.entity.VehicleEntity;
import mod.crend.autohud.render.ComponentRenderer;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphics;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(value = OverlayRenderer.class, remap = false)
abstract class ImmersiveAircraftOverlayMixin {
    @Unique private boolean nbidal18$engineGauge;
    @Unique private boolean nbidal18$aircraftHealth;
    @Unique private boolean nbidal18$flightHud;
    @Unique private boolean nbidal18$dials;

    @Inject(method = "renderAircraftGui", at = @At("HEAD"), cancellable = true, remap = false)
    private void nbidal18$beginEngineGauge(
            Minecraft client, GuiGraphics graphics, float tickDelta, EngineVehicle aircraft, CallbackInfo ci
    ) {
        nbidal18$engineGauge = AutoHudRenderGate.begin(ComponentRenderer.EXPERIENCE_LEVEL, graphics, ci);
    }

    @Inject(method = "renderAircraftGui", at = @At("RETURN"), remap = false)
    private void nbidal18$endEngineGauge(
            Minecraft client, GuiGraphics graphics, float tickDelta, EngineVehicle aircraft, CallbackInfo ci
    ) {
        AutoHudRenderGate.end(ComponentRenderer.EXPERIENCE_LEVEL, graphics, nbidal18$engineGauge);
        nbidal18$engineGauge = false;
    }

    @Inject(method = "renderAircraftHealth", at = @At("HEAD"), cancellable = true, remap = false)
    private void nbidal18$beginAircraftHealth(
            Minecraft client, GuiGraphics graphics, VehicleEntity vehicle, int offset, CallbackInfo ci
    ) {
        nbidal18$aircraftHealth = AutoHudRenderGate.begin(ComponentRenderer.HEALTH, graphics, ci);
    }

    @Inject(method = "renderAircraftHealth", at = @At("RETURN"), remap = false)
    private void nbidal18$endAircraftHealth(
            Minecraft client, GuiGraphics graphics, VehicleEntity vehicle, int offset, CallbackInfo ci
    ) {
        AutoHudRenderGate.end(ComponentRenderer.HEALTH, graphics, nbidal18$aircraftHealth);
        nbidal18$aircraftHealth = false;
    }

    @Inject(method = "renderAircraftHUD", at = @At("HEAD"), cancellable = true, remap = false)
    private void nbidal18$beginFlightHud(
            Minecraft client, GuiGraphics graphics, float tickDelta, int offset,
            EngineVehicle aircraft, CallbackInfo ci
    ) {
        nbidal18$flightHud = AutoHudRenderGate.begin(ComponentRenderer.HOTBAR, graphics, ci);
    }

    @Inject(method = "renderAircraftHUD", at = @At("RETURN"), remap = false)
    private void nbidal18$endFlightHud(
            Minecraft client, GuiGraphics graphics, float tickDelta, int offset,
            EngineVehicle aircraft, CallbackInfo ci
    ) {
        AutoHudRenderGate.end(ComponentRenderer.HOTBAR, graphics, nbidal18$flightHud);
        nbidal18$flightHud = false;
    }

    @Inject(method = "renderAircraftDials", at = @At("HEAD"), cancellable = true, remap = false)
    private void nbidal18$beginDials(
            Minecraft client, GuiGraphics graphics, float tickDelta, int offset,
            EngineVehicle aircraft, CallbackInfo ci
    ) {
        nbidal18$dials = AutoHudRenderGate.begin(ComponentRenderer.HOTBAR, graphics, ci);
    }

    @Inject(method = "renderAircraftDials", at = @At("RETURN"), remap = false)
    private void nbidal18$endDials(
            Minecraft client, GuiGraphics graphics, float tickDelta, int offset,
            EngineVehicle aircraft, CallbackInfo ci
    ) {
        AutoHudRenderGate.end(ComponentRenderer.HOTBAR, graphics, nbidal18$dials);
        nbidal18$dials = false;
    }
}
