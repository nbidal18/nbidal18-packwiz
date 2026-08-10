package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class StrictManifestTest {
    private static final String HASH = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    @Test
    void parsesTheCompleteV1Schema() throws Exception {
        String manifest = "\uFEFFnbidal18-strict-manifest\t1\n"
                + "strict-dir\tmods\n"
                + "strict-dir\tconfig\n"
                + "strict-dir\tshaderpacks\n"
                + "managed\t" + HASH.toUpperCase() + "\tmods/a.jar\n"
                + "managed\t" + HASH + "\t.nbidal18/defaults/options.txt\n"
                + "managed\t" + HASH + "\tshaderpacks/a.zip\n"
                + "optional\t" + HASH + "\tmods/private.jar\n"
                + "personal\tconfig/controlify.json\n"
                + "runtime\tconfig/runtime.json\n"
                + "runtime-prefix\tconfig/cache\n"
                + "seed\t.nbidal18/defaults/options.txt\toptions.txt\n"
                + "regenerate-prefix\tshaderpacks/generated\n";

        StrictManifest parsed = StrictManifest.parse(manifest.getBytes(StandardCharsets.UTF_8));

        assertEquals(3, parsed.strictDirectories().size());
        assertEquals(4, parsed.filesByKey().size());
        assertEquals(HASH, parsed.filesByKey().get("mods/a.jar").sha256());
        assertEquals(1, parsed.personalFilesByKey().size());
        assertEquals(1, parsed.runtimeFilesByKey().size());
        assertEquals(1, parsed.runtimePrefixes().size());
        assertEquals(1, parsed.seeds().size());
        assertEquals(1, parsed.regeneratePrefixes().size());
    }

    @Test
    void rejectsUnsafeAndAmbiguousPaths() {
        for (String path : new String[]{"../evil.jar", "mods\\evil.jar", "/mods/evil.jar", "C:/evil.jar",
                "mods//evil.jar", "mods/../evil.jar", "mods/NUL.jar", "mods/trailing. "}) {
            String manifest = "nbidal18-strict-manifest\t1\n"
                    + "strict-dir\tmods\n"
                    + "managed\t" + HASH + "\t" + path + "\n";
            assertThrows(
                    IntegrityException.class,
                    () -> StrictManifest.parse(manifest.getBytes(StandardCharsets.UTF_8)),
                    path
            );
        }
    }

    @Test
    void rejectsCaseConflictsAndOverlappingPrefixes() {
        String duplicate = "nbidal18-strict-manifest\t1\n"
                + "strict-dir\tmods\n"
                + "managed\t" + HASH + "\tmods/A.jar\n"
                + "optional\t" + HASH + "\tmods/a.jar\n";
        assertThrows(IntegrityException.class, () -> StrictManifest.parse(duplicate.getBytes(StandardCharsets.UTF_8)));

        String overlapping = "nbidal18-strict-manifest\t1\n"
                + "strict-dir\tconfig\n"
                + "managed\t" + HASH + "\tconfig/a.txt\n"
                + "runtime-prefix\tconfig/cache\n"
                + "regenerate-prefix\tconfig/cache/generated\n";
        IntegrityException failure = assertThrows(
                IntegrityException.class,
                () -> StrictManifest.parse(overlapping.getBytes(StandardCharsets.UTF_8))
        );
        assertTrue(failure.getMessage().contains("overlap"));
    }
}
