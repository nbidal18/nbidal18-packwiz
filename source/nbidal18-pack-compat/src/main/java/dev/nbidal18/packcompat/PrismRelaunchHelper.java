package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Locale;
import java.util.Optional;

/** Detached JDK-only helper. It never terminates Minecraft; it waits for a graceful exit. */
final class PrismRelaunchHelper {
    static final Duration MINECRAFT_EXIT_TIMEOUT = Duration.ofMinutes(5);
    static final Duration ACK_TIMEOUT = Duration.ofSeconds(90);
    static final Duration RETRY_ACK_TIMEOUT = Duration.ofSeconds(45);
    static final Duration POLL_INTERVAL = Duration.ofMillis(250);
    static final Duration PRISM_SETTLE_DELAY = Duration.ofSeconds(2);
    static final int MAXIMUM_LAUNCH_ATTEMPTS = 2;

    private PrismRelaunchHelper() {
    }

    static int run(Arguments arguments, Operations operations) throws Exception {
        validateArguments(arguments, operations);
        if (!operations.waitForExactProcessExit(
                arguments.minecraftPid(),
                arguments.minecraftStartedAt(),
                MINECRAFT_EXIT_TIMEOUT
        )) {
            return 2;
        }
        operations.sleep(PRISM_SETTLE_DELAY);

        Duration acknowledgementTimeout = ACK_TIMEOUT;
        for (int attempt = 1; attempt <= MAXIMUM_LAUNCH_ATTEMPTS; attempt++) {
            operations.startPrism(
                    arguments.prismExecutable(),
                    arguments.launcherRoot(),
                    arguments.instanceId()
            );
            if (operations.waitForAcknowledgment(arguments, acknowledgementTimeout)) {
                operations.deleteAcknowledgment(arguments);
                return 0;
            }
            acknowledgementTimeout = RETRY_ACK_TIMEOUT;
        }
        return 3;
    }

    private static void validateArguments(Arguments arguments, Operations operations)
            throws IOException, IntegrityException {
        if (arguments.minecraftPid() <= 0 || arguments.minecraftStartedAt() == null
                || arguments.instanceId() == null || arguments.instanceId().isEmpty()
                || arguments.instanceId().length() > 255
                || arguments.instanceId().chars().anyMatch(character -> character < 0x20 || character == 0x7f)
                || arguments.instanceId().indexOf('/') >= 0 || arguments.instanceId().indexOf('\\') >= 0) {
            throw new IntegrityException("The Prism relaunch helper arguments are unsafe");
        }
        operations.requirePlainRegularFile(arguments.prismExecutable(), "Prism executable");
        operations.requirePlainDirectory(arguments.launcherRoot(), "Prism application root");
        operations.requirePlainDirectory(arguments.gameDirectory(), "Minecraft game directory");
        if (!arguments.prismExecutable().getFileName().toString().equalsIgnoreCase("prismlauncher.exe")) {
            throw new IntegrityException("The relaunch executable is not Prism Launcher");
        }
        PrismRelaunchState.RelaunchMarker marker = PrismRelaunchState.read(arguments.gameDirectory());
        if (marker.state() != PrismRelaunchState.MarkerState.ARMED
                || !marker.nonce().equals(arguments.nonce())
                || !marker.guardSha256().equals(arguments.guardSha256())) {
            throw new IntegrityException("The Prism relaunch helper request is no longer armed");
        }
    }

    record Arguments(
            Path prismExecutable,
            Path launcherRoot,
            Path gameDirectory,
            String instanceId,
            long minecraftPid,
            Instant minecraftStartedAt,
            String nonce,
            String guardSha256
    ) {
        static Arguments parse(String[] arguments) throws IntegrityException {
            if (arguments == null || arguments.length != 8) {
                throw new IntegrityException("The Prism relaunch helper requires exactly eight arguments");
            }
            try {
                return new Arguments(
                        decodePath(arguments[0]),
                        decodePath(arguments[1]),
                        decodePath(arguments[2]),
                        decode(arguments[3]),
                        Long.parseLong(arguments[4]),
                        Instant.parse(decode(arguments[5])),
                        arguments[6],
                        arguments[7]
                );
            } catch (IllegalArgumentException invalid) {
                throw new IntegrityException("The Prism relaunch helper arguments are malformed", invalid);
            }
        }

        String[] serialize() {
            return new String[]{
                    encode(prismExecutable.toString()),
                    encode(launcherRoot.toString()),
                    encode(gameDirectory.toString()),
                    encode(instanceId),
                    Long.toString(minecraftPid),
                    encode(minecraftStartedAt.toString()),
                    nonce,
                    guardSha256
            };
        }

        private static Path decodePath(String encoded) {
            return Path.of(decode(encoded)).toAbsolutePath().normalize();
        }

        private static String encode(String value) {
            return Base64.getUrlEncoder().withoutPadding()
                    .encodeToString(value.getBytes(StandardCharsets.UTF_8));
        }

        private static String decode(String value) {
            byte[] bytes = Base64.getUrlDecoder().decode(value);
            try {
                return StandardCharsets.UTF_8.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT)
                        .decode(ByteBuffer.wrap(bytes)).toString();
            } catch (CharacterCodingException malformed) {
                throw new IllegalArgumentException("Malformed UTF-8 helper argument", malformed);
            }
        }
    }


    interface Operations {
        void requirePlainRegularFile(Path path, String label) throws IOException, IntegrityException;

        void requirePlainDirectory(Path path, String label) throws IOException, IntegrityException;

        boolean waitForExactProcessExit(long pid, Instant startedAt, Duration timeout) throws InterruptedException;

        void sleep(Duration duration) throws InterruptedException;

        void startPrism(Path executable, Path launcherRoot, String instanceId) throws IOException;

        boolean waitForAcknowledgment(Arguments arguments, Duration timeout) throws InterruptedException;

        void deleteAcknowledgment(Arguments arguments) throws IOException, IntegrityException;
    }

    static final class SystemOperations implements Operations {
        @Override
        public void requirePlainRegularFile(Path path, String label) throws IOException, IntegrityException {
            requirePlain(path, label, false);
        }

        @Override
        public void requirePlainDirectory(Path path, String label) throws IOException, IntegrityException {
            requirePlain(path, label, true);
        }

        @Override
        public boolean waitForExactProcessExit(long pid, Instant startedAt, Duration timeout)
                throws InterruptedException {
            Instant deadline = Instant.now().plus(timeout);
            while (Instant.now().isBefore(deadline)) {
                Optional<ProcessHandle> process = ProcessHandle.of(pid);
                if (process.isEmpty()) {
                    return true;
                }
                Optional<Instant> actualStart = process.get().info().startInstant();
                if (actualStart.isPresent() && !actualStart.get().equals(startedAt)) {
                    return true; // The PID was reused; the exact Minecraft process is gone.
                }
                Thread.sleep(POLL_INTERVAL.toMillis());
            }
            return false;
        }

        @Override
        public void sleep(Duration duration) throws InterruptedException {
            Thread.sleep(duration.toMillis());
        }

        @Override
        public void startPrism(Path executable, Path launcherRoot, String instanceId) throws IOException {
            new ProcessBuilder(
                    executable.toString(),
                    "--dir", launcherRoot.toString(),
                    "--launch", instanceId
            ).directory(launcherRoot.toFile())
                    .redirectInput(ProcessBuilder.Redirect.from(Path.of("NUL").toFile()))
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .redirectError(ProcessBuilder.Redirect.DISCARD)
                    .start();
        }

        @Override
        public boolean waitForAcknowledgment(Arguments arguments, Duration timeout)
                throws InterruptedException {
            Instant deadline = Instant.now().plus(timeout);
            while (Instant.now().isBefore(deadline)) {
                try {
                    if (PrismRelaunchState.acknowledgedMatches(
                            arguments.gameDirectory(),
                            arguments.nonce(),
                            arguments.guardSha256(),
                            arguments.instanceId()
                    )) {
                        return true;
                    }
                } catch (IOException | IntegrityException ignored) {
                    // A partial/absent/mismatched marker is not an acknowledgment.
                }
                Thread.sleep(POLL_INTERVAL.toMillis());
            }
            return false;
        }

        @Override
        public void deleteAcknowledgment(Arguments arguments) throws IOException, IntegrityException {
            PrismRelaunchState.RelaunchMarker marker = PrismRelaunchState.read(arguments.gameDirectory());
            if (marker.state() != PrismRelaunchState.MarkerState.ACKNOWLEDGED
                    || !PrismRelaunchState.acknowledgedMatches(
                    arguments.gameDirectory(),
                    arguments.nonce(),
                    arguments.guardSha256(),
                    arguments.instanceId()
            )) {
                throw new IntegrityException("The Prism relaunch acknowledgment does not match the helper request");
            }
            PrismRelaunchState.deleteMatching(arguments.gameDirectory(), marker);
        }

        private static void requirePlain(Path path, String label, boolean directory)
                throws IOException, IntegrityException {
            BasicFileAttributes attributes = Files.readAttributes(
                    path,
                    BasicFileAttributes.class,
                    LinkOption.NOFOLLOW_LINKS
            );
            if ((directory ? !attributes.isDirectory() : !attributes.isRegularFile())
                    || IntegrityFiles.isLinkOrReparse(path, attributes)) {
                throw new IntegrityException("The " + label + " is unsafe");
            }
        }
    }
}
