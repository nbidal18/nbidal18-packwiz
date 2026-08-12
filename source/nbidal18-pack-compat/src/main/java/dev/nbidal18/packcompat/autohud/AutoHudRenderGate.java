package dev.nbidal18.packcompat.autohud;

import mod.crend.autohud.render.ComponentRenderer;
import net.minecraft.client.gui.GuiGraphics;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

public final class AutoHudRenderGate {
    private AutoHudRenderGate() {
    }

    public static void verifyLoadable() {
        // Intentionally empty. Calling this from the client entrypoint makes Fabric/Mixin
        // resolve the helper during startup instead of waiting for the first HUD render.
    }

    public static boolean begin(ComponentRenderer renderer, GuiGraphics graphics, CallbackInfo ci) {
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

    public static void end(ComponentRenderer renderer, GuiGraphics graphics, boolean began) {
        if (began) {
            renderer.endRender(graphics);
        }
    }
}
