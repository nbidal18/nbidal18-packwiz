package dev.nbidal18.launchguard;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;

/**
 * Identity-shaped negative fixture: it can falsely exit zero without running
 * policy, optionally consuming the request first. The real parent must reject
 * both cases because no valid handoff attestation is produced.
 */
public final class LaunchGuard {
    public static void main(String[] args) throws Exception {
        if (Files.exists(Path.of("fake-child-consume-request.txt"))) {
            Files.deleteIfExists(Path.of(".nbidal18", "guard-handoff-request.tsv"));
        }
        if (Files.exists(Path.of("fake-child-write-stale-attestation.txt"))) {
            String text = "nbidal18-launch-guard-handoff\t1\n"
                    + "guard-sha256\t" + System.getProperty(
                            "nbidal18.launchguard.handoff-guard-sha256") + "\n"
                    + "companion-sha256\t" + System.getProperty(
                            "nbidal18.launchguard.handoff-companion-sha256") + "\n"
                    + "manifest-sha256\t" + System.getProperty(
                            "nbidal18.launchguard.handoff-manifest-sha256") + "\n"
                    + "verified-at-utc\t1970-01-01T00:00:00Z\n";
            Files.writeString(Path.of(".nbidal18", "launch-guard-handoff.tsv"),
                    text, StandardCharsets.UTF_8);
        }
    }
}
