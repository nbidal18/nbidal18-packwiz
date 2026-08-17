import java.awt.BorderLayout;
import java.awt.Dimension;
import java.awt.GraphicsEnvironment;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import javax.swing.BorderFactory;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JPanel;
import javax.swing.JProgressBar;
import javax.swing.SwingConstants;
import javax.swing.SwingUtilities;
import javax.swing.WindowConstants;

/** Cross-platform Prism pre-launch updater for nbidal18. */
public final class Nbidal18PackwizSync {
    private static final String DEFAULT_PACK_URL =
            "https://nbidal18.github.io/nbidal18-packwiz/pack.toml";
    private static final String DEFAULT_MANIFEST_URL =
            "https://nbidal18.github.io/nbidal18-packwiz/sync-manifest.json";
    private static final String EXPECTED_PACK_VERSION = "4.1.2-packwiz";
    private static final DateTimeFormatter MOVE_STAMP =
            DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss");
    private static final Pattern FILE_ENTRY = Pattern.compile(
            "\\{\\s*\\\"path\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"\\s*,\\s*"
                    + "\\\"sha256\\\"\\s*:\\s*\\\"([a-fA-F0-9]{64})\\\"\\s*}");
    private static final Pattern JSON_STRING = Pattern.compile("\\\"((?:\\\\.|[^\\\"])*)\\\"");

    private final Path minecraftRoot;
    private final Path stateRoot;
    private final Path lastManifestPath;
    private final Path bootstrapPath;
    private final String packUrl;
    private final String manifestUrl;
    private JFrame updaterWindow;
    private JLabel updaterLabel;

    private Nbidal18PackwizSync() {
        String prismMinecraft = System.getenv("INST_MC_DIR");
        minecraftRoot = Path.of(
                prismMinecraft == null || prismMinecraft.isBlank() ? "." : prismMinecraft)
                .toAbsolutePath().normalize();
        stateRoot = minecraftRoot.resolve(".nbidal18-packwiz");
        lastManifestPath = stateRoot.resolve("last-successful-manifest.json");
        bootstrapPath = minecraftRoot.resolve("packwiz-installer-bootstrap.jar");
        packUrl = envOrDefault("NBIDAL18_PACK_URL", DEFAULT_PACK_URL);
        manifestUrl = envOrDefault("NBIDAL18_MANIFEST_URL", DEFAULT_MANIFEST_URL);
    }

    public static void main(String[] args) {
        Nbidal18PackwizSync updater = new Nbidal18PackwizSync();
        int exitCode = updater.run();
        updater.closeUpdaterWindow();
        System.exit(exitCode);
    }

    private int run() {
        Path downloadedManifest = null;
        showUpdaterWindow();
        try {
            Files.createDirectories(stateRoot);
            downloadedManifest = Files.createTempFile(stateRoot, "manifest-", ".tmp");
            boolean updateSucceeded = false;

            try {
                int installerResult = invokePackwizInstaller();
                if (installerResult != 0) {
                    status("The first update check failed; retrying once...");
                    installerResult = invokePackwizInstaller();
                }
                updateSucceeded = installerResult == 0;
                if (updateSucceeded) {
                    downloadCurrentManifest(downloadedManifest);
                }
            } catch (Exception error) {
                warning("The online update check failed: " + messageOf(error));
                updateSucceeded = false;
            }

            if (updateSucceeded) {
                SyncManifest current = readSyncManifest(downloadedManifest);
                List<String> repairProblems = findSyncProblems(current, true, true);
                boolean needsRepair = repairProblems.stream()
                        .anyMatch(problem -> !problem.startsWith("extra:"));
                if (needsRepair) {
                    status("Repairing missing or modified official files...");
                    if (invokePackwizInstaller() != 0) {
                        throw new IOException("Packwiz could not repair the official files.");
                    }
                }

                List<String> remaining = findSyncProblems(current, true, false);
                if (!remaining.isEmpty()) {
                    throw new IOException("The instance could not be synchronized: "
                            + String.join(", ", remaining));
                }

                Files.move(downloadedManifest, lastManifestPath,
                        StandardCopyOption.REPLACE_EXISTING);
                downloadedManifest = null;
                status("The instance matches v4.1.2-packwiz.");
                return 0;
            }

            if (!Files.isRegularFile(lastManifestPath)) {
                throw new IOException(
                        "The online update could not complete and this instance has never completed its first installation.");
            }

            SyncManifest lastKnown = readSyncManifest(lastManifestPath);
            List<String> offlineProblems = findSyncProblems(lastKnown, true, false);
            if (!offlineProblems.isEmpty()) {
                throw new IOException(
                        "The online update could not complete and the last installed release is incomplete: "
                                + String.join(", ", offlineProblems));
            }

            warning("The online update could not complete. Starting the last complete installed release; "
                    + "the server will apply its current compatibility policy.");
            return 0;
        } catch (Exception error) {
            System.err.println("[nbidal18 packwiz] " + messageOf(error));
            return 1;
        } finally {
            if (downloadedManifest != null) {
                try {
                    Files.deleteIfExists(downloadedManifest);
                } catch (IOException ignored) {
                    // A stale temporary manifest is harmless and remains outside the load path.
                }
            }
        }
    }

    private int invokePackwizInstaller() throws IOException, InterruptedException {
        if (!Files.isRegularFile(bootstrapPath)) {
            throw new IOException("Packwiz bootstrap is missing: " + bootstrapPath);
        }

        // Prism substitutes INST_JAVA in the pre-launch command, but some Prism
        // builds do not export it to the child process. Reuse the Java runtime
        // that is already running this updater instead.
        String currentCommand = ProcessHandle.current().info().command().orElse("");
        Path javaPath;
        if (!currentCommand.isBlank()) {
            javaPath = Path.of(currentCommand).toAbsolutePath().normalize();
        } else {
            boolean windows = System.getProperty("os.name", "")
                    .toLowerCase(Locale.ROOT).contains("win");
            javaPath = Path.of(System.getProperty("java.home"), "bin",
                    windows ? "java.exe" : "java").toAbsolutePath().normalize();
        }
        if (!Files.isRegularFile(javaPath)) {
            throw new IOException("The updater could not locate its running Java runtime: " + javaPath);
        }
        if (javaPath.getFileName().toString().equalsIgnoreCase("javaw.exe")) {
            Path consoleJava = javaPath.resolveSibling("java.exe");
            if (Files.isRegularFile(consoleJava)) {
                javaPath = consoleJava;
            }
        }

        status("Checking GitHub for pack updates...");
        ProcessBuilder processBuilder = new ProcessBuilder(
                javaPath.toString(), "-jar", bootstrapPath.toString(), "-g", packUrl);
        processBuilder.directory(minecraftRoot.toFile());
        processBuilder.inheritIO();
        Process process = processBuilder.start();
        return process.waitFor();
    }

    private void downloadCurrentManifest(Path destination)
            throws IOException, InterruptedException {
        HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(30))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build();
        HttpRequest request = HttpRequest.newBuilder(URI.create(manifestUrl))
                .timeout(Duration.ofSeconds(30))
                .header("User-Agent", "nbidal18-packwiz/4.1.2")
                .GET()
                .build();
        HttpResponse<byte[]> response = client.send(
                request, HttpResponse.BodyHandlers.ofByteArray());
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new IOException("Manifest download returned HTTP " + response.statusCode());
        }
        Files.write(destination, response.body());
        readSyncManifest(destination);
    }

    private SyncManifest readSyncManifest(Path path) throws IOException {
        String json = Files.readString(path, StandardCharsets.UTF_8);
        Matcher schema = Pattern.compile("\\\"schema\\\"\\s*:\\s*(\\d+)").matcher(json);
        Matcher version = Pattern.compile(
                "\\\"packVersion\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"")
                .matcher(json);
        if (!schema.find() || !"1".equals(schema.group(1)) || !version.find()
                || !EXPECTED_PACK_VERSION.equals(jsonUnescape(version.group(1)))) {
            throw new IOException("Unsupported sync manifest in " + path);
        }

        List<String> exactRoots = parseStringArray(json, "exactRoots");
        Set<String> localAllowed = new HashSet<>();
        for (String allowed : parseStringArray(json, "localAllowed")) {
            localAllowed.add(pathKey(validateRelative(allowed)));
        }

        String filesArray = extractArray(json, "files");
        Matcher fileMatcher = FILE_ENTRY.matcher(filesArray);
        Map<String, FileEntry> files = new LinkedHashMap<>();
        while (fileMatcher.find()) {
            String relative = validateRelative(jsonUnescape(fileMatcher.group(1)));
            FileEntry entry = new FileEntry(relative, fileMatcher.group(2).toLowerCase(Locale.ROOT));
            if (files.put(pathKey(relative), entry) != null) {
                throw new IOException("Duplicate manifest path: " + relative);
            }
        }
        if (files.isEmpty()) {
            throw new IOException("The sync manifest contains no files: " + path);
        }
        return new SyncManifest(exactRoots, localAllowed, files);
    }

    private List<String> findSyncProblems(
            SyncManifest manifest, boolean cleanExtras, boolean prepareRepair) throws Exception {
        List<String> problems = new ArrayList<>();
        for (FileEntry entry : manifest.files.values()) {
            if (manifest.localAllowed.contains(pathKey(entry.path))) {
                continue;
            }
            Path target = resolveRelative(entry.path);
            if (!Files.isRegularFile(target)) {
                problems.add("missing:" + entry.path);
                continue;
            }
            String actual = sha256(target);
            if (!actual.equals(entry.sha256)) {
                problems.add("modified:" + entry.path);
                if (prepareRepair) {
                    moveOutOfLoadPath(target, "modified managed file");
                }
            }
        }

        for (String rootName : manifest.exactRoots) {
            String relativeRoot = validateRelative(rootName);
            Path rootPath = resolveRelative(relativeRoot);
            if (!Files.isDirectory(rootPath)) {
                continue;
            }
            try (Stream<Path> paths = Files.walk(rootPath)) {
                for (Path file : paths.filter(Files::isRegularFile).toList()) {
                    String relative = getRelativePath(file);
                    String key = pathKey(relative);
                    if (manifest.files.containsKey(key) || manifest.localAllowed.contains(key)) {
                        continue;
                    }
                    problems.add("extra:" + relative);
                    if (cleanExtras) {
                        moveOutOfLoadPath(file, "not present in the official pack");
                    }
                }
            }
        }
        return problems;
    }

    private void moveOutOfLoadPath(Path path, String reason) throws IOException {
        if (!Files.isRegularFile(path)) {
            return;
        }
        String relative = getRelativePath(path);
        String stamp = LocalDateTime.now().format(MOVE_STAMP);
        Path destination = stateRoot.resolve("removed-local-files")
                .resolve(stamp).resolve(relative.replace('/', java.io.File.separatorChar))
                .normalize();
        Path removalRoot = stateRoot.resolve("removed-local-files").normalize();
        if (!destination.startsWith(removalRoot)) {
            throw new IOException("Removal destination escaped the updater state directory: " + destination);
        }
        Files.createDirectories(destination.getParent());
        if (Files.exists(destination)) {
            destination = destination.resolveSibling(
                    destination.getFileName() + "." + UUID.randomUUID().toString().replace("-", ""));
        }
        Files.move(path, destination);
        status("Moved " + relative + " out of the load path (" + reason + ").");
    }

    private String getRelativePath(Path path) throws IOException {
        Path full = path.toAbsolutePath().normalize();
        if (!full.startsWith(minecraftRoot)) {
            throw new IOException("Path escapes the Minecraft directory: " + full);
        }
        return minecraftRoot.relativize(full).toString()
                .replace(java.io.File.separatorChar, '/');
    }

    private Path resolveRelative(String relative) throws IOException {
        Path resolved = minecraftRoot.resolve(relative.replace('/', java.io.File.separatorChar))
                .normalize();
        if (!resolved.startsWith(minecraftRoot)) {
            throw new IOException("Path escapes the Minecraft directory: " + relative);
        }
        return resolved;
    }

    private static String validateRelative(String value) throws IOException {
        String relative = value.replace('\\', '/');
        while (relative.startsWith("/")) {
            relative = relative.substring(1);
        }
        if (relative.isBlank() || relative.contains(":")
                || relative.equals("..") || relative.startsWith("../")
                || relative.endsWith("/..") || relative.contains("/../")) {
            throw new IOException("Invalid manifest path: " + value);
        }
        return relative;
    }

    private static String sha256(Path path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = Files.newInputStream(path)) {
            byte[] buffer = new byte[1024 * 128];
            int count;
            while ((count = input.read(buffer)) >= 0) {
                if (count > 0) {
                    digest.update(buffer, 0, count);
                }
            }
        }
        StringBuilder result = new StringBuilder(64);
        for (byte value : digest.digest()) {
            result.append(String.format("%02x", value & 0xff));
        }
        return result.toString();
    }

    private static List<String> parseStringArray(String json, String property) throws IOException {
        String array = extractArray(json, property);
        List<String> values = new ArrayList<>();
        Matcher matcher = JSON_STRING.matcher(array);
        while (matcher.find()) {
            values.add(jsonUnescape(matcher.group(1)));
        }
        return values;
    }

    private static String extractArray(String json, String property) throws IOException {
        Matcher propertyMatcher = Pattern.compile(
                "\\\"" + Pattern.quote(property) + "\\\"\\s*:").matcher(json);
        if (!propertyMatcher.find()) {
            throw new IOException("Missing manifest property: " + property);
        }
        int start = json.indexOf('[', propertyMatcher.end());
        if (start < 0) {
            throw new IOException("Manifest property is not an array: " + property);
        }
        int depth = 0;
        boolean inString = false;
        boolean escaped = false;
        for (int index = start; index < json.length(); index++) {
            char current = json.charAt(index);
            if (inString) {
                if (escaped) {
                    escaped = false;
                } else if (current == '\\') {
                    escaped = true;
                } else if (current == '"') {
                    inString = false;
                }
                continue;
            }
            if (current == '"') {
                inString = true;
            } else if (current == '[') {
                depth++;
            } else if (current == ']' && --depth == 0) {
                return json.substring(start + 1, index);
            }
        }
        throw new IOException("Unterminated manifest array: " + property);
    }

    private static String jsonUnescape(String value) throws IOException {
        StringBuilder output = new StringBuilder(value.length());
        for (int index = 0; index < value.length(); index++) {
            char current = value.charAt(index);
            if (current != '\\') {
                output.append(current);
                continue;
            }
            if (++index >= value.length()) {
                throw new IOException("Invalid JSON escape");
            }
            char escaped = value.charAt(index);
            switch (escaped) {
                case '"', '\\', '/' -> output.append(escaped);
                case 'b' -> output.append('\b');
                case 'f' -> output.append('\f');
                case 'n' -> output.append('\n');
                case 'r' -> output.append('\r');
                case 't' -> output.append('\t');
                case 'u' -> {
                    if (index + 4 >= value.length()) {
                        throw new IOException("Invalid JSON unicode escape");
                    }
                    try {
                        output.append((char) Integer.parseInt(
                                value.substring(index + 1, index + 5), 16));
                    } catch (NumberFormatException error) {
                        throw new IOException("Invalid JSON unicode escape", error);
                    }
                    index += 4;
                }
                default -> throw new IOException("Invalid JSON escape: \\" + escaped);
            }
        }
        return output.toString();
    }

    private void showUpdaterWindow() {
        if ("1".equals(System.getenv("NBIDAL18_HEADLESS_TEST"))
                || GraphicsEnvironment.isHeadless()) {
            return;
        }
        try {
            SwingUtilities.invokeAndWait(() -> {
                updaterWindow = new JFrame("nbidal18 updater");
                updaterWindow.setDefaultCloseOperation(WindowConstants.DO_NOTHING_ON_CLOSE);
                updaterWindow.setAlwaysOnTop(true);
                updaterWindow.setResizable(false);

                JPanel content = new JPanel(new BorderLayout(0, 12));
                content.setBorder(BorderFactory.createEmptyBorder(18, 18, 18, 18));
                updaterLabel = new JLabel("Preparing the modpack update...", SwingConstants.CENTER);
                JProgressBar progress = new JProgressBar();
                progress.setIndeterminate(true);
                progress.setPreferredSize(new Dimension(424, 22));
                content.add(updaterLabel, BorderLayout.CENTER);
                content.add(progress, BorderLayout.SOUTH);
                updaterWindow.setContentPane(content);
                updaterWindow.pack();
                updaterWindow.setLocationRelativeTo(null);
                updaterWindow.setVisible(true);
            });
        } catch (Exception error) {
            updaterWindow = null;
            updaterLabel = null;
        }
    }

    private void closeUpdaterWindow() {
        if (updaterWindow == null) {
            return;
        }
        try {
            SwingUtilities.invokeAndWait(() -> updaterWindow.dispose());
        } catch (Exception ignored) {
            // The updater has already finished; an unavailable window is harmless.
        }
    }

    private void status(String message) {
        System.out.println("[nbidal18 packwiz] " + message);
        JLabel label = updaterLabel;
        if (label != null) {
            SwingUtilities.invokeLater(() -> label.setText(message));
        }
    }

    private static void warning(String message) {
        System.err.println("[nbidal18 packwiz] WARNING: " + message);
    }

    private static String envOrDefault(String name, String defaultValue) {
        String value = System.getenv(name);
        return value == null || value.isBlank() ? defaultValue : value;
    }

    private static String pathKey(String path) {
        return path.replace('\\', '/').toLowerCase(Locale.ROOT);
    }

    private static String messageOf(Throwable error) {
        String message = error.getMessage();
        return message == null || message.isBlank() ? error.getClass().getSimpleName() : message;
    }

    private static final class FileEntry {
        private final String path;
        private final String sha256;

        private FileEntry(String path, String sha256) {
            this.path = path;
            this.sha256 = sha256;
        }
    }

    private static final class SyncManifest {
        private final List<String> exactRoots;
        private final Set<String> localAllowed;
        private final Map<String, FileEntry> files;

        private SyncManifest(
                List<String> exactRoots,
                Set<String> localAllowed,
                Map<String, FileEntry> files) {
            this.exactRoots = List.copyOf(exactRoots);
            this.localAllowed = Set.copyOf(localAllowed);
            this.files = Map.copyOf(files);
        }
    }
}
