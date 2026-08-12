package dev.nbidal18.packcompat;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
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
import java.util.Arrays;
import java.util.regex.Pattern;

final class LaunchGuardUpdater {
    static final String TARGET_FILE_NAME = "nbidal18-launch-guard.jar";

    private static final String PAYLOAD_RESOURCE = "/META-INF/nbidal18/nbidal18-launch-guard.jar";
    private static final String DESCRIPTOR_RESOURCE = "/META-INF/nbidal18/launch-guard.tsv";
    private static final String DESCRIPTOR_HEADER = "nbidal18-launch-guard\t1";
    private static final int MAXIMUM_PAYLOAD_BYTES = 16 * 1024 * 1024;
    private static final int MAXIMUM_DESCRIPTOR_BYTES = 1024;
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");

    private LaunchGuardUpdater() {
    }

    static UpdateResult install(Path gameDirectory) throws IOException, IntegrityException {
        EmbeddedGuard embedded = loadEmbedded();
        return install(gameDirectory, embedded.payload(), embedded.sha256());
    }

    static UpdateResult install(
            Path gameDirectory,
            byte[] payload,
            String expectedSha256
    ) throws IOException, IntegrityException {
        validatePayload(payload, expectedSha256);
        Path root = requirePlainGameDirectory(gameDirectory);
        Path target = root.resolve(TARGET_FILE_NAME).normalize();
        if (!root.equals(target.getParent())) {
            throw new IntegrityException("The launch-guard target escapes the game directory");
        }

        TargetState initial = inspectTarget(target, expectedSha256);
        if (initial == TargetState.MATCHING) {
            return UpdateResult.UP_TO_DATE;
        }

        Path staged = null;
        try {
            staged = Files.createTempFile(root, ".nbidal18-launch-guard-", ".tmp");
            requirePlainRegularFile(staged, "staged launch guard");
            try (FileChannel channel = FileChannel.open(
                    staged,
                    StandardOpenOption.WRITE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    LinkOption.NOFOLLOW_LINKS
            )) {
                ByteBuffer buffer = ByteBuffer.wrap(payload);
                while (buffer.hasRemaining()) {
                    channel.write(buffer);
                }
                channel.force(true);
            }
            requirePlainRegularFile(staged, "staged launch guard");
            if (Files.size(staged) != payload.length
                    || !expectedSha256.equals(IntegrityFiles.sha256(staged))) {
                throw new IntegrityException("The staged launch guard did not pass hash verification");
            }

            // Recheck immediately before the move so a newly introduced link or
            // reparse target is never treated as an ordinary replacement.
            inspectTarget(target, expectedSha256);
            try {
                Files.move(
                        staged,
                        target,
                        StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING
                );
            } catch (AtomicMoveNotSupportedException unsupported) {
                throw new IntegrityException(
                        "The game directory does not support atomic launch-guard replacement",
                        unsupported
                );
            }
            staged = null;

            if (inspectTarget(target, expectedSha256) != TargetState.MATCHING) {
                throw new IntegrityException("The installed launch guard did not pass verification");
            }
            return initial == TargetState.MISSING ? UpdateResult.INSTALLED : UpdateResult.REPLACED;
        } finally {
            if (staged != null) {
                Files.deleteIfExists(staged);
            }
        }
    }

    static EmbeddedGuard loadEmbedded() throws IOException, IntegrityException {
        byte[] descriptorBytes;
        try (InputStream input = LaunchGuardUpdater.class.getResourceAsStream(DESCRIPTOR_RESOURCE)) {
            if (input == null) {
                throw new IntegrityException("The embedded launch-guard descriptor is missing");
            }
            descriptorBytes = readBounded(input, MAXIMUM_DESCRIPTOR_BYTES, "launch-guard descriptor");
        }
        Descriptor descriptor = parseDescriptor(descriptorBytes);

        byte[] payload;
        try (InputStream input = LaunchGuardUpdater.class.getResourceAsStream(PAYLOAD_RESOURCE)) {
            if (input == null) {
                throw new IntegrityException("The embedded launch-guard payload is missing");
            }
            payload = readBounded(input, MAXIMUM_PAYLOAD_BYTES, "launch-guard payload");
        }
        if (payload.length != descriptor.size()) {
            throw new IntegrityException("The embedded launch-guard size does not match its descriptor");
        }
        validatePayload(payload, descriptor.sha256());
        return new EmbeddedGuard(payload, descriptor.sha256());
    }

    private static Path requirePlainGameDirectory(Path gameDirectory) throws IOException, IntegrityException {
        Path root = StrictManifest.normalizedRoot(gameDirectory);
        BasicFileAttributes attributes;
        try {
            attributes = Files.readAttributes(root, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        } catch (java.nio.file.NoSuchFileException missing) {
            throw new IntegrityException("The game directory does not exist", missing);
        }
        if (!attributes.isDirectory() || IntegrityFiles.isLinkOrReparse(root, attributes)) {
            throw new IntegrityException("The game directory is not a plain directory");
        }
        return root;
    }

    private static TargetState inspectTarget(Path target, String expectedSha256)
            throws IOException, IntegrityException {
        if (!Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
            return TargetState.MISSING;
        }
        BasicFileAttributes attributes = requirePlainRegularFile(target, "launch-guard target");
        if (attributes.size() == 0 || attributes.size() > MAXIMUM_PAYLOAD_BYTES) {
            throw new IntegrityException("The launch-guard target has an unsafe size");
        }
        return expectedSha256.equals(IntegrityFiles.sha256(target))
                ? TargetState.MATCHING
                : TargetState.DIFFERENT;
    }

    private static BasicFileAttributes requirePlainRegularFile(Path path, String label)
            throws IOException, IntegrityException {
        BasicFileAttributes attributes = Files.readAttributes(
                path,
                BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS
        );
        if (!attributes.isRegularFile() || IntegrityFiles.isLinkOrReparse(path, attributes)) {
            throw new IntegrityException("The " + label + " is not a plain regular file");
        }
        return attributes;
    }

    private static void validatePayload(byte[] payload, String expectedSha256) throws IntegrityException {
        if (payload == null || payload.length == 0 || payload.length > MAXIMUM_PAYLOAD_BYTES) {
            throw new IntegrityException("The embedded launch-guard payload has an unsafe size");
        }
        if (expectedSha256 == null || !SHA256.matcher(expectedSha256).matches()) {
            throw new IntegrityException("The embedded launch-guard SHA-256 is invalid");
        }
        if (!expectedSha256.equals(IntegrityFiles.sha256(payload))) {
            throw new IntegrityException("The embedded launch-guard payload failed hash verification");
        }
    }

    private static Descriptor parseDescriptor(byte[] content) throws IntegrityException {
        String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(content))
                    .toString();
        } catch (CharacterCodingException malformed) {
            throw new IntegrityException("The embedded launch-guard descriptor is not valid UTF-8", malformed);
        }

        String[] lines = text.split("\n", -1);
        if (lines.length != 4 || !lines[3].isEmpty()
                || lines[0].endsWith("\r") || lines[1].endsWith("\r") || lines[2].endsWith("\r")
                || !DESCRIPTOR_HEADER.equals(lines[0])) {
            throw new IntegrityException("The embedded launch-guard descriptor has an invalid format");
        }
        String[] hash = lines[1].split("\t", -1);
        String[] size = lines[2].split("\t", -1);
        if (hash.length != 2 || !"sha256".equals(hash[0]) || !SHA256.matcher(hash[1]).matches()
                || size.length != 2 || !"size".equals(size[0])) {
            throw new IntegrityException("The embedded launch-guard descriptor has invalid fields");
        }

        int parsedSize;
        try {
            parsedSize = Integer.parseInt(size[1]);
        } catch (NumberFormatException invalid) {
            throw new IntegrityException("The embedded launch-guard descriptor has an invalid size", invalid);
        }
        if (parsedSize <= 0 || parsedSize > MAXIMUM_PAYLOAD_BYTES) {
            throw new IntegrityException("The embedded launch-guard descriptor size is unsafe");
        }
        return new Descriptor(hash[1], parsedSize);
    }

    private static byte[] readBounded(InputStream input, int maximumBytes, String label)
            throws IOException, IntegrityException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(Math.min(maximumBytes, 64 * 1024));
        byte[] buffer = new byte[8192];
        int total = 0;
        int read;
        while ((read = input.read(buffer)) >= 0) {
            total += read;
            if (total > maximumBytes) {
                throw new IntegrityException("The embedded " + label + " is too large");
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }

    enum UpdateResult {
        INSTALLED,
        REPLACED,
        UP_TO_DATE
    }

    static final class EmbeddedGuard {
        private final byte[] payload;
        private final String sha256;

        private EmbeddedGuard(byte[] payload, String sha256) {
            this.payload = Arrays.copyOf(payload, payload.length);
            this.sha256 = sha256;
        }

        byte[] payload() {
            return Arrays.copyOf(payload, payload.length);
        }

        String sha256() {
            return sha256;
        }
    }

    private enum TargetState {
        MISSING,
        DIFFERENT,
        MATCHING
    }

    private record Descriptor(String sha256, int size) {
    }
}
