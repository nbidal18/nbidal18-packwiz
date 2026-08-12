package dev.nbidal18.packcompat;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Self-contained, single-class relaunch process. It deliberately has no dependency on the
 * managed companion JAR after this class has been loaded from the extracted control directory.
 */
public final class PrismRelaunchStandalone {
    private static final Pattern NONCE = Pattern.compile("[0-9a-f]{32}");
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");
    private static final String HEADER = "nbidal18-prism-relaunch\t1";
    private static final long POLL_MILLIS = 250;

    private PrismRelaunchStandalone() {
    }

    public static void main(String[] arguments) {
        Path game = null;
        int result = 1;
        try {
            if (arguments == null || arguments.length != 8) {
                throw new IllegalArgumentException("expected eight arguments");
            }
            Path prism = Path.of(decode(arguments[0])).toAbsolutePath().normalize();
            Path launcherRoot = Path.of(decode(arguments[1])).toAbsolutePath().normalize();
            game = Path.of(decode(arguments[2])).toAbsolutePath().normalize();
            String instanceId = decode(arguments[3]);
            long minecraftPid = Long.parseLong(arguments[4]);
            Instant minecraftStartedAt = Instant.parse(decode(arguments[5]));
            String nonce = arguments[6];
            String guardSha256 = arguments[7];
            validatePlain(prism, false);
            validatePlain(launcherRoot, true);
            validatePlain(game, true);
            if (!prism.getFileName().toString().equalsIgnoreCase("prismlauncher.exe")
                    || !safeInstanceId(instanceId) || minecraftPid <= 0
                    || !NONCE.matcher(nonce).matches() || !SHA256.matcher(guardSha256).matches()) {
                throw new IllegalArgumentException("unsafe relaunch identity");
            }
            Path marker = game.resolve(".nbidal18").resolve("prism-relaunch.tsv").normalize();
            String encodedInstance = Base64.getUrlEncoder().withoutPadding()
                    .encodeToString(instanceId.getBytes(StandardCharsets.UTF_8));
            if (!matchesMarker(marker, "armed", nonce, guardSha256, encodedInstance)) {
                throw new IllegalStateException("request is not armed");
            }

            Instant exitDeadline = Instant.now().plus(Duration.ofMinutes(5));
            boolean exited = false;
            while (Instant.now().isBefore(exitDeadline)) {
                Optional<ProcessHandle> process = ProcessHandle.of(minecraftPid);
                if (process.isEmpty()) {
                    exited = true;
                    break;
                }
                Optional<Instant> actualStart = process.get().info().startInstant();
                if (actualStart.isPresent() && !actualStart.get().equals(minecraftStartedAt)) {
                    exited = true;
                    break;
                }
                Thread.sleep(POLL_MILLIS);
            }
            if (!exited) {
                result = 2;
            } else {
                Thread.sleep(2000);
                for (int attempt = 0; attempt < 2; attempt++) {
                    new ProcessBuilder(
                            prism.toString(),
                            "--dir", launcherRoot.toString(),
                            "--launch", instanceId
                    ).directory(launcherRoot.toFile()).start();
                    Instant ackDeadline = Instant.now().plus(attempt == 0
                            ? Duration.ofSeconds(90) : Duration.ofSeconds(45));
                    while (Instant.now().isBefore(ackDeadline)) {
                        if (matchesMarker(marker, "acknowledged", nonce, guardSha256, encodedInstance)) {
                            if (consumeAcknowledgment(marker, nonce, guardSha256, encodedInstance)) {
                                result = 0;
                                break;
                            }
                        }
                        Thread.sleep(POLL_MILLIS);
                    }
                    if (result == 0) {
                        break;
                    }
                }
                if (result != 0) {
                    result = 3;
                }
            }
        } catch (Exception failure) {
            if (game != null) {
                diagnostic(game, "helper failure: " + failure.getClass().getSimpleName());
            }
            result = 1;
        }
        if (game != null && result != 0) {
            diagnostic(game, "helper stopped with code " + result);
        }
        System.exit(result);
    }

    private static boolean consumeAcknowledgment(
            Path marker,
            String nonce,
            String guardSha256,
            String encodedInstance
    ) throws IOException {
        byte[] expected = Files.readAllBytes(marker);
        Path consumed = null;
        try {
            consumed = Files.createTempFile(marker.getParent(), ".prism-relaunch-", ".consumed");
            Files.delete(consumed);
            try {
                Files.move(marker, consumed, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException unsupported) {
                throw new IOException("atomic acknowledgment consumption is unavailable", unsupported);
            }
            if (!java.util.Arrays.equals(expected, Files.readAllBytes(consumed))
                    || !matchesMarker(consumed, "acknowledged", nonce, guardSha256, encodedInstance)) {
                throw new IOException("acknowledgment changed while being consumed");
            }
            Files.delete(consumed);
            consumed = null;
            return true;
        } finally {
            if (consumed != null) {
                Files.deleteIfExists(consumed);
            }
        }
    }

    private static boolean matchesMarker(
            Path path,
            String state,
            String nonce,
            String guardSha256,
            String encodedInstance
    ) {
        try {
            validatePlain(path.getParent(), true);
            validatePlain(path, false);
            byte[] bytes = Files.readAllBytes(path);
            if (bytes.length == 0 || bytes.length > 4096) {
                return false;
            }
            String text = strictUtf8(bytes);
            String[] lines = text.split("\n", -1);
            int expectedLines = state.equals("armed") ? 7 : 8;
            if (lines.length != expectedLines || !lines[lines.length - 1].isEmpty()
                    || !HEADER.equals(lines[0])) {
                return false;
            }
            Map<String, String> values = new HashMap<>();
            String[] expectedOrder = state.equals("armed")
                    ? new String[]{"state", "nonce", "guard-sha256", "instance-id-base64", "armed-at-utc"}
                    : new String[]{"state", "nonce", "guard-sha256", "instance-id-base64", "armed-at-utc",
                    "acknowledged-at-utc"};
            for (int index = 1; index < lines.length - 1; index++) {
                if (lines[index].endsWith("\r")) {
                    return false;
                }
                String[] fields = lines[index].split("\t", -1);
                if (fields.length != 2 || !expectedOrder[index - 1].equals(fields[0]) || fields[1].isEmpty()
                        || values.putIfAbsent(fields[0], fields[1]) != null) {
                    return false;
                }
            }
            Set<String> expected = state.equals("armed")
                    ? Set.of("state", "nonce", "guard-sha256", "instance-id-base64", "armed-at-utc")
                    : Set.of("state", "nonce", "guard-sha256", "instance-id-base64", "armed-at-utc",
                    "acknowledged-at-utc");
            if (!values.keySet().equals(expected)
                    || !state.equals(values.get("state"))
                    || !nonce.equals(values.get("nonce"))
                    || !guardSha256.equals(values.get("guard-sha256"))
                    || !encodedInstance.equals(values.get("instance-id-base64"))) {
                return false;
            }
            Instant.parse(values.get("armed-at-utc"));
            if (state.equals("acknowledged")) {
                Instant.parse(values.get("acknowledged-at-utc"));
            }
            return true;
        } catch (Exception invalid) {
            return false;
        }
    }

    private static void validatePlain(Path path, boolean directory) throws IOException {
        BasicFileAttributes attributes = Files.readAttributes(
                path,
                BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS
        );
        if ((directory ? !attributes.isDirectory() : !attributes.isRegularFile())
                || attributes.isSymbolicLink() || attributes.isOther() || Files.isSymbolicLink(path)) {
            throw new IOException("unsafe filesystem object");
        }
        try {
            Object raw = Files.getAttribute(path, "dos:attributes", LinkOption.NOFOLLOW_LINKS);
            if (raw instanceof Number && ((((Number) raw).intValue() & 0x400) != 0)) {
                throw new IOException("reparse point");
            }
        } catch (UnsupportedOperationException | IllegalArgumentException ignored) {
        }
    }

    private static boolean safeInstanceId(String value) {
        if (value == null || value.isEmpty() || value.length() > 255 || !value.equals(value.strip())
                || value.equals(".") || value.equals("..") || value.indexOf('/') >= 0
                || value.indexOf('\\') >= 0) {
            return false;
        }
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            if (character < 0x20 || character == 0x7f) {
                return false;
            }
        }
        return true;
    }

    private static String decode(String encoded) throws CharacterCodingException {
        return strictUtf8(Base64.getUrlDecoder().decode(encoded));
    }

    private static String strictUtf8(byte[] bytes) throws CharacterCodingException {
        return StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString();
    }

    private static void diagnostic(Path game, String message) {
        try {
            Path directory = game.resolve(".nbidal18").normalize();
            validatePlain(directory, true);
            Files.writeString(
                    directory.resolve("prism-relaunch.log"),
                    Instant.now() + "\t" + message.replace('\r', ' ').replace('\n', ' ') + "\n",
                    StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS
            );
        } catch (Exception ignored) {
        }
    }
}
