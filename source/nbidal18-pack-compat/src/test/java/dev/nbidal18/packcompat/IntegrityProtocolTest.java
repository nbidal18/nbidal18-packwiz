package dev.nbidal18.packcompat;

import net.fabricmc.fabric.api.networking.v1.PacketByteBufs;
import net.minecraft.network.FriendlyByteBuf;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class IntegrityProtocolTest {
    private static final String SHA = "a".repeat(IntegrityProtocol.SHA256_LENGTH);

    @Test
    void requestRoundTripsAreStrictForAllSupportedServerGenerations() {
        for (int protocol : new int[] {
                IntegrityProtocol.IDENTITY_PROTOCOL,
                IntegrityProtocol.DIGEST_PROTOCOL,
                IntegrityProtocol.REASON_PROTOCOL
        }) {
            FriendlyByteBuf buffer = PacketByteBufs.create();
            IntegrityProtocol.writeRequest(
                    buffer,
                    new IntegrityProtocol.Request(protocol, "nbidal18", "3.2.3")
            );

            IntegrityProtocol.Request decoded = IntegrityProtocol.readRequest(buffer);
            assertEquals(protocol, decoded.protocol());
            assertEquals("nbidal18", decoded.expectedName());
            assertEquals("3.2.3", decoded.expectedVersion());
            assertFalse(buffer.isReadable());
        }
        assertFalse(IntegrityProtocol.clientSupports(0));
        assertFalse(IntegrityProtocol.clientSupports(4));
    }

    @Test
    void legacyIdentityResponseKeepsItsHistoricalShape() {
        FriendlyByteBuf buffer = writeResponse(new IntegrityProtocol.Response(
                IntegrityProtocol.IDENTITY_PROTOCOL,
                "nbidal18",
                "3.2.3",
                SHA,
                false,
                "must not be appended"
        ));

        IntegrityProtocol.Response decoded = IntegrityProtocol.readResponse(
                buffer,
                IntegrityProtocol.IDENTITY_PROTOCOL
        );
        assertEquals("", decoded.manifestSha256());
        assertTrue(decoded.integrityClean());
        assertEquals("", decoded.integrityReason());
        assertFalse(buffer.isReadable());
    }

    @Test
    void protocolTwoResponseKeepsItsHistoricalShapeWithoutTrailingReason() {
        FriendlyByteBuf buffer = writeResponse(new IntegrityProtocol.Response(
                IntegrityProtocol.DIGEST_PROTOCOL,
                "nbidal18",
                "3.2.3",
                SHA,
                false,
                "generated-cache verification is pending"
        ));

        IntegrityProtocol.Response decoded = IntegrityProtocol.readResponse(
                buffer,
                IntegrityProtocol.DIGEST_PROTOCOL
        );
        assertEquals(SHA, decoded.manifestSha256());
        assertFalse(decoded.integrityClean());
        assertEquals("", decoded.integrityReason());
        assertFalse(buffer.isReadable(), "an old protocol-2 server must see no added field");
    }

    @Test
    void protocolThreeCarriesOnlyABoundedSanitizedDirtyReason() {
        FriendlyByteBuf buffer = writeResponse(new IntegrityProtocol.Response(
                IntegrityProtocol.REASON_PROTOCOL,
                "nbidal18",
                "3.2.3",
                SHA,
                false,
                "Generated cache changed\r\nafter startup"
        ));

        IntegrityProtocol.Response decoded = IntegrityProtocol.readResponse(
                buffer,
                IntegrityProtocol.REASON_PROTOCOL
        );
        assertFalse(decoded.integrityClean());
        assertEquals("Generated cache changed after startup", decoded.integrityReason());
        assertFalse(buffer.isReadable());

        FriendlyByteBuf cleanBuffer = writeResponse(new IntegrityProtocol.Response(
                IntegrityProtocol.REASON_PROTOCOL,
                "nbidal18",
                "3.2.3",
                SHA,
                true,
                "ignored clean-state text"
        ));
        IntegrityProtocol.Response clean = IntegrityProtocol.readResponse(
                cleanBuffer,
                IntegrityProtocol.REASON_PROTOCOL
        );
        assertEquals("", clean.integrityReason());
    }

    @Test
    void malformedReasonAndTrailingPayloadAreRejected() {
        FriendlyByteBuf missing = PacketByteBufs.create();
        writeProtocolThreePrefix(missing, false);
        assertThrows(RuntimeException.class, () -> IntegrityProtocol.readResponse(
                missing,
                IntegrityProtocol.REASON_PROTOCOL
        ));

        FriendlyByteBuf controlFilled = PacketByteBufs.create();
        writeProtocolThreePrefix(controlFilled, false);
        controlFilled.writeUtf("dirty\nspoofed", IntegrityProtocol.MAX_REASON_LENGTH);
        assertThrows(IllegalArgumentException.class, () -> IntegrityProtocol.readResponse(
                controlFilled,
                IntegrityProtocol.REASON_PROTOCOL
        ));

        FriendlyByteBuf cleanWithReason = PacketByteBufs.create();
        writeProtocolThreePrefix(cleanWithReason, true);
        cleanWithReason.writeUtf("should not exist", IntegrityProtocol.MAX_REASON_LENGTH);
        assertThrows(IllegalArgumentException.class, () -> IntegrityProtocol.readResponse(
                cleanWithReason,
                IntegrityProtocol.REASON_PROTOCOL
        ));

        FriendlyByteBuf oversized = PacketByteBufs.create();
        writeProtocolThreePrefix(oversized, false);
        oversized.writeUtf("x".repeat(IntegrityProtocol.MAX_REASON_LENGTH + 1),
                IntegrityProtocol.MAX_REASON_LENGTH + 1);
        assertThrows(RuntimeException.class, () -> IntegrityProtocol.readResponse(
                oversized,
                IntegrityProtocol.REASON_PROTOCOL
        ));

        FriendlyByteBuf trailing = writeResponse(new IntegrityProtocol.Response(
                IntegrityProtocol.REASON_PROTOCOL,
                "nbidal18",
                "3.2.3",
                SHA,
                false,
                "concrete safe reason"
        ));
        trailing.writeByte(1);
        assertThrows(IllegalArgumentException.class, () -> IntegrityProtocol.readResponse(
                trailing,
                IntegrityProtocol.REASON_PROTOCOL
        ));
    }

    @Test
    void sanitizerPreservesPortableReasonsButRedactsPrivateAbsolutePaths() {
        assertEquals(
                "Managed loadable content changed: resourcepacks/injected.zip",
                IntegrityReason.sanitizeForWire(
                        "Managed loadable content changed: resourcepacks/injected.zip"
                )
        );
        assertEquals(
                IntegrityReason.PRIVATE_PATH_FALLBACK,
                IntegrityReason.sanitizeForWire("Could not read C:\\Users\\friend\\secret\\file.jar")
        );
        assertEquals(
                IntegrityProtocol.MAX_REASON_LENGTH,
                IntegrityReason.sanitizeForWire("x".repeat(1000)).length()
        );
    }

    private static FriendlyByteBuf writeResponse(IntegrityProtocol.Response response) {
        FriendlyByteBuf buffer = PacketByteBufs.create();
        IntegrityProtocol.writeResponse(buffer, response);
        return buffer;
    }

    private static void writeProtocolThreePrefix(FriendlyByteBuf buffer, boolean clean) {
        buffer.writeVarInt(IntegrityProtocol.REASON_PROTOCOL);
        buffer.writeUtf("nbidal18", IntegrityProtocol.MAX_IDENTITY_LENGTH);
        buffer.writeUtf("3.2.3", IntegrityProtocol.MAX_IDENTITY_LENGTH);
        buffer.writeUtf(SHA, IntegrityProtocol.SHA256_LENGTH);
        buffer.writeBoolean(clean);
    }
}
