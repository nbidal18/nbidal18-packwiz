package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.nio.file.Files;
import java.nio.file.attribute.FileTime;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ClientIntegrityMonitorTest {
    @TempDir
    Path temporary;

    @Test
    void initializationFailsClosedWithoutFreshMatchingGuardAttestation() throws Exception {
        TestPackFixture fixture = new TestPackFixture(temporary);
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");

        try (ClientIntegrityMonitor missing = ClientIntegrityMonitor.initialize(
                temporary, Clock.fixed(now, ZoneOffset.UTC))) {
            assertFalse(missing.loginState().clean());
        }

        fixture.writeAttestation(manifest, now.minusSeconds(5));
        try (ClientIntegrityMonitor fresh = ClientIntegrityMonitor.initialize(
                temporary, Clock.fixed(now, ZoneOffset.UTC))) {
            assertFalse(fresh.loginState().clean());
            assertTrue(fresh.loginState().message().contains("still pending"));
            assertTrue(fresh.isImmediateStrictViolation(Path.of("mods", "exact.jar")));
            assertTrue(fresh.isImmediateStrictViolation(Path.of("resourcepacks", "injected.zip")));
            assertFalse(fresh.isImmediateStrictViolation(Path.of(
                    "shaderpacks", "ComplementaryUnbound_r5.8.1.zip.txt")));
            assertFalse(fresh.isImmediateStrictViolation(Path.of(
                    "shaderpacks", "ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3", "generated.glsl")));
            assertFalse(fresh.isImmediateStrictViolation(Path.of("config", "general.toml")));
        }

        fixture.writeAttestation(manifest, now.minusSeconds(16 * 60));
        try (ClientIntegrityMonitor stale = ClientIntegrityMonitor.initialize(
                temporary, Clock.fixed(now, ZoneOffset.UTC))) {
            assertFalse(stale.loginState().clean());
        }
    }

    @Test
    void startupFullHashRejectsSameMetadataRaceAndWatchViolationIsSticky() throws Exception {
        TestPackFixture fixture = new TestPackFixture(temporary);
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);
        Path managed = fixture.resolve("mods/exact.jar");
        byte[] original = Files.readAllBytes(managed);
        FileTime originalTime = Files.getLastModifiedTime(managed);
        byte[] replacement = original.clone();
        replacement[0] ^= 0x01;
        Files.write(managed, replacement);
        Files.setLastModifiedTime(managed, originalTime);

        try (ClientIntegrityMonitor raced = ClientIntegrityMonitor.initialize(
                temporary, Clock.fixed(now, ZoneOffset.UTC))) {
            assertFalse(raced.loginState().clean());
            assertTrue(raced.loginState().message().contains("hash mismatch"));
        }

        Files.write(managed, original);
        manifest = StrictManifest.load(temporary);
        fixture.writeAttestation(manifest, now);
        try (ClientIntegrityMonitor watched = ClientIntegrityMonitor.initialize(
                temporary, Clock.fixed(now, ZoneOffset.UTC))) {
            watched.handleChangedPath(managed, System.nanoTime());
            assertFalse(watched.loginState().clean());
            assertTrue(watched.loginState().message().contains("changed after initialization"));
            // The bytes are exact again, but an observed strict-root mutation remains sticky.
            Files.write(managed, original);
            assertFalse(watched.loginState().clean());
        }
    }

    @Test
    void clientStartedFinalizationMakesGeneratedRootEventsSticky() throws Exception {
        Path dynamicRoot = temporary.resolve("dynamic-case");
        ClientIntegrityMonitor dynamic = initializedWithTinyPinnedDynamicCache(dynamicRoot);
        try (dynamic) {
            assertTrue(dynamic.loginState().clean());
            Path injected = dynamicRoot.resolve("dynamic-resource-pack-cache/injected.json");
            Files.writeString(injected, "loaded then removed");
            dynamic.handleChangedPath(injected, System.nanoTime());
            assertFalse(dynamic.loginState().clean());
            Files.delete(injected);
            dynamic.handleChangedPath(injected, System.nanoTime());
            Files.writeString(injected, "loaded then removed");
            dynamic.handleChangedPath(injected, System.nanoTime());
            assertFalse(dynamic.loginState().clean(), "create/delete/restore must remain sticky dirty");
        }

        Path euphoriaRoot = temporary.resolve("euphoria-case");
        ClientIntegrityMonitor euphoria = initializedWithTinyPinnedDynamicCache(euphoriaRoot);
        try (euphoria) {
            assertTrue(euphoria.loginState().clean());
            Path generated = euphoriaRoot.resolve(
                    "shaderpacks/ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3/generated.glsl"
            );
            Files.createDirectories(generated.getParent());
            Files.writeString(generated, "created after startup");
            euphoria.handleChangedPath(generated, System.nanoTime());
            assertFalse(euphoria.loginState().clean(), "absent-at-finalization Euphoria creation must be dirty");
            Files.delete(generated);
            euphoria.handleChangedPath(generated, System.nanoTime());
            assertFalse(euphoria.loginState().clean(), "removing the transient shader must not restore clean state");
        }
    }

    @Test
    void clientStartedFailsClosedWhenRequiredDynamicCacheIsMissing() throws Exception {
        TestPackFixture fixture = new TestPackFixture(temporary);
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);
        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                temporary,
                Clock.fixed(now, ZoneOffset.UTC)
        )) {
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("still pending"));
            monitor.clientStarted();
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("did not appear"));
        }
    }

    private static ClientIntegrityMonitor initializedWithTinyPinnedDynamicCache(Path root) throws Exception {
        TestPackFixture fixture = new TestPackFixture(root);
        fixture.write("dynamic-resource-pack-cache/assets/generated.json", "trusted generated payload");
        fixture.write("dynamic-resource-pack-cache/hash.txt", "variable Moonlight fingerprint");
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        FabricCacheVerifier cacheVerifier = new FabricCacheVerifier(root);
        FabricCacheVerifier.CacheRoot dynamic = cacheVerifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        );
        String dynamicDigest = GeneratedTreePins.reviewed()
                .validateDynamicResourceCache(dynamic)
                .actualSha256();
        GeneratedTreePins pins = GeneratedTreePins.withExpectedDigests(
                GeneratedTreePins.EUPHORIA_TREE_SHA256,
                dynamicDigest
        );
        ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                root,
                Clock.fixed(now, ZoneOffset.UTC),
                pins
        );
        monitor.clientStarted();
        return monitor;
    }
}
