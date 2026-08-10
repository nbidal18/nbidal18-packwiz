package dev.nbidal18.packcompat;

import dev.wuffs.bcc.BetterCompatibilityChecker;
import dev.wuffs.bcc.data.BetterStatus;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.api.EnvType;
import net.fabricmc.loader.api.FabricLoader;
import net.fabricmc.fabric.api.networking.v1.LoginPacketSender;
import net.fabricmc.fabric.api.networking.v1.PacketByteBufs;
import net.fabricmc.fabric.api.networking.v1.ServerLoginConnectionEvents;
import net.fabricmc.fabric.api.networking.v1.ServerLoginNetworking;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.network.ServerLoginPacketListenerImpl;

import java.util.Objects;
import java.util.regex.Pattern;

public final class Nbidal18PackCompat implements ModInitializer {
    static final ResourceLocation VERSION_QUERY =
            ResourceLocation.fromNamespaceAndPath("nbidal18_pack_compat", "version");
    static final int LEGACY_PROTOCOL_VERSION = 1;
    static final int PROTOCOL_VERSION = 2;
    static final int MAX_IDENTITY_LENGTH = 256;
    static final int SHA256_LENGTH = 64;
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");

    @Override
    public void onInitialize() {
        FabricLoader loader = FabricLoader.getInstance();
        if (!shouldEnforceServerLogin(loader.getEnvironmentType())) {
            return;
        }
        ExpectedManifestConfig expectedManifest = ExpectedManifestConfig.load(loader.getConfigDir());
        ServerLoginConnectionEvents.QUERY_START.register((handler, server, sender, synchronizer) ->
                beginVersionCheck(handler, sender, expectedManifest));
    }

    static boolean shouldEnforceServerLogin(EnvType environmentType) {
        return environmentType == EnvType.SERVER;
    }

    private static void beginVersionCheck(
            ServerLoginPacketListenerImpl handler,
            LoginPacketSender sender,
            ExpectedManifestConfig expectedManifest
    ) {
        if (!expectedManifest.valid()) {
            disconnect(handler, "The nbidal18 server integrity policy is unavailable. Contact the server operator.");
            return;
        }
        BetterStatus expected = currentStatus();
        if (!validStatus(expected)) {
            disconnect(handler, "The nbidal18 server pack identity is unavailable. Please try again shortly.");
            return;
        }

        boolean registered = ServerLoginNetworking.registerReceiver(
                handler,
                VERSION_QUERY,
                (server, loginHandler, understood, response, synchronizer, responseSender) ->
                        verifyResponse(loginHandler, expected, expectedManifest.sha256(), understood, response)
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
            String expectedManifestSha256,
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
            String actualManifestSha256 = response.readUtf(SHA256_LENGTH);
            boolean integrityClean = response.readBoolean();
            if (protocol != PROTOCOL_VERSION || response.isReadable()) {
                disconnect(handler, "Your nbidal18 compatibility response is invalid. Reinstall the matching client pack.");
                return;
            }
            if (!Objects.equals(expected.name(), actualName)
                    || !Objects.equals(expected.version(), actualVersion)) {
                disconnect(handler, "Modpack version mismatch. Server requires "
                        + expected.name() + " " + expected.version()
                        + "; your client reports " + actualName + " " + actualVersion + ".");
                return;
            }
            if (!integrityClean) {
                disconnect(handler, "Your nbidal18 client did not pass the launch integrity check. "
                        + "Close Minecraft and relaunch through Prism.");
                return;
            }
            if (!SHA256.matcher(actualManifestSha256).matches()) {
                disconnect(handler, "Your nbidal18 integrity response is invalid. Reinstall the matching client pack.");
                return;
            }
            if (!Objects.equals(expectedManifestSha256, actualManifestSha256)) {
                disconnect(handler, "Managed-content policy mismatch. Update to the server's current nbidal18 pack.");
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
