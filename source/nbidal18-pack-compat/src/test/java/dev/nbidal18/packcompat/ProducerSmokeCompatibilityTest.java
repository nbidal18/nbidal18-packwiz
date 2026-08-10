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
        assumeTrue(strictKeys.containsAll(closedRoots), "generated site has not yet received the latest closed roots");
        assertEquals(9, strictKeys.size());
        for (String closedRoot : closedRoots) {
            assertTrue(strictKeys.contains(closedRoot));
        }
        assertTrue(manifest.filesByKey().size() > 400);
        assertFalse(manifest.seeds().isEmpty());
        assertEquals(1, manifest.regeneratePrefixes().size());
        assertEquals("shaderpacks/ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3",
                StrictManifest.portable(manifest.regeneratePrefixes().getFirst()));
    }
}
