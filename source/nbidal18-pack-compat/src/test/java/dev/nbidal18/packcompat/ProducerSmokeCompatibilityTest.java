package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

class ProducerSmokeCompatibilityTest {
    @Test
    void parsesTheCurrentGeneratedSiteManifestWhenAvailable() throws Exception {
        Path siteRoot = Path.of("..", "..", "site").toAbsolutePath().normalize();
        assumeTrue(Files.isRegularFile(siteRoot.resolve(StrictManifest.RELATIVE_PATH)));
        Path packToml = siteRoot.resolve("pack.toml");
        assumeTrue(Files.isRegularFile(packToml)
                        && Files.readString(packToml).contains("version = \"3.2.4\""),
                "generated site has not yet been rebuilt for v3.2.4");

        StrictManifest manifest = StrictManifest.load(siteRoot);

        List<String> strictKeys = manifest.strictDirectories().stream().map(StrictManifest::key).toList();
        List<String> closedRoots = List.of(
                "moonlight-global-datapacks", "villagerpacks", "server-resource-packs");
        List<String> customSkinLoaderMarkers = List.of(
                "customskinloader/plugins/nbidal18-closed.marker",
                "customskinloader/extralist/nbidal18-closed.marker"
        );
        List<String> customSkinLoaderRuntimeFiles = List.of(
                "customskinloader/customskinloader.json",
                "customskinloader/customskinloader.log",
                "customskinloader/customskinapiplus-clientid"
        );
        List<String> customSkinLoaderRuntimePrefixes = List.of(
                "customskinloader/core",
                "customskinloader/localskin",
                "customskinloader/profilecache",
                "customskinloader/caches"
        );

        assertEquals(10, strictKeys.size());
        for (String closedRoot : closedRoots) {
            assertTrue(strictKeys.contains(closedRoot));
        }
        assertTrue(strictKeys.contains("customskinloader"));
        List<String> runtimePrefixes = manifest.runtimePrefixes().stream().map(StrictManifest::key).toList();
        assertFalse(runtimePrefixes.contains("customskinloader/plugins"));
        assertFalse(runtimePrefixes.contains("customskinloader/extralist"));
        for (String runtimeFile : customSkinLoaderRuntimeFiles) {
            assertFalse(manifest.runtimeFilesByKey().containsKey(runtimeFile));
        }
        for (String runtimePrefix : customSkinLoaderRuntimePrefixes) {
            assertFalse(runtimePrefixes.contains(runtimePrefix));
        }
        for (String marker : customSkinLoaderMarkers) {
            assertFalse(manifest.filesByKey().containsKey(marker));
        }
        assertFalse(manifest.runtimeFilesByKey().keySet().stream()
                .anyMatch(key -> key.startsWith("customskinloader/")));
        assertFalse(runtimePrefixes.stream()
                .anyMatch(key -> key.equals("customskinloader") || key.startsWith("customskinloader/")));
        assertFalse(manifest.filesByKey().keySet().stream()
                .anyMatch(key -> key.startsWith("customskinloader/")));
        assertFalse(manifest.filesByKey().keySet().stream()
                .anyMatch(key -> key.startsWith("mods/customskinloader")));
        assertTrue(manifest.filesByKey().size() > 400);
        assertFalse(manifest.seeds().isEmpty());
        assertEquals(1, manifest.regeneratePrefixes().size());
        assertEquals("shaderpacks/ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3",
                StrictManifest.portable(manifest.regeneratePrefixes().getFirst()));
    }
}
