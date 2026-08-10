package dev.nbidal18.packcompat;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

final class GeneratedTreePins {
    static final String EUPHORIA_TREE_SHA256 =
            "85d76c113189ad1792981aba9ae65aea145d7064525f1975fd70dc95ed14e313";
    static final String DYNAMIC_RESOURCE_CACHE_TREE_SHA256 =
            "f367d4554b75cf037acb745d4e03dc8982215cff28f7e2db77dc7c91c6bc9cc0";

    private static final GeneratedTreePins REVIEWED = new GeneratedTreePins(
            EUPHORIA_TREE_SHA256,
            DYNAMIC_RESOURCE_CACHE_TREE_SHA256
    );

    private final String euphoriaTreeSha256;
    private final String dynamicResourceCacheTreeSha256;

    private GeneratedTreePins(String euphoriaTreeSha256, String dynamicResourceCacheTreeSha256) {
        this.euphoriaTreeSha256 = euphoriaTreeSha256;
        this.dynamicResourceCacheTreeSha256 = dynamicResourceCacheTreeSha256;
    }

    static GeneratedTreePins reviewed() {
        return REVIEWED;
    }

    static GeneratedTreePins withExpectedDigests(String euphoriaTreeSha256, String dynamicResourceCacheTreeSha256) {
        return new GeneratedTreePins(euphoriaTreeSha256, dynamicResourceCacheTreeSha256);
    }

    Validation validateEuphoria(IntegrityVerifier.RegeneratedTree tree) {
        String actual = digest(
                tree.relativePrefix(),
                tree.directoriesByKey(),
                tree.filesByKey().entrySet().stream().collect(java.util.stream.Collectors.toMap(
                        Map.Entry::getKey,
                        entry -> new FileEntry(entry.getValue().relativePath(), entry.getValue().sha256())
                )),
                Set.of()
        );
        return validate("Euphoria generated shader tree", euphoriaTreeSha256, actual);
    }

    Validation validateDynamicResourceCache(FabricCacheVerifier.CacheRoot tree) {
        Map<String, FileEntry> files = tree.filesByKey().entrySet().stream().collect(
                java.util.stream.Collectors.toMap(
                        Map.Entry::getKey,
                        entry -> new FileEntry(entry.getValue().relativePath(), entry.getValue().sha256())
                )
        );
        String actual = digest(
                tree.relativeRoot(),
                tree.directoriesByKey(),
                files,
                Set.of("hash.txt")
        );
        return validate(
                "Moonlight dynamic resource cache",
                dynamicResourceCacheTreeSha256,
                actual
        );
    }

    static String digest(
            Path root,
            Map<String, Path> directoriesByKey,
            Map<String, FileEntry> filesByKey,
            Set<String> excludedRootRelativeFiles
    ) {
        List<CanonicalEntry> entries = new ArrayList<>();
        for (Path directory : directoriesByKey.values()) {
            String relative = rootRelative(root, directory);
            if (!relative.isEmpty()) {
                validateCanonicalPath(relative);
                entries.add(new CanonicalEntry(relative, 'D', "D\t" + relative + "\n"));
            }
        }
        Set<String> exclusions = new HashSet<>(excludedRootRelativeFiles);
        for (FileEntry file : filesByKey.values()) {
            String relative = rootRelative(root, file.relativePath());
            validateCanonicalPath(relative);
            if (!exclusions.remove(relative)) {
                entries.add(new CanonicalEntry(
                        relative,
                        'F',
                        "F\t" + file.sha256() + "\t" + relative + "\n"
                ));
            }
        }
        if (!exclusions.isEmpty()) {
            throw new IllegalArgumentException("Pinned-tree exclusion was not present: " + exclusions.iterator().next());
        }
        entries.sort(Comparator.comparing(CanonicalEntry::path).thenComparing(CanonicalEntry::kind));
        StringBuilder canonical = new StringBuilder();
        for (CanonicalEntry entry : entries) {
            canonical.append(entry.line());
        }
        return IntegrityFiles.sha256(canonical.toString().getBytes(StandardCharsets.UTF_8));
    }

    private static String rootRelative(Path root, Path candidate) {
        Path normalizedRoot = root.normalize();
        Path normalizedCandidate = candidate.normalize();
        if (!normalizedCandidate.startsWith(normalizedRoot)) {
            throw new IllegalArgumentException("Generated-tree entry is outside its root");
        }
        return StrictManifest.portable(normalizedRoot.relativize(normalizedCandidate));
    }

    private static void validateCanonicalPath(String relative) {
        if (relative.isEmpty()
                || relative.indexOf('\t') >= 0
                || relative.indexOf('\r') >= 0
                || relative.indexOf('\n') >= 0) {
            throw new IllegalArgumentException("Generated-tree path cannot be represented canonically");
        }
    }

    private static Validation validate(String label, String expected, String actual) {
        return expected.equals(actual)
                ? new Validation(true, "clean", actual)
                : new Validation(
                        false,
                        label + " does not match the reviewed release pin (expected "
                                + expected + ", got " + actual + ")",
                        actual
                );
    }

    record FileEntry(Path relativePath, String sha256) {
    }

    record Validation(boolean clean, String message, String actualSha256) {
    }

    private record CanonicalEntry(String path, char kind, String line) {
    }
}
