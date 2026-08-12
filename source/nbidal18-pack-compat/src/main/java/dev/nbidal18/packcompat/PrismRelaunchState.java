package dev.nbidal18.packcompat;

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
import java.security.SecureRandom;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** Hash-bound one-shot request acknowledged by the next launch guard. */
final class PrismRelaunchState {
    static final Path RELATIVE_PATH = Path.of(".nbidal18", "prism-relaunch.tsv");

    private static final String HEADER = "nbidal18-prism-relaunch\t1";
    private static final int MAXIMUM_BYTES = 4096;
    private static final Pattern NONCE = Pattern.compile("[0-9a-f]{32}");
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");
    private static final SecureRandom RANDOM = new SecureRandom();

    private PrismRelaunchState() {
    }

    static boolean shouldPrepareRelaunch(
            LaunchGuardUpdater.UpdateResult updateResult,
            boolean handoffConsumed
    ) {
        return updateResult != LaunchGuardUpdater.UpdateResult.UP_TO_DATE && !handoffConsumed;
    }

    static RelaunchMarker arm(
            Path gameDirectory,
            String guardSha256,
            String instanceId,
            Instant now
    ) throws IOException, IntegrityException {
        byte[] nonceBytes = new byte[16];
        RANDOM.nextBytes(nonceBytes);
        return arm(gameDirectory, guardSha256, instanceId, now, java.util.HexFormat.of().formatHex(nonceBytes));
    }

    static RelaunchMarker arm(
            Path gameDirectory,
            String guardSha256,
            String instanceId,
            Instant now,
            String nonce
    ) throws IOException, IntegrityException {
        String encodedId = Base64.getUrlEncoder().withoutPadding()
                .encodeToString(instanceId.getBytes(StandardCharsets.UTF_8));
        RelaunchMarker marker = new RelaunchMarker(
                MarkerState.ARMED,
                nonce,
                guardSha256,
                encodedId,
                now,
                null
        );
        validate(marker);
        atomicWrite(StrictManifest.normalizedRoot(gameDirectory), marker.serialize());
        return marker;
    }

    static RelaunchMarker read(Path gameDirectory) throws IOException, IntegrityException {
        Path root = StrictManifest.normalizedRoot(gameDirectory);
        Path path = root.resolve(RELATIVE_PATH).normalize();
        if (!path.startsWith(root)) {
            throw new IntegrityException("The Prism relaunch marker escapes the game directory");
        }
        requirePlainControlDirectory(root.resolve(".nbidal18"));
        return parse(IntegrityFiles.readRegularFile(path, MAXIMUM_BYTES));
    }

    static boolean acknowledgedMatches(
            Path gameDirectory,
            String nonce,
            String guardSha256,
            String instanceId
    ) throws IOException, IntegrityException {
        RelaunchMarker marker = read(gameDirectory);
        String encodedId = Base64.getUrlEncoder().withoutPadding()
                .encodeToString(instanceId.getBytes(StandardCharsets.UTF_8));
        return marker.state() == MarkerState.ACKNOWLEDGED
                && marker.nonce().equals(nonce)
                && marker.guardSha256().equals(guardSha256)
                && marker.instanceIdBase64().equals(encodedId);
    }

    static RelaunchMarker parse(byte[] content) throws IntegrityException {
        String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(content))
                    .toString();
        } catch (CharacterCodingException malformed) {
            throw new IntegrityException("The Prism relaunch marker is not valid UTF-8", malformed);
        }
        String[] lines = text.split("\n", -1);
        if ((lines.length != 7 && lines.length != 8) || !lines[lines.length - 1].isEmpty()
                || !HEADER.equals(lines[0])) {
            throw new IntegrityException("The Prism relaunch marker has an invalid exact format");
        }
        Map<String, String> values = new HashMap<>();
        String[] expectedOrder = lines.length == 7
                ? new String[]{"state", "nonce", "guard-sha256", "instance-id-base64", "armed-at-utc"}
                : new String[]{"state", "nonce", "guard-sha256", "instance-id-base64", "armed-at-utc",
                "acknowledged-at-utc"};
        for (int index = 1; index < lines.length - 1; index++) {
            if (lines[index].endsWith("\r")) {
                throw new IntegrityException("The Prism relaunch marker must use LF line endings");
            }
            String[] fields = lines[index].split("\t", -1);
            if (fields.length != 2 || !expectedOrder[index - 1].equals(fields[0]) || fields[1].isEmpty()
                    || values.putIfAbsent(fields[0], fields[1]) != null) {
                throw new IntegrityException("The Prism relaunch marker has an invalid record");
            }
        }
        try {
            MarkerState state = switch (values.get("state")) {
                case "armed" -> MarkerState.ARMED;
                case "acknowledged" -> MarkerState.ACKNOWLEDGED;
                default -> throw new IntegrityException("The Prism relaunch marker state is invalid");
            };
            Set<String> expected = state == MarkerState.ARMED
                    ? Set.of("state", "nonce", "guard-sha256", "instance-id-base64", "armed-at-utc")
                    : Set.of("state", "nonce", "guard-sha256", "instance-id-base64", "armed-at-utc",
                    "acknowledged-at-utc");
            if (!values.keySet().equals(expected)) {
                throw new IntegrityException("The Prism relaunch marker fields are invalid");
            }
            RelaunchMarker marker = new RelaunchMarker(
                    state,
                    values.get("nonce"),
                    values.get("guard-sha256"),
                    values.get("instance-id-base64"),
                    Instant.parse(values.get("armed-at-utc")),
                    state == MarkerState.ACKNOWLEDGED
                            ? Instant.parse(values.get("acknowledged-at-utc"))
                            : null
            );
            validate(marker);
            return marker;
        } catch (DateTimeParseException invalid) {
            throw new IntegrityException("The Prism relaunch marker timestamp is invalid", invalid);
        }
    }

    static void deleteMatching(Path gameDirectory, RelaunchMarker expected)
            throws IOException, IntegrityException {
        Path root = StrictManifest.normalizedRoot(gameDirectory);
        Path path = root.resolve(RELATIVE_PATH).normalize();
        RelaunchMarker actual = read(root);
        if (!actual.equals(expected)) {
            throw new IntegrityException("The Prism relaunch acknowledgment changed before consumption");
        }
        atomicConsume(path, expected);
    }

    static void deleteIfMatching(Path gameDirectory, RelaunchMarker expected)
            throws IOException, IntegrityException {
        Path root = StrictManifest.normalizedRoot(gameDirectory);
        Path path = root.resolve(RELATIVE_PATH).normalize();
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            return;
        }
        RelaunchMarker actual = read(root);
        if (actual.equals(expected)) {
            atomicConsume(path, expected);
        }
    }

    private static void atomicConsume(Path path, RelaunchMarker expected)
            throws IOException, IntegrityException {
        Path consumed = null;
        try {
            consumed = Files.createTempFile(path.getParent(), ".prism-relaunch-", ".consumed");
            Files.delete(consumed);
            try {
                Files.move(path, consumed, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException unsupported) {
                throw new IntegrityException("The Prism relaunch marker cannot be atomically consumed", unsupported);
            }
            RelaunchMarker moved = parse(IntegrityFiles.readRegularFile(consumed, MAXIMUM_BYTES));
            if (!moved.equals(expected)) {
                throw new IntegrityException("The Prism relaunch marker changed while being consumed");
            }
            Files.delete(consumed);
            consumed = null;
        } finally {
            if (consumed != null) {
                Files.deleteIfExists(consumed);
            }
        }
    }

    private static void validate(RelaunchMarker marker) throws IntegrityException {
        if (!NONCE.matcher(marker.nonce()).matches()
                || !SHA256.matcher(marker.guardSha256()).matches()
                || marker.instanceIdBase64() == null || marker.instanceIdBase64().isEmpty()
                || marker.instanceIdBase64().length() > 1024
                || !marker.instanceIdBase64().matches("[A-Za-z0-9_-]+")) {
            throw new IntegrityException("The Prism relaunch marker contains invalid identifiers");
        }
        try {
            byte[] decoded = Base64.getUrlDecoder().decode(marker.instanceIdBase64());
            String instanceId = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(decoded)).toString();
            if (instanceId.isEmpty() || instanceId.length() > 255
                    || instanceId.chars().anyMatch(character -> character < 0x20 || character == 0x7f)
                    || instanceId.indexOf('/') >= 0 || instanceId.indexOf('\\') >= 0) {
                throw new IntegrityException("The Prism relaunch marker instance ID is unsafe");
            }
        } catch (IllegalArgumentException | CharacterCodingException invalid) {
            throw new IntegrityException("The Prism relaunch marker instance ID encoding is invalid", invalid);
        }
        if (marker.state() == MarkerState.ARMED && marker.acknowledgedAtUtc() != null
                || marker.state() == MarkerState.ACKNOWLEDGED && marker.acknowledgedAtUtc() == null) {
            throw new IntegrityException("The Prism relaunch marker acknowledgment is inconsistent");
        }
    }

    private static void atomicWrite(Path gameDirectory, byte[] content)
            throws IOException, IntegrityException {
        Path controlDirectory = gameDirectory.resolve(".nbidal18").normalize();
        if (!controlDirectory.startsWith(gameDirectory)) {
            throw new IntegrityException("The Prism relaunch marker directory escapes the game directory");
        }
        requirePlainControlDirectory(controlDirectory);
        Path target = controlDirectory.resolve(RELATIVE_PATH.getFileName());
        Path staged = null;
        try {
            staged = Files.createTempFile(controlDirectory, ".prism-relaunch-", ".tmp");
            try (FileChannel channel = FileChannel.open(
                    staged,
                    StandardOpenOption.WRITE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    LinkOption.NOFOLLOW_LINKS
            )) {
                ByteBuffer buffer = ByteBuffer.wrap(content);
                while (buffer.hasRemaining()) {
                    channel.write(buffer);
                }
                channel.force(true);
            }
            try {
                Files.move(staged, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException unsupported) {
                throw new IntegrityException("The Prism relaunch marker cannot be written atomically", unsupported);
            }
            staged = null;
        } finally {
            if (staged != null) {
                Files.deleteIfExists(staged);
            }
        }
    }

    private static void requirePlainControlDirectory(Path controlDirectory)
            throws IOException, IntegrityException {
        BasicFileAttributes directoryAttributes = Files.readAttributes(
                controlDirectory,
                BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS
        );
        if (!directoryAttributes.isDirectory()
                || IntegrityFiles.isLinkOrReparse(controlDirectory, directoryAttributes)) {
            throw new IntegrityException("The Prism relaunch control directory is unsafe");
        }
    }

    enum MarkerState {
        ARMED("armed"),
        ACKNOWLEDGED("acknowledged");

        private final String serialized;

        MarkerState(String serialized) {
            this.serialized = serialized;
        }
    }

    record RelaunchMarker(
            MarkerState state,
            String nonce,
            String guardSha256,
            String instanceIdBase64,
            Instant armedAtUtc,
            Instant acknowledgedAtUtc
    ) {
        byte[] serialize() {
            StringBuilder text = new StringBuilder(512)
                    .append(HEADER).append('\n')
                    .append("state\t").append(state.serialized).append('\n')
                    .append("nonce\t").append(nonce).append('\n')
                    .append("guard-sha256\t").append(guardSha256).append('\n')
                    .append("instance-id-base64\t").append(instanceIdBase64).append('\n')
                    .append("armed-at-utc\t").append(armedAtUtc).append('\n');
            if (acknowledgedAtUtc != null) {
                text.append("acknowledged-at-utc\t").append(acknowledgedAtUtc).append('\n');
            }
            return text.toString().getBytes(StandardCharsets.UTF_8);
        }
    }
}
