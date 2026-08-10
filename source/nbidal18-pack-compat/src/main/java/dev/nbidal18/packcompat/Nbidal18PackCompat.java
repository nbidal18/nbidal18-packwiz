package dev.nbidal18.packcompat;

import dev.wuffs.bcc.BetterCompatibilityChecker;
import dev.wuffs.bcc.data.BetterStatus;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.networking.v1.LoginPacketSender;
import net.fabricmc.fabric.api.networking.v1.PacketByteBufs;
import net.fabricmc.fabric.api.networking.v1.ServerLoginConnectionEvents;
import net.fabricmc.fabric.api.networking.v1.ServerLoginNetworking;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.network.ServerLoginPacketListenerImpl;

import java.util.Objects;

public final class Nbidal18PackCompat implements ModInitializer {
    static final ResourceLocation VERSION_QUERY =
            ResourceLocation.fromNamespaceAndPath("nbidal18_pack_compat", "version");
    static final int PROTOCOL_VERSION = 1;
    static final int MAX_IDENTITY_LENGTH = 256;

    @Override
    public void onInitialize() {
        ServerLoginConnectionEvents.QUERY_START.register((handler, server, sender, synchronizer) ->
                beginVersionCheck(handler, sender));
    }

    private static void beginVersionCheck(ServerLoginPacketListenerImpl handler, LoginPacketSender sender) {
        BetterStatus expected = currentStatus();
        if (!validStatus(expected)) {
            disconnect(handler, "The nbidal18 server pack identity is unavailable. Please try again shortly.");
            return;
        }

        boolean registered = ServerLoginNetworking.registerReceiver(
                handler,
                VERSION_QUERY,
                (server, loginHandler, understood, response, synchronizer, responseSender) ->
                        verifyResponse(loginHandler, expected, understood, response)
        );
        if (!registered) {
            disconnect(handler, "The nbidal18 compatibility check could not start. Please reconnect.");
            return;
        }

        FriendlyByteBuf request = PacketByteBufs.create();
        request.writeVarInt(PROTOCOL_VERSION);
        request.writeUtf(expected.name(), MAX_IDENTITY_LENGTH);
        request.writeUtf(expected.version(), MAX_IDENTITY_LENGTH);
        sender.sendPacket(VERSION_QUERY, request);
    }

    private static void verifyResponse(
            ServerLoginPacketListenerImpl handler,
            BetterStatus expected,
            boolean understood,
            FriendlyByteBuf response
    ) {
        if (!understood || response == null) {
            disconnect(handler, "This server requires the matching nbidal18 client pack.");
            return;
        }

        try {
            int protocol = response.readVarInt();
            String actualName = response.readUtf(MAX_IDENTITY_LENGTH);
            String actualVersion = response.readUtf(MAX_IDENTITY_LENGTH);
            if (protocol != PROTOCOL_VERSION || response.isReadable()) {
                disconnect(handler, "Your nbidal18 compatibility response is invalid. Reinstall the matching client pack.");
                return;
            }
            if (!Objects.equals(expected.name(), actualName)
                    || !Objects.equals(expected.version(), actualVersion)) {
                disconnect(handler, "Modpack version mismatch. Server requires "
                        + expected.name() + " " + expected.version()
                        + "; your client reports " + actualName + " " + actualVersion + ".");
            }
        } catch (RuntimeException malformedResponse) {
            disconnect(handler, "Your nbidal18 compatibility response is malformed. Reinstall the matching client pack.");
        }
    }

    static BetterStatus currentStatus() {
        return BetterCompatibilityChecker.getBetterStatus();
    }

    static boolean validStatus(BetterStatus status) {
        return status != null
                && validIdentityPart(status.name())
                && validIdentityPart(status.version());
    }

    private static boolean validIdentityPart(String value) {
        return value != null && !value.isBlank() && value.length() <= MAX_IDENTITY_LENGTH;
    }

    private static void disconnect(ServerLoginPacketListenerImpl handler, String message) {
        handler.disconnect(Component.literal(message));
    }
}
