package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.FileTime;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

final class IntegrityVerifier {
    private static final int MAXIMUM_REGENERATED_FILES = 20_000;
    private static final Set<String> RUNTIME_MONITORED_STRICT_DIRECTORIES = Set.of(
            "mods",
            "resourcepacks",
            "shaderpacks",
            "datapacks",
            "defaultconfigs"
    );

    private final Path gameDirectory;

    IntegrityVerifier(Path gameDirectory) throws IntegrityException {
        this.gameDirectory = StrictManifest.normalizedRoot(gameDirectory);
    }

    VerificationResult verifyFull(
            StrictManifest manifest,
            Map<String, RegeneratedTree> regeneratedTrees,
            boolean allowUncapturedRegeneration
    ) {
        try {
            return inspect(
                    manifest,
                    regeneratedTrees,
                    allowUncapturedRegeneration,
                    null,
                    Set.of(),
                    InspectMode.FULL
            );
        } catch (IOException | IntegrityException failure) {
            return VerificationResult.failure(safeMessage(failure));
        }
    }

    VerificationResult verifyIncremental(
            StrictManifest manifest,
            Map<String, RegeneratedTree> regeneratedTrees,
            boolean allowUncapturedRegeneration,
            Map<String, FileFingerprint> baseline,
            Set<String> forcedHashKeys
    ) {
        try {
            return inspect(
                    manifest,
                    regeneratedTrees,
                    allowUncapturedRegeneration,
                    baseline,
                    forcedHashKeys,
                    InspectMode.INCREMENTAL
            );
        } catch (IOException | IntegrityException failure) {
            return VerificationResult.failure(safeMessage(failure));
        }
    }

    MetadataResult verifyMetadata(
            StrictManifest manifest,
            Map<String, RegeneratedTree> regeneratedTrees,
            boolean allowUncapturedRegeneration,
            Map<String, FileFingerprint> baseline
    ) {
        try {
            VerificationResult result = inspect(
                    manifest,
                    regeneratedTrees,
                    allowUncapturedRegeneration,
                    baseline,
                    Set.of(),
                    InspectMode.INCREMENTAL
            );
            return new MetadataResult(
                    result.clean(),
                    result.message(),
                    result.detectedRegeneratePrefixes()
            );
        } catch (IOException | IntegrityException failure) {
            return new MetadataResult(false, safeMessage(failure), Set.of());
        }
    }

    RegeneratedTree captureRegeneratedTree(Path relativePrefix) throws IOException, IntegrityException {
        Path absolutePrefix = resolve(relativePrefix);
        BasicFileAttributes prefixAttributes = readAttributes(absolutePrefix);
        if (!prefixAttributes.isDirectory() || IntegrityFiles.isLinkOrReparse(absolutePrefix, prefixAttributes)) {
            throw new IntegrityException("Regenerated shader prefix is not a regular directory: "
                    + StrictManifest.portable(relativePrefix));
        }
        ensureNoLinkedParent(relativePrefix);

        Map<String, CapturedFile> files = new LinkedHashMap<>();
        Map<String, Path> directories = new LinkedHashMap<>();
        Files.walkFileTree(absolutePrefix, new SimpleFileVisitor<>() {
            @Override
            public FileVisitResult preVisitDirectory(Path directory, BasicFileAttributes attributes)
                    throws IOException {
                if (IntegrityFiles.isLinkOrReparse(directory, attributes)) {
                    throw new VerificationFailure("Symbolic link in regenerated shader tree: "
                            + display(directory));
                }
                Path relative = relative(directory);
                if (directories.putIfAbsent(StrictManifest.key(relative), relative) != null) {
                    throw new VerificationFailure("Case-conflicting directory in regenerated shader tree: "
                            + StrictManifest.portable(relative));
                }
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attributes) throws IOException {
                if (!attributes.isRegularFile() || IntegrityFiles.isLinkOrReparse(file, attributes)) {
                    throw new VerificationFailure("Unsupported node in regenerated shader tree: "
                            + display(file));
                }
                if (files.size() >= MAXIMUM_REGENERATED_FILES) {
                    throw new VerificationFailure("Regenerated shader tree contains too many files");
                }
                Path relative = relative(file);
                BasicFileAttributes before = readAttributes(file);
                String digest = IntegrityFiles.sha256(file);
                BasicFileAttributes after = readAttributes(file);
                if (!stable(before, after)) {
                    throw new VerificationFailure("Regenerated shader file changed while being captured: "
                            + StrictManifest.portable(relative));
                }
                files.put(
                        StrictManifest.key(relative),
                        new CapturedFile(relative, digest, fingerprint(after))
                );
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFileFailed(Path file, IOException failure) throws IOException {
                throw new VerificationFailure("Could not inspect regenerated shader path: " + display(file), failure);
            }
        });
        if (files.isEmpty()) {
            throw new IntegrityException("Regenerated shader tree is empty");
        }
        return new RegeneratedTree(relativePrefix, files, directories);
    }

    private VerificationResult inspect(
            StrictManifest manifest,
            Map<String, RegeneratedTree> regeneratedTrees,
            boolean allowUncapturedRegeneration,
            Map<String, FileFingerprint> metadataBaseline,
            Set<String> forcedHashKeys,
            InspectMode mode
    ) throws IOException, IntegrityException {
        verifyManifestDigest(manifest);
        validateRegeneratedTrees(manifest, regeneratedTrees);

        Map<String, ExpectedFile> expected = new LinkedHashMap<>();
        for (Map.Entry<String, StrictManifest.FileRule> entry : manifest.filesByKey().entrySet()) {
            StrictManifest.FileRule rule = entry.getValue();
            if (!insideRuntimeMonitoredDirectory(rule.relativePath(), manifest.strictDirectories())) {
                continue;
            }
            expected.put(entry.getKey(), new ExpectedFile(
                    rule.relativePath(),
                    rule.sha256(),
                    rule.optional(),
                    false
            ));
        }

        Set<String> allowedUnhashedFiles = new HashSet<>();
        allowedUnhashedFiles.addAll(manifest.personalFilesByKey().keySet());
        allowedUnhashedFiles.addAll(manifest.runtimeFilesByKey().keySet());
        for (StrictManifest.SeedRule seed : manifest.seeds()) {
            if (insideRuntimeMonitoredDirectory(seed.target(), manifest.strictDirectories())) {
                allowedUnhashedFiles.add(StrictManifest.key(seed.target()));
            }
        }
        for (RegeneratedTree tree : regeneratedTrees.values()) {
            for (Map.Entry<String, CapturedFile> entry : tree.filesByKey().entrySet()) {
                if (expected.putIfAbsent(
                        entry.getKey(),
                        new ExpectedFile(entry.getValue().relativePath(), entry.getValue().sha256(), false, true)
                ) != null) {
                    throw new IntegrityException("Regenerated shader snapshot overlaps a managed file");
                }
            }
        }

        Map<String, FileFingerprint> observed = new LinkedHashMap<>();
        Set<String> seen = new HashSet<>();
        Set<String> seenRegenerateDirectories = new HashSet<>();
        Set<String> seenCapturedDirectories = new HashSet<>();
        Set<String> detectedRegeneratePrefixes = new LinkedHashSet<>();

        for (Path strictDirectory : manifest.strictDirectories()) {
            if (!runtimeMonitored(strictDirectory)) {
                continue;
            }
            ensureNoLinkedParent(strictDirectory);
            Path absoluteDirectory = resolve(strictDirectory);
            BasicFileAttributes rootAttributes = readAttributes(absoluteDirectory);
            if (!rootAttributes.isDirectory() || IntegrityFiles.isLinkOrReparse(absoluteDirectory, rootAttributes)) {
                throw new IntegrityException("Strict directory is missing or unsafe: "
                        + StrictManifest.portable(strictDirectory));
            }

            Files.walkFileTree(absoluteDirectory, new SimpleFileVisitor<>() {
                @Override
                public FileVisitResult preVisitDirectory(Path directory, BasicFileAttributes attributes)
                        throws IOException {
                    if (IntegrityFiles.isLinkOrReparse(directory, attributes)) {
                        throw new VerificationFailure("Symbolic link in strict directory: " + display(directory));
                    }
                    Path relative = relative(directory);
                    Path runtimePrefix = containingPrefix(relative, manifest.runtimePrefixes());
                    if (runtimePrefix != null) {
                        if (StrictManifest.key(relative).equals(StrictManifest.key(runtimePrefix))) {
                            return FileVisitResult.SKIP_SUBTREE;
                        }
                        return FileVisitResult.CONTINUE;
                    }
                    Path regeneratePrefix = containingRegeneratePrefix(relative, manifest.regeneratePrefixes());
                    if (regeneratePrefix != null
                            && StrictManifest.key(relative).equals(StrictManifest.key(regeneratePrefix))) {
                        String prefixKey = StrictManifest.key(regeneratePrefix);
                        seenRegenerateDirectories.add(prefixKey);
                        if (!regeneratedTrees.containsKey(prefixKey)) {
                            if (!allowUncapturedRegeneration) {
                                throw new VerificationFailure("Regenerated shader directory existed before launch: "
                                        + StrictManifest.portable(regeneratePrefix));
                            }
                            detectedRegeneratePrefixes.add(prefixKey);
                        }
                    }
                    if (regeneratePrefix != null) {
                        RegeneratedTree captured = regeneratedTrees.get(StrictManifest.key(regeneratePrefix));
                        if (captured != null) {
                            String directoryKey = StrictManifest.key(relative);
                            if (!captured.directoriesByKey().containsKey(directoryKey)) {
                                throw new VerificationFailure("Unexpected directory in regenerated shader tree: "
                                        + StrictManifest.portable(relative));
                            }
                            seenCapturedDirectories.add(directoryKey);
                        }
                    }
                    return FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult visitFile(Path file, BasicFileAttributes attributes) throws IOException {
                    if (!attributes.isRegularFile() || IntegrityFiles.isLinkOrReparse(file, attributes)) {
                        throw new VerificationFailure("Unsupported node in strict directory: " + display(file));
                    }

                    Path relative = relative(file);
                    Path runtimePrefix = containingPrefix(relative, manifest.runtimePrefixes());
                    if (runtimePrefix != null) {
                        if (StrictManifest.key(relative).equals(StrictManifest.key(runtimePrefix))) {
                            throw new VerificationFailure("Runtime prefix is not a directory: "
                                    + StrictManifest.portable(runtimePrefix));
                        }
                        return FileVisitResult.CONTINUE;
                    }
                    Path regeneratePrefix = containingRegeneratePrefix(relative, manifest.regeneratePrefixes());
                    if (regeneratePrefix != null
                            && !regeneratedTrees.containsKey(StrictManifest.key(regeneratePrefix))) {
                        if (!allowUncapturedRegeneration) {
                            throw new VerificationFailure("Unexpected regenerated shader content: "
                                    + StrictManifest.portable(relative));
                        }
                        detectedRegeneratePrefixes.add(StrictManifest.key(regeneratePrefix));
                        return FileVisitResult.CONTINUE;
                    }

                    String pathKey = StrictManifest.key(relative);
                    if (allowedUnhashedFiles.contains(pathKey)) {
                        return FileVisitResult.CONTINUE;
                    }
                    ExpectedFile rule = expected.get(pathKey);
                    if (rule == null) {
                        throw new VerificationFailure("Unexpected file in strict directory: "
                                + StrictManifest.portable(relative));
                    }
                    if (!seen.add(pathKey)) {
                        throw new VerificationFailure("Case-conflicting duplicate path in strict directory: "
                                + StrictManifest.portable(relative));
                    }

                    BasicFileAttributes before = readAttributes(file);
                    FileFingerprint current = fingerprint(before);
                    boolean metadataChanged = metadataBaseline != null
                            && !current.equals(metadataBaseline.get(pathKey));
                    boolean mustHash = mode == InspectMode.FULL
                            || (mode == InspectMode.INCREMENTAL
                            && (metadataChanged || forcedHashKeys.contains(pathKey)));
                    if (mode == InspectMode.INCREMENTAL && rule.regenerated() && metadataChanged) {
                        throw new VerificationFailure("Regenerated shader file metadata changed after capture: "
                                + StrictManifest.portable(relative));
                    }
                    if (mustHash) {
                        String actualSha256 = IntegrityFiles.sha256(file);
                        BasicFileAttributes after = readAttributes(file);
                        if (!stable(before, after)) {
                            throw new VerificationFailure("Managed file changed while being verified: "
                                    + StrictManifest.portable(relative));
                        }
                        if (!actualSha256.equals(rule.sha256())) {
                            throw new VerificationFailure("Managed file hash mismatch: "
                                    + StrictManifest.portable(relative));
                        }
                        current = fingerprint(after);
                    }
                    observed.put(pathKey, current);
                    return FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult visitFileFailed(Path file, IOException failure) throws IOException {
                    throw new VerificationFailure("Could not inspect strict path: " + display(file), failure);
                }
            });
        }

        for (Map.Entry<String, ExpectedFile> entry : expected.entrySet()) {
            if (!seen.contains(entry.getKey()) && !entry.getValue().optional()) {
                throw new IntegrityException("Required managed file is missing: "
                        + StrictManifest.portable(entry.getValue().relativePath()));
            }
        }
        for (Map.Entry<String, RegeneratedTree> entry : regeneratedTrees.entrySet()) {
            if (!seenRegenerateDirectories.contains(entry.getKey())) {
                throw new IntegrityException("Captured regenerated shader directory is missing: "
                        + StrictManifest.portable(entry.getValue().relativePrefix()));
            }
            if (!seenCapturedDirectories.containsAll(entry.getValue().directoriesByKey().keySet())) {
                throw new IntegrityException("Captured regenerated shader directory set changed: "
                        + StrictManifest.portable(entry.getValue().relativePrefix()));
            }
        }
        return VerificationResult.success(observed, detectedRegeneratePrefixes);
    }

    private void verifyManifestDigest(StrictManifest manifest) throws IOException, IntegrityException {
        byte[] current = IntegrityFiles.readRegularFile(
                gameDirectory.resolve(StrictManifest.RELATIVE_PATH),
                4 * 1024 * 1024
        );
        if (!IntegrityFiles.sha256(current).equals(manifest.sha256())) {
            throw new IntegrityException("The strict manifest changed after guard verification");
        }
    }

    private static void validateRegeneratedTrees(
            StrictManifest manifest,
            Map<String, RegeneratedTree> regeneratedTrees
    ) throws IntegrityException {
        Set<String> allowed = new HashSet<>();
        for (Path prefix : manifest.regeneratePrefixes()) {
            allowed.add(StrictManifest.key(prefix));
        }
        for (Map.Entry<String, RegeneratedTree> entry : regeneratedTrees.entrySet()) {
            if (!allowed.contains(entry.getKey())
                    || !entry.getKey().equals(StrictManifest.key(entry.getValue().relativePrefix()))) {
                throw new IntegrityException("Unrecognized regenerated shader snapshot");
            }
        }
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
                throw new IntegrityException("Symbolic links are not allowed in managed paths: "
                        + display(cursor));
            }
        }
    }

    private Path resolve(Path relative) throws IntegrityException {
        Path resolved = gameDirectory.resolve(relative).normalize();
        if (!resolved.startsWith(gameDirectory)) {
            throw new IntegrityException("Managed path escaped the game directory");
        }
        return resolved;
    }

    private Path relative(Path absolute) throws VerificationFailure {
        Path normalized = absolute.toAbsolutePath().normalize();
        if (!normalized.startsWith(gameDirectory)) {
            throw new VerificationFailure("Managed path escaped the game directory");
        }
        return gameDirectory.relativize(normalized);
    }

    private String display(Path absolute) {
        try {
            return StrictManifest.portable(relative(absolute));
        } catch (VerificationFailure outside) {
            return absolute.getFileName() == null ? "<unknown>" : absolute.getFileName().toString();
        }
    }

    private static Path containingRegeneratePrefix(Path relative, List<Path> prefixes) {
        return containingPrefix(relative, prefixes);
    }

    private static Path containingPrefix(Path relative, List<Path> prefixes) {
        String relativeKey = StrictManifest.key(relative);
        for (Path prefix : prefixes) {
            String prefixKey = StrictManifest.key(prefix);
            if (relativeKey.equals(prefixKey) || relativeKey.startsWith(prefixKey + "/")) {
                return prefix;
            }
        }
        return null;
    }

    static boolean runtimeMonitored(Path strictDirectory) {
        return RUNTIME_MONITORED_STRICT_DIRECTORIES.contains(StrictManifest.key(strictDirectory));
    }

    private static boolean insideRuntimeMonitoredDirectory(Path path, List<Path> strictDirectories) {
        for (Path strictDirectory : strictDirectories) {
            if (runtimeMonitored(strictDirectory)
                    && StrictManifest.within(path, strictDirectory)) {
                return true;
            }
        }
        return false;
    }

    private static BasicFileAttributes readAttributes(Path path) throws IOException {
        return Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
    }

    private static FileFingerprint fingerprint(BasicFileAttributes attributes) {
        Object fileKey = attributes.fileKey();
        return new FileFingerprint(
                attributes.size(),
                attributes.lastModifiedTime(),
                fileKey == null ? "" : fileKey.toString()
        );
    }

    private static boolean stable(BasicFileAttributes before, BasicFileAttributes after) {
        return before.size() == after.size()
                && before.lastModifiedTime().equals(after.lastModifiedTime())
                && String.valueOf(before.fileKey()).equals(String.valueOf(after.fileKey()));
    }

    private static String safeMessage(Exception failure) {
        String message = failure.getMessage();
        return message == null || message.isBlank() ? "Integrity verification failed" : message;
    }

    record FileFingerprint(long size, FileTime lastModified, String fileKey) {
    }

    record CapturedFile(Path relativePath, String sha256, FileFingerprint fingerprint) {
    }

    record RegeneratedTree(
            Path relativePrefix,
            Map<String, CapturedFile> filesByKey,
            Map<String, Path> directoriesByKey
    ) {
        RegeneratedTree {
            filesByKey = Collections.unmodifiableMap(new LinkedHashMap<>(filesByKey));
            directoriesByKey = Collections.unmodifiableMap(new LinkedHashMap<>(directoriesByKey));
        }
    }

    record VerificationResult(
            boolean clean,
            String message,
            Map<String, FileFingerprint> fingerprints,
            Set<String> detectedRegeneratePrefixes
    ) {
        static VerificationResult success(
                Map<String, FileFingerprint> fingerprints,
                Set<String> detectedRegeneratePrefixes
        ) {
            return new VerificationResult(
                    true,
                    "clean",
                    Collections.unmodifiableMap(new LinkedHashMap<>(fingerprints)),
                    Collections.unmodifiableSet(new LinkedHashSet<>(detectedRegeneratePrefixes))
            );
        }

        static VerificationResult failure(String message) {
            return new VerificationResult(false, message, Map.of(), Set.of());
        }
    }

    record MetadataResult(boolean unchanged, String message, Set<String> detectedRegeneratePrefixes) {
    }

    private record ExpectedFile(Path relativePath, String sha256, boolean optional, boolean regenerated) {
    }

    private enum InspectMode {
        FULL,
        INCREMENTAL
    }

    private static class VerificationFailure extends IOException {
        VerificationFailure(String message) {
            super(message);
        }

        VerificationFailure(String message, Throwable cause) {
            super(message, cause);
        }
    }

}
