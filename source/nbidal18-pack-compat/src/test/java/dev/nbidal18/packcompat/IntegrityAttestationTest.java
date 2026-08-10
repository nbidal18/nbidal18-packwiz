package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class IntegrityAttestationTest {
    @TempDir
    Path temporary;

    @Test
    void requiresMatchingFreshSuccessfulAttestation() throws Exception {
        TestPackFixture fixture = new TestPackFixture(temporary);
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now.minusSeconds(30));

        IntegrityAttestation attestation = IntegrityAttestation.loadAndValidate(
                temporary,
                manifest.sha256(),
                Clock.fixed(now, ZoneOffset.UTC)
        );
        assertEquals(manifest.sha256(), attestation.manifestSha256());

        fixture.writeAttestation(manifest, now.minus(IntegrityAttestation.MAXIMUM_AGE).minusSeconds(1));
        assertThrows(IntegrityException.class, () -> IntegrityAttestation.loadAndValidate(
                temporary, manifest.sha256(), Clock.fixed(now, ZoneOffset.UTC)));

        fixture.writeAttestation(manifest, now);
        assertThrows(IntegrityException.class, () -> IntegrityAttestation.loadAndValidate(
                temporary, "0".repeat(64), Clock.fixed(now, ZoneOffset.UTC)));
    }

    @Test
    void rejectsDuplicateOrMalformedRequiredRows() throws Exception {
        Path path = temporary.resolve(IntegrityAttestation.RELATIVE_PATH);
        Files.createDirectories(path.getParent());
        String digest = "0".repeat(64);
        String duplicate = "nbidal18-integrity-attestation\t1\n"
                + "manifest-sha256\t" + digest + "\n"
                + "manifest-sha256\t" + digest + "\n"
                + "verified-at-utc\t2026-08-11T12:00:00Z\n";
        Files.writeString(path, duplicate, StandardCharsets.UTF_8);
        assertThrows(IntegrityException.class, () -> IntegrityAttestation.parse(Files.readAllBytes(path)));
    }
}
