import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.StandardCopyOption;
import java.util.Arrays;

/** Disposable Packwiz-bootstrap stand-in used only by smoke-test.ps1. */
public final class FakeBootstrap {
    public static void main(String[] args) throws Exception {
        Path countPath = Path.of("fake-bootstrap-count.txt");
        int count = Files.exists(countPath)
                ? Integer.parseInt(Files.readString(countPath, StandardCharsets.UTF_8).trim())
                : 0;
        Files.writeString(countPath, Integer.toString(count + 1), StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
        Path failAtPath = Path.of("fake-bootstrap-fail-at.txt");
        if (Files.exists(failAtPath)) {
            int failAt = Integer.parseInt(Files.readString(failAtPath, StandardCharsets.UTF_8).trim());
            if (count + 1 >= failAt) System.exit(23);
        }
        Path forcedManifest = Path.of(".fake-packwiz-forced-manifest.tsv");
        if (Arrays.asList(args).contains("--bootstrap-no-update") && Files.exists(forcedManifest)) {
            Files.copy(forcedManifest, Path.of(".nbidal18", "strict-manifest.tsv"),
                    StandardCopyOption.REPLACE_EXISTING);
        }
        if (count == 0) Files.deleteIfExists(Path.of("config", "transition-setting.txt"));
        Files.writeString(Path.of("packwiz.json"), "{}\n", StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
    }
}
