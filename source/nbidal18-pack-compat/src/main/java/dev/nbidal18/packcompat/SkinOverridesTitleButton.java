package dev.nbidal18.packcompat;

import net.fabricmc.fabric.api.client.screen.v1.ScreenEvents;
import net.fabricmc.fabric.api.client.screen.v1.Screens;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.components.AbstractWidget;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.TitleScreen;
import net.minecraft.network.chat.Component;
import net.orifu.skin_overrides.gui.screen.OverridesScreen;

import java.util.List;

/** Adds a direct title-screen entry point to Skin Overrides' existing selector. */
final class SkinOverridesTitleButton {
    static final int BUTTON_GAP = TitleButtonLayout.DEFAULT_GAP;
    static final int MIN_SPLIT_WIDTH = 150;
    static final int FALLBACK_WIDTH = 110;
    static final int FALLBACK_HEIGHT = 20;
    static final int FALLBACK_MARGIN = 4;

    private static final Component LABEL = Component.translatable("nbidal18_pack_compat.skin_menu");
    private static final Component MODS_LABEL = Component.translatable("modmenu.title");

    private SkinOverridesTitleButton() {
    }

    static void register() {
        ScreenEvents.AFTER_INIT.register(SkinOverridesTitleButton::afterScreenInit);
    }

    private static void afterScreenInit(
            Minecraft client,
            Screen screen,
            int scaledWidth,
            int scaledHeight
    ) {
        if (!(screen instanceof TitleScreen)) {
            return;
        }

        List<AbstractWidget> buttons = Screens.getButtons(screen);
        if (buttons.stream().anyMatch(SkinOverridesTitleButton::isSkinButton)) {
            return;
        }

        Button modsButton = findFullWidthModsButton(buttons);
        if (modsButton != null) {
            TitleButtonLayout.SplitLayout split = TitleButtonLayout.splitRow(
                    modsButton.getX(), modsButton.getWidth(), BUTTON_GAP);
            modsButton.setWidth(split.leftWidth());
            buttons.add(buildButton(client, screen, split.rightX(), modsButton.getY(),
                    split.rightWidth(), modsButton.getHeight()));
            return;
        }

        ButtonPosition fallback = findFallbackPosition(buttons, scaledWidth, scaledHeight);
        buttons.add(buildButton(client, screen, fallback.x(), fallback.y(),
                FALLBACK_WIDTH, FALLBACK_HEIGHT));
    }

    private static Button findFullWidthModsButton(List<AbstractWidget> buttons) {
        String localizedModsLabel = MODS_LABEL.getString();
        for (AbstractWidget widget : buttons) {
            if (widget instanceof Button button
                    && button.getWidth() >= MIN_SPLIT_WIDTH
                    && button.getMessage().getString().equals(localizedModsLabel)) {
                return button;
            }
        }
        return null;
    }

    private static boolean isSkinButton(AbstractWidget widget) {
        return widget instanceof Button
                && widget.getMessage().getString().equals(LABEL.getString());
    }

    private static Button buildButton(
            Minecraft client,
            Screen parent,
            int x,
            int y,
            int width,
            int height
    ) {
        return Button.builder(LABEL, ignored -> client.setScreen(new OverridesScreen(parent)))
                .bounds(x, y, width, height)
                .build();
    }

    static ButtonPosition findFallbackPosition(
            List<? extends AbstractWidget> buttons,
            int scaledWidth,
            int scaledHeight
    ) {
        int x = Math.max(FALLBACK_MARGIN, scaledWidth - FALLBACK_WIDTH - FALLBACK_MARGIN);
        int maximumY = Math.max(FALLBACK_MARGIN, scaledHeight - FALLBACK_HEIGHT - FALLBACK_MARGIN);
        for (int y = FALLBACK_MARGIN; y <= maximumY; y += FALLBACK_HEIGHT + BUTTON_GAP) {
            int candidateY = y;
            if (buttons.stream().noneMatch(widget -> TitleButtonLayout.overlaps(
                    x, candidateY, FALLBACK_WIDTH, FALLBACK_HEIGHT,
                    widget.getX(), widget.getY(), widget.getWidth(), widget.getHeight()))) {
                return new ButtonPosition(x, candidateY);
            }
        }
        return new ButtonPosition(x, FALLBACK_MARGIN);
    }

    record ButtonPosition(int x, int y) {
    }
}
