package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

final class RuntimeSettingsVerifier {
    static final Path OPTIONS = Path.of("options.txt");
    static final Path IRIS = Path.of("config", "iris.properties");
    static final Path CONTROLIFY = Path.of("config", "controlify.json");

    private static final int MAXIMUM_TEXT_BYTES = 2 * 1024 * 1024;
    private static final Set<String> ALLOWED_SHADERS = Set.of(
            "",
            "ComplementaryUnbound_r5.8.1.zip",
            "ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3",
            "MakeUp-UltraFast-9.4b.zip"
    );

    private final Path gameDirectory;

    RuntimeSettingsVerifier(Path gameDirectory) throws IntegrityException {
        this.gameDirectory = StrictManifest.normalizedRoot(gameDirectory);
    }

    SettingsResult verify(StrictManifest manifest) {
        try {
            verifyOptions(manifest);
            verifyIris(manifest);
            verifyControlify(manifest);
            return new SettingsResult(true, "clean");
        } catch (IOException | IntegrityException failure) {
            String message = failure.getMessage();
            return new SettingsResult(
                    false,
                    message == null || message.isBlank() ? "Security-sensitive settings are invalid" : message
            );
        }
    }

    private void verifyOptions(StrictManifest manifest) throws IOException, IntegrityException {
        StrictManifest.SeedRule seed = seedForTarget(manifest, OPTIONS);
        if (seed == null) {
            throw new IntegrityException("The strict manifest has no options.txt security seed");
        }
        verifyManagedTemplate(manifest, seed.template());
        String template = readText(seed.template());
        String target = readText(seed.target());
        for (String key : List.of("resourcePacks", "incompatibleResourcePacks")) {
            String expected = uniqueColonLine(template, key, "canonical options template");
            String actual = uniqueColonLine(target, key, "player options.txt");
            if (!expected.equals(actual)) {
                throw new IntegrityException("Security-sensitive options.txt setting changed: " + key);
            }
        }
    }

    private void verifyIris(StrictManifest manifest) throws IOException, IntegrityException {
        StrictManifest.SeedRule seed = seedForTarget(manifest, IRIS);
        if (seed == null) {
            throw new IntegrityException("The strict manifest has no Iris security seed");
        }
        verifyManagedTemplate(manifest, seed.template());
        String target = readText(seed.target());
        String allowUnknown = uniqueProperty(target, "allowUnknownShaders", true);
        if (!"false".equals(allowUnknown)) {
            throw new IntegrityException("Iris allowUnknownShaders must remain false");
        }
        String shaderPack = uniqueProperty(target, "shaderPack", true);
        if (!ALLOWED_SHADERS.contains(shaderPack)) {
            throw new IntegrityException("Iris selected an undeclared shader pack");
        }
    }

    private void verifyControlify(StrictManifest manifest) throws IOException, IntegrityException {
        String key = StrictManifest.key(CONTROLIFY);
        if (!manifest.personalFilesByKey().containsKey(key)) {
            throw new IntegrityException("The strict manifest has no Controlify personal-file policy");
        }
        Path path = resolve(CONTROLIFY);
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            return;
        }
        JsonReachAround.Target target = new JsonReachAround(readText(CONTROLIFY)).parse();
        if (target == null || !target.stringValue() || !"OFF".equals(target.decoded())) {
            throw new IntegrityException("Controlify global.reach_around must remain OFF");
        }
    }

    private void verifyManagedTemplate(StrictManifest manifest, Path template)
            throws IOException, IntegrityException {
        StrictManifest.FileRule rule = manifest.filesByKey().get(StrictManifest.key(template));
        if (rule == null || rule.optional()) {
            throw new IntegrityException("Security seed template is not managed: "
                    + StrictManifest.portable(template));
        }
        Path path = resolve(template);
        byte[] content = IntegrityFiles.readRegularFile(path, MAXIMUM_TEXT_BYTES);
        if (!IntegrityFiles.sha256(content).equals(rule.sha256())) {
            throw new IntegrityException("Security seed template hash changed: "
                    + StrictManifest.portable(template));
        }
    }

    private StrictManifest.SeedRule seedForTarget(StrictManifest manifest, Path target) {
        String targetKey = StrictManifest.key(target);
        for (StrictManifest.SeedRule seed : manifest.seeds()) {
            if (StrictManifest.key(seed.target()).equals(targetKey)) {
                return seed;
            }
        }
        return null;
    }

    private String readText(Path relative) throws IOException, IntegrityException {
        byte[] content = IntegrityFiles.readRegularFile(resolve(relative), MAXIMUM_TEXT_BYTES);
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(content))
                    .toString();
        } catch (CharacterCodingException malformed) {
            throw new IntegrityException("Security-sensitive file is not valid UTF-8: "
                    + StrictManifest.portable(relative), malformed);
        }
    }

    private Path resolve(Path relative) throws IntegrityException {
        Path resolved = gameDirectory.resolve(relative).normalize();
        if (!resolved.startsWith(gameDirectory)) {
            throw new IntegrityException("Security-sensitive path escaped the game directory");
        }
        return resolved;
    }

    private static String uniqueColonLine(String text, String key, String description)
            throws IntegrityException {
        String found = null;
        for (String line : text.split("\\r?\\n", -1)) {
            if (!line.startsWith(key + ":")) {
                continue;
            }
            if (found != null) {
                throw new IntegrityException("Duplicate " + key + " in " + description);
            }
            found = line;
        }
        if (found == null) {
            throw new IntegrityException("Missing " + key + " in " + description);
        }
        return found;
    }

    private static String uniqueProperty(String text, String key, boolean required)
            throws IntegrityException {
        String value = null;
        for (String line : text.split("\\r?\\n", -1)) {
            String trimmed = line.trim();
            if (trimmed.isEmpty() || trimmed.startsWith("#") || trimmed.startsWith("!")) {
                continue;
            }
            int separator = propertySeparator(trimmed);
            String candidateKey = separator < 0 ? trimmed : trimmed.substring(0, separator).trim();
            if (!candidateKey.equals(key)) {
                continue;
            }
            if (value != null) {
                throw new IntegrityException("Duplicate Iris property: " + key);
            }
            value = separator < 0 ? "" : trimmed.substring(separator + 1).trim();
        }
        if (required && value == null) {
            throw new IntegrityException("Missing Iris property: " + key);
        }
        return value;
    }

    private static int propertySeparator(String value) {
        int equals = value.indexOf('=');
        int colon = value.indexOf(':');
        if (equals < 0) {
            return colon;
        }
        if (colon < 0) {
            return equals;
        }
        return Math.min(equals, colon);
    }

    record SettingsResult(boolean clean, String message) {
    }

    /** Strict JSON reader that exposes only the one Controlify value being checked. */
    private static final class JsonReachAround {
        private final String input;
        private int position;
        private Target target;

        record Target(boolean stringValue, String decoded) {
        }

        JsonReachAround(String input) {
            this.input = input;
        }

        Target parse() throws IntegrityException {
            skipWhitespace();
            parseValue(List.of());
            skipWhitespace();
            if (position != input.length()) {
                error("trailing data");
            }
            return target;
        }

        private Value parseValue(List<String> path) throws IntegrityException {
            skipWhitespace();
            if (position >= input.length()) {
                error("unexpected end of input");
            }
            char next = input.charAt(position);
            if (next == '{') {
                return parseObject(path);
            }
            if (next == '[') {
                return parseArray(path);
            }
            if (next == '"') {
                String value = parseString();
                return new Value(true, value);
            }
            if (startsWith("true")) {
                position += 4;
                return new Value(false, null);
            }
            if (startsWith("false")) {
                position += 5;
                return new Value(false, null);
            }
            if (startsWith("null")) {
                position += 4;
                return new Value(false, null);
            }
            return parseNumber();
        }

        private Value parseObject(List<String> path) throws IntegrityException {
            position++;
            skipWhitespace();
            Set<String> names = new HashSet<>();
            if (consume('}')) {
                return new Value(false, null);
            }
            while (true) {
                skipWhitespace();
                if (position >= input.length() || input.charAt(position) != '"') {
                    error("object key must be a string");
                }
                String name = parseString();
                if (!names.add(name)) {
                    error("duplicate object key: " + name);
                }
                skipWhitespace();
                require(':');
                List<String> childPath = new ArrayList<>(path);
                childPath.add(name);
                Value value = parseValue(List.copyOf(childPath));
                if (path.size() == 1 && path.get(0).equals("global") && name.equals("reach_around")) {
                    if (target != null) {
                        error("duplicate global.reach_around setting");
                    }
                    target = new Target(value.string(), value.decoded());
                }
                skipWhitespace();
                if (consume('}')) {
                    break;
                }
                require(',');
            }
            return new Value(false, null);
        }

        private Value parseArray(List<String> path) throws IntegrityException {
            position++;
            skipWhitespace();
            if (consume(']')) {
                return new Value(false, null);
            }
            while (true) {
                parseValue(path);
                skipWhitespace();
                if (consume(']')) {
                    break;
                }
                require(',');
            }
            return new Value(false, null);
        }

        private Value parseNumber() throws IntegrityException {
            int start = position;
            consume('-');
            if (consume('0')) {
                if (position < input.length() && Character.isDigit(input.charAt(position))) {
                    error("leading zero in number");
                }
            } else {
                requireDigits();
            }
            if (consume('.')) {
                requireDigits();
            }
            if (consume('e') || consume('E')) {
                if (!consume('+')) {
                    consume('-');
                }
                requireDigits();
            }
            if (position == start) {
                error("invalid value");
            }
            return new Value(false, null);
        }

        private void requireDigits() throws IntegrityException {
            int start = position;
            while (position < input.length() && Character.isDigit(input.charAt(position))) {
                position++;
            }
            if (position == start) {
                error("expected digit");
            }
        }

        private String parseString() throws IntegrityException {
            require('"');
            StringBuilder decoded = new StringBuilder();
            while (position < input.length()) {
                char value = input.charAt(position++);
                if (value == '"') {
                    return decoded.toString();
                }
                if (value < 0x20) {
                    error("control character in string");
                }
                if (value != '\\') {
                    decoded.append(value);
                    continue;
                }
                if (position >= input.length()) {
                    error("unterminated escape");
                }
                char escape = input.charAt(position++);
                switch (escape) {
                    case '"', '\\', '/' -> decoded.append(escape);
                    case 'b' -> decoded.append('\b');
                    case 'f' -> decoded.append('\f');
                    case 'n' -> decoded.append('\n');
                    case 'r' -> decoded.append('\r');
                    case 't' -> decoded.append('\t');
                    case 'u' -> decoded.append(parseUnicode());
                    default -> error("invalid string escape");
                }
            }
            error("unterminated string");
            return null;
        }

        private char parseUnicode() throws IntegrityException {
            if (position + 4 > input.length()) {
                error("short unicode escape");
            }
            int value = 0;
            for (int index = 0; index < 4; index++) {
                int digit = Character.digit(input.charAt(position++), 16);
                if (digit < 0) {
                    error("invalid unicode escape");
                }
                value = (value << 4) | digit;
            }
            return (char) value;
        }

        private void skipWhitespace() {
            while (position < input.length() && " \t\r\n".indexOf(input.charAt(position)) >= 0) {
                position++;
            }
        }

        private boolean startsWith(String value) {
            if (!input.startsWith(value, position)) {
                return false;
            }
            int end = position + value.length();
            return end == input.length() || " \t\r\n,]}".indexOf(input.charAt(end)) >= 0;
        }

        private boolean consume(char expected) {
            if (position < input.length() && input.charAt(position) == expected) {
                position++;
                return true;
            }
            return false;
        }

        private void require(char expected) throws IntegrityException {
            if (!consume(expected)) {
                error("expected '" + expected + "'");
            }
        }

        private void error(String message) throws IntegrityException {
            throw new IntegrityException("Malformed config/controlify.json near character "
                    + position + ": " + message);
        }

        private record Value(boolean string, String decoded) {
        }
    }
}
