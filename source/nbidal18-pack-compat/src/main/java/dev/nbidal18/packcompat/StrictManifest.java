package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.InvalidPathException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

final class StrictManifest {
    static final Path RELATIVE_PATH = Path.of(".nbidal18", "strict-manifest.tsv");
    static final String HEADER_NAME = "nbidal18-strict-manifest";
    static final String FORMAT_VERSION = "1";

    private static final int MAXIMUM_BYTES = 4 * 1024 * 1024;
    private static final int MAXIMUM_RECORDS = 20_000;
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");
    private static final Pattern WINDOWS_RESERVED = Pattern.compile(
            "(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\\..*)?"
    );

    private final String sha256;
    private final List<Path> strictDirectories;
    private final Map<String, FileRule> filesByKey;
    private final Map<String, Path> personalFilesByKey;
    private final Map<String, Path> runtimeFilesByKey;
    private final List<Path> runtimePrefixes;
    private final List<SeedRule> seeds;
    private final List<Path> regeneratePrefixes;

    private StrictManifest(
            String sha256,
            List<Path> strictDirectories,
            Map<String, FileRule> filesByKey,
            Map<String, Path> personalFilesByKey,
            Map<String, Path> runtimeFilesByKey,
            List<Path> runtimePrefixes,
            List<SeedRule> seeds,
            List<Path> regeneratePrefixes
    ) {
        this.sha256 = sha256;
        this.strictDirectories = List.copyOf(strictDirectories);
        this.filesByKey = Collections.unmodifiableMap(new LinkedHashMap<>(filesByKey));
        this.personalFilesByKey = Collections.unmodifiableMap(new LinkedHashMap<>(personalFilesByKey));
        this.runtimeFilesByKey = Collections.unmodifiableMap(new LinkedHashMap<>(runtimeFilesByKey));
        this.runtimePrefixes = List.copyOf(runtimePrefixes);
        this.seeds = List.copyOf(seeds);
        this.regeneratePrefixes = List.copyOf(regeneratePrefixes);
    }

    static StrictManifest load(Path gameDirectory) throws IOException, IntegrityException {
        Path manifestPath = normalizedRoot(gameDirectory).resolve(RELATIVE_PATH);
        return parse(IntegrityFiles.readRegularFile(manifestPath, MAXIMUM_BYTES));
    }

    static StrictManifest parse(byte[] content) throws IntegrityException {
        String text = decodeUtf8(content);
        String[] lines = text.split("\\n", -1);
        boolean headerSeen = false;
        int records = 0;

        List<Path> strictDirectories = new ArrayList<>();
        Map<String, FileRule> files = new LinkedHashMap<>();
        Map<String, Path> personalFiles = new LinkedHashMap<>();
        Map<String, Path> runtimeFiles = new LinkedHashMap<>();
        List<Path> runtimePrefixes = new ArrayList<>();
        List<SeedRule> seeds = new ArrayList<>();
        List<Path> regeneratePrefixes = new ArrayList<>();
        Set<String> strictKeys = new HashSet<>();
        Set<String> seedTargetKeys = new HashSet<>();
        Set<String> allFilePolicies = new HashSet<>();
        Set<String> runtimePrefixKeys = new HashSet<>();
        Set<String> regenerateKeys = new HashSet<>();

        for (int index = 0; index < lines.length; index++) {
            String line = stripCarriageReturn(lines[index]);
            if (index == 0 && line.startsWith("\uFEFF")) {
                line = line.substring(1);
            }
            if (line.isEmpty() || line.startsWith("#")) {
                continue;
            }
            records++;
            if (records > MAXIMUM_RECORDS) {
                throw invalid(index, "too many records");
            }

            String[] fields = line.split("\\t", -1);
            for (String field : fields) {
                if (field.isEmpty()) {
                    throw invalid(index, "empty fields are not allowed");
                }
            }

            if (!headerSeen) {
                if (fields.length != 2
                        || !HEADER_NAME.equals(fields[0])
                        || !FORMAT_VERSION.equals(fields[1])) {
                    throw invalid(index, "expected " + HEADER_NAME + " format " + FORMAT_VERSION);
                }
                headerSeen = true;
                continue;
            }

            switch (fields[0]) {
                case "strict-dir" -> {
                    requireFields(fields, 2, index);
                    Path path = safeRelativePath(fields[1], index);
                    String key = key(path);
                    if (key.equals(".nbidal18") || key.startsWith(".nbidal18/")) {
                        throw invalid(index, "strict directory may not contain launch-guard control data");
                    }
                    if (!strictKeys.add(key)) {
                        throw invalid(index, "duplicate strict directory " + fields[1]);
                    }
                    strictDirectories.add(path);
                }
                case "managed", "optional" -> {
                    requireFields(fields, 3, index);
                    String digest = fields[1].toLowerCase(Locale.ROOT);
                    if (!SHA256.matcher(digest).matches()) {
                        throw invalid(index, "SHA-256 must be 64 hexadecimal characters");
                    }
                    Path path = safeRelativePath(fields[2], index);
                    String key = key(path);
                    FileRule rule = new FileRule(path, digest, fields[0].equals("optional"));
                    if (!allFilePolicies.add(key) || files.putIfAbsent(key, rule) != null) {
                        throw invalid(index, "duplicate or conflicting file path " + fields[2]);
                    }
                }
                case "personal", "runtime" -> {
                    requireFields(fields, 2, index);
                    Path path = safeRelativePath(fields[1], index);
                    String key = key(path);
                    if (!allFilePolicies.add(key)) {
                        throw invalid(index, "duplicate or conflicting file path " + fields[1]);
                    }
                    (fields[0].equals("personal") ? personalFiles : runtimeFiles).put(key, path);
                }
                case "runtime-prefix" -> {
                    requireFields(fields, 2, index);
                    Path prefix = safeRelativePath(fields[1], index);
                    if (!runtimePrefixKeys.add(key(prefix))) {
                        throw invalid(index, "duplicate runtime prefix " + fields[1]);
                    }
                    runtimePrefixes.add(prefix);
                }
                case "seed" -> {
                    requireFields(fields, 3, index);
                    Path template = safeRelativePath(fields[1], index);
                    Path target = safeRelativePath(fields[2], index);
                    if (!seedTargetKeys.add(key(target))) {
                        throw invalid(index, "duplicate seed target " + fields[2]);
                    }
                    seeds.add(new SeedRule(template, target));
                }
                case "regenerate-prefix" -> {
                    requireFields(fields, 2, index);
                    Path prefix = safeRelativePath(fields[1], index);
                    if (!regenerateKeys.add(key(prefix))) {
                        throw invalid(index, "duplicate regenerate prefix " + fields[1]);
                    }
                    regeneratePrefixes.add(prefix);
                }
                default -> throw invalid(index, "unknown record type " + fields[0]);
            }
        }

        if (!headerSeen) {
            throw new IntegrityException("The strict manifest header is missing");
        }
        validateRelationships(
                strictDirectories,
                files,
                personalFiles,
                runtimeFiles,
                runtimePrefixes,
                seeds,
                regeneratePrefixes,
                allFilePolicies
        );
        return new StrictManifest(
                IntegrityFiles.sha256(content),
                strictDirectories,
                files,
                personalFiles,
                runtimeFiles,
                runtimePrefixes,
                seeds,
                regeneratePrefixes
        );
    }

    private static void validateRelationships(
            List<Path> strictDirectories,
            Map<String, FileRule> files,
            Map<String, Path> personalFiles,
            Map<String, Path> runtimeFiles,
            List<Path> runtimePrefixes,
            List<SeedRule> seeds,
            List<Path> regeneratePrefixes,
            Set<String> allFilePolicies
    ) throws IntegrityException {
        if (strictDirectories.isEmpty()) {
            throw new IntegrityException("The strict manifest declares no strict directories");
        }
        if (files.isEmpty()) {
            throw new IntegrityException("The strict manifest declares no managed or optional files");
        }

        for (int left = 0; left < strictDirectories.size(); left++) {
            for (int right = left + 1; right < strictDirectories.size(); right++) {
                if (within(strictDirectories.get(left), strictDirectories.get(right))
                        || within(strictDirectories.get(right), strictDirectories.get(left))) {
                    throw new IntegrityException("Strict directories may not overlap: "
                            + portable(strictDirectories.get(left)) + " and "
                            + portable(strictDirectories.get(right)));
                }
            }
        }

        Set<String> seedTemplateKeys = new HashSet<>();
        for (SeedRule seed : seeds) {
            FileRule template = files.get(key(seed.template()));
            if (template == null || template.optional()) {
                throw new IntegrityException("Seed template has no managed hash: " + portable(seed.template()));
            }
            if (allFilePolicies.contains(key(seed.target()))) {
                throw new IntegrityException("Seed target conflicts with another file policy: "
                        + portable(seed.target()));
            }
            seedTemplateKeys.add(key(seed.template()));
        }

        for (FileRule rule : files.values()) {
            boolean strictContent = strictlyWithinAny(rule.relativePath(), strictDirectories);
            if (rule.optional() && !strictContent) {
                throw new IntegrityException("Optional path is outside every strict directory: "
                        + portable(rule.relativePath()));
            }
            if (!rule.optional() && !strictContent && !seedTemplateKeys.contains(key(rule.relativePath()))) {
                throw new IntegrityException("Managed path is neither strict content nor a seed template: "
                        + portable(rule.relativePath()));
            }
        }
        for (Path path : personalFiles.values()) {
            if (!strictlyWithinAny(path, strictDirectories)) {
                throw new IntegrityException("Personal path is outside every strict directory: " + portable(path));
            }
        }
        for (Path path : runtimeFiles.values()) {
            if (!strictlyWithinAny(path, strictDirectories)) {
                throw new IntegrityException("Runtime path is outside every strict directory: " + portable(path));
            }
        }

        for (int left = 0; left < runtimePrefixes.size(); left++) {
            Path prefix = runtimePrefixes.get(left);
            if (!strictlyWithinAny(prefix, strictDirectories)) {
                throw new IntegrityException("Runtime prefix is outside every strict directory: " + portable(prefix));
            }
            for (int right = left + 1; right < runtimePrefixes.size(); right++) {
                if (withinOrEqual(prefix, runtimePrefixes.get(right))
                        || withinOrEqual(runtimePrefixes.get(right), prefix)) {
                    throw new IntegrityException("Runtime prefixes may not overlap");
                }
            }
            for (String fileKey : allFilePolicies) {
                if (fileKey.equals(key(prefix)) || fileKey.startsWith(key(prefix) + "/")) {
                    throw new IntegrityException("Runtime prefix contains a separate file policy: "
                            + portable(prefix));
                }
            }
        }

        for (int left = 0; left < regeneratePrefixes.size(); left++) {
            Path prefix = regeneratePrefixes.get(left);
            if (!strictlyWithinAny(prefix, strictDirectories)) {
                throw new IntegrityException("Regenerate prefix is outside every strict directory: "
                        + portable(prefix));
            }
            for (FileRule rule : files.values()) {
                if (withinOrEqual(prefix, rule.relativePath())) {
                    throw new IntegrityException("Managed path overlaps regenerate prefix: "
                            + portable(rule.relativePath()));
                }
            }
            for (String fileKey : allFilePolicies) {
                String prefixKey = key(prefix);
                if (fileKey.equals(prefixKey) || fileKey.startsWith(prefixKey + "/")) {
                    throw new IntegrityException("File policy overlaps regenerate prefix: "
                            + portable(prefix));
                }
            }
            for (Path runtimePrefix : runtimePrefixes) {
                if (withinOrEqual(prefix, runtimePrefix) || withinOrEqual(runtimePrefix, prefix)) {
                    throw new IntegrityException("Regenerate prefix overlaps runtime prefix");
                }
            }
            for (int right = left + 1; right < regeneratePrefixes.size(); right++) {
                if (within(prefix, regeneratePrefixes.get(right))
                        || within(regeneratePrefixes.get(right), prefix)) {
                    throw new IntegrityException("Regenerate prefixes may not overlap: "
                            + portable(prefix) + " and " + portable(regeneratePrefixes.get(right)));
                }
            }
        }

    }

    static Path safeRelativePath(String raw, int zeroBasedLine) throws IntegrityException {
        if (!raw.equals(raw.strip()) || raw.indexOf('\\') >= 0 || raw.indexOf('\0') >= 0) {
            throw invalid(zeroBasedLine, "path is not in canonical forward-slash form: " + raw);
        }
        String[] segments = raw.split("/", -1);
        if (segments.length == 0) {
            throw invalid(zeroBasedLine, "path is empty");
        }
        for (String segment : segments) {
            if (segment.isEmpty() || segment.equals(".") || segment.equals("..")) {
                throw invalid(zeroBasedLine, "path contains an empty or dot segment: " + raw);
            }
            if (segment.endsWith(".") || segment.endsWith(" ")
                    || segment.chars().anyMatch(character -> character < 0x20)
                    || containsWindowsInvalidCharacter(segment)
                    || WINDOWS_RESERVED.matcher(segment).matches()) {
                throw invalid(zeroBasedLine, "path is unsafe on Windows: " + raw);
            }
        }

        try {
            Path path = Path.of(raw);
            if (path.isAbsolute() || path.getRoot() != null || !portable(path).equals(raw)) {
                throw invalid(zeroBasedLine, "path is not a canonical relative path: " + raw);
            }
            return path;
        } catch (InvalidPathException invalidPath) {
            throw new IntegrityException("Invalid path on line " + (zeroBasedLine + 1) + ": " + raw, invalidPath);
        }
    }

    private static boolean containsWindowsInvalidCharacter(String segment) {
        return segment.indexOf('<') >= 0
                || segment.indexOf('>') >= 0
                || segment.indexOf(':') >= 0
                || segment.indexOf('"') >= 0
                || segment.indexOf('|') >= 0
                || segment.indexOf('?') >= 0
                || segment.indexOf('*') >= 0;
    }

    private static boolean strictlyWithinAny(Path path, List<Path> directories) {
        return directories.stream().anyMatch(directory -> within(path, directory));
    }

    private static boolean withinAny(Path path, List<Path> directories) {
        String pathKey = key(path);
        return directories.stream().anyMatch(directory -> {
            String directoryKey = key(directory);
            return pathKey.equals(directoryKey) || pathKey.startsWith(directoryKey + "/");
        });
    }

    static boolean within(Path child, Path parent) {
        String childKey = key(child);
        String parentKey = key(parent);
        return childKey.startsWith(parentKey + "/");
    }

    static boolean withinOrEqual(Path parent, Path candidate) {
        String parentKey = key(parent);
        String candidateKey = key(candidate);
        return candidateKey.equals(parentKey) || candidateKey.startsWith(parentKey + "/");
    }

    static String key(Path relativePath) {
        return portable(relativePath).toLowerCase(Locale.ROOT);
    }

    static String portable(Path path) {
        return path.toString().replace('\\', '/');
    }

    static Path normalizedRoot(Path gameDirectory) throws IntegrityException {
        if (gameDirectory == null) {
            throw new IntegrityException("The game directory is unavailable");
        }
        return gameDirectory.toAbsolutePath().normalize();
    }

    private static String decodeUtf8(byte[] content) throws IntegrityException {
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(content))
                    .toString();
        } catch (CharacterCodingException malformedUtf8) {
            throw new IntegrityException("The strict manifest is not valid UTF-8", malformedUtf8);
        }
    }

    private static String stripCarriageReturn(String line) {
        return line.endsWith("\r") ? line.substring(0, line.length() - 1) : line;
    }

    private static void requireFields(String[] fields, int expected, int zeroBasedLine)
            throws IntegrityException {
        if (fields.length != expected) {
            throw invalid(zeroBasedLine, fields[0] + " requires " + expected + " fields");
        }
    }

    private static IntegrityException invalid(int zeroBasedLine, String reason) {
        return new IntegrityException("Invalid strict manifest line " + (zeroBasedLine + 1) + ": " + reason);
    }

    String sha256() {
        return sha256;
    }

    List<Path> strictDirectories() {
        return strictDirectories;
    }

    Map<String, FileRule> filesByKey() {
        return filesByKey;
    }

    Map<String, Path> personalFilesByKey() {
        return personalFilesByKey;
    }

    Map<String, Path> runtimeFilesByKey() {
        return runtimeFilesByKey;
    }

    List<Path> runtimePrefixes() {
        return runtimePrefixes;
    }

    List<SeedRule> seeds() {
        return seeds;
    }

    List<Path> regeneratePrefixes() {
        return regeneratePrefixes;
    }

    record FileRule(Path relativePath, String sha256, boolean optional) {
    }

    record SeedRule(Path template, Path target) {
    }
}
