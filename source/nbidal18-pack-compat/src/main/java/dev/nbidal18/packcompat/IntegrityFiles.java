package dev.nbidal18.packcompat;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Locale;

final class IntegrityFiles {
    private static final HexFormat HEX = HexFormat.of();

    private IntegrityFiles() {
    }

    static byte[] readRegularFile(Path path, int maximumBytes) throws IOException, IntegrityException {
        BasicFileAttributes attributes = Files.readAttributes(
                path,
                BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS
        );
        if (!attributes.isRegularFile() || isLinkOrReparse(path, attributes)) {
            throw new IntegrityException("Expected a regular file: " + path.getFileName());
        }
        if (attributes.size() > maximumBytes) {
            throw new IntegrityException("File is larger than the supported limit: " + path.getFileName());
        }

        try (InputStream input = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS);
             ByteArrayOutputStream output = new ByteArrayOutputStream((int) attributes.size())) {
            byte[] buffer = new byte[8192];
            int total = 0;
            int read;
            while ((read = input.read(buffer)) >= 0) {
                total += read;
                if (total > maximumBytes) {
                    throw new IntegrityException("File grew beyond the supported limit: " + path.getFileName());
                }
                output.write(buffer, 0, read);
            }
            return output.toByteArray();
        }
    }

    static String sha256(byte[] content) {
        return HEX.formatHex(newDigest().digest(content));
    }

    static String sha256(Path path) throws IOException {
        MessageDigest digest = newDigest();
        try (InputStream input = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS)) {
            byte[] buffer = new byte[128 * 1024];
            int read;
            while ((read = input.read(buffer)) >= 0) {
                digest.update(buffer, 0, read);
            }
        }
        return HEX.formatHex(digest.digest());
    }

    static boolean isLinkOrReparse(Path path, BasicFileAttributes attributes) throws IOException {
        if (attributes.isSymbolicLink() || attributes.isOther() || Files.isSymbolicLink(path)) {
            return true;
        }
        if (System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win")) {
            try {
                Object raw = Files.getAttribute(path, "dos:attributes", LinkOption.NOFOLLOW_LINKS);
                if (raw instanceof Number number && (number.intValue() & 0x400) != 0) {
                    return true;
                }
            } catch (UnsupportedOperationException | IllegalArgumentException ignored) {
            }
        }
        if (attributes.isDirectory()) {
            Path notFollowed = path.toRealPath(LinkOption.NOFOLLOW_LINKS);
            Path followed = path.toRealPath();
            return !samePath(notFollowed, followed);
        }
        return false;
    }

    private static boolean samePath(Path first, Path second) {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win")
                ? first.toString().equalsIgnoreCase(second.toString())
                : first.equals(second);
    }

    private static MessageDigest newDigest() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }
}
