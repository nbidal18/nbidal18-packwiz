package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

class ReviewedGeneratedTreePinsTest {
    @Test
    void hardCodedPinsMatchTheReadOnlyReviewedReferenceTreesWhenAvailable() throws Exception {
        Path minecraft = Path.of(
                System.getProperty("user.home"),
                "AppData",
                "Roaming",
                "PrismLauncher",
                "instances",
                "nbidal18-3.1.0-client",
                "minecraft"
        );
        Path euphoria = minecraft.resolve(Path.of(
                "shaderpacks",
                "ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3"
        ));
        Path dynamic = minecraft.resolve(ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT);
        assumeTrue(Files.isDirectory(euphoria) && Files.isDirectory(dynamic));

        IntegrityVerifier integrityVerifier = new IntegrityVerifier(minecraft);
        IntegrityVerifier.RegeneratedTree euphoriaTree = integrityVerifier.captureRegeneratedTree(
                minecraft.relativize(euphoria)
        );
        GeneratedTreePins.Validation euphoriaPin = GeneratedTreePins.reviewed().validateEuphoria(euphoriaTree);
        assertTrue(euphoriaPin.clean(), euphoriaPin.message());
        assertEquals(GeneratedTreePins.EUPHORIA_TREE_SHA256, euphoriaPin.actualSha256());
        assertEquals(616, euphoriaTree.filesByKey().size());

        FabricCacheVerifier cacheVerifier = new FabricCacheVerifier(minecraft);
        FabricCacheVerifier.CacheRoot dynamicTree = cacheVerifier.captureRequiredNonEmptyRoot(
                ClientIntegrityMonitor.DYNAMIC_RESOURCE_CACHE_ROOT
        );
        GeneratedTreePins.Validation dynamicPin = GeneratedTreePins.reviewed()
                .validateDynamicResourceCache(dynamicTree);
        assertTrue(dynamicPin.clean(), dynamicPin.message());
        assertEquals(GeneratedTreePins.DYNAMIC_RESOURCE_CACHE_TREE_SHA256, dynamicPin.actualSha256());
        assertEquals(251, dynamicTree.filesByKey().size());
    }
}
