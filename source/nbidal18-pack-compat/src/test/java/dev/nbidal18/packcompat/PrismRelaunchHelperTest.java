package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PrismRelaunchHelperTest {
    @TempDir
    Path temporary;

    @Test
    void serializedArgumentsPreserveExactSubMillisecondProcessStart() throws Exception {
        PrismRelaunchHelper.Arguments expected = arguments();
        assertEquals(expected, PrismRelaunchHelper.Arguments.parse(expected.serialize()));
        assertEquals(
                Instant.parse("2026-08-12T10:15:30.123456700Z"),
                PrismRelaunchHelper.Arguments.parse(expected.serialize()).minecraftStartedAt()
        );
    }

    @Test
    void malformedUtf8ArgumentIsRejected() throws Exception {
        String[] serialized = arguments().serialize();
        serialized[3] = "_w";
        assertThrows(IntegrityException.class, () -> PrismRelaunchHelper.Arguments.parse(serialized));
    }

    @Test
    void helperWaitsForExactExitThenUsesBoundedExactPrismLaunchAndAck() throws Exception {
        PrismRelaunchHelper.Arguments arguments = arguments();
        Files.createDirectory(arguments.gameDirectory().resolve(".nbidal18"));
        PrismRelaunchState.arm(
                arguments.gameDirectory(),
                arguments.guardSha256(),
                arguments.instanceId(),
                Instant.parse("2026-08-12T10:15:00Z"),
                arguments.nonce()
        );
        FakeOperations operations = new FakeOperations();
        assertEquals(0, PrismRelaunchHelper.run(arguments, operations));
        assertTrue(operations.waitedForExit);
        assertEquals(1, operations.launches);
        assertTrue(operations.deletedAck);
        assertEquals(arguments.prismExecutable(), operations.executable);
        assertEquals(arguments.launcherRoot(), operations.launcherRoot);
        assertEquals(arguments.instanceId(), operations.instanceId);
    }

    @Test
    void extractedRuntimeClassIsOutsideManagedModsAndDoesNotNeedCompanionJar() throws Exception {
        Path game = Files.createDirectory(temporary.resolve("extract-game"));
        Files.createDirectory(game.resolve(".nbidal18"));
        Path mods = Files.createDirectory(game.resolve("mods"));
        Path companion = Files.writeString(mods.resolve("companion.jar"), "managed companion placeholder");

        Path classpath = PrismAutoRelaunch.extractStandaloneHelper(game);
        Path extracted = classpath.resolve("dev/nbidal18/packcompat/PrismRelaunchStandalone.class");
        assertTrue(Files.isRegularFile(extracted));
        assertFalse(extracted.startsWith(mods));
        Files.move(companion, temporary.resolve("moved-companion.jar"));
        assertTrue(Files.isRegularFile(extracted));
        assertTrue(Files.size(extracted) > 0);
    }

    @Test
    @EnabledOnOs(OS.WINDOWS)
    void detachedRuntimeCompletesAfterManagedCompanionIsMoved() throws Exception {
        Path game = Files.createDirectory(temporary.resolve("live-game"));
        Files.createDirectory(game.resolve(".nbidal18"));
        Path mods = Files.createDirectory(game.resolve("mods"));
        Path managedCompanion = Files.writeString(mods.resolve("companion.jar"), "replace me");
        Path classpath = PrismAutoRelaunch.extractStandaloneHelper(game);

        Path launcherRoot = Files.createDirectory(temporary.resolve("live-launcher"));
        Path fakePrism = launcherRoot.resolve("prismlauncher.exe");
        Files.copy(Path.of(System.getenv("SystemRoot"), "System32", "cmd.exe"), fakePrism);
        Process minecraft = new ProcessBuilder(
                Path.of(System.getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0",
                        "powershell.exe").toString(),
                "-NoProfile", "-Command", "Start-Sleep -Milliseconds 1500"
        ).redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start();
        Instant startedAt = minecraft.info().startInstant().orElseThrow();
        String nonce = "0123456789abcdef0123456789abcdef";
        String guard = "a".repeat(64);
        PrismRelaunchState.RelaunchMarker request = PrismRelaunchState.arm(
                game, guard, "nbidal18-client", Instant.now(), nonce
        );
        PrismRelaunchHelper.Arguments helperArguments = new PrismRelaunchHelper.Arguments(
                fakePrism, launcherRoot, game, "nbidal18-client", minecraft.pid(), startedAt, nonce, guard
        );
        Path javaExecutable = Path.of(ProcessHandle.current().info().command().orElseThrow());
        java.util.List<String> command = new java.util.ArrayList<>();
        command.add(javaExecutable.toString());
        command.add("-cp");
        command.add(classpath.toString());
        command.add(PrismRelaunchStandalone.class.getName());
        command.addAll(java.util.List.of(helperArguments.serialize()));
        Process helper = new ProcessBuilder(command)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start();

        Files.move(managedCompanion, temporary.resolve("companion-replaced.jar"));
        assertTrue(minecraft.waitFor(10, java.util.concurrent.TimeUnit.SECONDS));
        Thread.sleep(2500);
        PrismRelaunchState.RelaunchMarker acknowledgement = new PrismRelaunchState.RelaunchMarker(
                PrismRelaunchState.MarkerState.ACKNOWLEDGED,
                request.nonce(), request.guardSha256(), request.instanceIdBase64(), request.armedAtUtc(),
                Instant.now()
        );
        Files.write(game.resolve(PrismRelaunchState.RELATIVE_PATH), acknowledgement.serialize());

        assertTrue(helper.waitFor(10, java.util.concurrent.TimeUnit.SECONDS));
        assertEquals(0, helper.exitValue());
        assertFalse(Files.exists(game.resolve(PrismRelaunchState.RELATIVE_PATH)));
    }

    private PrismRelaunchHelper.Arguments arguments() throws Exception {
        Path root = Files.createDirectories(temporary.resolve("root"));
        Path game = Files.createDirectories(temporary.resolve("game"));
        Path prism = root.resolve("prismlauncher.exe");
        if (!Files.exists(prism)) {
            Files.writeString(prism, "prism");
        }
        return new PrismRelaunchHelper.Arguments(
                prism,
                root,
                game,
                "nbidal18 client",
                4242,
                Instant.parse("2026-08-12T10:15:30.123456700Z"),
                "0123456789abcdef0123456789abcdef",
                "a".repeat(64)
        );
    }

    private static final class FakeOperations implements PrismRelaunchHelper.Operations {
        boolean waitedForExit;
        int launches;
        boolean deletedAck;
        Path executable;
        Path launcherRoot;
        String instanceId;

        @Override
        public void requirePlainRegularFile(Path path, String label) {
        }

        @Override
        public void requirePlainDirectory(Path path, String label) {
        }

        @Override
        public boolean waitForExactProcessExit(long pid, Instant startedAt, Duration timeout) {
            waitedForExit = true;
            assertEquals(4242, pid);
            assertEquals(Instant.parse("2026-08-12T10:15:30.123456700Z"), startedAt);
            assertEquals(PrismRelaunchHelper.MINECRAFT_EXIT_TIMEOUT, timeout);
            return true;
        }

        @Override
        public void sleep(Duration duration) {
            assertEquals(PrismRelaunchHelper.PRISM_SETTLE_DELAY, duration);
        }

        @Override
        public void startPrism(Path executable, Path launcherRoot, String instanceId) {
            launches++;
            this.executable = executable;
            this.launcherRoot = launcherRoot;
            this.instanceId = instanceId;
        }

        @Override
        public boolean waitForAcknowledgment(
                PrismRelaunchHelper.Arguments arguments,
                Duration timeout
        ) {
            assertEquals(PrismRelaunchHelper.ACK_TIMEOUT, timeout);
            return true;
        }

        @Override
        public void deleteAcknowledgment(PrismRelaunchHelper.Arguments arguments) {
            deletedAck = true;
        }
    }
}
