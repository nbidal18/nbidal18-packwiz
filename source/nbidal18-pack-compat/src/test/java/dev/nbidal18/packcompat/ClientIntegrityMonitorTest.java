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
import static org.junit.jupiter.api.Assertions.assertNotEquals;
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
    void differentMachineGeneratedTreesLockPerLaunchAndPostLockMutationsStaySticky() throws Exception {
        Path machineA = temporary.resolve("machine-a");
        Path machineB = temporary.resolve("machine-b");
        ClientIntegrityMonitor launchA = initializedGeneratedLaunch(
                machineA,
                "machine A Moonlight bytes",
                "machine A Euphoria bytes"
        );
        ClientIntegrityMonitor launchB = initializedGeneratedLaunch(
                machineB,
                "machine B Moonlight bytes",
                "machine B Euphoria bytes"
        );

        try (launchA; launchB) {
            assertTrue(launchA.loginState().clean(), launchA.loginState().message());
            assertTrue(launchB.loginState().clean(), launchB.loginState().message());
            Path dynamicA = machineA.resolve("dynamic-resource-pack-cache/assets/generated.json");
            Path dynamicB = machineB.resolve("dynamic-resource-pack-cache/assets/generated.json");
            Path euphoriaA = machineA.resolve(EUPHORIA_ROOT).resolve("generated.glsl");
            Path euphoriaB = machineB.resolve(EUPHORIA_ROOT).resolve("generated.glsl");
            assertNotEquals(Files.readString(dynamicA), Files.readString(dynamicB));
            assertNotEquals(Files.readString(euphoriaA), Files.readString(euphoriaB));

            String originalDynamic = Files.readString(dynamicA);
            Files.writeString(dynamicA, "post-lock Moonlight mutation");
            launchA.handleChangedPath(dynamicA, System.nanoTime());
            assertFalse(launchA.loginState().clean());
            Files.writeString(dynamicA, originalDynamic);
            launchA.handleChangedPath(dynamicA, System.nanoTime());
            assertFalse(launchA.loginState().clean(), "restoring Moonlight bytes must remain sticky dirty");

            String originalEuphoria = Files.readString(euphoriaB);
            Files.writeString(euphoriaB, "post-lock Euphoria mutation");
            launchB.handleChangedPath(euphoriaB, System.nanoTime());
            assertFalse(launchB.loginState().clean());
            Files.writeString(euphoriaB, originalEuphoria);
            launchB.handleChangedPath(euphoriaB, System.nanoTime());
            assertFalse(launchB.loginState().clean(), "restoring Euphoria bytes must remain sticky dirty");
        }
    }

    @Test
    void absentEuphoriaCreationAfterLockIsStickyDirty() throws Exception {
        Path root = temporary.resolve("absent-euphoria");
        ClientIntegrityMonitor monitor = initializedGeneratedLaunch(root, "Moonlight bytes", null);
        try (monitor) {
            Path generated = root.resolve(EUPHORIA_ROOT).resolve("generated.glsl");
            Files.createDirectories(generated.getParent());
            Files.writeString(generated, "created after startup");
            monitor.handleChangedPath(generated, System.nanoTime());
            assertFalse(monitor.loginState().clean());
            Files.delete(generated);
            monitor.handleChangedPath(generated, System.nanoTime());
            assertFalse(monitor.loginState().clean(), "removing the transient shader must not restore clean state");
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
    void cacheAbsentAtClientStartedCanAppearBeforePostReloadLock() throws Exception {
        Path liveRoot = temporary.resolve("late-cache-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC)
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
    void delayedInitialResourceLoadCannotStartPeriodicScansBeforeGeneratedTreesAreLocked() throws Exception {
        Path liveRoot = temporary.resolve("delayed-load-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC)
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
    void initializationAllowsEuphoriaCreatedByEarlierClientInitializerThenLocksIt() throws Exception {
        Path liveRoot = temporary.resolve("early-euphoria-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        writeTinyDynamicCache(liveRoot, "trusted generated payload");
        writeTinyEuphoria(liveRoot, "trusted generated shader");
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC)
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
    void emptyEuphoriaFailsClosedDuringPostReloadFinalization() throws Exception {
        Path liveRoot = temporary.resolve("empty-euphoria-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        writeTinyDynamicCache(liveRoot, "trusted generated payload");
        Files.createDirectories(liveRoot.resolve(EUPHORIA_ROOT));
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC)
        )) {
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("still pending"));

            monitor.clientStarted();
            monitor.advanceStartupFinalization(true);
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("Regenerated shader tree is empty"));
        }
    }

    @Test
    void malformedGeneratedCacheFailsClosed() throws Exception {
        Path liveRoot = temporary.resolve("malformed-cache-live");
        TestPackFixture fixture = new TestPackFixture(liveRoot);
        fixture.write("dynamic-resource-pack-cache/assets/generated.json", "trusted generated payload");
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        try (ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                liveRoot,
                Clock.fixed(now, ZoneOffset.UTC)
        )) {
            monitor.clientStarted();
            monitor.advanceStartupFinalization(true);
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("missing required marker"));
        }
    }

    @Test
    void fullScanDetectsSameMetadataGeneratedMutationWithoutWatcherEvent() throws Exception {
        Path root = temporary.resolve("full-scan");
        ClientIntegrityMonitor monitor = initializedGeneratedLaunch(root, "AAAA", "CCCC");
        try (monitor) {
            Path dynamic = root.resolve("dynamic-resource-pack-cache/assets/generated.json");
            FileTime originalTime = Files.getLastModifiedTime(dynamic);
            Files.writeString(dynamic, "BBBB");
            Files.setLastModifiedTime(dynamic, originalTime);
            monitor.runFullScan();
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("hash changed"));
        }
    }

    private static ClientIntegrityMonitor initializedGeneratedLaunch(
            Path root,
            String dynamicPayload,
            String euphoriaPayload
    ) throws Exception {
        TestPackFixture fixture = new TestPackFixture(root);
        writeTinyDynamicCache(root, dynamicPayload);
        if (euphoriaPayload != null) {
            writeTinyEuphoria(root, euphoriaPayload);
        }
        StrictManifest manifest = fixture.writeManifest();
        Instant now = Instant.parse("2026-08-11T12:00:00Z");
        fixture.writeAttestation(manifest, now);

        ClientIntegrityMonitor monitor = ClientIntegrityMonitor.initialize(
                root,
                Clock.fixed(now, ZoneOffset.UTC)
        );
        monitor.clientStarted();
        monitor.advanceStartupFinalization(true);
        assertTrue(monitor.loginState().clean(), monitor.loginState().message());
        return monitor;
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
