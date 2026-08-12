package dev.nbidal18.packcompat.autohud.mixin;

import immersive_machinery.client.OverlayRenderer;
import immersive_machinery.entity.MachineEntity;
import mod.crend.autohud.render.ComponentRenderer;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphics;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(value = OverlayRenderer.class, remap = false)
abstract class ImmersiveMachineryOverlayMixin {
    @Unique private boolean nbidal18$machineryHud;

    @Inject(method = "renderMachineryGui", at = @At("HEAD"), cancellable = true, remap = false)
    private void nbidal18$beginMachineryHud(
            Minecraft client, GuiGraphics graphics, float tickDelta, MachineEntity machinery, CallbackInfo ci
    ) {
        nbidal18$machineryHud = AutoHudRenderGate.begin(ComponentRenderer.HOTBAR, graphics, ci);
    }

    @Inject(method = "renderMachineryGui", at = @At("RETURN"), remap = false)
    private void nbidal18$endMachineryHud(
            Minecraft client, GuiGraphics graphics, float tickDelta, MachineEntity machinery, CallbackInfo ci
    ) {
        AutoHudRenderGate.end(ComponentRenderer.HOTBAR, graphics, nbidal18$machineryHud);
        nbidal18$machineryHud = false;
    }
}
