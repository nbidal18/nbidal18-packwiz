package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LaunchGuardUpdaterTest {
    @TempDir
    Path temporary;

    @Test
    void bundledGuardPassesDescriptorValidationAndInstalls() throws Exception {
        try (InputStream descriptor = LaunchGuardUpdater.class.getResourceAsStream(
                "/META-INF/nbidal18/launch-guard.tsv"
        )) {
            assertTrue(descriptor != null);
            String descriptorText = new String(descriptor.readAllBytes(), StandardCharsets.UTF_8);
            assertTrue(descriptorText.startsWith("nbidal18-launch-guard\t1\nsha256\t"));
            assertTrue(descriptorText.contains("\nsize\t"));
            assertFalse(descriptorText.contains("\\t"));
        }

        LaunchGuardUpdater.EmbeddedGuard embedded = LaunchGuardUpdater.loadEmbedded();
        assertTrue(embedded.payload().length > 0);
        assertEquals(embedded.sha256(), IntegrityFiles.sha256(embedded.payload()));

        Path gameDirectory = plainGameDirectory("bundled");
        assertEquals(
                LaunchGuardUpdater.UpdateResult.INSTALLED,
                LaunchGuardUpdater.install(gameDirectory)
        );
        assertArrayEquals(
                embedded.payload(),
                Files.readAllBytes(gameDirectory.resolve(LaunchGuardUpdater.TARGET_FILE_NAME))
        );
    }

    @Test
    void matchingTargetIsAByteAndMetadataNoOp() throws Exception {
        byte[] payload = payload("current guard");
        String sha256 = IntegrityFiles.sha256(payload);
        Path gameDirectory = plainGameDirectory("matching");
        Path target = gameDirectory.resolve(LaunchGuardUpdater.TARGET_FILE_NAME);
        Files.write(target, payload);
        Files.setLastModifiedTime(target, FileTime.fromMillis(1_700_000_000_000L));
        FileTime before = Files.getLastModifiedTime(target);

        assertEquals(
                LaunchGuardUpdater.UpdateResult.UP_TO_DATE,
                LaunchGuardUpdater.install(gameDirectory, payload, sha256)
        );
        assertArrayEquals(payload, Files.readAllBytes(target));
        assertEquals(before, Files.getLastModifiedTime(target));
        assertNoStagedFiles(gameDirectory);
    }

    @Test
    void differentPlainTargetIsAtomicallyReplaced() throws Exception {
        byte[] payload = payload("new guard");
        String sha256 = IntegrityFiles.sha256(payload);
        Path gameDirectory = plainGameDirectory("replace");
        Path target = gameDirectory.resolve(LaunchGuardUpdater.TARGET_FILE_NAME);
        Files.write(target, payload("old guard"));

        assertEquals(
                LaunchGuardUpdater.UpdateResult.REPLACED,
                LaunchGuardUpdater.install(gameDirectory, payload, sha256)
        );
        assertArrayEquals(payload, Files.readAllBytes(target));
        assertNoStagedFiles(gameDirectory);
    }

    @Test
    void badEmbeddedHashCannotTouchAnExistingGuard() throws Exception {
        Path gameDirectory = plainGameDirectory("bad-hash");
        Path target = gameDirectory.resolve(LaunchGuardUpdater.TARGET_FILE_NAME);
        byte[] old = payload("old guard");
        Files.write(target, old);

        IntegrityException failure = assertThrows(
                IntegrityException.class,
                () -> LaunchGuardUpdater.install(
                        gameDirectory,
                        payload("untrusted guard"),
                        IntegrityFiles.sha256(payload("different bytes"))
                )
        );
        assertTrue(failure.getMessage().contains("hash verification"));
        assertArrayEquals(old, Files.readAllBytes(target));
        assertNoStagedFiles(gameDirectory);
    }

    @Test
    void directoryAtTargetIsRejectedWithoutModification() throws Exception {
        byte[] payload = payload("new guard");
        Path gameDirectory = plainGameDirectory("directory-target");
        Path target = gameDirectory.resolve(LaunchGuardUpdater.TARGET_FILE_NAME);
        Files.createDirectory(target);
        Files.writeString(target.resolve("keep.txt"), "unchanged", StandardCharsets.UTF_8);

        IntegrityException failure = assertThrows(
                IntegrityException.class,
                () -> LaunchGuardUpdater.install(gameDirectory, payload, IntegrityFiles.sha256(payload))
        );
        assertTrue(failure.getMessage().contains("not a plain regular file"));
        assertEquals("unchanged", Files.readString(target.resolve("keep.txt"), StandardCharsets.UTF_8));
        assertNoStagedFiles(gameDirectory);
    }

    @Test
    void linkedTargetIsRejectedWithoutFollowingItWhenLinksAreAvailable() throws Exception {
        byte[] payload = payload("new guard");
        Path gameDirectory = plainGameDirectory("linked-target");
        Path external = temporary.resolve("external-guard.jar");
        byte[] externalBytes = payload("external guard");
        Files.write(external, externalBytes);
        Path target = gameDirectory.resolve(LaunchGuardUpdater.TARGET_FILE_NAME);
        createSymbolicLinkOrAbort(target, external);

        IntegrityException failure = assertThrows(
                IntegrityException.class,
                () -> LaunchGuardUpdater.install(gameDirectory, payload, IntegrityFiles.sha256(payload))
        );
        assertTrue(failure.getMessage().contains("not a plain regular file"));
        assertArrayEquals(externalBytes, Files.readAllBytes(external));
        assertTrue(Files.isSymbolicLink(target));
        assertNoStagedFiles(gameDirectory);
    }

    @Test
    void linkedGameDirectoryIsRejectedWhenLinksAreAvailable() throws Exception {
        byte[] payload = payload("new guard");
        Path realGameDirectory = plainGameDirectory("real-game");
        Path linkedGameDirectory = temporary.resolve("linked-game");
        createSymbolicLinkOrAbort(linkedGameDirectory, realGameDirectory);

        IntegrityException failure = assertThrows(
                IntegrityException.class,
                () -> LaunchGuardUpdater.install(
                        linkedGameDirectory,
                        payload,
                        IntegrityFiles.sha256(payload)
                )
        );
        assertTrue(failure.getMessage().contains("not a plain directory"));
        assertFalse(Files.exists(realGameDirectory.resolve(LaunchGuardUpdater.TARGET_FILE_NAME)));
    }

    private Path plainGameDirectory(String name) throws IOException {
        return Files.createDirectory(temporary.resolve(name));
    }

    private static byte[] payload(String marker) {
        return ("PK\u0003\u0004" + marker).getBytes(StandardCharsets.UTF_8);
    }

    private static void assertNoStagedFiles(Path gameDirectory) throws IOException {
        try (var children = Files.list(gameDirectory)) {
            assertFalse(children.anyMatch(path -> path.getFileName().toString()
                    .startsWith(".nbidal18-launch-guard-")));
        }
    }

    private static void createSymbolicLinkOrAbort(Path link, Path target) {
        try {
            Files.createSymbolicLink(link, target);
        } catch (UnsupportedOperationException | IOException | SecurityException unavailable) {
            Assumptions.abort("Symbolic-link creation is unavailable: " + unavailable.getMessage());
        }
    }
}
