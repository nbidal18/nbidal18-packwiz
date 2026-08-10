package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Pattern;

record IntegrityAttestation(String manifestSha256, Instant verifiedAtUtc) {
    static final Path RELATIVE_PATH = Path.of(".nbidal18", "integrity-attestation.tsv");
    static final Duration MAXIMUM_AGE = Duration.ofMinutes(15);
    static final Duration MAXIMUM_FUTURE_SKEW = Duration.ofMinutes(2);

    private static final int MAXIMUM_BYTES = 16 * 1024;
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");

    static IntegrityAttestation loadAndValidate(
            Path gameDirectory,
            String expectedManifestSha256,
            Clock clock
    ) throws IOException, IntegrityException {
        Path path = StrictManifest.normalizedRoot(gameDirectory).resolve(RELATIVE_PATH);
        byte[] content = IntegrityFiles.readRegularFile(path, MAXIMUM_BYTES);
        IntegrityAttestation attestation = parse(content);

        if (!attestation.manifestSha256.equals(expectedManifestSha256)) {
            throw new IntegrityException("The guard attestation does not match the current strict manifest");
        }
        Instant now = clock.instant();
        if (attestation.verifiedAtUtc.isBefore(now.minus(MAXIMUM_AGE))) {
            throw new IntegrityException("The guard attestation is stale; relaunch through Prism");
        }
        if (attestation.verifiedAtUtc.isAfter(now.plus(MAXIMUM_FUTURE_SKEW))) {
            throw new IntegrityException("The guard attestation timestamp is in the future");
        }
        return attestation;
    }

    static IntegrityAttestation parse(byte[] content) throws IntegrityException {
        String text = decodeUtf8(content);
        String[] lines = text.split("\\n", -1);
        boolean headerSeen = false;
        Map<String, String> required = new HashMap<>();

        for (int index = 0; index < lines.length; index++) {
            String line = lines[index].endsWith("\r")
                    ? lines[index].substring(0, lines[index].length() - 1)
                    : lines[index];
            if (line.isEmpty() || line.startsWith("#")) {
                continue;
            }
            String[] fields = line.split("\\t", -1);
            for (String field : fields) {
                if (field.isEmpty()) {
                    throw invalid(index, "empty fields are not allowed");
                }
            }

            if (!headerSeen) {
                if (fields.length != 2
                        || !fields[0].equals("nbidal18-integrity-attestation")
                        || !fields[1].equals("1")) {
                    throw invalid(index, "expected nbidal18-integrity-attestation format 1");
                }
                headerSeen = true;
                continue;
            }

            if (fields[0].equals("manifest-sha256") || fields[0].equals("verified-at-utc")) {
                if (fields.length != 2) {
                    throw invalid(index, fields[0] + " requires two fields");
                }
                if (required.putIfAbsent(fields[0], fields[1]) != null) {
                    throw invalid(index, "duplicate " + fields[0] + " record");
                }
            }
            // Unknown non-empty rows are reserved for forwards-compatible guard metadata.
        }

        if (!headerSeen) {
            throw new IntegrityException("The guard attestation header is missing");
        }
        String manifestSha256 = required.get("manifest-sha256");
        String verifiedAt = required.get("verified-at-utc");
        if (manifestSha256 == null || verifiedAt == null) {
            throw new IntegrityException("The guard attestation is incomplete");
        }
        if (!SHA256.matcher(manifestSha256).matches()) {
            throw new IntegrityException("The attested manifest SHA-256 is invalid");
        }
        try {
            return new IntegrityAttestation(manifestSha256, Instant.parse(verifiedAt));
        } catch (DateTimeParseException invalidTime) {
            throw new IntegrityException("The guard attestation timestamp is invalid", invalidTime);
        }
    }

    private static String decodeUtf8(byte[] content) throws IntegrityException {
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(content))
                    .toString();
        } catch (CharacterCodingException malformedUtf8) {
            throw new IntegrityException("The guard attestation is not valid UTF-8", malformedUtf8);
        }
    }

    private static IntegrityException invalid(int zeroBasedLine, String reason) {
        return new IntegrityException("Invalid guard attestation line " + (zeroBasedLine + 1) + ": " + reason);
    }
}
