package dev.nbidal18.packcompat;

import net.fabricmc.loader.api.ModContainer;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/** Consumes a guard-created proof that this exact updated companion already ran pre-launch. */
final class LaunchGuardHandoff {
    static final Path RELATIVE_PATH = Path.of(".nbidal18", "launch-guard-handoff.tsv");
    static final Duration MAXIMUM_AGE = Duration.ofMinutes(10);
    static final Duration MAXIMUM_FUTURE_SKEW = Duration.ofSeconds(30);

    private static final String HEADER = "nbidal18-launch-guard-handoff\t1";
    private static final int MAXIMUM_BYTES = 4096;
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");

    private LaunchGuardHandoff() {
    }

    static Path companionJar(ModContainer container) throws IOException, IntegrityException {
        List<Path> paths = container.getOrigin().getPaths();
        if (paths.size() != 1) {
            throw new IntegrityException("The companion mod origin is not a single JAR");
        }
        Path path = paths.getFirst().toAbsolutePath().normalize();
        BasicFileAttributes attributes = Files.readAttributes(
                path,
                BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS
        );
        if (!attributes.isRegularFile() || IntegrityFiles.isLinkOrReparse(path, attributes)) {
            throw new IntegrityException("The companion mod origin is not a plain regular JAR");
        }
        return path;
    }

    static boolean consumeIfMatching(
            Path gameDirectory,
            Path companionJar,
            String expectedGuardSha256,
            Clock clock
    ) throws IOException, IntegrityException {
        Path root = StrictManifest.normalizedRoot(gameDirectory);
        Path path = root.resolve(RELATIVE_PATH).normalize();
        if (!path.startsWith(root) || !Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            return false;
        }
        Path controlDirectory = root.resolve(".nbidal18").normalize();
        BasicFileAttributes controlAttributes = Files.readAttributes(
                controlDirectory,
                BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS
        );
        if (!controlAttributes.isDirectory()
                || IntegrityFiles.isLinkOrReparse(controlDirectory, controlAttributes)) {
            throw new IntegrityException("The launch-guard handoff control directory is unsafe");
        }
        byte[] handoffBytes = IntegrityFiles.readRegularFile(path, MAXIMUM_BYTES);
        Handoff handoff = parse(handoffBytes);
        String companionSha256 = IntegrityFiles.sha256(companionJar);
        String manifestSha256 = StrictManifest.load(root).sha256();
        Instant now = clock.instant();
        if (!handoff.guardSha256().equals(expectedGuardSha256)
                || !handoff.companionSha256().equals(companionSha256)
                || !handoff.manifestSha256().equals(manifestSha256)
                || handoff.verifiedAtUtc().isBefore(now.minus(MAXIMUM_AGE))
                || handoff.verifiedAtUtc().isAfter(now.plus(MAXIMUM_FUTURE_SKEW))) {
            return false;
        }
        atomicConsume(path, root, IntegrityFiles.sha256(handoffBytes));
        return true;
    }

    static Handoff parse(byte[] content) throws IntegrityException {
        String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(content))
                    .toString();
        } catch (CharacterCodingException malformed) {
            throw new IntegrityException("The launch-guard handoff is not valid UTF-8", malformed);
        }
        String[] lines = text.split("\n", -1);
        if (lines.length != 6 || !lines[5].isEmpty() || !HEADER.equals(lines[0])) {
            throw new IntegrityException("The launch-guard handoff has an invalid exact format");
        }
        Map<String, String> values = new HashMap<>();
        String[] expectedKeys = {"guard-sha256", "companion-sha256", "manifest-sha256", "verified-at-utc"};
        for (int index = 1; index < 5; index++) {
            if (lines[index].endsWith("\r")) {
                throw new IntegrityException("The launch-guard handoff must use LF line endings");
            }
            String[] fields = lines[index].split("\t", -1);
            if (fields.length != 2 || !expectedKeys[index - 1].equals(fields[0]) || fields[1].isEmpty()
                    || values.putIfAbsent(fields[0], fields[1]) != null) {
                throw new IntegrityException("The launch-guard handoff has an invalid record");
            }
        }
        if (values.size() != 4
                || !values.keySet().equals(java.util.Set.of(
                "guard-sha256", "companion-sha256", "manifest-sha256", "verified-at-utc"
        )) || !SHA256.matcher(values.get("guard-sha256")).matches()
                || !SHA256.matcher(values.get("companion-sha256")).matches()
                || !SHA256.matcher(values.get("manifest-sha256")).matches()) {
            throw new IntegrityException("The launch-guard handoff has invalid fields");
        }
        try {
            return new Handoff(
                    values.get("guard-sha256"),
                    values.get("companion-sha256"),
                    values.get("manifest-sha256"),
                    Instant.parse(values.get("verified-at-utc"))
            );
        } catch (DateTimeParseException invalid) {
            throw new IntegrityException("The launch-guard handoff timestamp is invalid", invalid);
        }
    }

    private static void atomicConsume(Path path, Path directory, String expectedSha256)
            throws IOException, IntegrityException {
        Path consumed = null;
        try {
            consumed = Files.createTempFile(directory.resolve(".nbidal18"), ".launch-guard-handoff-", ".consumed");
            Files.delete(consumed);
            try {
                Files.move(path, consumed, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException unsupported) {
                throw new IntegrityException("The launch-guard handoff cannot be atomically consumed", unsupported);
            }
            if (!expectedSha256.equals(IntegrityFiles.sha256(consumed))) {
                throw new IntegrityException("The launch-guard handoff changed while it was being consumed");
            }
            Files.delete(consumed);
            consumed = null;
        } finally {
            if (consumed != null) {
                Files.deleteIfExists(consumed);
            }
        }
    }

    record Handoff(String guardSha256, String companionSha256, String manifestSha256, Instant verifiedAtUtc) {
    }
}
