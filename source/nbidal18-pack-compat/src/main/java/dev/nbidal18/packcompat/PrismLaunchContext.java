package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.InvalidPathException;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.charset.StandardCharsets;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.CharacterCodingException;
import java.time.Instant;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;

/** A fail-closed description of the exact Prism instance that started this JVM. */
record PrismLaunchContext(
        Path gameDirectory,
        Path instanceDirectory,
        Path launcherRoot,
        Path prismExecutable,
        Path javaExecutable,
        Path companionJar,
        String instanceId,
        long minecraftPid,
        Instant minecraftStartedAt
) {
    private static final int MAXIMUM_INSTANCE_ID_CHARACTERS = 255;

    static PrismLaunchContext discover(Path gameDirectory, Path companionJar)
            throws IOException, IntegrityException {
        ProcessHandle current = ProcessHandle.current();
        ProcessSnapshot snapshot = snapshot(current);
        return discover(
                gameDirectory,
                companionJar,
                System.getenv(),
                snapshot,
                System.getProperty("os.name", "")
        );
    }

    static PrismLaunchContext discover(
            Path gameDirectory,
            Path companionJar,
            Map<String, String> environment,
            ProcessSnapshot current,
            String operatingSystem
    ) throws IOException, IntegrityException {
        if (operatingSystem == null
                || !operatingSystem.toLowerCase(Locale.ROOT).contains("win")) {
            throw new IntegrityException("Automatic Prism relaunch is currently supported only on Windows");
        }
        if (current == null || current.pid() <= 0 || current.startedAt() == null) {
            throw new IntegrityException("The current Minecraft process identity is unavailable");
        }

        String instanceId = requireInstanceId(environment.get("INST_ID"));
        Path instanceDirectory = requireAbsoluteEnvironmentPath(environment, "INST_DIR");
        Path environmentGameDirectory = requireAbsoluteEnvironmentPath(environment, "INST_MC_DIR");
        Path normalizedGameDirectory = requirePlainDirectory(gameDirectory, "Minecraft game directory");
        requireSamePath(normalizedGameDirectory, environmentGameDirectory, "INST_MC_DIR");

        instanceDirectory = requirePlainDirectory(instanceDirectory, "Prism instance directory");
        if (instanceDirectory.getFileName() == null
                || !instanceId.equals(instanceDirectory.getFileName().toString())) {
            throw new IntegrityException("INST_ID does not exactly match the Prism instance folder");
        }
        Path instancesDirectory = instanceDirectory.getParent();
        if (instancesDirectory == null || instancesDirectory.getFileName() == null
                || !"instances".equalsIgnoreCase(instancesDirectory.getFileName().toString())) {
            throw new IntegrityException("INST_DIR is not inside Prism's instances directory");
        }
        instancesDirectory = requirePlainDirectory(instancesDirectory, "Prism instances directory");
        Path launcherRoot = instancesDirectory.getParent();
        if (launcherRoot == null) {
            throw new IntegrityException("Prism's application root is unavailable");
        }
        launcherRoot = requirePlainDirectory(launcherRoot, "Prism application root");
        requireGuardedPreLaunch(instanceDirectory);
        requireSamePath(
                normalizedGameDirectory,
                instanceDirectory.resolve("minecraft"),
                "Prism instance Minecraft directory"
        );

        Path javaExecutable = requirePlainRegularFile(current.command(), "Minecraft Java executable");
        String javaName = fileName(javaExecutable).toLowerCase(Locale.ROOT);
        if (!javaName.equals("java.exe") && !javaName.equals("javaw.exe")) {
            throw new IntegrityException("The current Minecraft process was not started by Java on Windows");
        }

        ProcessSnapshot parent = current.parent();
        if (parent == null) {
            throw new IntegrityException("Minecraft's direct parent process is unavailable");
        }
        Path prismExecutable = requirePlainRegularFile(parent.command(), "Prism executable");
        if (!fileName(prismExecutable).equalsIgnoreCase("prismlauncher.exe")) {
            throw new IntegrityException("Minecraft's direct parent is not Prism Launcher");
        }

        Path normalizedCompanion = requirePlainRegularFile(companionJar, "companion JAR");
        Path modsDirectory = normalizedGameDirectory.resolve("mods").toAbsolutePath().normalize();
        if (normalizedCompanion.getParent() == null
                || !samePath(normalizedCompanion.getParent(), modsDirectory)) {
            throw new IntegrityException("The companion JAR is not a direct child of the managed mods directory");
        }

        return new PrismLaunchContext(
                normalizedGameDirectory,
                instanceDirectory,
                launcherRoot,
                prismExecutable,
                javaExecutable,
                normalizedCompanion,
                instanceId,
                current.pid(),
                current.startedAt()
        );
    }

    private static ProcessSnapshot snapshot(ProcessHandle process) throws IntegrityException {
        ProcessHandle.Info info = process.info();
        Path command = info.command().map(Path::of).orElseThrow(
                () -> new IntegrityException("A required process executable is unavailable")
        );
        Instant startedAt = info.startInstant().orElseThrow(
                () -> new IntegrityException("A required process start time is unavailable")
        );
        ProcessSnapshot parent = null;
        Optional<ProcessHandle> parentProcess = process.parent();
        if (parentProcess.isPresent()) {
            ProcessHandle handle = parentProcess.get();
            ProcessHandle.Info parentInfo = handle.info();
            Optional<String> parentCommand = parentInfo.command();
            Optional<Instant> parentStartedAt = parentInfo.startInstant();
            if (parentCommand.isPresent() && parentStartedAt.isPresent()) {
                parent = new ProcessSnapshot(
                        handle.pid(),
                        parentStartedAt.get(),
                        Path.of(parentCommand.get()),
                        null
                );
            }
        }
        return new ProcessSnapshot(process.pid(), startedAt, command, parent);
    }

    private static String requireInstanceId(String value) throws IntegrityException {
        if (value == null || value.isEmpty() || value.length() > MAXIMUM_INSTANCE_ID_CHARACTERS
                || !value.equals(value.strip()) || value.equals(".") || value.equals("..")
                || value.chars().anyMatch(character -> character < 0x20 || character == 0x7f)
                || value.indexOf('/') >= 0 || value.indexOf('\\') >= 0) {
            throw new IntegrityException("INST_ID is missing or unsafe");
        }
        return value;
    }

    private static Path requireAbsoluteEnvironmentPath(Map<String, String> environment, String name)
            throws IntegrityException {
        String raw = environment.get(name);
        if (raw == null || raw.isEmpty() || raw.indexOf('\0') >= 0) {
            throw new IntegrityException(name + " is missing");
        }
        try {
            Path path = Path.of(raw);
            if (!path.isAbsolute()) {
                throw new IntegrityException(name + " is not an absolute path");
            }
            return path.toAbsolutePath().normalize();
        } catch (InvalidPathException invalid) {
            throw new IntegrityException(name + " is not a valid path", invalid);
        }
    }

    private static Path requirePlainDirectory(Path path, String label)
            throws IOException, IntegrityException {
        if (path == null) {
            throw new IntegrityException("The " + label + " is unavailable");
        }
        Path normalized = path.toAbsolutePath().normalize();
        BasicFileAttributes attributes = Files.readAttributes(
                normalized,
                BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS
        );
        if (!attributes.isDirectory() || IntegrityFiles.isLinkOrReparse(normalized, attributes)) {
            throw new IntegrityException("The " + label + " is not a plain directory");
        }
        return normalized;
    }

    private static Path requirePlainRegularFile(Path path, String label)
            throws IOException, IntegrityException {
        if (path == null) {
            throw new IntegrityException("The " + label + " is unavailable");
        }
        Path normalized = path.toAbsolutePath().normalize();
        BasicFileAttributes attributes = Files.readAttributes(
                normalized,
                BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS
        );
        if (!attributes.isRegularFile() || IntegrityFiles.isLinkOrReparse(normalized, attributes)) {
            throw new IntegrityException("The " + label + " is not a plain regular file");
        }
        return normalized;
    }

    private static void requireGuardedPreLaunch(Path instanceDirectory)
            throws IOException, IntegrityException {
        Path configuration = requirePlainRegularFile(
                instanceDirectory.resolve("instance.cfg"),
                "Prism instance configuration"
        );
        byte[] content = IntegrityFiles.readRegularFile(configuration, 1024 * 1024);
        String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(content)).toString();
        } catch (CharacterCodingException malformed) {
            throw new IntegrityException("The Prism instance configuration is not valid UTF-8", malformed);
        }
        String preLaunch = null;
        int overrideCommands = 0;
        for (String line : text.split("\\R", -1)) {
            if (line.equals("OverrideCommands=true")) {
                overrideCommands++;
            }
            if (line.startsWith("PreLaunchCommand=")) {
                if (preLaunch != null) {
                    throw new IntegrityException("The Prism instance has duplicate pre-launch commands");
                }
                preLaunch = line.substring("PreLaunchCommand=".length());
            }
        }
        String canonicalCommand = preLaunch == null ? "" : preLaunch.replace("\\\"", "\"");
        boolean exactGuardCommand = canonicalCommand.equals(
                "\"$INST_JAVA\" -jar nbidal18-launch-guard.jar "
                        + "https://nbidal18.github.io/nbidal18-packwiz/pack.toml"
        ) || canonicalCommand.equals(
                "$INST_JAVA -jar nbidal18-launch-guard.jar "
                        + "https://nbidal18.github.io/nbidal18-packwiz/pack.toml"
        );
        if (overrideCommands != 1 || !exactGuardCommand) {
            throw new IntegrityException("The Prism instance is not configured to run the nbidal18 launch guard");
        }
    }

    private static void requireSamePath(Path expected, Path candidate, String label)
            throws IOException, IntegrityException {
        Path normalizedCandidate = candidate.toAbsolutePath().normalize();
        if (!samePath(expected, normalizedCandidate) || !Files.isSameFile(expected, normalizedCandidate)) {
            throw new IntegrityException(label + " does not match the active Minecraft directory");
        }
    }

    private static boolean samePath(Path first, Path second) {
        return first.toString().equalsIgnoreCase(second.toString());
    }

    private static String fileName(Path path) throws IntegrityException {
        if (path.getFileName() == null) {
            throw new IntegrityException("An executable file name is unavailable");
        }
        return path.getFileName().toString();
    }

    record ProcessSnapshot(long pid, Instant startedAt, Path command, ProcessSnapshot parent) {
    }
}
