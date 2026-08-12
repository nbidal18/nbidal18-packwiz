package dev.nbidal18.packcompat;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PrismLaunchContextTest {
    @TempDir
    Path temporary;

    @Test
    void acceptsOnlyExactGuardedPrismParentAndInstanceEnvironment() throws Exception {
        Fixture fixture = fixture();
        PrismLaunchContext context = PrismLaunchContext.discover(
                fixture.game(), fixture.companion(), fixture.environment(), fixture.process(), "Windows 11"
        );
        assertEquals("nbidal18-client", context.instanceId());
        assertEquals(fixture.root(), context.launcherRoot());
        assertEquals(fixture.prism(), context.prismExecutable());
        assertEquals(4242, context.minecraftPid());
    }

    @Test
    void rejectsWrongGameDirectoryParentAndUnguardedLegacyPreLaunch() throws Exception {
        Fixture fixture = fixture();
        Map<String, String> wrongGame = new HashMap<>(fixture.environment());
        wrongGame.put("INST_MC_DIR", temporary.toString());
        assertThrows(IntegrityException.class, () -> PrismLaunchContext.discover(
                fixture.game(), fixture.companion(), wrongGame, fixture.process(), "Windows 11"
        ));

        PrismLaunchContext.ProcessSnapshot badParent = new PrismLaunchContext.ProcessSnapshot(
                4242, fixture.process().startedAt(), fixture.java(),
                new PrismLaunchContext.ProcessSnapshot(40, fixture.process().startedAt(), fixture.java(), null)
        );
        assertThrows(IntegrityException.class, () -> PrismLaunchContext.discover(
                fixture.game(), fixture.companion(), fixture.environment(), badParent, "Windows 11"
        ));

        Files.writeString(
                fixture.instance().resolve("instance.cfg"),
                "PreLaunchCommand=$INST_JAVA -jar packwiz-installer-bootstrap.jar pack.toml\n",
                StandardCharsets.UTF_8
        );
        IntegrityException failure = assertThrows(IntegrityException.class, () -> PrismLaunchContext.discover(
                fixture.game(), fixture.companion(), fixture.environment(), fixture.process(), "Windows 11"
        ));
        assertTrue(failure.getMessage().contains("not configured"));
    }

    @Test
    void rejectsNonWindowsAndUnsafeInstanceId() throws Exception {
        Fixture fixture = fixture();
        assertThrows(IntegrityException.class, () -> PrismLaunchContext.discover(
                fixture.game(), fixture.companion(), fixture.environment(), fixture.process(), "Linux"
        ));
        Map<String, String> unsafe = new HashMap<>(fixture.environment());
        unsafe.put("INST_ID", "../other");
        assertThrows(IntegrityException.class, () -> PrismLaunchContext.discover(
                fixture.game(), fixture.companion(), unsafe, fixture.process(), "Windows 11"
        ));
    }

    private Fixture fixture() throws Exception {
        Path root = Files.createDirectory(temporary.resolve("prism-root"));
        Path instances = Files.createDirectory(root.resolve("instances"));
        Path instance = Files.createDirectory(instances.resolve("nbidal18-client"));
        Path game = Files.createDirectory(instance.resolve("minecraft"));
        Path mods = Files.createDirectory(game.resolve("mods"));
        Path companion = Files.writeString(mods.resolve("companion.jar"), "companion");
        Path java = Files.writeString(root.resolve("javaw.exe"), "java");
        Path prism = Files.writeString(root.resolve("prismlauncher.exe"), "prism");
        Files.writeString(
                instance.resolve("instance.cfg"),
                "[General]\nOverrideCommands=true\n"
                        + "PreLaunchCommand=\"$INST_JAVA\" -jar nbidal18-launch-guard.jar "
                        + "https://nbidal18.github.io/nbidal18-packwiz/pack.toml\n",
                StandardCharsets.UTF_8
        );
        Map<String, String> environment = Map.of(
                "INST_ID", "nbidal18-client",
                "INST_DIR", instance.toString(),
                "INST_MC_DIR", game.toString()
        );
        Instant start = Instant.parse("2026-08-12T10:15:30.123456700Z");
        PrismLaunchContext.ProcessSnapshot process = new PrismLaunchContext.ProcessSnapshot(
                4242, start, java,
                new PrismLaunchContext.ProcessSnapshot(40, start.minusSeconds(2), prism, null)
        );
        return new Fixture(root, instance, game, companion, java, prism, environment, process);
    }

    private record Fixture(
            Path root,
            Path instance,
            Path game,
            Path companion,
            Path java,
            Path prism,
            Map<String, String> environment,
            PrismLaunchContext.ProcessSnapshot process
    ) {
    }
}
