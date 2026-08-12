package dev.nbidal18.packcompat.autohud.mixin;

import me.flashyreese.mods.sodiumextra.client.gui.SodiumExtraHud;
import mod.crend.autohud.render.ComponentRenderer;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.gui.GuiGraphics;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(value = SodiumExtraHud.class, remap = false)
abstract class SodiumExtraHudMixin {
    @Unique private boolean nbidal18$sodiumHud;

    @Inject(method = "onHudRender", at = @At("HEAD"), cancellable = true, remap = false)
    private void nbidal18$beginSodiumHud(
            GuiGraphics graphics, DeltaTracker deltaTracker, CallbackInfo ci
    ) {
        nbidal18$sodiumHud = AutoHudRenderGate.begin(ComponentRenderer.HOTBAR, graphics, ci);
    }

    @Inject(method = "onHudRender", at = @At("RETURN"), remap = false)
    private void nbidal18$endSodiumHud(
            GuiGraphics graphics, DeltaTracker deltaTracker, CallbackInfo ci
    ) {
        AutoHudRenderGate.end(ComponentRenderer.HOTBAR, graphics, nbidal18$sodiumHud);
        nbidal18$sodiumHud = false;
    }
}
