package dev.nbidal18.packcompat.autohud.mixin;

import artifacts.client.CooldownOverlayRenderer;
import dev.nbidal18.packcompat.autohud.AutoHudRenderGate;
import mod.crend.autohud.render.ComponentRenderer;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.gui.GuiGraphics;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(value = CooldownOverlayRenderer.class, remap = false)
abstract class ArtifactsCooldownOverlayMixin {
    @Unique private static boolean nbidal18$cooldownOverlay;

    @Inject(method = "render", at = @At("HEAD"), cancellable = true, remap = false)
    private static void nbidal18$beginCooldownOverlay(
            GuiGraphics graphics, DeltaTracker deltaTracker, CallbackInfo ci
    ) {
        nbidal18$cooldownOverlay = AutoHudRenderGate.begin(ComponentRenderer.HOTBAR, graphics, ci);
    }

    @Inject(method = "render", at = @At("RETURN"), remap = false)
    private static void nbidal18$endCooldownOverlay(
            GuiGraphics graphics, DeltaTracker deltaTracker, CallbackInfo ci
    ) {
        AutoHudRenderGate.end(ComponentRenderer.HOTBAR, graphics, nbidal18$cooldownOverlay);
        nbidal18$cooldownOverlay = false;
    }
}
