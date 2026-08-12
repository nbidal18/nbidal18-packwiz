package dev.nbidal18.packcompat;

import dev.wuffs.bcc.data.BetterStatus;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.api.EnvType;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientLoginNetworking;
import net.fabricmc.fabric.api.networking.v1.PacketByteBufs;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.network.FriendlyByteBuf;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.concurrent.CompletableFuture;

public final class Nbidal18PackCompatClient implements ClientModInitializer {
    private static final Logger LOGGER = LoggerFactory.getLogger("nbidal18-pack-compat");
    private static final String CUSTOM_SKIN_LOADER_BOOTSTRAP_MOD_ID = "customskinloader-bootstrap";

    @Override
    public void onInitializeClient() {
        FabricLoader loader = FabricLoader.getInstance();
        if (!shouldInstallLaunchGuard(loader.getEnvironmentType())) {
            return;
        }
        try {
            LaunchGuardUpdater.UpdateResult guardUpdate = LaunchGuardUpdater.install(loader.getGameDir());
            if (guardUpdate != LaunchGuardUpdater.UpdateResult.UP_TO_DATE) {
                LOGGER.info(
                        "Installed the current nbidal18 launch guard for the next Prism launch ({})",
                        guardUpdate
                );
            }
        } catch (java.io.IOException | IntegrityException failure) {
            throw new IllegalStateException(
                    "Could not safely install the current nbidal18 launch guard for the next Prism launch",
                    failure
            );
        }

        SkinOverridesTitleButton.register();
        ClientIntegrityMonitor integrityMonitor = ClientIntegrityMonitor.initialize(
                loader.getGameDir(),
                loader.isModLoaded(CUSTOM_SKIN_LOADER_BOOTSTRAP_MOD_ID)
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

    static boolean shouldInstallLaunchGuard(EnvType environmentType) {
        return environmentType == EnvType.CLIENT;
    }

    private static CompletableFuture<FriendlyByteBuf> createResponse(
            FriendlyByteBuf request,
            ClientIntegrityMonitor integrityMonitor
    ) {
        try {
            IntegrityProtocol.Request serverRequest = IntegrityProtocol.readRequest(request);
            int protocol = serverRequest.protocol();
            if (!IntegrityProtocol.clientSupports(protocol)) {
                return CompletableFuture.completedFuture(null);
            }

            BetterStatus status = Nbidal18PackCompat.currentStatus();
            if (!Nbidal18PackCompat.validStatus(status)) {
                return CompletableFuture.completedFuture(null);
            }

            FriendlyByteBuf response = PacketByteBufs.create();
            ClientIntegrityMonitor.LoginIntegrityState integrity = protocol >= Nbidal18PackCompat.DIGEST_PROTOCOL_VERSION
                    ? integrityMonitor.loginState()
                    : new ClientIntegrityMonitor.LoginIntegrityState(true, "", "clean");
            if (protocol >= Nbidal18PackCompat.DIGEST_PROTOCOL_VERSION) {
                if (!integrity.clean()) {
                    LOGGER.warn(
                            "nbidal18 protocol-{} login reports non-clean integrity: {}",
                            protocol,
                            integrity.message()
                    );
                }
            }
            IntegrityProtocol.writeResponse(
                    response,
                    new IntegrityProtocol.Response(
                            protocol,
                            status.name(),
                            status.version(),
                            integrity.manifestSha256(),
                            integrity.clean(),
                            integrity.message()
                    )
            );
            return CompletableFuture.completedFuture(response);
        } catch (RuntimeException malformedRequest) {
            return CompletableFuture.completedFuture(null);
        }
    }
}
