package dev.nbidal18.launchguard;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.Base64;
import java.util.regex.Pattern;

/** One-shot acknowledgement that the requested exact Prism instance entered its new guard. */
final class PrismRelaunchMarker {
    static final String RELATIVE = ".nbidal18/prism-relaunch.tsv";
    private static final long MAX_BYTES = 2048;
    private static final Duration MAX_AGE = Duration.ofMinutes(10);
    private static final Duration MAX_FUTURE_SKEW = Duration.ofSeconds(30);
    private static final Pattern NONCE = Pattern.compile("[0-9a-f]{32}");
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");
    private static final Pattern BASE64URL = Pattern.compile("[A-Za-z0-9_-]{1,1024}");

    private PrismRelaunchMarker() {}

    static void acknowledgeIfArmed(Path root, String currentGuardSha256)
            throws IOException, GuardException {
        Path path = LaunchGuard.resolve(root, RELATIVE);
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return;
        BasicFileAttributes attributes = Files.readAttributes(
                path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        if (!attributes.isRegularFile() || LaunchGuard.isLinkOrReparse(path, attributes)) {
            throw new GuardException("Prism relaunch marker is not a plain regular file.");
        }

        final Marker marker;
        try {
            marker = parse(LaunchGuard.readPlainBytes(path, MAX_BYTES));
        } catch (GuardException malformed) {
            Files.delete(path);
            System.err.println("[nbidal18-launch-guard] Discarded malformed Prism relaunch marker: "
                    + malformed.getMessage());
            return;
        }
        if (marker.acknowledgedAt() != null) return; // Leave it for the waiting helper to consume.

        Instant now = Instant.now();
        Duration age = Duration.between(marker.armedAt(), now);
        String instanceId = System.getenv("INST_ID");
        byte[] expectedInstance = instanceId == null
                ? new byte[0] : instanceId.getBytes(StandardCharsets.UTF_8);
        boolean matches = age.compareTo(MAX_AGE) <= 0
                && age.compareTo(MAX_FUTURE_SKEW.negated()) >= 0
                && MessageDigest.isEqual(marker.guardSha256().getBytes(StandardCharsets.US_ASCII),
                        currentGuardSha256.getBytes(StandardCharsets.US_ASCII))
                && MessageDigest.isEqual(marker.instanceId(), expectedInstance);
        if (!matches) {
            Files.delete(path);
            System.err.println("[nbidal18-launch-guard] Discarded stale or mismatched Prism relaunch marker.");
            return;
        }

        String encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(marker.instanceId());
        String text = "nbidal18-prism-relaunch\t1\n"
                + "state\tacknowledged\n"
                + "nonce\t" + marker.nonce() + "\n"
                + "guard-sha256\t" + marker.guardSha256() + "\n"
                + "instance-id-base64\t" + encoded + "\n"
                + "armed-at-utc\t" + marker.armedAt() + "\n"
                + "acknowledged-at-utc\t" + now + "\n";
        LaunchGuard.writeAtomic(path, text.getBytes(StandardCharsets.UTF_8));
        System.out.println("[nbidal18-launch-guard] Acknowledged exact Prism relaunch request "
                + marker.nonce() + ".");
    }

    static Marker parse(byte[] bytes) throws GuardException {
        final String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException e) {
            throw new GuardException("Prism relaunch marker is not valid UTF-8.", e);
        }
        String[] lines = text.split("\\n", -1);
        boolean acknowledged;
        if (lines.length == 7 && lines[6].isEmpty() && lines[1].equals("state\tarmed")) {
            acknowledged = false;
        } else if (lines.length == 8 && lines[7].isEmpty() && lines[1].equals("state\tacknowledged")) {
            acknowledged = true;
        } else {
            throw new GuardException("Prism relaunch marker has an invalid record count or state.");
        }
        if (!lines[0].equals("nbidal18-prism-relaunch\t1")) {
            throw new GuardException("Prism relaunch marker has an invalid header.");
        }
        String nonce = field(lines[2], "nonce", NONCE);
        String guard = field(lines[3], "guard-sha256", SHA256);
        String encoded = field(lines[4], "instance-id-base64", BASE64URL);
        byte[] instance;
        try { instance = Base64.getUrlDecoder().decode(encoded); }
        catch (IllegalArgumentException e) { throw new GuardException("Prism relaunch instance ID is invalid.", e); }
        if (instance.length == 0 || instance.length > 512
                || !Base64.getUrlEncoder().withoutPadding().encodeToString(instance).equals(encoded)) {
            throw new GuardException("Prism relaunch instance ID encoding is non-canonical.");
        }
        Instant armed = instantField(lines[5], "armed-at-utc");
        Instant ack = acknowledged ? instantField(lines[6], "acknowledged-at-utc") : null;
        return new Marker(nonce, guard, instance, armed, ack);
    }

    private static String field(String line, String key, Pattern valuePattern) throws GuardException {
        String prefix = key + "\t";
        String value = line.startsWith(prefix) ? line.substring(prefix.length()) : "";
        if (!valuePattern.matcher(value).matches()) {
            throw new GuardException("Prism relaunch marker has an invalid " + key + " field.");
        }
        return value;
    }

    private static Instant instantField(String line, String key) throws GuardException {
        String prefix = key + "\t";
        if (!line.startsWith(prefix)) throw new GuardException("Prism relaunch marker is missing " + key + ".");
        try { return Instant.parse(line.substring(prefix.length())); }
        catch (DateTimeParseException e) { throw new GuardException("Prism relaunch marker has invalid time.", e); }
    }

    record Marker(String nonce, String guardSha256, byte[] instanceId,
                  Instant armedAt, Instant acknowledgedAt) {
        Marker { instanceId = instanceId.clone(); }
        @Override public byte[] instanceId() { return instanceId.clone(); }
    }
}
