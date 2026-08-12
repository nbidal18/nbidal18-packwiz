package dev.nbidal18.launchguard;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.DirectoryNotEmptyException;
import java.nio.file.DirectoryStream;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

public final class LaunchGuard {
    private static final String CONTROL_DIR = ".nbidal18";
    private static final String ATTESTATION = CONTROL_DIR + "/integrity-attestation.tsv";
    private static final String HANDOFF_ATTESTATION = CONTROL_DIR + "/launch-guard-handoff.tsv";
    private static final String STATE = "packwiz.json";
    private static final String BOOTSTRAP = "packwiz-installer-bootstrap.jar";
    private static final long MAX_TEXT_BYTES = 16L * 1024L * 1024L;
    private static final LinkOption[] NO_FOLLOW = { LinkOption.NOFOLLOW_LINKS };
    private static final DateTimeFormatter RUN_TIME = DateTimeFormatter
            .ofPattern("uuuuMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC);

    private final Path root;
    private final String packUrl;
    private final Quarantine quarantine;
    private final InternalWork internalWork;

    private LaunchGuard(Path root, String packUrl) throws IOException, GuardException {
        this.root = root;
        this.packUrl = validatePackUrl(packUrl);
        Path control = resolve(root, CONTROL_DIR);
        ensurePlainDirectoryTree(root, control);
        this.quarantine = Quarantine.create(root, control.resolve("quarantine"));
        this.internalWork = InternalWork.create(root, control.resolve("guard-work"));
    }

    public static void main(String[] args) {
        int exitCode;
        try {
            if (args.length != 1) throw new GuardException("Usage: java -jar nbidal18-launch-guard.jar <https-pack.toml-url>");
            Path root = Path.of("").toAbsolutePath().normalize().toRealPath();
            BasicFileAttributes rootAttributes = Files.readAttributes(root, BasicFileAttributes.class, NO_FOLLOW);
            if (!rootAttributes.isDirectory() || isLinkOrReparse(root, rootAttributes)) {
                throw new GuardException("Minecraft working directory is not a plain directory: " + root);
            }
            LaunchGuard guard = new LaunchGuard(root, args[0]);
            exitCode = guard.runWithLock();
        } catch (PackwizExit e) {
            System.err.println("[nbidal18-launch-guard] Packwiz failed with exit code " + e.exitCode + ". Launch blocked.");
            exitCode = e.exitCode == 0 ? 70 : e.exitCode;
        } catch (Exception e) {
            System.err.println("[nbidal18-launch-guard] ERROR: " + e.getMessage());
            e.printStackTrace(System.err);
            exitCode = 70;
        }
        if (exitCode != 0) System.exit(exitCode);
    }

    private int runWithLock() throws Exception {
        Path lockPath = resolve(root, CONTROL_DIR + "/launch-guard.lock");
        if (Files.exists(lockPath, NO_FOLLOW)) requirePlainRegular(lockPath, "launch guard lock");
        ExecutionOutcome outcome;
        try (FileChannel channel = FileChannel.open(lockPath,
                StandardOpenOption.CREATE, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS)) {
            final FileLock lock;
            try {
                lock = channel.tryLock();
            } catch (OverlappingFileLockException e) {
                throw new GuardException("Another launch guard is already running.", e);
            }
            if (lock == null) throw new GuardException("Another launch guard is already running.");
            try (lock) {
                String currentGuardSha256 = NextGuardHandoff.currentArtifactSha256();
                PrismRelaunchMarker.acknowledgeIfArmed(root, currentGuardSha256);
                NextGuardHandoff.consumeOrClearParentRequest(root, currentGuardSha256);
                outcome = execute(currentGuardSha256);
            }
        }
        if (outcome.handoff() != null) {
            int exitCode = NextGuardHandoff.invoke(root, packUrl, outcome.handoff());
            if (exitCode == 0) internalWork.removeAfterSuccess();
            return exitCode;
        }
        return outcome.exitCode();
    }

    private ExecutionOutcome execute(String currentGuardSha256) throws Exception {
        System.out.println("[nbidal18-launch-guard] Starting strict pre-launch validation in " + root);
        deleteStaleAttestation();
        deleteStaleHandoffAttestation();
        requirePlainRegular(resolve(root, BOOTSTRAP), "Packwiz bootstrap");

        Path localManifestPath = resolve(root, StrictManifest.RELATIVE_MANIFEST);
        if (Files.exists(localManifestPath, NO_FOLLOW)) {
            StrictManifest previousManifest = readManifest();
            backupSeedTargets(previousManifest);
        }

        runPackwiz(false);
        StrictManifest firstManifest = readManifest();
        Path state = resolve(root, STATE);
        requirePlainRegular(state, "Packwiz state after normal update");
        internalWork.move(state, STATE);

        boolean successful = false;
        try {
            runPackwiz(true);
            requirePlainRegular(state, "Packwiz state after forced validation");
            StrictManifest manifest = readManifest();
            if (!manifest.sha256.equals(firstManifest.sha256)) {
                throw new GuardException("Strict manifest changed between the two Packwiz passes; retry the launch.");
            }

            applyStrictPolicy(manifest);
            // Candidate code is considered only after the forced Packwiz pass,
            // manifest stability check, strict cleanup, and exact managed-file
            // verification have all succeeded. The normal Packwiz fast path is
            // deliberately insufficient authority to execute downloaded code.
            NextGuardHandoff.Request handoff = NextGuardHandoff.find(
                    root, manifest, currentGuardSha256);
            if (handoff != null) {
                System.out.println("[nbidal18-launch-guard] A fully validated newer embedded guard will finish this launch.");
                return ExecutionOutcome.handoff(handoff);
            }
            writeAttestation(manifest.sha256);
            NextGuardHandoff.writeSuccessfulHandoffAttestation(root, manifest.sha256, currentGuardSha256);
            successful = true;
            System.out.println("[nbidal18-launch-guard] Strict integrity validation passed.");
            return ExecutionOutcome.success();
        } finally {
            if (successful) internalWork.removeAfterSuccess();
        }
    }

    private void runPackwiz(boolean forcedPass) throws IOException, InterruptedException, GuardException, PackwizExit {
        Path javaExecutable = Path.of(System.getProperty("java.home"), "bin", isWindows() ? "java.exe" : "java");
        requirePlainRegular(javaExecutable, "Java executable");
        List<String> command = new ArrayList<>();
        command.add(javaExecutable.toString());
        command.add("-jar");
        command.add(BOOTSTRAP);
        if (forcedPass) command.add("--bootstrap-no-update");
        command.add("-g");
        command.add(packUrl);
        System.out.println("[nbidal18-launch-guard] Running Packwiz " + (forcedPass ? "forced hash-validation" : "normal update") + " pass...");
        Process process = new ProcessBuilder(command).directory(root.toFile()).inheritIO().start();
        int exitCode = process.waitFor();
        if (exitCode != 0) throw new PackwizExit(exitCode);
    }

    private StrictManifest readManifest() throws IOException, GuardException {
        Path path = resolve(root, StrictManifest.RELATIVE_MANIFEST);
        ensurePlainDirectoryTree(root, path.getParent());
        byte[] bytes = readPlainBytes(path, MAX_TEXT_BYTES);
        StrictManifest manifest = StrictManifest.parse(bytes);
        System.out.println("[nbidal18-launch-guard] Loaded strict manifest SHA-256 " + manifest.sha256);
        return manifest;
    }

    private void applyStrictPolicy(StrictManifest manifest) throws IOException, GuardException {
        for (Map.Entry<String, String> entry : manifest.regeneratePrefixes.entrySet()) {
            Path generated = resolve(root, entry.getValue());
            ensurePlainDirectoryTree(root, generated.getParent());
            if (Files.exists(generated, NO_FOLLOW)) {
                deleteGeneratedCacheNode(generated, generated);
                System.out.println("[nbidal18-launch-guard] Purged regenerate-prefix: " + entry.getValue());
            }
        }

        Set<String> allowedFiles = new HashSet<>();
        allowedFiles.addAll(manifest.managed.keySet());
        allowedFiles.addAll(manifest.optional.keySet());
        allowedFiles.addAll(manifest.personal.keySet());
        allowedFiles.addAll(manifest.runtime.keySet());
        for (StrictManifest.SeedRule seed : manifest.seeds) allowedFiles.add(seed.targetKey());

        Map<String, String> canonicalPaths = new HashMap<>();
        for (StrictManifest.FileRule rule : manifest.managed.values()) canonicalPaths.put(rule.key(), rule.relative());
        for (StrictManifest.FileRule rule : manifest.optional.values()) canonicalPaths.put(rule.key(), rule.relative());
        canonicalPaths.putAll(manifest.personal);
        canonicalPaths.putAll(manifest.runtime);
        for (StrictManifest.SeedRule seed : manifest.seeds) canonicalPaths.put(seed.targetKey(), seed.target());

        Set<String> neededDirectories = new HashSet<>();
        for (String file : allowedFiles) addAncestors(file, neededDirectories, true);
        for (String regenerate : manifest.regeneratePrefixes.keySet()) addAncestors(regenerate, neededDirectories, false);
        for (String runtimePrefix : manifest.runtimePrefixes.keySet()) {
            neededDirectories.add(runtimePrefix);
            addAncestors(runtimePrefix, neededDirectories, false);
        }

        for (String strictRelative : manifest.strictDirs) {
            cleanStrictDirectory(strictRelative, manifest, allowedFiles, canonicalPaths, neededDirectories);
        }

        verifyManagedFiles(manifest);
        seedPlayerFiles(manifest);
        MixedSettings.enforce(root, manifest);
        verifyRegeneratePrefixesAbsent(manifest);
        purgeFabricGeneratedCaches();
        purgeTopLevelGeneratedCache("dynamic-resource-pack-cache");
    }

    private void cleanStrictDirectory(
            String strictRelative,
            StrictManifest manifest,
            Set<String> allowedFiles,
            Map<String, String> canonicalPaths,
            Set<String> neededDirectories) throws IOException, GuardException {
        Path strictPath = resolve(root, strictRelative);
        if (Files.exists(strictPath, NO_FOLLOW)) {
            BasicFileAttributes attributes = Files.readAttributes(strictPath, BasicFileAttributes.class, NO_FOLLOW);
            if (!attributes.isDirectory() || isLinkOrReparse(strictPath, attributes)) {
                quarantine.move(strictPath, strictRelative);
                ensurePlainDirectoryTree(root, strictPath);
            }
        } else {
            ensurePlainDirectoryTree(root, strictPath);
        }

        try {
            Files.walkFileTree(strictPath, new SimpleFileVisitor<>() {
            @Override
            public FileVisitResult preVisitDirectory(Path directory, BasicFileAttributes attributes) throws IOException {
                if (directory.equals(strictPath)) return FileVisitResult.CONTINUE;
                String relative = relative(root, directory);
                String key = StrictManifest.key(relative);
                try {
                    if (isLinkOrReparse(directory, attributes)) {
                        quarantine.move(directory, relative);
                        return FileVisitResult.SKIP_SUBTREE;
                    }
                    if (manifest.runtimePrefixes.containsKey(key)) {
                        if (!manifest.runtimePrefixes.get(key).equals(relative)) {
                            quarantine.move(directory, relative);
                        }
                        return FileVisitResult.SKIP_SUBTREE;
                    }
                    if (!neededDirectories.contains(key)) {
                        quarantine.move(directory, relative);
                        return FileVisitResult.SKIP_SUBTREE;
                    }
                } catch (GuardException e) {
                    throw new PolicyIOException(e);
                }
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attributes) throws IOException {
                String relative = relative(root, file);
                String key = StrictManifest.key(relative);
                try {
                    if (isLinkOrReparse(file, attributes) || !attributes.isRegularFile()) {
                        quarantine.move(file, relative);
                        return FileVisitResult.CONTINUE;
                    }
                    if (!allowedFiles.contains(key)) {
                        quarantine.move(file, relative);
                        return FileVisitResult.CONTINUE;
                    }
                    String canonical = canonicalPaths.get(key);
                    if (canonical != null && !canonical.equals(relative)) {
                        quarantine.move(file, relative);
                        return FileVisitResult.CONTINUE;
                    }
                    StrictManifest.FileRule optional = manifest.optional.get(key);
                    if (optional != null && !hash(file).equals(optional.sha256())) {
                        System.err.println("[nbidal18-launch-guard] Quarantining optional file with an unapproved hash: " + relative);
                        quarantine.move(file, relative);
                    }
                } catch (GuardException e) {
                    throw new PolicyIOException(e);
                }
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFileFailed(Path file, IOException error) throws IOException {
                throw new IOException("Unable to inspect strict path: " + file, error);
            }
            });
        } catch (PolicyIOException e) {
            if (e.getCause() instanceof GuardException guardException) throw guardException;
            throw e;
        }
    }

    private void verifyManagedFiles(StrictManifest manifest) throws IOException, GuardException {
        for (StrictManifest.FileRule rule : manifest.managed.values()) {
            Path path = resolve(root, rule.relative());
            ensurePlainDirectoryTree(root, path.getParent());
            requirePlainRegular(path, "managed file");
            String actual = hash(path);
            if (!actual.equals(rule.sha256())) {
                quarantine.move(path, rule.relative());
                throw new GuardException("Managed SHA-256 mismatch after Packwiz validation: " + rule.relative());
            }
        }
    }

    private void seedPlayerFiles(StrictManifest manifest) throws IOException, GuardException {
        for (StrictManifest.SeedRule seed : manifest.seeds) {
            Path template = resolve(root, seed.template());
            Path target = resolve(root, seed.target());
            ensurePlainDirectoryTree(root, template.getParent());
            ensurePlainDirectoryTree(root, target.getParent());
            requirePlainRegular(template, "seed template");
            if (Files.exists(target, NO_FOLLOW)) {
                BasicFileAttributes attributes = Files.readAttributes(target, BasicFileAttributes.class, NO_FOLLOW);
                if (attributes.isRegularFile() && !isLinkOrReparse(target, attributes)) continue;
                quarantine.move(target, seed.target());
            }
            if (internalWork.restoreSeedTarget(target, seed.target())) {
                System.out.println("[nbidal18-launch-guard] Preserved player setting across manifest transition: " + seed.target());
                continue;
            }
            ensurePlainDirectoryTree(root, target.getParent());
            Path temporary = target.resolveSibling(target.getFileName() + ".seed-" + UUID.randomUUID() + ".tmp");
            try {
                Files.copy(template, temporary, LinkOption.NOFOLLOW_LINKS);
                moveAtomic(temporary, target);
            } finally {
                Files.deleteIfExists(temporary);
            }
            System.out.println("[nbidal18-launch-guard] Seeded first-run player setting: " + seed.target());
        }
    }

    private void backupSeedTargets(StrictManifest previousManifest) throws IOException, GuardException {
        for (StrictManifest.SeedRule seed : previousManifest.seeds) {
            Path target = resolve(root, seed.target());
            ensurePlainDirectoryTree(root, target.getParent());
            if (!Files.exists(target, NO_FOLLOW)) continue;
            requirePlainRegular(target, "existing seed target");
            internalWork.backupSeedTarget(target, seed.target());
        }
    }

    private void verifyRegeneratePrefixesAbsent(StrictManifest manifest) throws GuardException {
        for (String relative : manifest.regeneratePrefixes.values()) {
            if (Files.exists(resolve(root, relative), NO_FOLLOW)) {
                throw new GuardException("regenerate-prefix still exists after cleanup: " + relative);
            }
        }
    }

    private void purgeFabricGeneratedCaches() throws IOException, GuardException {
        Path fabric = resolve(root, ".fabric");
        if (!Files.exists(fabric, NO_FOLLOW)) return;

        BasicFileAttributes fabricAttributes = Files.readAttributes(fabric, BasicFileAttributes.class, NO_FOLLOW);
        if (!fabricAttributes.isDirectory() || isLinkOrReparse(fabric, fabricAttributes)) {
            throw new GuardException("Unsafe .fabric ancestry; expected a plain in-instance directory: " + fabric);
        }

        for (String name : List.of("processedMods", "remappedJars", "tmp")) {
            Path generatedRoot = fabric.resolve(name).normalize();
            if (!generatedRoot.getParent().equals(fabric)) {
                throw new GuardException("Unsafe generated Fabric cache path: " + generatedRoot);
            }
            if (!Files.exists(generatedRoot, NO_FOLLOW)) continue;
            deleteGeneratedCacheNode(generatedRoot, generatedRoot);
            System.out.println("[nbidal18-launch-guard] Purged generated Fabric cache: .fabric/" + name);
        }
    }

    private void purgeTopLevelGeneratedCache(String name) throws IOException, GuardException {
        Path generatedRoot = resolve(root, name);
        if (!generatedRoot.getParent().equals(root)) {
            throw new GuardException("Unsafe top-level generated cache path: " + generatedRoot);
        }
        if (!Files.exists(generatedRoot, NO_FOLLOW)) return;
        deleteGeneratedCacheNode(generatedRoot, generatedRoot);
        System.out.println("[nbidal18-launch-guard] Purged generated cache: " + name);
    }

    private void deleteGeneratedCacheNode(Path cacheRoot, Path node) throws IOException, GuardException {
        Path trustedRoot = cacheRoot.toAbsolutePath().normalize();
        Path normalized = node.toAbsolutePath().normalize();
        if (!normalized.startsWith(trustedRoot)) {
            throw new GuardException("Refusing to purge outside generated Fabric cache root: " + node);
        }

        BasicFileAttributes attributes = Files.readAttributes(node, BasicFileAttributes.class, NO_FOLLOW);
        if (!attributes.isDirectory() || isLinkOrReparse(node, attributes)) {
            Files.delete(node); // Deletes a file/link/reparse node itself; never follows its target.
            return;
        }

        try (DirectoryStream<Path> children = Files.newDirectoryStream(node)) {
            for (Path child : children) deleteGeneratedCacheNode(trustedRoot, child);
        }
        Files.delete(node);
    }

    private void writeAttestation(String manifestHash) throws IOException, GuardException {
        String text = "nbidal18-integrity-attestation\t1\n"
                + "manifest-sha256\t" + manifestHash + "\n"
                + "verified-at-utc\t" + Instant.now() + "\n";
        Path target = resolve(root, ATTESTATION);
        writeAtomic(target, text.getBytes(StandardCharsets.UTF_8));
    }

    private void deleteStaleAttestation() throws IOException, GuardException {
        Path path = resolve(root, ATTESTATION);
        if (!Files.exists(path, NO_FOLLOW)) return;
        BasicFileAttributes attributes = Files.readAttributes(path, BasicFileAttributes.class, NO_FOLLOW);
        if (attributes.isDirectory() && !attributes.isSymbolicLink()) {
            throw new GuardException("Integrity attestation path is unexpectedly a directory: " + path);
        }
        Files.delete(path); // Deletes a link/reparse node itself; it never follows it.
    }

    private void deleteStaleHandoffAttestation() throws IOException, GuardException {
        Path path = resolve(root, HANDOFF_ATTESTATION);
        if (!Files.exists(path, NO_FOLLOW)) return;
        BasicFileAttributes attributes = Files.readAttributes(path, BasicFileAttributes.class, NO_FOLLOW);
        if (attributes.isDirectory() && !attributes.isSymbolicLink()) {
            throw new GuardException("Launch-guard handoff attestation path is unexpectedly a directory: " + path);
        }
        Files.delete(path);
    }

    static String validatePackUrl(String value) throws GuardException {
        final URI uri;
        try { uri = new URI(value); }
        catch (URISyntaxException e) { throw new GuardException("Invalid Packwiz URL.", e); }
        String scheme = uri.getScheme();
        if (scheme == null || (!scheme.equalsIgnoreCase("https") && !scheme.equalsIgnoreCase("http"))
                || uri.getHost() == null || uri.getFragment() != null || uri.getRawUserInfo() != null) {
            throw new GuardException("Packwiz URL must be an absolute HTTP(S) URL without userinfo or a fragment.");
        }
        if (scheme.equalsIgnoreCase("http") && !isLoopbackHost(uri.getHost())) {
            throw new GuardException("Plain HTTP Packwiz URLs are allowed only for an exact loopback host used by isolated tests.");
        }
        if (!uri.getPath().toLowerCase(Locale.ROOT).endsWith("/pack.toml")) {
            throw new GuardException("Packwiz URL must end with /pack.toml.");
        }
        return uri.toASCIIString();
    }

    private static boolean isLoopbackHost(String rawHost) {
        String host = rawHost;
        if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length() - 1);
        if (host.equalsIgnoreCase("localhost")) return true;

        if (host.indexOf(':') >= 0) {
            if (host.indexOf('%') >= 0) return false; // Reject scoped/encoded variants.
            try {
                InetAddress address = InetAddress.getByName(host);
                return address instanceof Inet6Address && address.isLoopbackAddress();
            } catch (UnknownHostException e) {
                return false;
            }
        }

        String[] octets = host.split("\\.", -1);
        if (octets.length != 4) return false;
        int first = -1;
        for (int index = 0; index < octets.length; index++) {
            String octet = octets[index];
            if (octet.isEmpty() || (octet.length() > 1 && octet.startsWith("0"))) return false;
            for (int character = 0; character < octet.length(); character++) {
                char value = octet.charAt(character);
                if (value < '0' || value > '9') return false;
            }
            final int parsed;
            try { parsed = Integer.parseInt(octet); }
            catch (NumberFormatException e) { return false; }
            if (parsed > 255) return false;
            if (index == 0) first = parsed;
        }
        return first == 127;
    }

    static Path resolve(Path root, String relative) throws GuardException {
        Path result = root.resolve(relative.replace('/', java.io.File.separatorChar)).normalize();
        if (!result.startsWith(root) || result.equals(root)) throw new GuardException("Path escapes Minecraft root: " + relative);
        return result;
    }

    static String readPlainUtf8(Path path) throws IOException, GuardException {
        byte[] bytes = readPlainBytes(path, MAX_TEXT_BYTES);
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (java.nio.charset.CharacterCodingException e) {
            throw new GuardException("File is not valid UTF-8: " + path, e);
        }
    }

    static byte[] readPlainBytes(Path path, long maximum) throws IOException, GuardException {
        requirePlainRegular(path, "required file");
        try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            ByteBuffer buffer = ByteBuffer.allocate(8192);
            long total = 0;
            while (channel.read(buffer) >= 0) {
                buffer.flip();
                int count = buffer.remaining();
                total += count;
                if (total > maximum) throw new GuardException("Text file exceeds safety limit: " + path);
                output.write(buffer.array(), buffer.position(), count);
                buffer.clear();
            }
            requirePlainRegular(path, "required file");
            return output.toByteArray();
        }
    }

    static void writeUtf8IfChanged(Path path, String text) throws IOException, GuardException {
        byte[] replacement = text.getBytes(StandardCharsets.UTF_8);
        byte[] existing = readPlainBytes(path, MAX_TEXT_BYTES);
        if (!java.util.Arrays.equals(existing, replacement)) writeAtomic(path, replacement);
    }

    static void writeAtomic(Path target, byte[] bytes) throws IOException, GuardException {
        Path parent = target.toAbsolutePath().normalize().getParent();
        BasicFileAttributes parentAttributes = Files.readAttributes(parent, BasicFileAttributes.class, NO_FOLLOW);
        if (!parentAttributes.isDirectory() || isLinkOrReparse(parent, parentAttributes)) {
            throw new GuardException("Atomic-write parent is not a plain directory: " + parent);
        }
        if (Files.exists(target, NO_FOLLOW)) requirePlainRegular(target, "atomic-write target");
        Path temporary = target.resolveSibling(target.getFileName() + ".write-" + UUID.randomUUID() + ".tmp");
        try {
            Files.write(temporary, bytes, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
            moveAtomic(temporary, target);
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    static String hash(Path path) throws IOException, GuardException {
        requirePlainRegular(path, "hash target");
        final MessageDigest digest;
        try { digest = MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException e) { throw new GuardException("SHA-256 is unavailable.", e); }
        try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            ByteBuffer buffer = ByteBuffer.allocateDirect(64 * 1024);
            while (channel.read(buffer) >= 0) {
                buffer.flip();
                digest.update(buffer);
                buffer.clear();
            }
        }
        requirePlainRegular(path, "hash target");
        return HexFormatSupport.hex(digest.digest());
    }

    static void requirePlainRegular(Path path, String description) throws IOException, GuardException {
        final BasicFileAttributes attributes;
        try { attributes = Files.readAttributes(path, BasicFileAttributes.class, NO_FOLLOW); }
        catch (NoSuchFileException e) { throw new GuardException("Missing " + description + ": " + path, e); }
        if (!attributes.isRegularFile() || isLinkOrReparse(path, attributes)) {
            throw new GuardException(description + " is not a plain regular file: " + path);
        }
    }

    static void ensurePlainDirectoryTree(Path trustedRoot, Path directory) throws IOException, GuardException {
        Path root = trustedRoot.toAbsolutePath().normalize();
        Path target = directory.toAbsolutePath().normalize();
        if (!target.startsWith(root)) throw new GuardException("Directory escapes trusted root: " + target);
        Path current = root;
        for (Path component : root.relativize(target)) {
            current = current.resolve(component);
            if (!Files.exists(current, NO_FOLLOW)) {
                try { Files.createDirectory(current); }
                catch (FileAlreadyExistsException ignored) {}
            }
            BasicFileAttributes attributes = Files.readAttributes(current, BasicFileAttributes.class, NO_FOLLOW);
            if (!attributes.isDirectory() || isLinkOrReparse(current, attributes)) {
                throw new GuardException("Unsafe directory or reparse point: " + current);
            }
        }
    }

    static boolean isLinkOrReparse(Path path, BasicFileAttributes attributes) throws IOException {
        if (attributes.isSymbolicLink() || attributes.isOther() || Files.isSymbolicLink(path)) return true;
        if (isWindows()) {
            try {
                Object raw = Files.getAttribute(path, "dos:attributes", LinkOption.NOFOLLOW_LINKS);
                if (raw instanceof Number number && (number.intValue() & 0x400) != 0) return true;
            } catch (UnsupportedOperationException | IllegalArgumentException ignored) {}
        }
        if (attributes.isDirectory()) {
            Path notFollowed = path.toRealPath(LinkOption.NOFOLLOW_LINKS);
            Path followed = path.toRealPath();
            return !samePath(notFollowed, followed);
        }
        return false;
    }

    private static boolean samePath(Path first, Path second) {
        return isWindows()
                ? first.toString().equalsIgnoreCase(second.toString())
                : first.equals(second);
    }

    private static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win");
    }

    private static String relative(Path root, Path path) {
        return root.relativize(path).toString().replace('\\', '/');
    }

    private static void addAncestors(String pathKey, Set<String> output, boolean includeParent) {
        int end = includeParent ? pathKey.lastIndexOf('/') : pathKey.lastIndexOf('/');
        while (end > 0) {
            output.add(pathKey.substring(0, end));
            end = pathKey.lastIndexOf('/', end - 1);
        }
    }

    private static void moveAtomic(Path source, Path target) throws IOException {
        try {
            Files.move(source, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (AtomicMoveNotSupportedException e) {
            Files.move(source, target, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private static final class Quarantine {
        private final Path minecraftRoot;
        private final Path quarantineParent;
        private Path runRoot;

        private Quarantine(Path minecraftRoot, Path quarantineParent) {
            this.minecraftRoot = minecraftRoot;
            this.quarantineParent = quarantineParent;
        }

        static Quarantine create(Path minecraftRoot, Path quarantineParent) throws IOException, GuardException {
            ensurePlainDirectoryTree(minecraftRoot, quarantineParent);
            return new Quarantine(minecraftRoot, quarantineParent);
        }

        private Path ensureRunRoot() throws IOException, GuardException {
            if (runRoot != null) return runRoot;
            for (int attempt = 0; attempt < 10; attempt++) {
                String name = RUN_TIME.format(Instant.now()) + "-" + UUID.randomUUID();
                Path run = quarantineParent.resolve(name);
                try {
                    Files.createDirectory(run);
                    runRoot = run;
                    return runRoot;
                } catch (FileAlreadyExistsException ignored) {}
            }
            throw new GuardException("Could not allocate a unique quarantine directory.");
        }

        void move(Path source, String originalRelative) throws IOException, GuardException {
            Path normalized = source.toAbsolutePath().normalize();
            if (!normalized.startsWith(minecraftRoot) || normalized.equals(minecraftRoot)) {
                throw new GuardException("Refusing to quarantine outside Minecraft root: " + source);
            }
            String safeRelative = StrictManifest.validateRelative(originalRelative, 0);
            Path currentRunRoot = ensureRunRoot();
            Path destination = currentRunRoot.resolve(safeRelative.replace('/', java.io.File.separatorChar)).normalize();
            if (!destination.startsWith(currentRunRoot)) throw new GuardException("Unsafe quarantine target: " + originalRelative);
            ensurePlainDirectoryTree(currentRunRoot, destination.getParent());
            if (Files.exists(destination, NO_FOLLOW)) {
                destination = destination.resolveSibling(destination.getFileName() + "-" + UUID.randomUUID());
            }
            try {
                Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException e) {
                Files.move(source, destination);
            }
            System.out.println("[nbidal18-launch-guard] Quarantined: " + originalRelative);
        }
    }

    private static final class InternalWork {
        private final Path minecraftRoot;
        private final Path workParent;
        private Path runRoot;

        private InternalWork(Path minecraftRoot, Path workParent) {
            this.minecraftRoot = minecraftRoot;
            this.workParent = workParent;
        }

        static InternalWork create(Path minecraftRoot, Path workParent) throws IOException, GuardException {
            ensurePlainDirectoryTree(minecraftRoot, workParent);
            return new InternalWork(minecraftRoot, workParent);
        }

        private Path ensureRunRoot() throws IOException, GuardException {
            if (runRoot != null) return runRoot;
            for (int attempt = 0; attempt < 10; attempt++) {
                Path candidate = workParent.resolve(RUN_TIME.format(Instant.now()) + "-" + UUID.randomUUID());
                try {
                    Files.createDirectory(candidate);
                    runRoot = candidate;
                    return runRoot;
                } catch (FileAlreadyExistsException ignored) {}
            }
            throw new GuardException("Could not allocate launch-guard work directory.");
        }

        void move(Path source, String relative) throws IOException, GuardException {
            Path normalized = source.toAbsolutePath().normalize();
            if (!normalized.startsWith(minecraftRoot) || normalized.equals(minecraftRoot)) {
                throw new GuardException("Refusing to move internal work outside Minecraft root: " + source);
            }
            String safeRelative = StrictManifest.validateRelative(relative, 0);
            Path currentRunRoot = ensureRunRoot();
            Path destination = currentRunRoot.resolve(safeRelative.replace('/', java.io.File.separatorChar)).normalize();
            if (!destination.startsWith(currentRunRoot)) throw new GuardException("Unsafe internal-work target: " + relative);
            ensurePlainDirectoryTree(currentRunRoot, destination.getParent());
            try {
                Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException e) {
                Files.move(source, destination);
            }
        }

        void backupSeedTarget(Path source, String relative) throws IOException, GuardException {
            requirePlainRegular(source, "seed target backup source");
            Path destination = seedBackupPath(relative, true);
            Files.copy(source, destination, LinkOption.NOFOLLOW_LINKS);
            requirePlainRegular(source, "seed target backup source");
        }

        boolean restoreSeedTarget(Path target, String relative) throws IOException, GuardException {
            if (runRoot == null) return false;
            Path backup = seedBackupPath(relative, false);
            if (!Files.exists(backup, NO_FOLLOW)) return false;
            requirePlainRegular(backup, "seed target transition backup");
            if (Files.exists(target, NO_FOLLOW)) return false;
            try {
                Files.move(backup, target, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException e) {
                Files.move(backup, target);
            }
            return true;
        }

        private Path seedBackupPath(String relative, boolean createParents) throws IOException, GuardException {
            String safeRelative = StrictManifest.validateRelative(relative, 0);
            Path currentRunRoot = createParents ? ensureRunRoot() : runRoot;
            if (currentRunRoot == null) throw new GuardException("Seed backup run is unavailable.");
            Path backupRoot = currentRunRoot.resolve("seed-targets");
            Path destination = backupRoot.resolve(safeRelative.replace('/', java.io.File.separatorChar)).normalize();
            if (!destination.startsWith(backupRoot)) throw new GuardException("Unsafe seed backup target: " + relative);
            if (createParents) ensurePlainDirectoryTree(currentRunRoot, destination.getParent());
            return destination;
        }

        void removeAfterSuccess() throws IOException, GuardException {
            if (runRoot == null) return;
            deleteOwnedTree(runRoot);
            try { Files.delete(workParent); }
            catch (DirectoryNotEmptyException ignored) {}
            runRoot = null;
        }

        private void deleteOwnedTree(Path ownedRoot) throws IOException, GuardException {
            Path normalized = ownedRoot.toAbsolutePath().normalize();
            if (!normalized.startsWith(workParent) || normalized.equals(workParent)) {
                throw new GuardException("Refusing to clean unsafe internal-work path: " + ownedRoot);
            }
            Files.walkFileTree(ownedRoot, new SimpleFileVisitor<>() {
                @Override
                public FileVisitResult visitFile(Path file, BasicFileAttributes attributes) throws IOException {
                    Files.delete(file); // No FOLLOW_LINKS: a link node is deleted, never its target.
                    return FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult postVisitDirectory(Path directory, IOException error) throws IOException {
                    if (error != null) throw error;
                    Files.delete(directory);
                    return FileVisitResult.CONTINUE;
                }
            });
        }
    }

    private static final class PolicyIOException extends IOException {
        PolicyIOException(GuardException cause) { super(cause); }
    }

    private static final class PackwizExit extends Exception {
        final int exitCode;
        PackwizExit(int exitCode) { this.exitCode = exitCode; }
    }

    private record ExecutionOutcome(int exitCode, NextGuardHandoff.Request handoff) {
        static ExecutionOutcome success() { return new ExecutionOutcome(0, null); }
        static ExecutionOutcome handoff(NextGuardHandoff.Request request) {
            return new ExecutionOutcome(0, request);
        }
    }
}
