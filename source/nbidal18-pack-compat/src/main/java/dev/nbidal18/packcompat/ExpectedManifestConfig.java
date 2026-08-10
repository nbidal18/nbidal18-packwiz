package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.List;
import java.util.regex.Pattern;

record ExpectedManifestConfig(String sha256, String error) {
    static final String FILE_NAME = "nbidal18-pack-compat.properties";
    static final String PROPERTY_NAME = "expected-manifest-sha256";

    private static final int MAXIMUM_BYTES = 4096;
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");

    static ExpectedManifestConfig load(Path configDirectory) {
        Path path = configDirectory.resolve(FILE_NAME);
        try {
            BasicFileAttributes attributes = Files.readAttributes(
                    path,
                    BasicFileAttributes.class,
                    LinkOption.NOFOLLOW_LINKS
            );
            if (!attributes.isRegularFile()
                    || IntegrityFiles.isLinkOrReparse(path, attributes)
                    || attributes.size() > MAXIMUM_BYTES) {
                return invalid("Expected manifest digest config is missing or unsafe");
            }
            List<String> lines = Files.readAllLines(path, StandardCharsets.UTF_8);
            String value = null;
            for (String rawLine : lines) {
                String line = rawLine.strip();
                if (line.isEmpty() || line.startsWith("#")) {
                    continue;
                }
                int separator = line.indexOf('=');
                if (separator <= 0 || separator != line.lastIndexOf('=')) {
                    return invalid("Expected manifest digest config contains a malformed line");
                }
                String name = line.substring(0, separator).strip();
                String candidate = line.substring(separator + 1).strip();
                if (!name.equals(PROPERTY_NAME) || value != null) {
                    return invalid("Expected manifest digest config contains an unknown or duplicate property");
                }
                value = candidate;
            }
            if (value == null || !SHA256.matcher(value).matches()) {
                return invalid("Expected manifest digest config is missing a valid lowercase SHA-256");
            }
            return new ExpectedManifestConfig(value, "");
        } catch (IOException | RuntimeException failure) {
            return invalid("Expected manifest digest config could not be read");
        }
    }

    static ExpectedManifestConfig parseForTest(String content) {
        String value = null;
        for (String rawLine : content.split("\\R", -1)) {
            String line = rawLine.strip();
            if (line.isEmpty() || line.startsWith("#")) {
                continue;
            }
            int separator = line.indexOf('=');
            if (separator <= 0 || separator != line.lastIndexOf('=')) {
                return invalid("Expected manifest digest config contains a malformed line");
            }
            String name = line.substring(0, separator).strip();
            String candidate = line.substring(separator + 1).strip();
            if (!name.equals(PROPERTY_NAME) || value != null) {
                return invalid("Expected manifest digest config contains an unknown or duplicate property");
            }
            value = candidate;
        }
        return value != null && SHA256.matcher(value).matches()
                ? new ExpectedManifestConfig(value, "")
                : invalid("Expected manifest digest config is missing a valid lowercase SHA-256");
    }

    boolean valid() {
        return sha256 != null;
    }

    private static ExpectedManifestConfig invalid(String error) {
        return new ExpectedManifestConfig(null, error);
    }
}
