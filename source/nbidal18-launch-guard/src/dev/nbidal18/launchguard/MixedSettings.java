package dev.nbidal18.launchguard;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

final class MixedSettings {
    private static final String OPTIONS = "options.txt";
    private static final String IRIS = "config/iris.properties";
    private static final String CONTROLIFY = "config/controlify.json";
    private static final Set<String> ALLOWED_SHADERS = Set.of(
            "",
            "ComplementaryUnbound_r5.8.1.zip",
            "MakeUp-UltraFast-9.4b.zip");

    private MixedSettings() {}

    static void enforce(Path root, StrictManifest manifest) throws IOException, GuardException {
        for (StrictManifest.SeedRule seed : manifest.seeds) {
            if (seed.targetKey().equals(OPTIONS)) enforceOptions(root, seed);
            if (seed.targetKey().equals(IRIS)) enforceIris(root, seed);
        }
        if (manifest.personal.containsKey(CONTROLIFY)) {
            Path path = LaunchGuard.resolve(root, manifest.personal.get(CONTROLIFY));
            if (Files.exists(path, LinkOption.NOFOLLOW_LINKS)) enforceControlify(path);
        }
    }

    private static void enforceOptions(Path root, StrictManifest.SeedRule seed) throws IOException, GuardException {
        Path templatePath = LaunchGuard.resolve(root, seed.template());
        Path targetPath = LaunchGuard.resolve(root, seed.target());
        String template = LaunchGuard.readPlainUtf8(templatePath);
        String target = LaunchGuard.readPlainUtf8(targetPath);
        String[] keys = {"resourcePacks", "incompatibleResourcePacks"};
        for (String key : keys) {
            String canonical = uniqueColonLine(template, key, true);
            target = replaceUniqueColonLine(target, key, canonical);
        }
        LaunchGuard.writeUtf8IfChanged(targetPath, target);
    }

    private static String uniqueColonLine(String text, String key, boolean required) throws GuardException {
        String found = null;
        for (String line : logicalLines(text)) {
            if (line.startsWith(key + ":")) {
                if (found != null) throw new GuardException("Duplicate " + key + " setting in canonical options template.");
                found = line;
            }
        }
        if (required && found == null) throw new GuardException("Canonical options template has no " + key + " setting.");
        return found;
    }

    private static String replaceUniqueColonLine(String text, String key, String replacement) throws GuardException {
        LineDocument document = LineDocument.parse(text);
        int found = -1;
        for (int i = 0; i < document.lines.size(); i++) {
            if (document.lines.get(i).startsWith(key + ":")) {
                if (found >= 0) throw new GuardException("Duplicate " + key + " setting in player options.txt.");
                found = i;
            }
        }
        if (found >= 0) document.lines.set(found, replacement); else document.lines.add(replacement);
        return document.render();
    }

    private static void enforceIris(Path root, StrictManifest.SeedRule seed) throws IOException, GuardException {
        Path templatePath = LaunchGuard.resolve(root, seed.template());
        Path targetPath = LaunchGuard.resolve(root, seed.target());
        String template = LaunchGuard.readPlainUtf8(templatePath);
        String target = LaunchGuard.readPlainUtf8(targetPath);

        String templateShader = propertyValue(template, "shaderPack", false);
        if (templateShader == null || !ALLOWED_SHADERS.contains(templateShader)) templateShader = "";
        LineDocument document = LineDocument.parse(target);
        setProperty(document, "allowUnknownShaders", "false", true);
        String currentShader = propertyValue(document.render(), "shaderPack", false);
        if (currentShader == null) {
            setProperty(document, "shaderPack", templateShader, true);
        } else if (!ALLOWED_SHADERS.contains(currentShader)) {
            setProperty(document, "shaderPack", templateShader, false);
        }
        LaunchGuard.writeUtf8IfChanged(targetPath, document.render());
    }

    private static String propertyValue(String text, String key, boolean required) throws GuardException {
        String value = null;
        for (String line : logicalLines(text)) {
            String trimmed = line.trim();
            if (trimmed.isEmpty() || trimmed.startsWith("#") || trimmed.startsWith("!")) continue;
            int separator = propertySeparator(trimmed);
            String candidateKey = separator < 0 ? trimmed : trimmed.substring(0, separator).trim();
            if (candidateKey.equals(key)) {
                if (value != null) throw new GuardException("Duplicate Iris property: " + key);
                value = separator < 0 ? "" : trimmed.substring(separator + 1).trim();
            }
        }
        if (required && value == null) throw new GuardException("Missing Iris property: " + key);
        return value;
    }

    private static void setProperty(LineDocument document, String key, String value, boolean appendIfMissing) throws GuardException {
        int found = -1;
        for (int i = 0; i < document.lines.size(); i++) {
            String trimmed = document.lines.get(i).trim();
            if (trimmed.isEmpty() || trimmed.startsWith("#") || trimmed.startsWith("!")) continue;
            int separator = propertySeparator(trimmed);
            String candidateKey = separator < 0 ? trimmed : trimmed.substring(0, separator).trim();
            if (candidateKey.equals(key)) {
                if (found >= 0) throw new GuardException("Duplicate Iris property: " + key);
                found = i;
            }
        }
        if (found >= 0) document.lines.set(found, key + "=" + value);
        else if (appendIfMissing) document.lines.add(key + "=" + value);
    }

    private static int propertySeparator(String value) {
        int equals = value.indexOf('=');
        int colon = value.indexOf(':');
        if (equals < 0) return colon;
        if (colon < 0) return equals;
        return Math.min(equals, colon);
    }

    private static void enforceControlify(Path path) throws IOException, GuardException {
        String json = LaunchGuard.readPlainUtf8(path);
        JsonReachAround parser = new JsonReachAround(json);
        JsonReachAround.Target target = parser.parse();
        if (target == null) throw new GuardException("config/controlify.json has no global.reach_around setting.");
        if (!target.stringValue()) throw new GuardException("config/controlify.json global.reach_around is not a string.");
        if (!target.decoded().equals("OFF")) {
            String replacement = json.substring(0, target.start()) + "\"OFF\"" + json.substring(target.end());
            LaunchGuard.writeUtf8IfChanged(path, replacement);
        }
    }

    private static List<String> logicalLines(String text) {
        return List.of(text.split("\\r?\\n", -1));
    }

    private static final class LineDocument {
        final List<String> lines;
        final String newline;
        final boolean endedWithNewline;

        private LineDocument(List<String> lines, String newline, boolean endedWithNewline) {
            this.lines = lines;
            this.newline = newline;
            this.endedWithNewline = endedWithNewline;
        }

        static LineDocument parse(String text) {
            String newline = text.contains("\r\n") ? "\r\n" : "\n";
            boolean ended = text.endsWith("\n");
            String[] split = text.split("\\r?\\n", -1);
            List<String> lines = new ArrayList<>(List.of(split));
            if (ended && !lines.isEmpty() && lines.get(lines.size() - 1).isEmpty()) lines.remove(lines.size() - 1);
            return new LineDocument(lines, newline, ended);
        }

        String render() {
            String result = String.join(newline, lines);
            return endedWithNewline ? result + newline : result;
        }
    }

    /** Strict JSON parser that records only the byte-preserving edit range we need. */
    private static final class JsonReachAround {
        private final String input;
        private int position;
        private Target target;

        record Target(int start, int end, boolean stringValue, String decoded) {}

        JsonReachAround(String input) { this.input = input; }

        Target parse() throws GuardException {
            skipWhitespace();
            parseValue(List.of());
            skipWhitespace();
            if (position != input.length()) error("trailing data");
            return target;
        }

        private Value parseValue(List<String> path) throws GuardException {
            skipWhitespace();
            if (position >= input.length()) error("unexpected end of input");
            char next = input.charAt(position);
            if (next == '{') return parseObject(path);
            if (next == '[') return parseArray(path);
            if (next == '"') {
                int start = position;
                String value = parseString();
                return new Value(start, position, true, value);
            }
            if (startsWith("true")) { int start = position; position += 4; return new Value(start, position, false, null); }
            if (startsWith("false")) { int start = position; position += 5; return new Value(start, position, false, null); }
            if (startsWith("null")) { int start = position; position += 4; return new Value(start, position, false, null); }
            return parseNumber();
        }

        private Value parseObject(List<String> path) throws GuardException {
            int start = position++;
            skipWhitespace();
            Set<String> names = new HashSet<>();
            if (consume('}')) return new Value(start, position, false, null);
            while (true) {
                skipWhitespace();
                if (position >= input.length() || input.charAt(position) != '"') error("object key must be a string");
                String name = parseString();
                if (!names.add(name)) error("duplicate object key: " + name);
                skipWhitespace();
                require(':');
                List<String> childPath = new ArrayList<>(path);
                childPath.add(name);
                Value value = parseValue(List.copyOf(childPath));
                if (path.size() == 1 && path.get(0).equals("global") && name.equals("reach_around")) {
                    if (target != null) error("duplicate global.reach_around setting");
                    target = new Target(value.start, value.end, value.string, value.decoded);
                }
                skipWhitespace();
                if (consume('}')) break;
                require(',');
            }
            return new Value(start, position, false, null);
        }

        private Value parseArray(List<String> path) throws GuardException {
            int start = position++;
            skipWhitespace();
            if (consume(']')) return new Value(start, position, false, null);
            List<String> elementPath = new ArrayList<>(path);
            elementPath.add("[]");
            while (true) {
                parseValue(List.copyOf(elementPath));
                skipWhitespace();
                if (consume(']')) break;
                require(',');
            }
            return new Value(start, position, false, null);
        }

        private Value parseNumber() throws GuardException {
            int start = position;
            if (consume('-')) {}
            if (consume('0')) {
                if (position < input.length() && Character.isDigit(input.charAt(position))) error("leading zero in number");
            } else {
                requireDigits();
            }
            if (consume('.')) requireDigits();
            if (consume('e') || consume('E')) {
                if (!consume('+')) consume('-');
                requireDigits();
            }
            if (position == start) error("invalid value");
            return new Value(start, position, false, null);
        }

        private void requireDigits() throws GuardException {
            int start = position;
            while (position < input.length() && Character.isDigit(input.charAt(position))) position++;
            if (position == start) error("expected digit");
        }

        private String parseString() throws GuardException {
            require('"');
            StringBuilder decoded = new StringBuilder();
            while (position < input.length()) {
                char value = input.charAt(position++);
                if (value == '"') return decoded.toString();
                if (value < 0x20) error("control character in string");
                if (value != '\\') { decoded.append(value); continue; }
                if (position >= input.length()) error("unterminated escape");
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

        private char parseUnicode() throws GuardException {
            if (position + 4 > input.length()) error("short unicode escape");
            int value = 0;
            for (int i = 0; i < 4; i++) {
                int digit = Character.digit(input.charAt(position++), 16);
                if (digit < 0) error("invalid unicode escape");
                value = (value << 4) | digit;
            }
            return (char) value;
        }

        private void skipWhitespace() {
            while (position < input.length()) {
                char c = input.charAt(position);
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') position++; else break;
            }
        }

        private boolean startsWith(String value) {
            if (!input.startsWith(value, position)) return false;
            int end = position + value.length();
            return end == input.length() || " \t\r\n,]}".indexOf(input.charAt(end)) >= 0;
        }

        private boolean consume(char expected) {
            if (position < input.length() && input.charAt(position) == expected) { position++; return true; }
            return false;
        }

        private void require(char expected) throws GuardException {
            if (!consume(expected)) error("expected '" + expected + "'");
        }

        private void error(String message) throws GuardException {
            throw new GuardException("Malformed config/controlify.json at character " + position + ": " + message);
        }

        private record Value(int start, int end, boolean string, String decoded) {}
    }
}
