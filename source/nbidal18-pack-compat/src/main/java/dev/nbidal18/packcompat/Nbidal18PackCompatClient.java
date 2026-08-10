package dev.nbidal18.packcompat;

import dev.wuffs.bcc.data.BetterStatus;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.networking.v1.ClientLoginNetworking;
import net.fabricmc.fabric.api.networking.v1.PacketByteBufs;
import net.minecraft.network.FriendlyByteBuf;

import java.util.concurrent.CompletableFuture;

public final class Nbidal18PackCompatClient implements ClientModInitializer {
    @Override
    public void onInitializeClient() {
        boolean registered = ClientLoginNetworking.registerGlobalReceiver(
                Nbidal18PackCompat.VERSION_QUERY,
                (client, handler, request, callbacks) -> createResponse(request)
        );
        if (!registered) {
            throw new IllegalStateException("The nbidal18 pack compatibility login channel is already registered");
        }
    }

    private static CompletableFuture<FriendlyByteBuf> createResponse(FriendlyByteBuf request) {
        try {
            int protocol = request.readVarInt();
            request.readUtf(Nbidal18PackCompat.MAX_IDENTITY_LENGTH);
            request.readUtf(Nbidal18PackCompat.MAX_IDENTITY_LENGTH);
            if (protocol != Nbidal18PackCompat.PROTOCOL_VERSION || request.isReadable()) {
                return CompletableFuture.completedFuture(null);
            }

            BetterStatus status = Nbidal18PackCompat.currentStatus();
            if (!Nbidal18PackCompat.validStatus(status)) {
                return CompletableFuture.completedFuture(null);
            }

            FriendlyByteBuf response = PacketByteBufs.create();
            response.writeVarInt(Nbidal18PackCompat.PROTOCOL_VERSION);
            response.writeUtf(status.name(), Nbidal18PackCompat.MAX_IDENTITY_LENGTH);
            response.writeUtf(status.version(), Nbidal18PackCompat.MAX_IDENTITY_LENGTH);
            return CompletableFuture.completedFuture(response);
        } catch (RuntimeException malformedRequest) {
            return CompletableFuture.completedFuture(null);
        }
    }
}
