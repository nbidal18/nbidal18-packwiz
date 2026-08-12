package dev.nbidal18.launchguard;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.URISyntaxException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.time.Duration;
import java.time.format.DateTimeParseException;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.jar.Attributes;
import java.util.jar.JarInputStream;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/** Secure, one-generation self-handoff to the guard embedded in the managed companion mod. */
final class NextGuardHandoff {
    static final String HANDOFF_RELATIVE = ".nbidal18/launch-guard-handoff.tsv";
    static final String REQUEST_RELATIVE = ".nbidal18/guard-handoff-request.tsv";

    private static final String PAYLOAD_ENTRY = "META-INF/nbidal18/nbidal18-launch-guard.jar";
    private static final String DESCRIPTOR_ENTRY = "META-INF/nbidal18/launch-guard.tsv";
    private static final String DEPTH_PROPERTY = "nbidal18.launchguard.handoff-depth";
    private static final String GUARD_PROPERTY = "nbidal18.launchguard.handoff-guard-sha256";
    private static final String COMPANION_PROPERTY = "nbidal18.launchguard.handoff-companion-sha256";
    private static final String MANIFEST_PROPERTY = "nbidal18.launchguard.handoff-manifest-sha256";
    private static final String TOKEN_PROPERTY = "nbidal18.launchguard.handoff-token";
    private static final int MAX_GUARD_BYTES = 16 * 1024 * 1024;
    private static final int MAX_COMPANION_BYTES = 64 * 1024 * 1024;
    private static final int MAX_DESCRIPTOR_BYTES = 1024;
    private static final long MAX_EXPANDED_COMPANION_BYTES = 128L * 1024L * 1024L;
    private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");
    private static final Pattern NONCE = Pattern.compile("[0-9a-f]{32}");
    private static final Duration MAX_REQUEST_AGE = Duration.ofMinutes(10);
    private static final Duration MAX_FUTURE_SKEW = Duration.ofSeconds(30);
    private static final Pattern COMPANION = Pattern.compile(
            "(?i)^mods/nbidal18-pack-compat-[^/]+\\.jar$");

    private NextGuardHandoff() {}

    record Request(
            Path candidate,
            String guardSha256,
            String companionSha256,
            String manifestSha256,
            int depth,
            String nonce) {}

    static String currentArtifactSha256() throws IOException, GuardException {
        final Path artifact;
        try {
            var source = LaunchGuard.class.getProtectionDomain().getCodeSource();
            if (source == null || source.getLocation() == null
                    || !"file".equalsIgnoreCase(source.getLocation().getProtocol())) {
                throw new GuardException("The running launch guard has no verifiable file artifact.");
            }
            artifact = Path.of(source.getLocation().toURI()).toAbsolutePath().normalize();
        } catch (URISyntaxException | IllegalArgumentException e) {
            throw new GuardException("The running launch-guard artifact path is invalid.", e);
        }
        LaunchGuard.requirePlainRegular(artifact, "running launch-guard artifact");
        if (Files.size(artifact) <= 0 || Files.size(artifact) > MAX_GUARD_BYTES) {
            throw new GuardException("The running launch-guard artifact has an unsafe size.");
        }
        return LaunchGuard.hash(artifact);
    }

    static Request find(Path root, StrictManifest manifest, String currentGuardSha256)
            throws IOException, GuardException {
        int depth = handoffDepth();
        StrictManifest.FileRule companionRule = null;
        for (StrictManifest.FileRule rule : manifest.managed.values()) {
            if (!COMPANION.matcher(rule.relative()).matches()) continue;
            if (companionRule != null) {
                throw new GuardException("Strict manifest declares more than one nbidal18 companion JAR.");
            }
            companionRule = rule;
        }
        if (companionRule == null) return null; // Compatible with older/non-companion v1 manifests.

        Path companion = LaunchGuard.resolve(root, companionRule.relative());
        byte[] companionBytes = LaunchGuard.readPlainBytes(companion, MAX_COMPANION_BYTES);
        String companionHash = sha256(companionBytes);
        if (!MessageDigest.isEqual(
                companionHash.getBytes(StandardCharsets.US_ASCII),
                companionRule.sha256().getBytes(StandardCharsets.US_ASCII))) {
            throw new GuardException("Managed companion SHA-256 mismatch before guard handoff: "
                    + companionRule.relative());
        }

        EmbeddedGuard embedded = readEmbeddedGuard(companionBytes);
        if (embedded.sha256().equals(currentGuardSha256)) return null;
        if (depth >= 1) {
            throw new GuardException("Launch-guard handoff depth exceeded; refusing a recursive guard chain.");
        }

        Path candidate = installCandidate(root, embedded);
        String nonce = UUID.randomUUID().toString().replace("-", "");
        armParentRequest(root, nonce, embedded.sha256(), companionHash, manifest.sha256);
        return new Request(candidate, embedded.sha256(), companionHash,
                manifest.sha256, depth + 1, nonce);
    }

    static int invoke(Path root, String packUrl, Request request)
            throws IOException, InterruptedException, GuardException {
        LaunchGuard.requirePlainRegular(request.candidate(), "validated next launch guard");
        if (!LaunchGuard.hash(request.candidate()).equals(request.guardSha256())) {
            throw new GuardException("The staged next launch guard changed before execution.");
        }
        Path javaExecutable = Path.of(System.getProperty("java.home"), "bin",
                isWindows() ? "java.exe" : "java");
        LaunchGuard.requirePlainRegular(javaExecutable, "Java executable");
        final Process process;
        try {
            process = new ProcessBuilder(
                    javaExecutable.toString(),
                    "-D" + DEPTH_PROPERTY + "=" + request.depth(),
                    "-D" + GUARD_PROPERTY + "=" + request.guardSha256(),
                    "-D" + COMPANION_PROPERTY + "=" + request.companionSha256(),
                    "-D" + MANIFEST_PROPERTY + "=" + request.manifestSha256(),
                    "-D" + TOKEN_PROPERTY + "=" + request.nonce(),
                    "-jar", request.candidate().toString(), packUrl)
                    .directory(root.toFile())
                    .inheritIO()
                    .start();
        } catch (IOException startFailure) {
            cleanupRequest(root, request.nonce());
            cleanupCandidate(root, request);
            throw startFailure;
        }
        int exitCode = process.waitFor();
        System.out.println("[nbidal18-launch-guard] Next-guard handoff exited with code " + exitCode + ".");
        if (exitCode == 0) {
            try {
                requireRequestConsumed(root);
                verifySuccessfulHandoffAttestation(root, request);
                cleanupCandidate(root, request);
                return 0;
            } catch (IOException | GuardException verificationFailure) {
                cleanupAfterRejectedSuccess(root, request, verificationFailure);
                throw verificationFailure;
            }
        }
        try {
            cleanupRequest(root, request.nonce());
            cleanupCandidate(root, request);
        } catch (Exception cleanupFailure) {
            System.err.println("[nbidal18-launch-guard] Could not clean failed handoff staging: "
                    + cleanupFailure.getMessage());
        }
        return exitCode;
    }

    /** Requires a fresh one-shot request at depth one; clears abandoned requests at depth zero. */
    static void consumeOrClearParentRequest(Path root, String currentGuardSha256)
            throws IOException, GuardException {
        Path path = LaunchGuard.resolve(root, REQUEST_RELATIVE);
        int depth = handoffDepth();
        if (depth == 0) {
            if (Files.exists(path, LinkOption.NOFOLLOW_LINKS)) deletePlainRequest(path);
            return;
        }
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            throw new GuardException("Handed-off guard has no parent-bound one-shot request.");
        }
        LaunchGuard.requirePlainRegular(path, "guard handoff parent request");
        ParentRequest request = parseParentRequest(LaunchGuard.readPlainBytes(path, 2048));
        String token = System.getProperty(TOKEN_PROPERTY, "");
        String expectedGuard = requiredHashProperty(GUARD_PROPERTY);
        String expectedCompanion = requiredHashProperty(COMPANION_PROPERTY);
        String expectedManifest = requiredHashProperty(MANIFEST_PROPERTY);
        Duration age = Duration.between(request.armedAt(), Instant.now());
        boolean valid = NONCE.matcher(token).matches()
                && MessageDigest.isEqual(token.getBytes(StandardCharsets.US_ASCII),
                        request.nonce().getBytes(StandardCharsets.US_ASCII))
                && MessageDigest.isEqual(currentGuardSha256.getBytes(StandardCharsets.US_ASCII),
                        request.guardSha256().getBytes(StandardCharsets.US_ASCII))
                && MessageDigest.isEqual(expectedGuard.getBytes(StandardCharsets.US_ASCII),
                        request.guardSha256().getBytes(StandardCharsets.US_ASCII))
                && MessageDigest.isEqual(expectedCompanion.getBytes(StandardCharsets.US_ASCII),
                        request.companionSha256().getBytes(StandardCharsets.US_ASCII))
                && MessageDigest.isEqual(expectedManifest.getBytes(StandardCharsets.US_ASCII),
                        request.manifestSha256().getBytes(StandardCharsets.US_ASCII))
                && age.compareTo(MAX_REQUEST_AGE) <= 0
                && age.compareTo(MAX_FUTURE_SKEW.negated()) >= 0;
        if (!valid) throw new GuardException("Handed-off guard parent request is stale or mismatched.");
        Files.delete(path); // Consumed under the same exclusive launch lock.
    }

    private static void armParentRequest(
            Path root, String nonce, String guardSha256, String companionSha256,
            String manifestSha256)
            throws IOException, GuardException {
        String text = "nbidal18-guard-handoff-request\t1\n"
                + "nonce\t" + nonce + "\n"
                + "guard-sha256\t" + guardSha256 + "\n"
                + "companion-sha256\t" + companionSha256 + "\n"
                + "manifest-sha256\t" + manifestSha256 + "\n"
                + "armed-at-utc\t" + Instant.now() + "\n";
        LaunchGuard.writeAtomic(LaunchGuard.resolve(root, REQUEST_RELATIVE),
                text.getBytes(StandardCharsets.UTF_8));
    }

    private static ParentRequest parseParentRequest(byte[] bytes) throws GuardException {
        final String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException e) {
            throw new GuardException("Guard handoff parent request is not valid UTF-8.", e);
        }
        String[] lines = text.split("\\n", -1);
        if (lines.length != 7 || !lines[6].isEmpty()
                || !lines[0].equals("nbidal18-guard-handoff-request\t1")) {
            throw new GuardException("Guard handoff parent request has an invalid format.");
        }
        String nonce = exactField(lines[1], "nonce", NONCE);
        String guard = exactField(lines[2], "guard-sha256", SHA256);
        String companion = exactField(lines[3], "companion-sha256", SHA256);
        String manifest = exactField(lines[4], "manifest-sha256", SHA256);
        Instant armed;
        String prefix = "armed-at-utc\t";
        if (!lines[5].startsWith(prefix)) throw new GuardException("Guard handoff request has no armed time.");
        try { armed = Instant.parse(lines[5].substring(prefix.length())); }
        catch (DateTimeParseException e) { throw new GuardException("Guard handoff request time is invalid.", e); }
        return new ParentRequest(nonce, guard, companion, manifest, armed);
    }

    private static String exactField(String line, String key, Pattern pattern) throws GuardException {
        String prefix = key + "\t";
        String value = line.startsWith(prefix) ? line.substring(prefix.length()) : "";
        if (!pattern.matcher(value).matches()) {
            throw new GuardException("Guard handoff request has invalid " + key + ".");
        }
        return value;
    }

    private static void cleanupRequest(Path root, String nonce) throws IOException, GuardException {
        Path path = LaunchGuard.resolve(root, REQUEST_RELATIVE);
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return;
        LaunchGuard.requirePlainRegular(path, "guard handoff parent request");
        ParentRequest request = parseParentRequest(LaunchGuard.readPlainBytes(path, 2048));
        if (MessageDigest.isEqual(nonce.getBytes(StandardCharsets.US_ASCII),
                request.nonce().getBytes(StandardCharsets.US_ASCII))) {
            Files.delete(path);
        }
    }

    private static void deletePlainRequest(Path path) throws IOException, GuardException {
        LaunchGuard.requirePlainRegular(path, "abandoned guard handoff parent request");
        Files.delete(path);
    }

    private static void cleanupCandidate(Path root, Request request) throws IOException, GuardException {
        Path directory = LaunchGuard.resolve(root, ".nbidal18/guard-candidates");
        Path expected = directory.resolve(request.guardSha256() + ".jar").normalize();
        if (!expected.equals(request.candidate()) || !expected.getParent().equals(directory)) {
            throw new GuardException("Refusing to clean an unexpected next-guard candidate path.");
        }
        if (Files.exists(expected, LinkOption.NOFOLLOW_LINKS)) {
            LaunchGuard.requirePlainRegular(expected, "completed next-guard candidate");
            if (!LaunchGuard.hash(expected).equals(request.guardSha256())) {
                throw new GuardException("Completed next-guard candidate changed before cleanup.");
            }
            Files.delete(expected);
        }
        try { Files.delete(directory); }
        catch (java.nio.file.DirectoryNotEmptyException ignored) {}
    }

    static void writeSuccessfulHandoffAttestation(
            Path root, String manifestSha256, String currentGuardSha256)
            throws IOException, GuardException {
        if (handoffDepth() == 0) return;
        String expectedGuard = requiredHashProperty(GUARD_PROPERTY);
        String companion = requiredHashProperty(COMPANION_PROPERTY);
        String expectedManifest = requiredHashProperty(MANIFEST_PROPERTY);
        if (!MessageDigest.isEqual(expectedGuard.getBytes(StandardCharsets.US_ASCII),
                currentGuardSha256.getBytes(StandardCharsets.US_ASCII))) {
            throw new GuardException("The handed-off guard artifact does not match its parent request.");
        }
        if (!MessageDigest.isEqual(expectedManifest.getBytes(StandardCharsets.US_ASCII),
                manifestSha256.getBytes(StandardCharsets.US_ASCII))) {
            throw new GuardException("The handed-off strict manifest changed after parent validation.");
        }
        String text = "nbidal18-launch-guard-handoff\t1\n"
                + "guard-sha256\t" + currentGuardSha256 + "\n"
                + "companion-sha256\t" + companion + "\n"
                + "manifest-sha256\t" + manifestSha256 + "\n"
                + "verified-at-utc\t" + Instant.now() + "\n";
        LaunchGuard.writeAtomic(LaunchGuard.resolve(root, HANDOFF_RELATIVE),
                text.getBytes(StandardCharsets.UTF_8));
    }

    private static int handoffDepth() throws GuardException {
        String value = System.getProperty(DEPTH_PROPERTY, "0");
        if (value.equals("0")) return 0;
        if (value.equals("1")) return 1;
        throw new GuardException("Invalid launch-guard handoff depth.");
    }

    private static String requiredHashProperty(String name) throws GuardException {
        String value = System.getProperty(name, "");
        if (!SHA256.matcher(value).matches()) {
            throw new GuardException("Missing or malformed launch-guard handoff identity.");
        }
        return value;
    }

    private static void requireRequestConsumed(Path root) throws GuardException {
        Path path = LaunchGuard.resolve(root, REQUEST_RELATIVE);
        if (Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            throw new GuardException("Next guard reported success without consuming its parent-bound request.");
        }
    }

    private static void verifySuccessfulHandoffAttestation(Path root, Request request)
            throws IOException, GuardException {
        Path path = LaunchGuard.resolve(root, HANDOFF_RELATIVE);
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            throw new GuardException("Next guard reported success without a handoff attestation.");
        }
        byte[] bytes = LaunchGuard.readPlainBytes(path, 2048);
        HandoffAttestation attestation = parseHandoffAttestation(bytes);
        Instant now = Instant.now();
        Duration age = Duration.between(attestation.verifiedAt(), now);
        boolean matches = MessageDigest.isEqual(
                    attestation.guardSha256().getBytes(StandardCharsets.US_ASCII),
                    request.guardSha256().getBytes(StandardCharsets.US_ASCII))
                && MessageDigest.isEqual(
                    attestation.companionSha256().getBytes(StandardCharsets.US_ASCII),
                    request.companionSha256().getBytes(StandardCharsets.US_ASCII))
                && MessageDigest.isEqual(
                    attestation.manifestSha256().getBytes(StandardCharsets.US_ASCII),
                    request.manifestSha256().getBytes(StandardCharsets.US_ASCII))
                && age.compareTo(MAX_REQUEST_AGE) <= 0
                && age.compareTo(MAX_FUTURE_SKEW.negated()) >= 0;
        if (!matches) {
            throw new GuardException("Next guard reported success with a stale or mismatched handoff attestation.");
        }
    }

    private static HandoffAttestation parseHandoffAttestation(byte[] bytes) throws GuardException {
        final String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException e) {
            throw new GuardException("Launch-guard handoff attestation is not valid UTF-8.", e);
        }
        String[] lines = text.split("\\n", -1);
        if (lines.length != 6 || !lines[5].isEmpty()
                || !lines[0].equals("nbidal18-launch-guard-handoff\t1")) {
            throw new GuardException("Launch-guard handoff attestation has an invalid format.");
        }
        String guard = exactField(lines[1], "guard-sha256", SHA256);
        String companion = exactField(lines[2], "companion-sha256", SHA256);
        String manifest = exactField(lines[3], "manifest-sha256", SHA256);
        String prefix = "verified-at-utc\t";
        if (!lines[4].startsWith(prefix)) {
            throw new GuardException("Launch-guard handoff attestation has no verification time.");
        }
        final Instant verified;
        try { verified = Instant.parse(lines[4].substring(prefix.length())); }
        catch (DateTimeParseException e) {
            throw new GuardException("Launch-guard handoff attestation time is invalid.", e);
        }
        return new HandoffAttestation(guard, companion, manifest, verified);
    }

    private static void cleanupAfterRejectedSuccess(
            Path root, Request request, Exception primaryFailure) {
        try { cleanupRequest(root, request.nonce()); }
        catch (Exception cleanupFailure) { primaryFailure.addSuppressed(cleanupFailure); }
        try { cleanupCandidate(root, request); }
        catch (Exception cleanupFailure) { primaryFailure.addSuppressed(cleanupFailure); }
    }

    private static Path installCandidate(Path root, EmbeddedGuard embedded)
            throws IOException, GuardException {
        Path directory = LaunchGuard.resolve(root, ".nbidal18/guard-candidates");
        LaunchGuard.ensurePlainDirectoryTree(root, directory);
        Path target = directory.resolve(embedded.sha256() + ".jar").normalize();
        if (!target.getParent().equals(directory)) {
            throw new GuardException("Unsafe next-guard candidate path.");
        }
        if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
            LaunchGuard.requirePlainRegular(target, "next-guard candidate");
            if (!LaunchGuard.hash(target).equals(embedded.sha256())) {
                throw new GuardException("A hash-named next-guard candidate contains different bytes.");
            }
            return target;
        }

        Path temporary = Files.createTempFile(directory, ".candidate-", ".tmp");
        try {
            Files.write(temporary, embedded.payload(), StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
            LaunchGuard.requirePlainRegular(temporary, "staged next-guard candidate");
            if (!LaunchGuard.hash(temporary).equals(embedded.sha256())) {
                throw new GuardException("The staged next-guard candidate failed hash verification.");
            }
            try {
                Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE);
            } catch (FileAlreadyExistsException exists) {
                // Another validated process may have published the same immutable hash-named file.
            } catch (AtomicMoveNotSupportedException unsupported) {
                throw new GuardException("The game directory cannot atomically stage a next launch guard.", unsupported);
            }
        } finally {
            Files.deleteIfExists(temporary);
        }
        LaunchGuard.requirePlainRegular(target, "next-guard candidate");
        if (!LaunchGuard.hash(target).equals(embedded.sha256())) {
            throw new GuardException("The published next-guard candidate failed hash verification.");
        }
        return target;
    }

    static EmbeddedGuard readEmbeddedGuard(byte[] companionBytes) throws IOException, GuardException {
        byte[] payload = null;
        byte[] descriptor = null;
        Set<String> names = new HashSet<>();
        long expanded = 0;
        try (ZipInputStream zip = new ZipInputStream(new ByteArrayInputStream(companionBytes), StandardCharsets.UTF_8)) {
            ZipEntry entry;
            while ((entry = zip.getNextEntry()) != null) {
                if (!names.add(entry.getName())) {
                    throw new GuardException("Managed companion contains a duplicate ZIP entry: " + entry.getName());
                }
                byte[] content = readZipEntry(zip, entry.getName());
                expanded += content.length;
                if (expanded > MAX_EXPANDED_COMPANION_BYTES) {
                    throw new GuardException("Managed companion expands beyond the safety limit.");
                }
                if (entry.getName().equals(PAYLOAD_ENTRY)) {
                    if (payload != null) throw new GuardException("Managed companion has duplicate guard payloads.");
                    payload = content;
                } else if (entry.getName().equals(DESCRIPTOR_ENTRY)) {
                    if (descriptor != null) throw new GuardException("Managed companion has duplicate guard descriptors.");
                    descriptor = content;
                }
                zip.closeEntry();
            }
        }
        if (payload == null || descriptor == null) {
            throw new GuardException("Managed companion is missing its exact embedded guard payload or descriptor.");
        }
        if (payload.length == 0 || payload.length > MAX_GUARD_BYTES
                || descriptor.length == 0 || descriptor.length > MAX_DESCRIPTOR_BYTES) {
            throw new GuardException("Managed companion embeds an unsafe guard payload or descriptor size.");
        }
        Descriptor parsed = parseDescriptor(descriptor);
        if (payload.length != parsed.size() || !sha256(payload).equals(parsed.sha256())) {
            throw new GuardException("Managed companion embedded guard does not match its descriptor.");
        }
        validateGuardIdentity(payload);
        return new EmbeddedGuard(payload, parsed.sha256());
    }

    private static byte[] readZipEntry(ZipInputStream input, String name) throws IOException, GuardException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int total = 0;
        int read;
        while ((read = input.read(buffer)) >= 0) {
            total += read;
            if (total > MAX_COMPANION_BYTES) {
                throw new GuardException("Managed companion ZIP entry exceeds the safety limit: " + name);
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }

    private static Descriptor parseDescriptor(byte[] bytes) throws GuardException {
        final String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException e) {
            throw new GuardException("Embedded guard descriptor is not valid UTF-8.", e);
        }
        String[] lines = text.split("\\n", -1);
        if (lines.length != 4 || !lines[3].isEmpty()
                || !lines[0].equals("nbidal18-launch-guard\t1")
                || lines[0].endsWith("\r") || lines[1].endsWith("\r") || lines[2].endsWith("\r")) {
            throw new GuardException("Embedded guard descriptor has an invalid format.");
        }
        String[] hash = lines[1].split("\\t", -1);
        String[] size = lines[2].split("\\t", -1);
        if (hash.length != 2 || !hash[0].equals("sha256") || !SHA256.matcher(hash[1]).matches()
                || size.length != 2 || !size[0].equals("size")) {
            throw new GuardException("Embedded guard descriptor has invalid fields.");
        }
        final int parsedSize;
        try { parsedSize = Integer.parseInt(size[1]); }
        catch (NumberFormatException e) { throw new GuardException("Embedded guard descriptor size is invalid.", e); }
        if (parsedSize <= 0 || parsedSize > MAX_GUARD_BYTES) {
            throw new GuardException("Embedded guard descriptor size is unsafe.");
        }
        return new Descriptor(hash[1], parsedSize);
    }

    private static void validateGuardIdentity(byte[] payload) throws IOException, GuardException {
        boolean mainClassPresent = false;
        try (JarInputStream jar = new JarInputStream(new ByteArrayInputStream(payload), false)) {
            Attributes attributes = jar.getManifest() == null ? null : jar.getManifest().getMainAttributes();
            if (attributes == null
                    || !"dev.nbidal18.launchguard.LaunchGuard".equals(attributes.getValue("Main-Class"))
                    || !"nbidal18-launch-guard".equals(attributes.getValue("Implementation-Title"))) {
                throw new GuardException("Embedded guard JAR has an unexpected executable identity.");
            }
            ZipEntry entry;
            while ((entry = jar.getNextEntry()) != null) {
                if (entry.getName().equals("dev/nbidal18/launchguard/LaunchGuard.class")) {
                    if (mainClassPresent) throw new GuardException("Embedded guard JAR duplicates its main class.");
                    mainClassPresent = true;
                }
            }
        }
        if (!mainClassPresent) throw new GuardException("Embedded guard JAR is missing its main class.");
    }

    private static String sha256(byte[] bytes) throws GuardException {
        try { return HexFormatSupport.hex(MessageDigest.getInstance("SHA-256").digest(bytes)); }
        catch (NoSuchAlgorithmException e) { throw new GuardException("SHA-256 is unavailable.", e); }
    }

    private static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win");
    }

    record EmbeddedGuard(byte[] payload, String sha256) {
        EmbeddedGuard { payload = payload.clone(); }
        @Override public byte[] payload() { return payload.clone(); }
    }
    private record Descriptor(String sha256, int size) {}
    private record ParentRequest(String nonce, String guardSha256,
                                 String companionSha256, String manifestSha256,
                                 Instant armedAt) {}
    private record HandoffAttestation(String guardSha256, String companionSha256,
                                      String manifestSha256, Instant verifiedAt) {}
}
