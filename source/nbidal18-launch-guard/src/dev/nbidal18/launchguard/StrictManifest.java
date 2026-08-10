package dev.nbidal18.launchguard;

import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.InvalidPathException;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

final class StrictManifest {
    static final String RELATIVE_MANIFEST = ".nbidal18/strict-manifest.tsv";
    private static final Pattern SHA256 = Pattern.compile("[0-9a-fA-F]{64}");

    record FileRule(String relative, String key, String sha256) {}
    record SeedRule(String template, String templateKey, String target, String targetKey) {}

    final String sha256;
    final List<String> strictDirs;
    final Map<String, FileRule> managed;
    final Map<String, FileRule> optional;
    final Map<String, String> personal;
    final Map<String, String> runtime;
    final Map<String, String> runtimePrefixes;
    final List<SeedRule> seeds;
    final Map<String, String> regeneratePrefixes;

    private StrictManifest(
            String sha256,
            List<String> strictDirs,
            Map<String, FileRule> managed,
            Map<String, FileRule> optional,
            Map<String, String> personal,
            Map<String, String> runtime,
            Map<String, String> runtimePrefixes,
            List<SeedRule> seeds,
            Map<String, String> regeneratePrefixes) {
        this.sha256 = sha256;
        this.strictDirs = List.copyOf(strictDirs);
        this.managed = Map.copyOf(managed);
        this.optional = Map.copyOf(optional);
        this.personal = Map.copyOf(personal);
        this.runtime = Map.copyOf(runtime);
        this.runtimePrefixes = Map.copyOf(runtimePrefixes);
        this.seeds = List.copyOf(seeds);
        this.regeneratePrefixes = Map.copyOf(regeneratePrefixes);
    }

    static StrictManifest parse(byte[] bytes) throws GuardException {
        final String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException e) {
            throw new GuardException("Strict manifest is not valid UTF-8.", e);
        }

        List<String> strictDirs = new ArrayList<>();
        Map<String, FileRule> managed = new LinkedHashMap<>();
        Map<String, FileRule> optional = new LinkedHashMap<>();
        Map<String, String> personal = new LinkedHashMap<>();
        Map<String, String> runtime = new LinkedHashMap<>();
        Map<String, String> runtimePrefixes = new LinkedHashMap<>();
        List<SeedRule> seeds = new ArrayList<>();
        Map<String, String> regenerate = new LinkedHashMap<>();
        Set<String> seedTargets = new HashSet<>();
        Set<String> allFilePolicies = new HashSet<>();
        boolean headerSeen = false;

        String[] lines = text.split("\\r?\\n", -1);
        for (int index = 0; index < lines.length; index++) {
            String line = lines[index];
            if (index == 0 && line.startsWith("\uFEFF")) line = line.substring(1);
            if (line.isEmpty() || line.startsWith("#")) continue;
            String[] fields = line.split("\\t", -1);
            int lineNumber = index + 1;
            if (!headerSeen) {
                if (fields.length != 2 || !fields[0].equals("nbidal18-strict-manifest") || !fields[1].equals("1")) {
                    throw malformed(lineNumber, "expected `nbidal18-strict-manifest<TAB>1` header");
                }
                headerSeen = true;
                continue;
            }

            switch (fields[0]) {
                case "strict-dir" -> {
                    requireFields(fields, 2, lineNumber);
                    String relative = validateRelative(fields[1], lineNumber);
                    String key = key(relative);
                    if (key.equals(".nbidal18") || key.startsWith(".nbidal18/")) {
                        throw malformed(lineNumber, "strict-dir may not contain launch-guard control data");
                    }
                    if (strictDirs.stream().map(StrictManifest::key).anyMatch(key::equals)) {
                        throw malformed(lineNumber, "duplicate strict-dir");
                    }
                    strictDirs.add(relative);
                }
                case "managed", "optional" -> {
                    requireFields(fields, 3, lineNumber);
                    if (!SHA256.matcher(fields[1]).matches()) throw malformed(lineNumber, "invalid SHA-256");
                    String relative = validateRelative(fields[2], lineNumber);
                    String key = key(relative);
                    if (!allFilePolicies.add(key)) throw malformed(lineNumber, "conflicting or duplicate file policy");
                    FileRule rule = new FileRule(relative, key, fields[1].toLowerCase(Locale.ROOT));
                    if (fields[0].equals("managed")) managed.put(key, rule); else optional.put(key, rule);
                }
                case "personal" -> {
                    requireFields(fields, 2, lineNumber);
                    String relative = validateRelative(fields[1], lineNumber);
                    String key = key(relative);
                    if (!allFilePolicies.add(key)) throw malformed(lineNumber, "conflicting or duplicate file policy");
                    personal.put(key, relative);
                }
                case "runtime" -> {
                    requireFields(fields, 2, lineNumber);
                    String relative = validateRelative(fields[1], lineNumber);
                    String key = key(relative);
                    if (!allFilePolicies.add(key)) throw malformed(lineNumber, "conflicting or duplicate file policy");
                    runtime.put(key, relative);
                }
                case "runtime-prefix" -> {
                    requireFields(fields, 2, lineNumber);
                    String relative = validateRelative(fields[1], lineNumber);
                    String key = key(relative);
                    if (runtimePrefixes.putIfAbsent(key, relative) != null) {
                        throw malformed(lineNumber, "duplicate runtime-prefix");
                    }
                }
                case "seed" -> {
                    requireFields(fields, 3, lineNumber);
                    String template = validateRelative(fields[1], lineNumber);
                    String target = validateRelative(fields[2], lineNumber);
                    String templateKey = key(template);
                    String targetKey = key(target);
                    if (!seedTargets.add(targetKey)) throw malformed(lineNumber, "duplicate seed target");
                    seeds.add(new SeedRule(template, templateKey, target, targetKey));
                }
                case "regenerate-prefix" -> {
                    requireFields(fields, 2, lineNumber);
                    String relative = validateRelative(fields[1], lineNumber);
                    String key = key(relative);
                    if (regenerate.putIfAbsent(key, relative) != null) {
                        throw malformed(lineNumber, "duplicate regenerate-prefix");
                    }
                }
                default -> throw malformed(lineNumber, "unknown record type: " + fields[0]);
            }
        }

        if (!headerSeen) throw new GuardException("Strict manifest has no v1 header.");
        if (strictDirs.isEmpty()) throw new GuardException("Strict manifest declares no strict-dir records.");
        validateRelationships(strictDirs, managed, optional, personal, runtime, runtimePrefixes,
                seeds, regenerate, allFilePolicies);
        return new StrictManifest(digest(bytes), strictDirs, managed, optional, personal,
                runtime, runtimePrefixes, seeds, regenerate);
    }

    private static void validateRelationships(
            List<String> strictDirs,
            Map<String, FileRule> managed,
            Map<String, FileRule> optional,
            Map<String, String> personal,
            Map<String, String> runtime,
            Map<String, String> runtimePrefixes,
            List<SeedRule> seeds,
            Map<String, String> regenerate,
            Set<String> allFilePolicies) throws GuardException {
        List<String> strictKeys = strictDirs.stream().map(StrictManifest::key).toList();
        for (int i = 0; i < strictKeys.size(); i++) {
            for (int j = i + 1; j < strictKeys.size(); j++) {
                if (descendantOrEqual(strictKeys.get(i), strictKeys.get(j))
                        || descendantOrEqual(strictKeys.get(j), strictKeys.get(i))) {
                    throw new GuardException("strict-dir records may not overlap: " + strictDirs.get(i) + " and " + strictDirs.get(j));
                }
            }
        }

        Set<String> templateKeys = new HashSet<>();
        for (SeedRule seed : seeds) {
            if (seed.targetKey().equals(".nbidal18") || seed.targetKey().startsWith(".nbidal18/")) {
                throw new GuardException("Seed target may not use launch-guard control data: " + seed.target());
            }
            if (!managed.containsKey(seed.templateKey())) {
                throw new GuardException("Seed template must have a managed SHA-256 record: " + seed.template());
            }
            if (allFilePolicies.contains(seed.targetKey())) {
                throw new GuardException("Seed target conflicts with another file policy: " + seed.target());
            }
            templateKeys.add(seed.templateKey());
        }
        for (FileRule rule : managed.values()) {
            if (!insideAny(rule.key(), strictKeys) && !templateKeys.contains(rule.key())) {
                throw new GuardException("Managed file is neither strict content nor a seed template: " + rule.relative());
            }
        }
        for (FileRule rule : optional.values()) {
            if (!insideAny(rule.key(), strictKeys)) {
                throw new GuardException("Optional file must be inside a strict-dir: " + rule.relative());
            }
        }
        for (Map.Entry<String, String> entry : personal.entrySet()) {
            if (!insideAny(entry.getKey(), strictKeys)) {
                throw new GuardException("Personal file must be inside a strict-dir: " + entry.getValue());
            }
        }
        for (Map.Entry<String, String> entry : runtime.entrySet()) {
            if (!insideAny(entry.getKey(), strictKeys)) {
                throw new GuardException("Runtime file must be inside a strict-dir: " + entry.getValue());
            }
        }
        List<String> runtimePrefixKeys = new ArrayList<>(runtimePrefixes.keySet());
        for (int i = 0; i < runtimePrefixKeys.size(); i++) {
            String key = runtimePrefixKeys.get(i);
            if (!insideAny(key, strictKeys)) {
                throw new GuardException("runtime-prefix must be inside a strict-dir: " + runtimePrefixes.get(key));
            }
            for (int j = i + 1; j < runtimePrefixKeys.size(); j++) {
                if (descendantOrEqual(key, runtimePrefixKeys.get(j))
                        || descendantOrEqual(runtimePrefixKeys.get(j), key)) {
                    throw new GuardException("runtime-prefix records may not overlap.");
                }
            }
            for (String fileKey : allFilePolicies) {
                if (descendantOrEqual(key, fileKey)) {
                    throw new GuardException("runtime-prefix contains a separate file policy: " + runtimePrefixes.get(key));
                }
            }
        }
        List<String> regenerateKeys = new ArrayList<>(regenerate.keySet());
        for (SeedRule seed : seeds) {
            for (String runtimePrefix : runtimePrefixKeys) {
                if (descendantOrEqual(runtimePrefix, seed.targetKey())) {
                    throw new GuardException("Seed target is inside runtime-prefix: " + seed.target());
                }
            }
            for (String regenerateKey : regenerateKeys) {
                if (descendantOrEqual(regenerateKey, seed.targetKey())) {
                    throw new GuardException("Seed target is inside regenerate-prefix: " + seed.target());
                }
            }
        }
        for (int i = 0; i < regenerateKeys.size(); i++) {
            String key = regenerateKeys.get(i);
            if (!insideAny(key, strictKeys)) {
                throw new GuardException("regenerate-prefix must be inside a strict-dir: " + regenerate.get(key));
            }
            for (int j = i + 1; j < regenerateKeys.size(); j++) {
                if (descendantOrEqual(key, regenerateKeys.get(j)) || descendantOrEqual(regenerateKeys.get(j), key)) {
                    throw new GuardException("regenerate-prefix records may not overlap.");
                }
            }
            for (String fileKey : allFilePolicies) {
                if (descendantOrEqual(key, fileKey)) {
                    throw new GuardException("regenerate-prefix contains a file policy: " + regenerate.get(key));
                }
            }
            for (String runtimePrefix : runtimePrefixKeys) {
                if (descendantOrEqual(key, runtimePrefix) || descendantOrEqual(runtimePrefix, key)) {
                    throw new GuardException("regenerate-prefix overlaps runtime-prefix.");
                }
            }
        }
    }

    static String validateRelative(String raw, int lineNumber) throws GuardException {
        if (raw.isEmpty() || !raw.equals(raw.trim()) || raw.startsWith("/") || raw.endsWith("/")
                || raw.contains("\\") || raw.contains("//") || raw.contains(":")) {
            throw malformed(lineNumber, "invalid relative path: " + raw);
        }
        for (int offset = 0; offset < raw.length(); offset++) {
            if (Character.isISOControl(raw.charAt(offset))) throw malformed(lineNumber, "path contains a control character");
        }
        for (String part : raw.split("/", -1)) {
            if (part.isEmpty() || part.equals(".") || part.equals("..")) throw malformed(lineNumber, "path traversal is forbidden");
            if (part.endsWith(".") || part.endsWith(" ") || part.matches(".*[<>\"|?*].*")) {
                throw malformed(lineNumber, "path uses a Windows-ambiguous name");
            }
            String baseName = part.contains(".") ? part.substring(0, part.indexOf('.')) : part;
            if (baseName.matches("(?i)CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]")) {
                throw malformed(lineNumber, "path uses a reserved device name");
            }
        }
        try {
            Path parsed = Path.of(raw);
            if (parsed.isAbsolute() || !parsed.normalize().toString().replace('\\', '/').equals(raw)) {
                throw malformed(lineNumber, "path is not normalized: " + raw);
            }
        } catch (InvalidPathException e) {
            throw malformed(lineNumber, "invalid platform path: " + raw);
        }
        return raw;
    }

    static String key(String relative) {
        return relative.toLowerCase(Locale.ROOT);
    }

    static boolean descendantOrEqual(String directoryKey, String candidateKey) {
        return candidateKey.equals(directoryKey) || candidateKey.startsWith(directoryKey + "/");
    }

    private static boolean insideAny(String candidateKey, List<String> directoryKeys) {
        return directoryKeys.stream().anyMatch(directory -> descendantOrEqual(directory, candidateKey) && !directory.equals(candidateKey));
    }

    private static void requireFields(String[] fields, int count, int lineNumber) throws GuardException {
        if (fields.length != count) throw malformed(lineNumber, "wrong field count for " + fields[0]);
    }

    private static GuardException malformed(int line, String message) {
        return new GuardException("Malformed strict manifest at line " + line + ": " + message);
    }

    private static String digest(byte[] bytes) throws GuardException {
        try {
            return HexFormatSupport.hex(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (NoSuchAlgorithmException e) {
            throw new GuardException("SHA-256 is unavailable.", e);
        }
    }
}

final class GuardException extends Exception {
    GuardException(String message) { super(message); }
    GuardException(String message, Throwable cause) { super(message, cause); }
}

final class HexFormatSupport {
    private static final char[] HEX = "0123456789abcdef".toCharArray();
    static String hex(byte[] bytes) {
        char[] result = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            int value = bytes[i] & 0xff;
            result[i * 2] = HEX[value >>> 4];
            result[i * 2 + 1] = HEX[value & 0xf];
        }
        return new String(result);
    }
}
