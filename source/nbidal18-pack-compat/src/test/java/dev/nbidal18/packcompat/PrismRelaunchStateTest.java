package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Base64;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PrismRelaunchStateTest {
    private static final String NONCE = "0123456789abcdef0123456789abcdef";
    private static final String GUARD = "a".repeat(64);

    @TempDir
    Path temporary;

    @Test
    void armWritesExactGuardContractAndRoundTrips() throws Exception {
        Path game = gameDirectory();
        Instant armed = Instant.parse("2026-08-12T10:15:30.123456700Z");
        PrismRelaunchState.RelaunchMarker marker = PrismRelaunchState.arm(
                game, GUARD, "nbidal18-client", armed, NONCE
        );
        String encoded = Base64.getUrlEncoder().withoutPadding()
                .encodeToString("nbidal18-client".getBytes(StandardCharsets.UTF_8));
        assertEquals(
                "nbidal18-prism-relaunch\t1\n"
                        + "state\tarmed\n"
                        + "nonce\t" + NONCE + "\n"
                        + "guard-sha256\t" + GUARD + "\n"
                        + "instance-id-base64\t" + encoded + "\n"
                        + "armed-at-utc\t" + armed + "\n",
                Files.readString(game.resolve(PrismRelaunchState.RELATIVE_PATH), StandardCharsets.UTF_8)
        );
        assertEquals(marker, PrismRelaunchState.read(game));
        assertFalse(PrismRelaunchState.acknowledgedMatches(game, NONCE, GUARD, "nbidal18-client"));
    }

    @Test
    void exactAcknowledgmentMatchesAndCanBeConsumed() throws Exception {
        Path game = gameDirectory();
        Instant armed = Instant.parse("2026-08-12T10:15:30Z");
        PrismRelaunchState.RelaunchMarker request = PrismRelaunchState.arm(
                game, GUARD, "instance with spaces", armed, NONCE
        );
        PrismRelaunchState.RelaunchMarker acknowledgement = new PrismRelaunchState.RelaunchMarker(
                PrismRelaunchState.MarkerState.ACKNOWLEDGED,
                request.nonce(), request.guardSha256(), request.instanceIdBase64(), request.armedAtUtc(),
                armed.plusSeconds(3)
        );
        Files.write(game.resolve(PrismRelaunchState.RELATIVE_PATH), acknowledgement.serialize());

        assertTrue(PrismRelaunchState.acknowledgedMatches(
                game, NONCE, GUARD, "instance with spaces"
        ));
        assertFalse(PrismRelaunchState.acknowledgedMatches(
                game, NONCE, GUARD, "another-instance"
        ));
        PrismRelaunchState.deleteMatching(game, acknowledgement);
        assertFalse(Files.exists(game.resolve(PrismRelaunchState.RELATIVE_PATH)));
    }

    @Test
    void parserRejectsCrLfUnknownFieldsAndMalformedInstanceEncoding() throws Exception {
        Path game = gameDirectory();
        PrismRelaunchState.RelaunchMarker marker = PrismRelaunchState.arm(
                game, GUARD, "nbidal18-client", Instant.parse("2026-08-12T10:15:30Z"), NONCE
        );
        byte[] crlf = new String(marker.serialize(), StandardCharsets.UTF_8)
                .replace("\n", "\r\n").getBytes(StandardCharsets.UTF_8);
        assertThrows(IntegrityException.class, () -> PrismRelaunchState.parse(crlf));

        String unknown = new String(marker.serialize(), StandardCharsets.UTF_8)
                .replace("armed-at-utc", "unexpected");
        assertThrows(IntegrityException.class,
                () -> PrismRelaunchState.parse(unknown.getBytes(StandardCharsets.UTF_8)));

        String malformed = new String(marker.serialize(), StandardCharsets.UTF_8)
                .replace(marker.instanceIdBase64(), "_");
        assertThrows(IntegrityException.class,
                () -> PrismRelaunchState.parse(malformed.getBytes(StandardCharsets.UTF_8)));
    }

    @Test
    void pureDecisionPreventsUpdateRestartLoops() {
        assertTrue(PrismRelaunchState.shouldPrepareRelaunch(
                LaunchGuardUpdater.UpdateResult.REPLACED, false
        ));
        assertFalse(PrismRelaunchState.shouldPrepareRelaunch(
                LaunchGuardUpdater.UpdateResult.REPLACED, true
        ));
        assertFalse(PrismRelaunchState.shouldPrepareRelaunch(
                LaunchGuardUpdater.UpdateResult.UP_TO_DATE, false
        ));
    }

    private Path gameDirectory() throws Exception {
        Path game = Files.createDirectory(temporary.resolve("game-" + Files.list(temporary).count()));
        Files.createDirectory(game.resolve(".nbidal18"));
        return game;
    }
}
