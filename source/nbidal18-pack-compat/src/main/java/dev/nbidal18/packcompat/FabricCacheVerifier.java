package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.FileTime;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

final class FabricCacheVerifier {
    static final List<Path> RELATIVE_ROOTS = List.of(
            Path.of(".fabric", "processedMods"),
            Path.of(".fabric", "remappedJars")
    );

    private static final int MAXIMUM_NODES_PER_ROOT = 100_000;

    private final Path gameDirectory;

    FabricCacheVerifier(Path gameDirectory) throws IntegrityException {
        this.gameDirectory = StrictManifest.normalizedRoot(gameDirectory);
    }

    CacheBaseline capture() throws IOException, IntegrityException {
        Map<String, CacheRoot> roots = new LinkedHashMap<>();
        for (Path relativeRoot : RELATIVE_ROOTS) {
            CacheRoot root = inspectRoot(relativeRoot, true);
            roots.put(StrictManifest.key(relativeRoot), root);
        }
        return new CacheBaseline(roots);
    }

    CacheRoot captureRequiredNonEmptyRoot(Path relativeRoot) throws IOException, IntegrityException {
        CacheRoot captured = inspectRoot(relativeRoot, true);
        if (!captured.present()) {
            throw new IntegrityException("Generated cache root did not appear: "
                    + StrictManifest.portable(relativeRoot));
        }
        if (captured.filesByKey().isEmpty()) {
            throw new IntegrityException("Generated cache root is still empty: "
                    + StrictManifest.portable(relativeRoot));
        }
        return captured;
    }

    VerificationResult verifyRootMetadata(CacheRoot baseline) {
        return verifyRoot(baseline, false);
    }

    VerificationResult verifyRootFull(CacheRoot baseline) {
        return verifyRoot(baseline, true);
    }

    VerificationResult verifyMetadata(CacheBaseline baseline) {
        return verify(baseline, false);
    }

    VerificationResult verifyFull(CacheBaseline baseline) {
        return verify(baseline, true);
    }

    boolean contains(Path relative) {
        for (Path root : RELATIVE_ROOTS) {
            if (StrictManifest.withinOrEqual(root, relative)) {
                return true;
            }
        }
        return false;
    }

    private VerificationResult verify(CacheBaseline baseline, boolean hashFiles) {
        try {
            for (Path relativeRoot : RELATIVE_ROOTS) {
                String rootKey = StrictManifest.key(relativeRoot);
                CacheRoot expected = baseline.rootsByKey().get(rootKey);
                if (expected == null) {
                    return VerificationResult.failure("Fabric cache baseline is incomplete");
                }
                CacheRoot actual = inspectRoot(relativeRoot, hashFiles);
                String difference = compare(expected, actual, hashFiles);
                if (difference != null) {
                    return VerificationResult.failure(difference);
                }
            }
            return VerificationResult.success();
        } catch (IOException | IntegrityException failure) {
            String message = failure.getMessage();
            return VerificationResult.failure(
                    message == null || message.isBlank() ? "Fabric generated-cache verification failed" : message
            );
        }
    }

    private VerificationResult verifyRoot(CacheRoot baseline, boolean hashFiles) {
        try {
            CacheRoot actual = inspectRoot(baseline.relativeRoot(), hashFiles);
            String difference = compare(baseline, actual, hashFiles);
            return difference == null
                    ? VerificationResult.success()
                    : VerificationResult.failure(difference);
        } catch (IOException | IntegrityException failure) {
            String message = failure.getMessage();
            return VerificationResult.failure(
                    message == null || message.isBlank() ? "Generated-cache verification failed" : message
            );
        }
    }

    private CacheRoot inspectRoot(Path relativeRoot, boolean hashFiles)
            throws IOException, IntegrityException {
        ensureNoLinkedParent(relativeRoot);
        Path absoluteRoot = resolve(relativeRoot);
        if (!Files.exists(absoluteRoot, LinkOption.NOFOLLOW_LINKS)) {
            return CacheRoot.missing(relativeRoot);
        }
        BasicFileAttributes rootAttributes = readAttributes(absoluteRoot);
        if (!rootAttributes.isDirectory() || IntegrityFiles.isLinkOrReparse(absoluteRoot, rootAttributes)) {
            throw new IntegrityException("Fabric generated-cache root is not a plain directory: "
                    + StrictManifest.portable(relativeRoot));
        }

        Map<String, Path> directories = new LinkedHashMap<>();
        Map<String, CachedFile> files = new LinkedHashMap<>();
        int[] nodeCount = {0};
        Files.walkFileTree(absoluteRoot, new SimpleFileVisitor<>() {
            @Override
            public FileVisitResult preVisitDirectory(Path directory, BasicFileAttributes attributes)
                    throws IOException {
                countNode(nodeCount, relativeRoot);
                if (IntegrityFiles.isLinkOrReparse(directory, attributes)) {
                    throw new CacheVerificationFailure("Unsafe directory in Fabric generated cache: "
                            + display(directory));
                }
                Path relative = relative(directory);
                if (directories.putIfAbsent(StrictManifest.key(relative), relative) != null) {
                    throw new CacheVerificationFailure("Case-conflicting directory in Fabric generated cache: "
                            + StrictManifest.portable(relative));
                }
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attributes) throws IOException {
                countNode(nodeCount, relativeRoot);
                if (!attributes.isRegularFile() || IntegrityFiles.isLinkOrReparse(file, attributes)) {
                    throw new CacheVerificationFailure("Unsafe node in Fabric generated cache: " + display(file));
                }
                Path relative = relative(file);
                String key = StrictManifest.key(relative);
                BasicFileAttributes before = readAttributes(file);
                String sha256 = hashFiles ? IntegrityFiles.sha256(file) : "";
                BasicFileAttributes after = readAttributes(file);
                if (!stable(before, after)) {
                    throw new CacheVerificationFailure("Fabric generated-cache file changed during verification: "
                            + StrictManifest.portable(relative));
                }
                if (files.putIfAbsent(key, new CachedFile(
                        relative,
                        after.size(),
                        after.lastModifiedTime(),
                        fileKey(after),
                        sha256
                )) != null) {
                    throw new CacheVerificationFailure("Case-conflicting file in Fabric generated cache: "
                            + StrictManifest.portable(relative));
                }
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFileFailed(Path file, IOException failure) throws IOException {
                throw new CacheVerificationFailure("Could not inspect Fabric generated-cache path: "
                        + display(file), failure);
            }
        });
        return new CacheRoot(relativeRoot, true, directories, files);
    }

    private static String compare(CacheRoot expected, CacheRoot actual, boolean compareHashes) {
        String root = StrictManifest.portable(expected.relativeRoot());
        if (expected.present() != actual.present()) {
            return "Fabric generated-cache root presence changed: " + root;
        }
        if (!expected.present()) {
            return null;
        }
        if (!expected.directoriesByKey().keySet().equals(actual.directoriesByKey().keySet())) {
            return "Fabric generated-cache directory set changed: " + root;
        }
        if (!expected.filesByKey().keySet().equals(actual.filesByKey().keySet())) {
            return "Fabric generated-cache file set changed: " + root;
        }
        for (Map.Entry<String, CachedFile> entry : expected.filesByKey().entrySet()) {
            CachedFile expectedFile = entry.getValue();
            CachedFile actualFile = actual.filesByKey().get(entry.getKey());
            if (expectedFile.size() != actualFile.size()
                    || !expectedFile.lastModified().equals(actualFile.lastModified())
                    || !expectedFile.fileKey().equals(actualFile.fileKey())) {
                return "Fabric generated-cache file metadata changed: "
                        + StrictManifest.portable(expectedFile.relativePath());
            }
            if (compareHashes && !expectedFile.sha256().equals(actualFile.sha256())) {
                return "Fabric generated-cache file hash changed: "
                        + StrictManifest.portable(expectedFile.relativePath());
            }
        }
        return null;
    }

    private void ensureNoLinkedParent(Path relative) throws IOException, IntegrityException {
        Path cursor = gameDirectory;
        for (Path segment : relative) {
            cursor = cursor.resolve(segment);
            if (!Files.exists(cursor, LinkOption.NOFOLLOW_LINKS)) {
                return;
            }
            BasicFileAttributes attributes = readAttributes(cursor);
            if (IntegrityFiles.isLinkOrReparse(cursor, attributes)) {
                throw new IntegrityException("Unsafe link or reparse point in Fabric generated-cache path: "
                        + display(cursor));
            }
        }
    }

    private Path resolve(Path relative) throws IntegrityException {
        Path result = gameDirectory.resolve(relative).normalize();
        if (!result.startsWith(gameDirectory)) {
            throw new IntegrityException("Fabric generated-cache path escaped the game directory");
        }
        return result;
    }

    private Path relative(Path absolute) throws CacheVerificationFailure {
        Path normalized = absolute.toAbsolutePath().normalize();
        if (!normalized.startsWith(gameDirectory)) {
            throw new CacheVerificationFailure("Fabric generated-cache path escaped the game directory");
        }
        return gameDirectory.relativize(normalized);
    }

    private String display(Path absolute) {
        try {
            return StrictManifest.portable(relative(absolute));
        } catch (CacheVerificationFailure outside) {
            return absolute.getFileName() == null ? "<unknown>" : absolute.getFileName().toString();
        }
    }

    private static void countNode(int[] count, Path root) throws CacheVerificationFailure {
        count[0]++;
        if (count[0] > MAXIMUM_NODES_PER_ROOT) {
            throw new CacheVerificationFailure("Fabric generated cache contains too many nodes: "
                    + StrictManifest.portable(root));
        }
    }

    private static BasicFileAttributes readAttributes(Path path) throws IOException {
        return Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
    }

    private static boolean stable(BasicFileAttributes before, BasicFileAttributes after) {
        return before.size() == after.size()
                && before.lastModifiedTime().equals(after.lastModifiedTime())
                && fileKey(before).equals(fileKey(after));
    }

    private static String fileKey(BasicFileAttributes attributes) {
        return attributes.fileKey() == null ? "" : attributes.fileKey().toString();
    }

    record CacheBaseline(Map<String, CacheRoot> rootsByKey) {
        CacheBaseline {
            rootsByKey = Collections.unmodifiableMap(new LinkedHashMap<>(rootsByKey));
        }
    }

    record CacheRoot(
            Path relativeRoot,
            boolean present,
            Map<String, Path> directoriesByKey,
            Map<String, CachedFile> filesByKey
    ) {
        CacheRoot {
            directoriesByKey = Collections.unmodifiableMap(new LinkedHashMap<>(directoriesByKey));
            filesByKey = Collections.unmodifiableMap(new LinkedHashMap<>(filesByKey));
        }

        static CacheRoot missing(Path relativeRoot) {
            return new CacheRoot(relativeRoot, false, Map.of(), Map.of());
        }
    }

    record CachedFile(
            Path relativePath,
            long size,
            FileTime lastModified,
            String fileKey,
            String sha256
    ) {
    }

    record VerificationResult(boolean clean, String message) {
        static VerificationResult success() {
            return new VerificationResult(true, "clean");
        }

        static VerificationResult failure(String message) {
            return new VerificationResult(false, message);
        }
    }

    private static final class CacheVerificationFailure extends IOException {
        CacheVerificationFailure(String message) {
            super(message);
        }

        CacheVerificationFailure(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
