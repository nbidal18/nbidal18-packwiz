package dev.nbidal18.packcompat;

import java.util.regex.Pattern;

final class IntegrityReason {
    static final String PRIVATE_PATH_FALLBACK =
            "Local integrity verification failed; inspect latest.log for private path details";

    private static final Pattern WINDOWS_ABSOLUTE_PATH = Pattern.compile(
            "(?i)(?:[a-z]:[\\\\/]|\\\\\\\\|file:[\\\\/]{2,})"
    );
    private static final Pattern UNIX_ABSOLUTE_PATH = Pattern.compile(
            "(?i)(?:^|[^a-z0-9])/(?:home|users|root|tmp|var|private|etc|opt)(?:/|\\b)"
    );

    private IntegrityReason() {
    }

    static String sanitizeForWire(String raw) {
        String normalized = normalizePrintableAscii(raw);
        if (normalized.isBlank()) {
            return "Integrity verification failed without a local reason";
        }
        if (WINDOWS_ABSOLUTE_PATH.matcher(normalized).find()
                || UNIX_ABSOLUTE_PATH.matcher(normalized).find()) {
            return PRIVATE_PATH_FALLBACK;
        }
        if (normalized.length() <= IntegrityProtocol.MAX_REASON_LENGTH) {
            return normalized;
        }
        return normalized.substring(0, IntegrityProtocol.MAX_REASON_LENGTH - 3) + "...";
    }

    private static String normalizePrintableAscii(String raw) {
        if (raw == null) {
            return "";
        }
        StringBuilder result = new StringBuilder(Math.min(raw.length(), IntegrityProtocol.MAX_REASON_LENGTH));
        boolean pendingSpace = false;
        for (int index = 0; index < raw.length(); index++) {
            char value = raw.charAt(index);
            if (Character.isWhitespace(value) || Character.isISOControl(value)) {
                pendingSpace = result.length() > 0;
                continue;
            }
            if (pendingSpace) {
                result.append(' ');
                pendingSpace = false;
            }
            result.append(value >= 0x20 && value <= 0x7e ? value : '?');
        }
        return result.toString().trim();
    }
}
