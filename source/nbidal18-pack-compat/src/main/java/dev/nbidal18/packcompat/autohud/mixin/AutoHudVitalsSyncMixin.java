package dev.nbidal18.packcompat.autohud.mixin;

import mod.crend.autohud.AutoHud;
import mod.crend.autohud.component.Component;
import mod.crend.autohud.component.Components;
import mod.crend.autohud.config.RevealType;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(value = Component.class, remap = false)
abstract class AutoHudVitalsSyncMixin {
    @Unique
    private static boolean nbidal18$syncing;

    @Inject(method = "revealCombined(F)V", at = @At("HEAD"), remap = false)
    private void nbidal18$syncVitals(float visibleTime, CallbackInfo ci) {
        if (nbidal18$syncing || AutoHud.config == null
                || AutoHud.config.revealType() != RevealType.Individual) {
            return;
        }
        Component component = (Component) (Object) this;
        Component[] group = {
                Components.Hotbar,
                Components.Health,
                Components.Hunger,
                Components.ExperienceLevel
        };
        boolean member = false;
        for (Component candidate : group) {
            if (component == candidate) {
                member = true;
                break;
            }
        }
        if (!member) {
            return;
        }
        nbidal18$syncing = true;
        try {
            for (Component candidate : group) {
                if (candidate != component) {
                    candidate.revealCombined(visibleTime);
                }
            }
        } finally {
            nbidal18$syncing = false;
        }
    }
}
