package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ClosedEmptyRootVerifierTest {
    @TempDir
    Path temporary;

    @Test
    void requiresAllThreeExistingExactlyEmptyLoadableRoots() throws Exception {
        ClosedEmptyRootVerifier verifier = new ClosedEmptyRootVerifier(temporary);
        assertFalse(verifier.verify().clean());

        for (Path relativeRoot : ClosedEmptyRootVerifier.RELATIVE_ROOTS) {
            Files.createDirectories(temporary.resolve(relativeRoot));
        }
        assertTrue(verifier.verify().clean());

        for (Path relativeRoot : ClosedEmptyRootVerifier.RELATIVE_ROOTS) {
            Path root = temporary.resolve(relativeRoot);
            Files.createDirectories(root.resolve("nested-empty-directory"));
            assertFalse(verifier.verify().clean(), relativeRoot.toString());
            Files.delete(root.resolve("nested-empty-directory"));
            Files.writeString(root.resolve("injected.zip"), "unknown loadable content");
            assertFalse(verifier.verify().clean(), relativeRoot.toString());
            Files.delete(root.resolve("injected.zip"));
            assertTrue(verifier.verify().clean(), relativeRoot.toString());
        }
    }
}
