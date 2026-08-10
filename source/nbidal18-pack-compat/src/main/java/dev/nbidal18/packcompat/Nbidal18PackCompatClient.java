package dev.nbidal18.packcompat;

import dev.wuffs.bcc.data.BetterStatus;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientLoginNetworking;
import net.fabricmc.fabric.api.networking.v1.PacketByteBufs;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.network.FriendlyByteBuf;

import java.util.concurrent.CompletableFuture;

public final class Nbidal18PackCompatClient implements ClientModInitializer {
    @Override
    public void onInitializeClient() {
        ClientIntegrityMonitor integrityMonitor = ClientIntegrityMonitor.initialize(
                FabricLoader.getInstance().getGameDir()
        );
        boolean registered = ClientLoginNetworking.registerGlobalReceiver(
                Nbidal18PackCompat.VERSION_QUERY,
                (client, handler, request, callbacks) -> createResponse(request, integrityMonitor)
        );
        if (!registered) {
            throw new IllegalStateException("The nbidal18 pack compatibility login channel is already registered");
        }
        ClientTickEvents.END_CLIENT_TICK.register(integrityMonitor::tick);
        ClientLifecycleEvents.CLIENT_STARTED.register(client -> integrityMonitor.clientStarted());
        ClientLifecycleEvents.CLIENT_STOPPING.register(client -> integrityMonitor.close());
    }

    private static CompletableFuture<FriendlyByteBuf> createResponse(
            FriendlyByteBuf request,
            ClientIntegrityMonitor integrityMonitor
    ) {
        try {
            int protocol = request.readVarInt();
            request.readUtf(Nbidal18PackCompat.MAX_IDENTITY_LENGTH);
            request.readUtf(Nbidal18PackCompat.MAX_IDENTITY_LENGTH);
            if ((protocol != Nbidal18PackCompat.PROTOCOL_VERSION
                    && protocol != Nbidal18PackCompat.LEGACY_PROTOCOL_VERSION)
                    || request.isReadable()) {
                return CompletableFuture.completedFuture(null);
            }

            BetterStatus status = Nbidal18PackCompat.currentStatus();
            if (!Nbidal18PackCompat.validStatus(status)) {
                return CompletableFuture.completedFuture(null);
            }

            FriendlyByteBuf response = PacketByteBufs.create();
            response.writeVarInt(protocol);
            response.writeUtf(status.name(), Nbidal18PackCompat.MAX_IDENTITY_LENGTH);
            response.writeUtf(status.version(), Nbidal18PackCompat.MAX_IDENTITY_LENGTH);
            if (protocol == Nbidal18PackCompat.PROTOCOL_VERSION) {
                ClientIntegrityMonitor.LoginIntegrityState integrity = integrityMonitor.loginState();
                response.writeUtf(integrity.manifestSha256(), Nbidal18PackCompat.SHA256_LENGTH);
                response.writeBoolean(integrity.clean());
            }
            return CompletableFuture.completedFuture(response);
        } catch (RuntimeException malformedRequest) {
            return CompletableFuture.completedFuture(null);
        }
    }
}
