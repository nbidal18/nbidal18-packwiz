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

        StrictManifest manifest = StrictManifest.load(siteRoot);

        List<String> strictKeys = manifest.strictDirectories().stream().map(StrictManifest::key).toList();
        List<String> closedRoots = List.of(
                "moonlight-global-datapacks", "villagerpacks", "server-resource-packs");
        assumeTrue(strictKeys.contains("customskinloader"),
                "generated site has not yet received the v3.2.0 CustomSkinLoader policy");
        assertEquals(10, strictKeys.size());
        for (String closedRoot : closedRoots) {
            assertTrue(strictKeys.contains(closedRoot));
        }
        assertTrue(strictKeys.contains("customskinloader"));

        for (String runtimeFile : List.of(
                "customskinloader/customskinloader.json",
                "customskinloader/customskinloader.log",
                "customskinloader/customskinapiplus-clientid"
        )) {
            assertTrue(manifest.runtimeFilesByKey().containsKey(runtimeFile));
        }
        List<String> runtimePrefixes = manifest.runtimePrefixes().stream().map(StrictManifest::key).toList();
        for (String runtimePrefix : List.of(
                "customskinloader/core",
                "customskinloader/localskin",
                "customskinloader/profilecache",
                "customskinloader/caches"
        )) {
            assertTrue(runtimePrefixes.contains(runtimePrefix));
        }
        assertFalse(runtimePrefixes.contains("customskinloader/plugins"));
        assertFalse(runtimePrefixes.contains("customskinloader/extralist"));
        assertTrue(manifest.filesByKey().size() > 400);
        assertFalse(manifest.seeds().isEmpty());
        assertEquals(1, manifest.regeneratePrefixes().size());
        assertEquals("shaderpacks/ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3",
                StrictManifest.portable(manifest.regeneratePrefixes().getFirst()));
    }
}
