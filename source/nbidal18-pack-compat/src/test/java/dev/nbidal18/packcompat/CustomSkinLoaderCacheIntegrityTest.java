package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardWatchEventKinds;
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
    void windowsParentDirectoryModifyForLegitimateRuntimeWritesRemainsClean() throws Exception {
        Path root = temporary.resolve("parent-metadata");
        try (ClientIntegrityMonitor monitor = initializedRunningMonitor(root)) {
            Path runtimeConfig = root.resolve("CustomSkinLoader/CustomSkinLoader.json");
            Files.writeString(runtimeConfig, "{\"enable\":true}");
            monitor.handleChangedPath(
                    runtimeConfig,
                    System.nanoTime(),
                    StandardWatchEventKinds.ENTRY_CREATE
            );

            Path runtimeCache = root.resolve("CustomSkinLoader/ProfileCache/player.json");
            Files.createDirectories(runtimeCache.getParent());
            monitor.handleChangedPath(
                    runtimeCache.getParent(),
                    System.nanoTime(),
                    StandardWatchEventKinds.ENTRY_CREATE
            );
            Files.writeString(runtimeCache, "runtime cache");
            monitor.handleChangedPath(
                    runtimeCache,
                    System.nanoTime(),
                    StandardWatchEventKinds.ENTRY_CREATE
            );

            monitor.runFullScan();
            assertTrue(monitor.loginState().clean(), monitor.loginState().message());

            monitor.handleChangedPath(
                    root.resolve("CustomSkinLoader"),
                    System.nanoTime(),
                    StandardWatchEventKinds.ENTRY_MODIFY
            );
            assertTrue(monitor.loginState().clean(), monitor.loginState().message());
        }
    }

    @Test
    void parentDirectoryModifyDoesNotMaskUnexpectedPluginOrExtraListChildren() throws Exception {
        for (String relative : new String[] {
                "CustomSkinLoader/Plugins/injected.jar",
                "CustomSkinLoader/ExtraList/injected.json"
        }) {
            Path root = temporary.resolve(relative.contains("Plugins") ? "parent-plugin" : "parent-extra-list");
            try (ClientIntegrityMonitor monitor = initializedRunningMonitor(root)) {
                monitor.handleChangedPath(
                        root.resolve("CustomSkinLoader"),
                        System.nanoTime(),
                        StandardWatchEventKinds.ENTRY_MODIFY
                );
                assertTrue(monitor.loginState().clean(), monitor.loginState().message());

                Path injected = root.resolve(relative);
                Files.createDirectories(injected.getParent());
                Files.writeString(injected, "unmanaged runtime content");
                monitor.handleChangedPath(
                        injected,
                        System.nanoTime(),
                        StandardWatchEventKinds.ENTRY_CREATE
                );

                assertFalse(monitor.loginState().clean());
                assertTrue(monitor.loginState().message().contains(relative));
            }
        }
    }

    @Test
    void strictRootCreateDeleteAndNonDirectoryModifyRemainStickyDirty() throws Exception {
        for (var eventKind : new java.nio.file.WatchEvent.Kind<?>[] {
                StandardWatchEventKinds.ENTRY_CREATE,
                StandardWatchEventKinds.ENTRY_DELETE
        }) {
            Path root = temporary.resolve(eventKind == StandardWatchEventKinds.ENTRY_CREATE
                    ? "root-create"
                    : "root-delete");
            try (ClientIntegrityMonitor monitor = initializedRunningMonitor(root)) {
                monitor.handleChangedPath(root.resolve("CustomSkinLoader"), System.nanoTime(), eventKind);
                assertFalse(monitor.loginState().clean());
                assertTrue(monitor.loginState().message().contains("CustomSkinLoader"));
            }
        }

        Path replacementRoot = temporary.resolve("root-replacement");
        try (ClientIntegrityMonitor monitor = initializedRunningMonitor(replacementRoot)) {
            Path customSkinLoader = replacementRoot.resolve("CustomSkinLoader");
            removeCustomSkinLoaderRoot(customSkinLoader);
            Files.writeString(customSkinLoader, "not a directory");
            monitor.handleChangedPath(
                    customSkinLoader,
                    System.nanoTime(),
                    StandardWatchEventKinds.ENTRY_MODIFY
            );
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("CustomSkinLoader"));
        }
    }

    @Test
    void strictRootReparseModifyRemainsStickyDirtyWhenLinksAreSupported() throws Exception {
        Path root = temporary.resolve("root-reparse");
        try (ClientIntegrityMonitor monitor = initializedRunningMonitor(root)) {
            Path customSkinLoader = root.resolve("CustomSkinLoader");
            removeCustomSkinLoaderRoot(customSkinLoader);
            Path target = root.resolve("outside-target");
            Files.createDirectories(target);
            try {
                Files.createSymbolicLink(customSkinLoader, target);
            } catch (UnsupportedOperationException | java.io.IOException | SecurityException unavailable) {
                Assumptions.abort("Symbolic-link creation is unavailable: " + unavailable.getMessage());
            }

            monitor.handleChangedPath(
                    customSkinLoader,
                    System.nanoTime(),
                    StandardWatchEventKinds.ENTRY_MODIFY
            );
            assertFalse(monitor.loginState().clean());
            assertTrue(monitor.loginState().message().contains("CustomSkinLoader"));
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

    private static ClientIntegrityMonitor initializedRunningMonitor(Path root) throws Exception {
        TestPackFixture fixture = new TestPackFixture(root);
        fixture.write("CustomSkinLoader/Core/core.jar", "AAAA");
        writeTinyDynamicCache(root);
        StrictManifest manifest = fixture.writeManifest();
        fixture.writeAttestation(manifest, NOW);

        FabricCacheVerifier cacheVerifier = new FabricCacheVerifier(root, true);
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
                Clock.fixed(NOW, ZoneOffset.UTC),
                pins,
                true
        );
        monitor.clientStarted();
        monitor.advanceStartupFinalization(true);
        assertTrue(monitor.loginState().clean(), monitor.loginState().message());
        return monitor;
    }

    private static void writeTinyDynamicCache(Path root) throws Exception {
        Path generated = root.resolve("dynamic-resource-pack-cache/assets/generated.json");
        Files.createDirectories(generated.getParent());
        Files.writeString(generated, "trusted generated payload");
        Files.writeString(root.resolve("dynamic-resource-pack-cache/hash.txt"), "variable fingerprint");
    }

    private static void removeCustomSkinLoaderRoot(Path customSkinLoader) throws Exception {
        Files.delete(customSkinLoader.resolve("Plugins/nbidal18-closed.marker"));
        Files.delete(customSkinLoader.resolve("Plugins"));
        Files.delete(customSkinLoader.resolve("ExtraList/nbidal18-closed.marker"));
        Files.delete(customSkinLoader.resolve("ExtraList"));
        Files.delete(customSkinLoader.resolve("Core/core.jar"));
        Files.delete(customSkinLoader.resolve("Core"));
        Files.delete(customSkinLoader);
    }

    private static void assertCacheEventIsDirty(ClientIntegrityMonitor monitor) {
        assertFalse(monitor.loginState().clean());
        assertTrue(monitor.loginState().message().contains("generated executable cache changed"));
        assertTrue(monitor.loginState().message().contains("CustomSkinLoader/Core"));
    }
}
