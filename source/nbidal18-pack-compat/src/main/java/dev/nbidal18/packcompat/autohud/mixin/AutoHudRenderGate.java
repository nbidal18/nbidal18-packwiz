package dev.nbidal18.packcompat.autohud.mixin;

import mod.crend.autohud.render.ComponentRenderer;
import net.minecraft.client.gui.GuiGraphics;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

final class AutoHudRenderGate {
    private AutoHudRenderGate() {
    }

    static boolean begin(ComponentRenderer renderer, GuiGraphics graphics, CallbackInfo ci) {
        if (!renderer.isActive()) {
            return false;
        }
        if (!renderer.doRender()) {
            ci.cancel();
            return false;
        }
        renderer.beginRender(graphics);
        return true;
    }

    static void end(ComponentRenderer renderer, GuiGraphics graphics, boolean began) {
        if (began) {
            renderer.endRender(graphics);
        }
    }
}
