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
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
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
    /**
     * Lowest pack version this updater will accept from the channel. Raising it with each release
     * stops a rolled-back or spoofed channel downgrading an instance: once a client runs this
     * build, publishing anything below 4.2.6 would be refused rather than installed.
     */
    private static final int[] MINIMUM_PACK_VERSION = {4, 2, 6};
    private static final DateTimeFormatter MOVE_STAMP =
            DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss");
    private static final Pattern FILE_ENTRY = Pattern.compile(
            "\\{\\s*\\\"path\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"\\s*,\\s*"
                    + "\\\"sha256\\\"\\s*:\\s*\\\"([a-fA-F0-9]{64})\\\"\\s*}");
    private static final Pattern PROPERTY_RULE = Pattern.compile(
            "\\{\\s*\\\"path\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"\\s*,\\s*"
                    + "\\\"key\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"\\s*,\\s*"
                    + "\\\"value\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"])*)\\\"\\s*}");
    private static final Pattern JSON_STRING = Pattern.compile("\\\"((?:\\\\.|[^\\\"])*)\\\"");
    private static final String NATURE_X_PACK = "file/Nature X - 12.2 [1.21.1].zip";
    private static final String ENHANCED_GRASS_PACK = "file/Enhanced Grass V1_4.zip";
    private static final String OLD_DARK_CONTAINERS_PACK =
            "file/\u00a78\u00a7lDarkmode \u00a7f\u00a7lColourful Containers\u00a78.zip";
    private static final String OLD_MODDED_CONTAINERS_PACK =
            "file/\u00a75\u00a7lModded \u00a7f\u00a7lContainers \u00a78\u00a7lDark\u00a78.zip";
    private static final String OLED_CONTAINERS_PACK =
            "file/\u00a70\u00a7lOLED \u00a7f\u00a7lColourful Containers\u00a78.zip";
    private static final String INMIS_OLED_ADDON_PACK =
            "file/\u00a70\u00a7lOLED \u00a7f\u00a7lInmis Backpacks Addon\u00a78.zip";

    /**
     * config/autohud.json5 is a first-install default that becomes player-owned, so a changed
     * default never reaches an existing instance. This release deliberately republishes it once:
     * the local copy is removed before the sync so packwiz restores the shipped file, the marker
     * below records that it happened, and the file is player-owned again from then on. Bump the
     * token only when a future release genuinely needs to reissue the defaults again.
     */
    private static final String AUTOHUD_DEFAULT_TOKEN = "autohud-place-break-v1";

    private final Path minecraftRoot;
    private final Path stateRoot;
    private final Path lastManifestPath;
    private final Path autoHudConfigPath;
    private final Path autoHudRestorePath;
    private final Path autoHudDefaultMarker;
    private final Path bootstrapPath;
    private final Path installerPath;
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
        autoHudConfigPath = minecraftRoot.resolve("config").resolve("autohud.json5");
        autoHudRestorePath = stateRoot.resolve("autohud.json5.restore");
        autoHudDefaultMarker = stateRoot.resolve("applied-" + AUTOHUD_DEFAULT_TOKEN);
        bootstrapPath = minecraftRoot.resolve("packwiz-installer-bootstrap.jar");
        installerPath = minecraftRoot.resolve("packwiz-installer.jar");
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
            boolean autoHudStaged = stageForcedAutoHudDefault();

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
            finishForcedAutoHudDefault(autoHudStaged, updateSucceeded);

            if (updateSucceeded) {
                SyncManifest current = readSyncManifest(downloadedManifest);
                repairPropertyRules(current);
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

                tryMigratePlayerOptions();
                Files.move(downloadedManifest, lastManifestPath,
                        StandardCopyOption.REPLACE_EXISTING);
                downloadedManifest = null;
                status("The instance matches v" + current.packVersion + ".");
                return 0;
            }

            if (!Files.isRegularFile(lastManifestPath)) {
                throw new IOException(
                        "The online update could not complete and this instance has never completed its first installation.");
            }

            SyncManifest lastKnown = readSyncManifest(lastManifestPath);
            repairPropertyRules(lastKnown);
            List<String> offlineProblems = findSyncProblems(lastKnown, true, false);
            if (!offlineProblems.isEmpty()) {
                throw new IOException(
                        "The online update could not complete and the last installed release is incomplete: "
                                + String.join(", ", offlineProblems));
            }

            tryMigratePlayerOptions();
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
        if (!Files.isRegularFile(installerPath)) {
            throw new IOException("Bundled Packwiz installer is missing: " + installerPath);
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
        List<String> command = new ArrayList<>();
        command.add(javaPath.toString());
        command.add("-jar");
        command.add(bootstrapPath.toString());
        command.add("--bootstrap-no-update");
        command.add("-g");
        command.add(packUrl);
        ProcessBuilder processBuilder = new ProcessBuilder(command);
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
                .header("User-Agent", "nbidal18-packwiz/4.1.3")
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
        String packVersion = version.find() ? jsonUnescape(version.group(1)) : "";
        if (!schema.find() || !"1".equals(schema.group(1))
                || !isSupportedPackVersion(packVersion)) {
            throw new IOException("Unsupported sync manifest in " + path);
        }

        List<String> exactRoots = parseStringArray(json, "exactRoots");
        // Optional: this also parses the manifest the player already had, which predates the field.
        // A manifest without it tolerates nothing, which is exactly the previous behaviour.
        List<String> extraTolerantRoots = new ArrayList<>();
        if (json.contains("\"extraTolerantRoots\"")) {
            for (String tolerant : parseStringArray(json, "extraTolerantRoots")) {
                extraTolerantRoots.add(validateRelative(tolerant));
            }
        }
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

        String propertyRulesArray = extractArray(json, "propertyRules");
        Matcher propertyRuleMatcher = PROPERTY_RULE.matcher(propertyRulesArray);
        List<PropertyRule> propertyRules = new ArrayList<>();
        Set<String> propertyRuleKeys = new HashSet<>();
        while (propertyRuleMatcher.find()) {
            String relative = validateRelative(jsonUnescape(propertyRuleMatcher.group(1)));
            String key = jsonUnescape(propertyRuleMatcher.group(2));
            String value = jsonUnescape(propertyRuleMatcher.group(3));
            if (!key.matches("[A-Za-z0-9_.-]+") || value.contains("\n") || value.contains("\r")) {
                throw new IOException("Invalid property rule for " + relative);
            }
            String relativeKey = pathKey(relative);
            if (!files.containsKey(relativeKey) || !localAllowed.contains(relativeKey)) {
                throw new IOException("Property rule path must be a preserved managed file: " + relative);
            }
            if (!propertyRuleKeys.add(relativeKey + "\u0000" + key)) {
                throw new IOException("Duplicate property rule: " + relative + "#" + key);
            }
            propertyRules.add(new PropertyRule(relative, key, value));
        }
        if (propertyRules.isEmpty()) {
            throw new IOException("The sync manifest contains no property rules: " + path);
        }
        return new SyncManifest(
                packVersion, exactRoots, extraTolerantRoots, localAllowed, files, propertyRules);
    }

    /**
     * Accepts both {@code 4.2.3-packwiz} and the bare {@code 4.3.0}.
     *
     * <p>The suffix is being retired: packwiz is a known part of the pack, so the number alone says
     * everything. It cannot be dropped in one release, because whichever updater a player already
     * has is the one that validates the next manifest — an updater that demanded the suffix would
     * reject the first suffix-less release outright, abandon the update and silently leave that
     * player on their installed build forever. This release teaches the updater both forms so a
     * later one can stop writing the suffix. Keep accepting both: some client will always be a
     * release or two behind.
     */
    private static boolean isSupportedPackVersion(String value) {
        Matcher matcher = Pattern.compile("(\\d+)\\.(\\d+)\\.(\\d+)(?:-packwiz)?").matcher(value);
        if (!matcher.matches()) {
            return false;
        }
        try {
            int[] candidate = {
                    Integer.parseInt(matcher.group(1)),
                    Integer.parseInt(matcher.group(2)),
                    Integer.parseInt(matcher.group(3))
            };
            for (int index = 0; index < candidate.length; index++) {
                if (candidate[index] != MINIMUM_PACK_VERSION[index]) {
                    return candidate[index] > MINIMUM_PACK_VERSION[index];
                }
            }
            return true;
        } catch (NumberFormatException ignored) {
            return false;
        }
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

        for (PropertyRule rule : manifest.propertyRules) {
            Path target = resolveRelative(rule.path);
            if (!Files.isRegularFile(target)
                    || !rule.value.equals(readPropertyValue(target, rule.key))) {
                problems.add("property:" + rule.path + "#" + rule.key);
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
                    if (manifest.files.containsKey(key) || manifest.localAllowed.contains(key)
                            || manifest.isExtraTolerant(relative)) {
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

    private void repairPropertyRules(SyncManifest manifest) throws IOException {
        for (PropertyRule rule : manifest.propertyRules) {
            Path target = resolveRelative(rule.path);
            if (!Files.isRegularFile(target)
                    || rule.value.equals(readPropertyValue(target, rule.key))) {
                continue;
            }
            List<String> original = Files.readAllLines(target, StandardCharsets.UTF_8);
            Pattern propertyLine = Pattern.compile(
                    "^\\s*" + Pattern.quote(rule.key) + "\\s*[:=].*$");
            List<String> repaired = new ArrayList<>();
            for (String line : original) {
                if (!propertyLine.matcher(line).matches()) {
                    repaired.add(line);
                }
            }
            repaired.add(rule.key + "=" + rule.value);
            Files.write(target, repaired, StandardCharsets.UTF_8);
            status("Reset protected shader option " + rule.key + " while preserving other settings.");
        }
    }

    private static String readPropertyValue(Path path, String key) throws IOException {
        Pattern propertyLine = Pattern.compile(
                "^\\s*" + Pattern.quote(key) + "\\s*[:=]\\s*(.*?)\\s*$");
        String value = null;
        for (String line : Files.readAllLines(path, StandardCharsets.UTF_8)) {
            Matcher matcher = propertyLine.matcher(line);
            if (matcher.matches()) {
                value = matcher.group(1);
            }
        }
        return value;
    }

    /**
     * Removes the player's Auto HUD config once so the sync restores this release's defaults.
     * The old file is kept aside and put back if the update does not complete, so a failed or
     * offline launch never leaves the instance without it. Returns true when a copy was staged.
     */
    private boolean stageForcedAutoHudDefault() {
        try {
            if (Files.exists(autoHudDefaultMarker) || !Files.isRegularFile(autoHudConfigPath)) {
                return false;
            }
            Files.copy(autoHudConfigPath, autoHudRestorePath, StandardCopyOption.REPLACE_EXISTING);
            Files.delete(autoHudConfigPath);
            status("Reissuing the Auto HUD defaults once; other personal settings are untouched.");
            return true;
        } catch (IOException error) {
            warning("Could not reissue the Auto HUD defaults; the existing settings were kept: "
                    + messageOf(error));
            return false;
        }
    }

    private void finishForcedAutoHudDefault(boolean staged, boolean updateSucceeded) {
        try {
            if (updateSucceeded) {
                // Marked even when nothing was staged, so a fresh install does not reissue later.
                Files.deleteIfExists(autoHudRestorePath);
                Files.writeString(autoHudDefaultMarker, AUTOHUD_DEFAULT_TOKEN + System.lineSeparator(),
                        StandardCharsets.UTF_8);
            } else if (staged && Files.isRegularFile(autoHudRestorePath)) {
                Files.createDirectories(autoHudConfigPath.getParent());
                Files.move(autoHudRestorePath, autoHudConfigPath, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException error) {
            warning("Could not finish reissuing the Auto HUD defaults: " + messageOf(error));
        }
    }

    private void tryMigratePlayerOptions() {
        try {
            if (migratePlayerOptions()) {
                status("Updated the enabled resource-pack list while preserving personal options.");
            }
        } catch (Exception error) {
            warning("Could not migrate the enabled resource-pack list; personal options were left unchanged: "
                    + messageOf(error));
        }
    }

    private boolean migratePlayerOptions() throws IOException {
        Path options = minecraftRoot.resolve("options.txt").normalize();
        if (!options.getParent().equals(minecraftRoot)
                || !Files.isRegularFile(options, LinkOption.NOFOLLOW_LINKS)
                || Files.isSymbolicLink(options)) {
            return false;
        }
        if (Files.size(options) > 16L * 1024L * 1024L) {
            throw new IOException("options.txt is unexpectedly large");
        }

        String original = Files.readString(options, StandardCharsets.UTF_8);
        String migrated = migrateOptionArrayLine(original, "resourcePacks", true);
        migrated = migrateOptionArrayLine(migrated, "incompatibleResourcePacks", false);
        if (migrated.equals(original)) {
            return false;
        }

        Path temporary = options.resolveSibling(
                "options.txt.nbidal18-" + UUID.randomUUID() + ".tmp");
        try {
            Files.writeString(temporary, migrated, StandardCharsets.UTF_8);
            try {
                Files.move(temporary, options, StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, options, StandardCopyOption.REPLACE_EXISTING);
            }
        } finally {
            Files.deleteIfExists(temporary);
        }
        return true;
    }

    private static String migrateOptionArrayLine(
            String options, String key, boolean enabledPacks) throws IOException {
        Pattern linePattern = Pattern.compile("(?m)^(" + Pattern.quote(key) + ":)([^\\r\\n]*)");
        Matcher lineMatcher = linePattern.matcher(options);
        if (!lineMatcher.find()) {
            return options;
        }

        List<String> values = parseJsonStringArray(lineMatcher.group(2));
        List<String> migrated = enabledPacks
                ? migrateEnabledResourcePacks(values)
                : migrateIncompatibleResourcePacks(values);
        String replacement = lineMatcher.group(1) + encodeJsonStringArray(migrated);
        return options.substring(0, lineMatcher.start()) + replacement
                + options.substring(lineMatcher.end());
    }

    private static List<String> migrateEnabledResourcePacks(List<String> original) {
        List<String> result = new ArrayList<>();
        for (String value : original) {
            if (value.equals(OLD_DARK_CONTAINERS_PACK)
                    || value.equals(OLD_MODDED_CONTAINERS_PACK)
                    || value.equals(OLED_CONTAINERS_PACK)
                    || value.equals(INMIS_OLED_ADDON_PACK)) {
                continue;
            }
            String migrated = value.equals(NATURE_X_PACK) ? ENHANCED_GRASS_PACK : value;
            if (!result.contains(migrated)) {
                result.add(migrated);
            }
        }

        if (!result.contains(ENHANCED_GRASS_PACK)) {
            int grassIndex = result.indexOf("file/Fancy Crops v1.3.zip");
            result.add(grassIndex >= 0 ? grassIndex : result.size(), ENHANCED_GRASS_PACK);
        }
        return result;
    }

    private static List<String> migrateIncompatibleResourcePacks(List<String> original) {
        List<String> result = new ArrayList<>();
        for (String value : original) {
            if (value.equals(NATURE_X_PACK)
                    || value.equals(OLD_DARK_CONTAINERS_PACK)
                    || value.equals(OLD_MODDED_CONTAINERS_PACK)
                    || value.equals(OLED_CONTAINERS_PACK)
                    || value.equals(INMIS_OLED_ADDON_PACK)) {
                continue;
            }
            if (!result.contains(value)) {
                result.add(value);
            }
        }
        return result;
    }

    private static List<String> parseJsonStringArray(String text) throws IOException {
        String value = text.strip();
        if (value.length() < 2 || value.charAt(0) != '['
                || value.charAt(value.length() - 1) != ']') {
            throw new IOException("invalid " + "resource-pack option array");
        }
        List<String> result = new ArrayList<>();
        int index = 1;
        while (true) {
            while (index < value.length() - 1 && Character.isWhitespace(value.charAt(index))) {
                index++;
            }
            if (index == value.length() - 1) {
                return result;
            }
            if (value.charAt(index) != '"') {
                throw new IOException("invalid resource-pack option entry");
            }
            int start = ++index;
            boolean escaped = false;
            while (index < value.length() - 1) {
                char current = value.charAt(index);
                if (!escaped && current == '"') {
                    break;
                }
                escaped = !escaped && current == '\\';
                if (current != '\\') {
                    escaped = false;
                }
                index++;
            }
            if (index >= value.length() - 1) {
                throw new IOException("unterminated resource-pack option entry");
            }
            result.add(jsonUnescape(value.substring(start, index)));
            index++;
            while (index < value.length() - 1 && Character.isWhitespace(value.charAt(index))) {
                index++;
            }
            if (index < value.length() - 1 && value.charAt(index) == ',') {
                index++;
                continue;
            }
            if (index != value.length() - 1) {
                throw new IOException("invalid resource-pack option separator");
            }
        }
    }

    private static String encodeJsonStringArray(List<String> values) {
        StringBuilder result = new StringBuilder("[");
        for (int index = 0; index < values.size(); index++) {
            if (index > 0) {
                result.append(',');
            }
            result.append('"');
            for (int character = 0; character < values.get(index).length(); character++) {
                char current = values.get(index).charAt(character);
                switch (current) {
                    case '"' -> result.append("\\\"");
                    case '\\' -> result.append("\\\\");
                    case '\b' -> result.append("\\b");
                    case '\f' -> result.append("\\f");
                    case '\n' -> result.append("\\n");
                    case '\r' -> result.append("\\r");
                    case '\t' -> result.append("\\t");
                    default -> result.append(current);
                }
            }
            result.append('"');
        }
        return result.append(']').toString();
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

    private static final class PropertyRule {
        private final String path;
        private final String key;
        private final String value;

        private PropertyRule(String path, String key, String value) {
            this.path = path;
            this.key = key;
            this.value = value;
        }
    }

    private static final class SyncManifest {
        private final String packVersion;
        private final List<String> exactRoots;
        private final List<String> extraTolerantRoots;
        private final Set<String> localAllowed;
        private final Map<String, FileEntry> files;
        private final List<PropertyRule> propertyRules;

        private SyncManifest(
                String packVersion,
                List<String> exactRoots,
                List<String> extraTolerantRoots,
                Set<String> localAllowed,
                Map<String, FileEntry> files,
                List<PropertyRule> propertyRules) {
            this.packVersion = packVersion;
            this.exactRoots = List.copyOf(exactRoots);
            this.extraTolerantRoots = List.copyOf(extraTolerantRoots);
            this.localAllowed = Set.copyOf(localAllowed);
            this.files = Map.copyOf(files);
            this.propertyRules = List.copyOf(propertyRules);
        }

        /**
         * Whether an unmanaged file at this path may simply be left alone. Config libraries write
         * their own files while Minecraft starts, so cleaning one here achieves nothing: the game
         * recreates it during mod init and the integrity check then refuses the login, every
         * launch, with no way for the player to clear it.
         */
        private boolean isExtraTolerant(String relative) {
            String key = pathKey(relative);
            for (String root : extraTolerantRoots) {
                String rootKey = pathKey(root);
                if (key.equals(rootKey) || key.startsWith(rootKey + "/")) {
                    return true;
                }
            }
            return false;
        }
    }
}
