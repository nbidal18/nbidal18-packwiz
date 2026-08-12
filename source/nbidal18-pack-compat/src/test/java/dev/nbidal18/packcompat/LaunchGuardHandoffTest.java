package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LaunchGuardHandoffTest {
    @TempDir
    Path temporary;

    @Test
    void exactFreshHashBoundHandoffIsAtomicallyConsumed() throws Exception {
        TestPackFixture fixture = new TestPackFixture(temporary.resolve("pack"));
        StrictManifest manifest = fixture.writeManifest();
        Path companion = fixture.resolve("mods/companion.jar");
        Files.writeString(companion, "exact companion", StandardCharsets.UTF_8);
        String guard = "b".repeat(64);
        Instant now = Instant.parse("2026-08-12T10:15:30Z");
        writeHandoff(fixture.root, guard, IntegrityFiles.sha256(companion), manifest.sha256(), now);

        assertTrue(LaunchGuardHandoff.consumeIfMatching(
                fixture.root, companion, guard, Clock.fixed(now, ZoneOffset.UTC)
        ));
        assertFalse(Files.exists(fixture.root.resolve(LaunchGuardHandoff.RELATIVE_PATH)));
    }

    @Test
    void staleOrMismatchedProofNeverSuppressesAndIsNotConsumed() throws Exception {
        TestPackFixture fixture = new TestPackFixture(temporary.resolve("pack"));
        StrictManifest manifest = fixture.writeManifest();
        Path companion = fixture.resolve("mods/companion.jar");
        Files.writeString(companion, "exact companion", StandardCharsets.UTF_8);
        String guard = "b".repeat(64);
        Instant now = Instant.parse("2026-08-12T10:15:30Z");
        writeHandoff(
                fixture.root,
                guard,
                IntegrityFiles.sha256(companion),
                manifest.sha256(),
                now.minus(LaunchGuardHandoff.MAXIMUM_AGE).minusSeconds(1)
        );
        assertFalse(LaunchGuardHandoff.consumeIfMatching(
                fixture.root, companion, guard, Clock.fixed(now, ZoneOffset.UTC)
        ));
        assertTrue(Files.exists(fixture.root.resolve(LaunchGuardHandoff.RELATIVE_PATH)));

        writeHandoff(fixture.root, "c".repeat(64), IntegrityFiles.sha256(companion), manifest.sha256(), now);
        assertFalse(LaunchGuardHandoff.consumeIfMatching(
                fixture.root, companion, guard, Clock.fixed(now, ZoneOffset.UTC)
        ));
        assertTrue(Files.exists(fixture.root.resolve(LaunchGuardHandoff.RELATIVE_PATH)));
    }

    @Test
    void exactParserRejectsCrLfDuplicateAndUnknownRecords() throws Exception {
        String valid = handoff("a".repeat(64), "b".repeat(64), "c".repeat(64),
                Instant.parse("2026-08-12T10:15:30Z"));
        assertThrows(IntegrityException.class, () -> LaunchGuardHandoff.parse(
                valid.replace("\n", "\r\n").getBytes(StandardCharsets.UTF_8)
        ));
        assertThrows(IntegrityException.class, () -> LaunchGuardHandoff.parse(
                valid.replace("manifest-sha256", "guard-sha256").getBytes(StandardCharsets.UTF_8)
        ));
        assertThrows(IntegrityException.class, () -> LaunchGuardHandoff.parse(
                valid.replace("manifest-sha256", "unknown").getBytes(StandardCharsets.UTF_8)
        ));
    }

    private static void writeHandoff(
            Path root,
            String guard,
            String companion,
            String manifest,
            Instant time
    ) throws Exception {
        Files.writeString(
                root.resolve(LaunchGuardHandoff.RELATIVE_PATH),
                handoff(guard, companion, manifest, time),
                StandardCharsets.UTF_8
        );
    }

    private static String handoff(String guard, String companion, String manifest, Instant time) {
        return "nbidal18-launch-guard-handoff\t1\n"
                + "guard-sha256\t" + guard + "\n"
                + "companion-sha256\t" + companion + "\n"
                + "manifest-sha256\t" + manifest + "\n"
                + "verified-at-utc\t" + time + "\n";
    }
}
