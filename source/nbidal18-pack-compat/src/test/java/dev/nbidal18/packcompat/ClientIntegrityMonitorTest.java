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
    private static final Path EUPHORIA_ROOT = Path.of(
            "shaderpacks", "ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3"
    );

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
    void postReloadFinalizationMakesGeneratedRootEventsSticky() throws Exception {
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
    void clientStartedOnlyArmsAndPostReloadFinalizationFailsClosedWhenCacheIsMissing() throws Exception {
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
            assertTrue(monitor.loginState().message().contains("initial resource loading"));
            monitor.advanceStartupFinalization(false);
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("initial resource loading"));
            monitor.advanceStartupFinalization(true);
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("did not appear"));
        }
    }

    @Test
    void cacheAbsentAtClientStartedCanAppearBeforePostReloadPinning() throws Exception {
        Path referenceRoot = temporary.resolve("late-cache-reference");
        GeneratedTreePins pins = tinyGeneratedPins(referenceRoot, false);

        Path liveRoot = temporary.resolve("late-cache-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC),
                pins
        )) {
            monitor.clientStarted();
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("initial resource loading"));

            monitor.advanceStartupFinalization(false);
            assertFalse(monitor.loginState().clean());
            writeTinyDynamicCache(liveRoot, "trusted generated payload");

            monitor.advanceStartupFinalization(true);
            assertTrue(monitor.loginState().clean());
        }
    }

    @Test
    void delayedInitialResourceLoadCannotStartPeriodicScansBeforeGeneratedTreesArePinned() throws Exception {
        Path referenceRoot = temporary.resolve("delayed-load-reference");
        GeneratedTreePins pins = tinyGeneratedPins(referenceRoot, true);

        Path liveRoot = temporary.resolve("delayed-load-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC),
                pins
        )) {
            monitor.clientStarted();
            writeTinyDynamicCache(liveRoot, "trusted generated payload");
            writeTinyEuphoria(liveRoot, "trusted generated shader");

            // Model an initial reload that outlives every constructor-armed interval without
            // sleeping in the test. The old raw-state gate started verifyIncremental here with
            // an empty regeneratedTrees map and produced "existed before launch".
            assertFalse(monitor.queueDuePeriodicScans(Long.MAX_VALUE / 2));
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("initial resource loading"));

            monitor.advanceStartupFinalization(true);
            assertTrue(monitor.loginState().clean());
        }
    }

    @Test
    void initializationAllowsPinnedEuphoriaCreatedByEarlierClientInitializer() throws Exception {
        Path referenceRoot = temporary.resolve("early-euphoria-reference");
        GeneratedTreePins pins = tinyGeneratedPins(referenceRoot, true);

        Path liveRoot = temporary.resolve("early-euphoria-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        writeTinyDynamicCache(liveRoot, "trusted generated payload");
        writeTinyEuphoria(liveRoot, "trusted generated shader");
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC),
                pins
        )) {
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("still pending"));
            assertFalse(monitor.loginState().message().contains("existed before launch"));

            monitor.clientStarted();
            monitor.advanceStartupFinalization(true);
            assertTrue(monitor.loginState().clean());
        }
    }

    @Test
    void earlyEuphoriaWithWrongPinFailsClosedDuringPostReloadFinalization() throws Exception {
        Path referenceRoot = temporary.resolve("wrong-euphoria-reference");
        GeneratedTreePins pins = tinyGeneratedPins(referenceRoot, true);

        Path liveRoot = temporary.resolve("wrong-euphoria-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        writeTinyDynamicCache(liveRoot, "trusted generated payload");
        writeTinyEuphoria(liveRoot, "tampered generated shader");
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC),
                pins
        )) {
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("still pending"));

            monitor.clientStarted();
            monitor.advanceStartupFinalization(true);
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("Euphoria generated shader tree"));
            assertTrue(monitor.loginState().message().contains("does not match the reviewed release pin"));
        }
    }

    @Test
    void wrongGeneratedCachePinFailsClosedAndCannotReturnClean() throws Exception {
        Path referenceRoot = temporary.resolve("wrong-cache-reference");
        GeneratedTreePins pins = tinyGeneratedPins(referenceRoot, false);

        Path liveRoot = temporary.resolve("wrong-cache-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        writeTinyDynamicCache(liveRoot, "tampered generated payload");
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC),
                pins
        )) {
            monitor.clientStarted();
            monitor.advanceStartupFinalization(true);
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("does not match the reviewed release pin"));

            writeTinyDynamicCache(liveRoot, "trusted generated payload");
            monitor.advanceStartupFinalization(true);
            assertFalse(monitor.loginState().clean(), "repair after a failed pin must require a clean relaunch");
        }
    }

    @Test
    void malformedGeneratedCacheFailsClosed() throws Exception {
        Path referenceRoot = temporary.resolve("malformed-cache-reference");
        GeneratedTreePins pins = tinyGeneratedPins(referenceRoot, false);

        Path liveRoot = temporary.resolve("malformed-cache-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        fixture.write("dynamic-resource-pack-cache/assets/generated.json", "trusted generated payload");
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC),
                pins
        )) {
            monitor.clientStarted();
            monitor.advanceStartupFinalization(true);
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("exclusion was not present"));
        }
    }

    private static ClientIntegrityMonitor initializedWithTinyPinnedDynamicCache(Path root) throws Exception {
        TestPackFixture fixture = new TestPackFixture(root);
        writeTinyDynamicCache(root, "trusted generated payload");
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
        monitor.advanceStartupFinalization(true);
        return monitor;
    }

    private static GeneratedTreePins tinyGeneratedPins(Path root, boolean includeEuphoria) throws Exception {
        Files.createDirectories(root);
        writeTinyDynamicCache(root, "trusted generated payload");
        FabricCacheVerifier cacheVerifier = new FabricCacheVerifier(root);
        FabricCacheVerifier.CacheRoot dynamic = cacheVerifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        );
        String dynamicDigest = GeneratedTreePins.reviewed()
                .validateDynamicResourceCache(dynamic)
                .actualSha256();

        String euphoriaDigest = GeneratedTreePins.EUPHORIA_TREE_SHA256;
        if (includeEuphoria) {
            writeTinyEuphoria(root, "trusted generated shader");
            IntegrityVerifier verifier = new IntegrityVerifier(root);
            IntegrityVerifier.RegeneratedTree euphoria = verifier.captureRegeneratedTree(EUPHORIA_ROOT);
            euphoriaDigest = GeneratedTreePins.reviewed().validateEuphoria(euphoria).actualSha256();
        }
        return GeneratedTreePins.withExpectedDigests(euphoriaDigest, dynamicDigest);
    }

    private static void writeTinyDynamicCache(Path root, String payload) throws Exception {
        Path generated = root.resolve("dynamic-resource-pack-cache/assets/generated.json");
        Files.createDirectories(generated.getParent());
        Files.writeString(generated, payload);
        Files.writeString(root.resolve("dynamic-resource-pack-cache/hash.txt"), "variable Moonlight fingerprint");
    }

    private static void writeTinyEuphoria(Path root, String payload) throws Exception {
        Path generated = root.resolve(EUPHORIA_ROOT).resolve("generated.glsl");
        Files.createDirectories(generated.getParent());
        Files.writeString(generated, payload);
    }
}
