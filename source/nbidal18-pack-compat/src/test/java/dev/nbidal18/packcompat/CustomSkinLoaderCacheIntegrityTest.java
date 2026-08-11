package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class CustomSkinLoaderCacheIntegrityTest {
    private static final Instant NOW = Instant.parse("2026-08-11T12:00:00Z");

    @TempDir
    Path temporary;

    @Test
    void createModifyAndDeleteEventsAfterBaselineAreStickyDirty() throws Exception {
        Path createRoot = temporary.resolve("create");
        try (ClientIntegrityMonitor monitor = initializedMonitor(createRoot)) {
            Path injected = createRoot.resolve("CustomSkinLoader/Core/injected.jar");
            Files.writeString(injected, "injected executable");
            monitor.handleChangedPath(injected, System.nanoTime());
            assertCacheEventIsDirty(monitor);

            Files.delete(injected);
            assertCacheEventIsDirty(monitor);
        }

        Path modifyRoot = temporary.resolve("modify");
        try (ClientIntegrityMonitor monitor = initializedMonitor(modifyRoot)) {
            Path core = modifyRoot.resolve("CustomSkinLoader/Core/core.jar");
            Files.writeString(core, "BBBB");
            monitor.handleChangedPath(core, System.nanoTime());
            assertCacheEventIsDirty(monitor);

            Files.writeString(core, "AAAA");
            assertCacheEventIsDirty(monitor);
        }

        Path deleteRoot = temporary.resolve("delete");
        try (ClientIntegrityMonitor monitor = initializedMonitor(deleteRoot)) {
            Path core = deleteRoot.resolve("CustomSkinLoader/Core/core.jar");
            Files.delete(core);
            monitor.handleChangedPath(core, System.nanoTime());
            assertCacheEventIsDirty(monitor);

            Files.writeString(core, "AAAA");
            assertCacheEventIsDirty(monitor);
        }
    }

    @Test
    void periodicFullVerificationCatchesHashOnlyCoreMutation() throws Exception {
        Path root = temporary.resolve("periodic-full-scan");
        try (ClientIntegrityMonitor monitor = initializedMonitor(root)) {
            Path core = root.resolve("CustomSkinLoader/Core/core.jar");
            FileTime trustedTime = Files.getLastModifiedTime(core);
            Files.writeString(core, "BBBB");
            Files.setLastModifiedTime(core, trustedTime);

            monitor.runFullScan();

            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("file hash changed"));
            assertTrue(monitor.loginState().message().contains("CustomSkinLoader/Core/core.jar"));
        }
    }

    @Test
    void strictCustomSkinLoaderRootRejectsUndeclaredPluginAndExtraListCreation() throws Exception {
        for (String relative : new String[] {
                "CustomSkinLoader/Plugins/injected.jar",
                "CustomSkinLoader/ExtraList/injected.json"
        }) {
            Path root = temporary.resolve(relative.contains("Plugins") ? "plugin" : "extra-list");
            try (ClientIntegrityMonitor monitor = initializedMonitor(root)) {
                assertTrue(monitor.isImmediateStrictViolation(Path.of(relative)));
                assertFalse(monitor.isImmediateStrictViolation(Path.of("CustomSkinLoader/Core/core.jar")));
                assertFalse(monitor.isImmediateStrictViolation(Path.of("CustomSkinLoader/LocalSkin/player.png")));
                assertFalse(monitor.isImmediateStrictViolation(Path.of("CustomSkinLoader/caches/profile.json")));
                assertFalse(monitor.isImmediateStrictViolation(Path.of("CustomSkinLoader/ProfileCache/player.json")));

                Path injected = root.resolve(relative);
                Files.createDirectories(injected.getParent());
                Files.writeString(injected, "unmanaged runtime content");
                monitor.handleChangedPath(injected, System.nanoTime());

                assertFalse(monitor.loginState().clean());
                assertTrue(monitor.loginState().message().contains("Managed loadable content changed"));
                assertTrue(monitor.loginState().message().contains(relative));
                Files.delete(injected);
                assertFalse(monitor.loginState().clean(), "removing observed content must not restore clean state");
            }
        }
    }

    @Test
    void loadedBootstrapRequiresAFileBearingCoreBaseline() throws Exception {
        Path missing = temporary.resolve("missing");
        Files.createDirectories(missing);
        FabricCacheVerifier optional = new FabricCacheVerifier(missing, false);
        assertFalse(optional.capture().rootsByKey()
                .get(StrictManifest.key(FabricCacheVerifier.CUSTOM_SKIN_LOADER_CORE_ROOT))
                .present());

        FabricCacheVerifier requiredMissing = new FabricCacheVerifier(missing, true);
        IntegrityException missingFailure = assertThrows(IntegrityException.class, requiredMissing::capture);
        assertTrue(missingFailure.getMessage().contains("did not appear"));

        Path empty = temporary.resolve("empty");
        Files.createDirectories(empty.resolve("CustomSkinLoader/Core"));
        FabricCacheVerifier requiredEmpty = new FabricCacheVerifier(empty, true);
        IntegrityException emptyFailure = assertThrows(IntegrityException.class, requiredEmpty::capture);
        assertTrue(emptyFailure.getMessage().contains("still empty"));
    }

    private static ClientIntegrityMonitor initializedMonitor(Path root) throws Exception {
        TestPackFixture fixture = new TestPackFixture(root);
        fixture.write("CustomSkinLoader/Core/core.jar", "AAAA");
        StrictManifest manifest = fixture.writeManifest();
        fixture.writeAttestation(manifest, NOW);
        return ClientIntegrityMonitor.initialize(
                root,
                Clock.fixed(NOW, ZoneOffset.UTC),
                GeneratedTreePins.reviewed(),
                true
        );
    }

    private static void assertCacheEventIsDirty(ClientIntegrityMonitor monitor) {
        assertFalse(monitor.loginState().clean());
        assertTrue(monitor.loginState().message().contains("generated executable cache changed"));
        assertTrue(monitor.loginState().message().contains("CustomSkinLoader/Core"));
    }
}
