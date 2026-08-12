package dev.nbidal18.packcompat;

import net.minecraft.client.Minecraft;
import org.slf4j.Logger;

import java.io.IOException;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.Clock;
import java.util.ArrayList;
import java.util.List;

/** Coordinates a graceful one-time same-instance relaunch after a guard migration. */
final class PrismAutoRelaunch {
    private final Logger logger;
    private final PrismLaunchContext context;
    private boolean shutdownRequested;

    private PrismAutoRelaunch(
            Logger logger,
            PrismLaunchContext context
    ) {
        this.logger = logger;
        this.context = context;
    }

    static PrismAutoRelaunch prepare(
            Logger logger,
            Path gameDirectory,
            Path companionJar,
            String guardSha256
    ) throws IOException, IntegrityException {
        PrismLaunchContext context = PrismLaunchContext.discover(gameDirectory, companionJar);
        PrismRelaunchState.RelaunchMarker marker = PrismRelaunchState.arm(
                context.gameDirectory(),
                guardSha256,
                context.instanceId(),
                Clock.systemUTC().instant()
        );
        try {
            startDetachedHelper(context, marker, guardSha256);
        } catch (IOException | IntegrityException failure) {
            try {
                PrismRelaunchState.deleteIfMatching(context.gameDirectory(), marker);
            } catch (IOException | IntegrityException cleanupFailure) {
                failure.addSuppressed(cleanupFailure);
            }
            throw failure;
        }
        return new PrismAutoRelaunch(logger, context);
    }

    void tick(Minecraft client) {
        if (shutdownRequested || client == null || !client.isGameLoadFinished()) {
            return;
        }
        // Never close a world, server connection, or an in-progress connection attempt.
        if (client.level != null || client.getConnection() != null) {
            return;
        }
        shutdownRequested = true;
        logger.info(
                "The launch guard changed; gracefully closing Minecraft so Prism can relaunch instance {} once",
                context.instanceId()
        );
        client.stop();
    }

    static boolean handoffSuppressesRestart(
            Path gameDirectory,
            Path companionJar,
            String guardSha256,
            Clock clock
    ) throws IOException, IntegrityException {
        return LaunchGuardHandoff.consumeIfMatching(gameDirectory, companionJar, guardSha256, clock);
    }

    private static void startDetachedHelper(
            PrismLaunchContext context,
            PrismRelaunchState.RelaunchMarker marker,
            String guardSha256
    ) throws IOException, IntegrityException {
        PrismRelaunchHelper.Arguments helperArguments = new PrismRelaunchHelper.Arguments(
                context.prismExecutable(),
                context.launcherRoot(),
                context.gameDirectory(),
                context.instanceId(),
                context.minecraftPid(),
                context.minecraftStartedAt(),
                marker.nonce(),
                guardSha256
        );
        Path extractedClasspath = extractStandaloneHelper(context.gameDirectory());
        List<String> command = new ArrayList<>();
        command.add(context.javaExecutable().toString());
        command.add("-cp");
        command.add(extractedClasspath.toString());
        command.add(PrismRelaunchStandalone.class.getName());
        command.addAll(List.of(helperArguments.serialize()));
        new ProcessBuilder(command)
                .directory(context.launcherRoot().toFile())
                .redirectInput(ProcessBuilder.Redirect.from(Path.of("NUL").toFile()))
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start();
    }

    static Path extractStandaloneHelper(Path gameDirectory) throws IOException, IntegrityException {
        String classResource = "/" + PrismRelaunchStandalone.class.getName().replace('.', '/') + ".class";
        byte[] classBytes;
        try (InputStream input = PrismAutoRelaunch.class.getResourceAsStream(classResource)) {
            if (input == null) {
                throw new IntegrityException("The standalone Prism relaunch helper is missing");
            }
            ByteArrayOutputStream output = new ByteArrayOutputStream(32 * 1024);
            byte[] buffer = new byte[8192];
            int total = 0;
            int read;
            while ((read = input.read(buffer)) >= 0) {
                total += read;
                if (total > 1024 * 1024) {
                    throw new IntegrityException("The standalone Prism relaunch helper is too large");
                }
                output.write(buffer, 0, read);
            }
            classBytes = output.toByteArray();
        }
        if (classBytes.length < 8 || classBytes[0] != (byte) 0xca || classBytes[1] != (byte) 0xfe
                || classBytes[2] != (byte) 0xba || classBytes[3] != (byte) 0xbe) {
            throw new IntegrityException("The standalone Prism relaunch helper has an invalid class identity");
        }

        Path game = StrictManifest.normalizedRoot(gameDirectory);
        Path control = requirePlainDirectory(game.resolve(".nbidal18"), "relaunch control directory");
        Path classpathRoot = ensurePlainChildDirectory(control, "relaunch-helper");
        Path packageDirectory = classpathRoot;
        for (String segment : PrismRelaunchStandalone.class.getPackageName().split("\\.")) {
            packageDirectory = ensurePlainChildDirectory(packageDirectory, segment);
        }
        Path target = packageDirectory.resolve("PrismRelaunchStandalone.class").normalize();
        if (!target.startsWith(classpathRoot)) {
            throw new IntegrityException("The standalone helper target escapes its control directory");
        }
        String expectedHash = IntegrityFiles.sha256(classBytes);
        if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
            BasicFileAttributes existing = Files.readAttributes(
                    target, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS
            );
            if (!existing.isRegularFile() || IntegrityFiles.isLinkOrReparse(target, existing)) {
                throw new IntegrityException("The standalone helper target is unsafe");
            }
            if (expectedHash.equals(IntegrityFiles.sha256(target))) {
                return classpathRoot;
            }
        }

        Path staged = null;
        try {
            staged = Files.createTempFile(packageDirectory, ".prism-relaunch-helper-", ".tmp");
            try (FileChannel channel = FileChannel.open(
                    staged,
                    StandardOpenOption.WRITE,
                    StandardOpenOption.TRUNCATE_EXISTING,
                    LinkOption.NOFOLLOW_LINKS
            )) {
                ByteBuffer bytes = ByteBuffer.wrap(classBytes);
                while (bytes.hasRemaining()) {
                    channel.write(bytes);
                }
                channel.force(true);
            }
            if (!expectedHash.equals(IntegrityFiles.sha256(staged))) {
                throw new IntegrityException("The staged standalone relaunch helper failed hash verification");
            }
            try {
                Files.move(staged, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException unsupported) {
                throw new IntegrityException("The standalone relaunch helper cannot be replaced atomically", unsupported);
            }
            staged = null;
        } finally {
            if (staged != null) {
                Files.deleteIfExists(staged);
            }
        }
        if (!expectedHash.equals(IntegrityFiles.sha256(target))) {
            throw new IntegrityException("The installed standalone relaunch helper failed hash verification");
        }
        return classpathRoot;
    }

    private static Path ensurePlainChildDirectory(Path parent, String child)
            throws IOException, IntegrityException {
        Path path = parent.resolve(child).normalize();
        if (!path.getParent().equals(parent)) {
            throw new IntegrityException("The standalone helper directory escapes its parent");
        }
        try {
            Files.createDirectory(path);
        } catch (java.nio.file.FileAlreadyExistsException ignored) {
        }
        return requirePlainDirectory(path, "standalone helper directory");
    }

    private static Path requirePlainDirectory(Path path, String label)
            throws IOException, IntegrityException {
        Path normalized = path.toAbsolutePath().normalize();
        BasicFileAttributes attributes = Files.readAttributes(
                normalized, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS
        );
        if (!attributes.isDirectory() || IntegrityFiles.isLinkOrReparse(normalized, attributes)) {
            throw new IntegrityException("The " + label + " is unsafe");
        }
        return normalized;
    }
}
