package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

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
    void systemOperationsLaunchCannotBlockOnEitherPrismOutputStream() throws Exception {
        Path launcherRoot = Files.createDirectory(temporary.resolve("system-operations-launcher"));
        Path fakePrism = buildFloodingFakePrism(launcherRoot);
        prewarmFakePrism(fakePrism);
        String instanceId = "nbidal18-client";

        new PrismRelaunchHelper.SystemOperations().startPrism(fakePrism, launcherRoot, instanceId);

        assertTrue(waitForExactLaunchRecord(
                launcherRoot.resolve("flood-complete.tsv"),
                launcherRoot,
                instanceId,
                Duration.ofSeconds(30)
        ), "the fake Prism child did not finish flooding both stdout and stderr");
        assertTrue(waitForExecutableUnlock(fakePrism, Duration.ofSeconds(15)),
                "the fake Prism executable remained locked after its output flood");
    }

    @Test
    @EnabledOnOs(OS.WINDOWS)
    void detachedRuntimeCompletesAfterManagedCompanionIsMoved() throws Exception {
        String instanceId = "nbidal18-client";
        Path launcherRoot = Files.createDirectory(temporary.resolve("live-launcher"));
        Path instance = Files.createDirectories(launcherRoot.resolve("instances").resolve(instanceId));
        Path game = Files.createDirectory(instance.resolve("minecraft"));
        Files.createDirectory(game.resolve(".nbidal18"));
        Path mods = Files.createDirectory(game.resolve("mods"));
        Path managedCompanion = Files.writeString(mods.resolve("companion.jar"), "replace me");
        Path classpath = PrismAutoRelaunch.extractStandaloneHelper(game);

        Path fakePrism = buildFloodingFakePrism(launcherRoot);
        prewarmFakePrism(fakePrism);
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
        PrismRelaunchState.arm(game, guard, instanceId, Instant.now(), nonce);
        PrismRelaunchHelper.Arguments helperArguments = new PrismRelaunchHelper.Arguments(
                fakePrism, launcherRoot, game, instanceId, minecraft.pid(), startedAt, nonce, guard
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
        assertTrue(minecraft.waitFor(10, TimeUnit.SECONDS));
        assertTrue(waitForExactLaunchRecord(
                launcherRoot.resolve("flood-complete.tsv"),
                launcherRoot,
                instanceId,
                Duration.ofSeconds(30)
        ), "the detached fake Prism child did not finish flooding both output streams");
        assertTrue(helper.waitFor(15, TimeUnit.SECONDS));
        assertEquals(0, helper.exitValue());
        assertTrue(waitForExecutableUnlock(fakePrism, Duration.ofSeconds(15)),
                "the detached fake Prism executable remained locked after helper completion");
        assertFalse(Files.exists(game.resolve(PrismRelaunchState.RELATIVE_PATH)));
        Path diagnostic = game.resolve(".nbidal18").resolve("prism-relaunch.log");
        assertTrue(!Files.exists(diagnostic)
                || !Files.readString(diagnostic).contains("PRIVATE_PRISM_OUTPUT"));
    }

    private Path buildFloodingFakePrism(Path launcherRoot) throws Exception {
        Path compiler = Path.of(
                System.getenv("WINDIR"),
                "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe"
        );
        assertTrue(Files.isRegularFile(compiler), "the Windows .NET Framework C# compiler is unavailable");
        Path fixtureDirectory = Path.of(
                "build", "test-fixtures", "flooding-prism-" + UUID.randomUUID()
        ).toAbsolutePath().normalize();
        Files.createDirectories(fixtureDirectory);
        Path source = fixtureDirectory.resolve("FloodingPrism.cs");
        Path executable = fixtureDirectory.resolve("prismlauncher.exe");
        Files.writeString(source, """
                using System;
                using System.IO;
                using System.Text;

                internal static class FloodingPrism
                {
                    private static int Main(string[] args)
                    {
                        if (args.Length != 4 || args[0] != "--dir" || args[2] != "--launch")
                        {
                            return 10;
                        }

                        string chunk = new string('P', 4096) + "PRIVATE_PRISM_OUTPUT";
                        for (int index = 0; index < 4096; index++)
                        {
                            Console.Out.Write(chunk);
                            Console.Error.Write(chunk);
                        }
                        Console.Out.Flush();
                        Console.Error.Flush();

                        var utf8 = new UTF8Encoding(false);
                        File.WriteAllText(
                            Path.Combine(args[1], "flood-complete.tsv"),
                            string.Join("\\n", args) + "\\n",
                            utf8
                        );

                        string marker = Path.Combine(
                            args[1], "instances", args[3], "minecraft", ".nbidal18",
                            "prism-relaunch.tsv"
                        );
                        if (File.Exists(marker))
                        {
                            string text = File.ReadAllText(marker, utf8);
                            if (!text.Contains("state\\tarmed\\n"))
                            {
                                return 11;
                            }
                            text = text.Replace("state\\tarmed\\n", "state\\tacknowledged\\n")
                                + "acknowledged-at-utc\\t2026-08-12T14:30:00Z\\n";
                            File.WriteAllText(marker, text, utf8);
                        }
                        return 0;
                    }
                }
                """);
        Process compilerProcess = new ProcessBuilder(
                compiler.toString(),
                "/nologo",
                "/target:exe",
                "/out:" + executable,
                source.toString()
        ).redirectInput(ProcessBuilder.Redirect.from(Path.of("NUL").toFile()))
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start();
        assertTrue(compilerProcess.waitFor(30, TimeUnit.SECONDS), "fake Prism compilation timed out");
        assertEquals(0, compilerProcess.exitValue(), "fake Prism compilation failed");
        assertTrue(Files.isRegularFile(executable));
        return executable;
    }

    private static void prewarmFakePrism(Path executable) throws Exception {
        Process process = new ProcessBuilder(executable.toString())
                .redirectInput(ProcessBuilder.Redirect.from(Path.of("NUL").toFile()))
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start();
        assertTrue(process.waitFor(30, TimeUnit.SECONDS), "fake Prism prewarm timed out");
        assertEquals(10, process.exitValue(), "fake Prism prewarm did not reach its argument check");
    }

    private static boolean waitForExecutableUnlock(Path executable, Duration timeout) throws Exception {
        Instant deadline = Instant.now().plus(timeout);
        while (Instant.now().isBefore(deadline)) {
            try (java.nio.channels.FileChannel ignored = java.nio.channels.FileChannel.open(
                    executable,
                    java.nio.file.StandardOpenOption.WRITE
            )) {
                return true;
            } catch (java.nio.file.AccessDeniedException ignored) {
                Thread.sleep(50);
            }
        }
        return false;
    }

    private static boolean waitForExactLaunchRecord(
            Path record,
            Path launcherRoot,
            String instanceId,
            Duration timeout
    ) throws Exception {
        List<String> expected = List.of("--dir", launcherRoot.toString(), "--launch", instanceId);
        Instant deadline = Instant.now().plus(timeout);
        while (Instant.now().isBefore(deadline)) {
            try {
                if (Files.readAllLines(record).equals(expected)) {
                    return true;
                }
            } catch (java.nio.file.NoSuchFileException ignored) {
                // The child has not yet drained both output writes.
            }
            Thread.sleep(50);
        }
        return false;
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
