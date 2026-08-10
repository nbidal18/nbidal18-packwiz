package dev.nbidal18.packcompat;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class FabricCacheVerifierTest {
    @TempDir
    Path temporary;

    private FabricCacheVerifier verifier;

    @BeforeEach
    void prepare() throws Exception {
        verifier = new FabricCacheVerifier(temporary);
    }

    @Test
    void capturesExistingAndMissingRootsWithoutFalseDirty() throws Exception {
        write(".fabric/processedMods/nested/processed.jar", "trusted processed mod");
        Files.createDirectories(resolve(".fabric/remappedJars"));

        FabricCacheVerifier.CacheBaseline baseline = verifier.capture();

        assertTrue(verifier.verifyMetadata(baseline).clean());
        assertTrue(verifier.verifyFull(baseline).clean());
        assertTrue(baseline.rootsByKey().get(".fabric/processedmods").present());
        assertTrue(baseline.rootsByKey().get(".fabric/remappedjars").present());
    }

    @Test
    void fullVerificationDetectsSameSizeMutationEvenWithRestoredTimestamp() throws Exception {
        Path cached = write(".fabric/processedMods/processed.jar", "AAAA");
        FabricCacheVerifier.CacheBaseline baseline = verifier.capture();
        FileTime originalTime = Files.getLastModifiedTime(cached);

        Files.writeString(cached, "BBBB", StandardCharsets.UTF_8);
        Files.setLastModifiedTime(cached, originalTime);

        assertFalse(verifier.verifyFull(baseline).clean());
    }

    @Test
    void detectsDeletionAndAddition() throws Exception {
        Path cached = write(".fabric/processedMods/processed.jar", "trusted");
        Files.createDirectories(resolve(".fabric/remappedJars"));
        FabricCacheVerifier.CacheBaseline baseline = verifier.capture();

        Files.delete(cached);
        assertFalse(verifier.verifyMetadata(baseline).clean());

        write(".fabric/processedMods/processed.jar", "trusted");
        FabricCacheVerifier.CacheBaseline restored = verifier.capture();
        write(".fabric/remappedJars/injected.jar", "unknown cached code");
        assertFalse(verifier.verifyMetadata(restored).clean());
        assertFalse(verifier.verifyFull(restored).clean());
    }

    @Test
    void missingRootMustStayMissingAndEmptyRootMustStayEmpty() throws Exception {
        FabricCacheVerifier.CacheBaseline missing = verifier.capture();
        assertTrue(verifier.verifyFull(missing).clean());

        Files.createDirectories(resolve(".fabric/processedMods"));
        assertFalse(verifier.verifyMetadata(missing).clean());

        FabricCacheVerifier.CacheBaseline empty = verifier.capture();
        assertTrue(verifier.verifyFull(empty).clean());
        Files.createDirectories(resolve(".fabric/processedMods/empty-extra-directory"));
        assertFalse(verifier.verifyMetadata(empty).clean());
    }

    @Test
    void dynamicResourceCacheCapturesOnceAndDetectsSameSizeMutation() throws Exception {
        Path cached = write("dynamic-resource-pack-cache/assets/generated.bin", "AAAA");
        write("dynamic-resource-pack-cache/hash.txt", "trusted metadata");

        FabricCacheVerifier.CacheRoot baseline = verifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        );
        assertTrue(verifier.verifyRootMetadata(baseline).clean());
        assertTrue(verifier.verifyRootFull(baseline).clean());

        FileTime originalTime = Files.getLastModifiedTime(cached);
        Files.writeString(cached, "BBBB", StandardCharsets.UTF_8);
        Files.setLastModifiedTime(cached, originalTime);
        assertFalse(verifier.verifyRootFull(baseline).clean());
    }

    @Test
    void dynamicResourceCacheDetectsAdditionDeletionAndIncompleteCapture() throws Exception {
        Files.createDirectories(resolve("dynamic-resource-pack-cache"));
        assertThrows(IntegrityException.class, () -> verifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        ));

        Path cached = write("dynamic-resource-pack-cache/generated.zip", "trusted");
        FabricCacheVerifier.CacheRoot deletionBaseline = verifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        );
        Files.delete(cached);
        assertFalse(verifier.verifyRootMetadata(deletionBaseline).clean());

        write("dynamic-resource-pack-cache/generated.zip", "trusted");
        FabricCacheVerifier.CacheRoot additionBaseline = verifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        );
        write("dynamic-resource-pack-cache/injected.zip", "unknown cached resource pack");
        assertFalse(verifier.verifyRootMetadata(additionBaseline).clean());
        assertFalse(verifier.verifyRootFull(additionBaseline).clean());
    }

    @Test
    void dynamicCanonicalPinExcludesOnlyTheRootFingerprint() throws Exception {
        write("dynamic-resource-pack-cache/assets/example.json", "{\"trusted\":true}");
        write("dynamic-resource-pack-cache/hash.txt", "first Moonlight fingerprint");
        FabricCacheVerifier.CacheRoot first = verifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        );
        String firstDigest = GeneratedTreePins.reviewed().validateDynamicResourceCache(first).actualSha256();

        write("dynamic-resource-pack-cache/hash.txt", "different companion-version fingerprint");
        FabricCacheVerifier.CacheRoot second = verifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        );
        String secondDigest = GeneratedTreePins.reviewed().validateDynamicResourceCache(second).actualSha256();
        assertTrue(firstDigest.equals(secondDigest));

        write("dynamic-resource-pack-cache/assets/example.json", "{\"trusted\":false}");
        FabricCacheVerifier.CacheRoot changedPayload = verifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        );
        assertFalse(firstDigest.equals(
                GeneratedTreePins.reviewed().validateDynamicResourceCache(changedPayload).actualSha256()
        ));
    }

    private Path write(String relative, String content) throws Exception {
        Path path = resolve(relative);
        Files.createDirectories(path.getParent());
        Files.writeString(path, content, StandardCharsets.UTF_8);
        return path;
    }

    private Path resolve(String relative) {
        return temporary.resolve(relative.replace('/', java.io.File.separatorChar));
    }
}
