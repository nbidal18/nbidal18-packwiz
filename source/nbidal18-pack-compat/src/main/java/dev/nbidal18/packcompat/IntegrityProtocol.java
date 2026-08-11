package dev.nbidal18.packcompat;

import net.minecraft.network.FriendlyByteBuf;

final class IntegrityProtocol {
    static final int IDENTITY_PROTOCOL = 1;
    static final int DIGEST_PROTOCOL = 2;
    static final int REASON_PROTOCOL = 3;
    static final int CURRENT_PROTOCOL = REASON_PROTOCOL;
    static final int MAX_IDENTITY_LENGTH = 256;
    static final int SHA256_LENGTH = 64;
    static final int MAX_REASON_LENGTH = 256;

    private IntegrityProtocol() {
    }

    static boolean clientSupports(int protocol) {
        return protocol == IDENTITY_PROTOCOL
                || protocol == DIGEST_PROTOCOL
                || protocol == REASON_PROTOCOL;
    }

    static void writeRequest(FriendlyByteBuf buffer, Request request) {
        buffer.writeVarInt(request.protocol());
        buffer.writeUtf(request.expectedName(), MAX_IDENTITY_LENGTH);
        buffer.writeUtf(request.expectedVersion(), MAX_IDENTITY_LENGTH);
    }

    static Request readRequest(FriendlyByteBuf buffer) {
        int protocol = buffer.readVarInt();
        String expectedName = buffer.readUtf(MAX_IDENTITY_LENGTH);
        String expectedVersion = buffer.readUtf(MAX_IDENTITY_LENGTH);
        requireFullyConsumed(buffer);
        return new Request(protocol, expectedName, expectedVersion);
    }

    static void writeResponse(FriendlyByteBuf buffer, Response response) {
        int protocol = response.protocol();
        if (!clientSupports(protocol)) {
            throw new IllegalArgumentException("Unsupported nbidal18 integrity protocol: " + protocol);
        }
        buffer.writeVarInt(protocol);
        buffer.writeUtf(response.actualName(), MAX_IDENTITY_LENGTH);
        buffer.writeUtf(response.actualVersion(), MAX_IDENTITY_LENGTH);
        if (protocol >= DIGEST_PROTOCOL) {
            buffer.writeUtf(response.manifestSha256(), SHA256_LENGTH);
            buffer.writeBoolean(response.integrityClean());
        }
        if (protocol >= REASON_PROTOCOL) {
            String reason = response.integrityClean()
                    ? ""
                    : IntegrityReason.sanitizeForWire(response.integrityReason());
            buffer.writeUtf(reason, MAX_REASON_LENGTH);
        }
    }

    static Response readResponse(FriendlyByteBuf buffer, int requiredProtocol) {
        int protocol = buffer.readVarInt();
        if (protocol != requiredProtocol || !clientSupports(protocol)) {
            throw new IllegalArgumentException("Unexpected nbidal18 integrity protocol: " + protocol);
        }
        String actualName = buffer.readUtf(MAX_IDENTITY_LENGTH);
        String actualVersion = buffer.readUtf(MAX_IDENTITY_LENGTH);
        String manifestSha256 = "";
        boolean integrityClean = true;
        String integrityReason = "";
        if (protocol >= DIGEST_PROTOCOL) {
            manifestSha256 = buffer.readUtf(SHA256_LENGTH);
            integrityClean = buffer.readBoolean();
        }
        if (protocol >= REASON_PROTOCOL) {
            integrityReason = buffer.readUtf(MAX_REASON_LENGTH);
            if (integrityClean && !integrityReason.isEmpty()) {
                throw new IllegalArgumentException("Clean nbidal18 response contained a failure reason");
            }
            if (!integrityClean
                    && !integrityReason.equals(IntegrityReason.sanitizeForWire(integrityReason))) {
                throw new IllegalArgumentException("Unsafe nbidal18 integrity reason");
            }
        }
        requireFullyConsumed(buffer);
        return new Response(
                protocol,
                actualName,
                actualVersion,
                manifestSha256,
                integrityClean,
                integrityReason
        );
    }

    private static void requireFullyConsumed(FriendlyByteBuf buffer) {
        if (buffer.isReadable()) {
            throw new IllegalArgumentException("Trailing bytes in nbidal18 integrity message");
        }
    }

    record Request(int protocol, String expectedName, String expectedVersion) {
    }

    record Response(
            int protocol,
            String actualName,
            String actualVersion,
            String manifestSha256,
            boolean integrityClean,
            String integrityReason
    ) {
    }
}
