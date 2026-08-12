package dev.nbidal18.packcompat;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;

/** Persistent user-visible fallback when a safe exact-instance handoff cannot be prepared. */
final class PrismRelaunchNotice {
    private PrismRelaunchNotice() {
    }

    static Screen manualRestartScreen(Screen parent, String detail) {
        return new ManualRestartScreen(parent, detail);
    }

    private static final class ManualRestartScreen extends Screen {
        private final Screen parent;
        private final String detail;

        private ManualRestartScreen(Screen parent, String detail) {
            super(Component.literal("nbidal18 update needs one manual restart"));
            this.parent = parent;
            this.detail = detail;
        }

        @Override
        protected void init() {
            addRenderableWidget(Button.builder(
                    Component.literal("Close Minecraft"),
                    button -> Minecraft.getInstance().stop()
            ).bounds(width / 2 - 100, height / 2 + 28, 200, 20).build());
        }

        @Override
        public void render(net.minecraft.client.gui.GuiGraphics graphics, int mouseX, int mouseY, float delta) {
            renderBackground(graphics, mouseX, mouseY, delta);
            graphics.drawCenteredString(font, title, width / 2, height / 2 - 48, 0xFFFFFF);
            graphics.drawCenteredString(
                    font,
                    Component.literal("Close Minecraft, then click Play in Prism once more."),
                    width / 2,
                    height / 2 - 20,
                    0xFFFFFF
            );
            graphics.drawCenteredString(
                    font,
                    Component.literal(detail),
                    width / 2,
                    height / 2,
                    0xAAAAAA
            );
            super.render(graphics, mouseX, mouseY, delta);
        }

        @Override
        public void onClose() {
            // Keep the recovery instruction visible; the only action is the safe graceful close.
        }
    }
}
