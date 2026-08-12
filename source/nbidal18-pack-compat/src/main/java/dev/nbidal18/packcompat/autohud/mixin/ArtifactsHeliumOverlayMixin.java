package dev.nbidal18.packcompat.autohud.mixin;

import artifacts.client.HeliumFlamingoOverlay;
import dev.nbidal18.packcompat.autohud.AutoHudRenderGate;
import mod.crend.autohud.render.ComponentRenderer;
import net.minecraft.client.gui.GuiGraphics;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(value = HeliumFlamingoOverlay.class, remap = false)
abstract class ArtifactsHeliumOverlayMixin {
    @Unique private static boolean nbidal18$heliumOverlay;

    @Inject(method = "renderOverlay", at = @At("HEAD"), cancellable = true, remap = false)
    private static void nbidal18$beginHeliumOverlay(
            int height, GuiGraphics graphics, int screenWidth, int screenHeight,
            CallbackInfoReturnable<Boolean> cir
    ) {
        if (!ComponentRenderer.HOTBAR.isActive()) {
            return;
        }
        if (!ComponentRenderer.HOTBAR.doRender()) {
            cir.setReturnValue(false);
            return;
        }
        ComponentRenderer.HOTBAR.beginRender(graphics);
        nbidal18$heliumOverlay = true;
    }

    @Inject(method = "renderOverlay", at = @At("RETURN"), remap = false)
    private static void nbidal18$endHeliumOverlay(
            int height, GuiGraphics graphics, int screenWidth, int screenHeight,
            CallbackInfoReturnable<Boolean> cir
    ) {
        AutoHudRenderGate.end(ComponentRenderer.HOTBAR, graphics, nbidal18$heliumOverlay);
        nbidal18$heliumOverlay = false;
    }
}
