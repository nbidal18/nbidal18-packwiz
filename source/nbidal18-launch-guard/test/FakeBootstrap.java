import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

/** Disposable Packwiz-bootstrap stand-in used only by smoke-test.ps1. */
public final class FakeBootstrap {
    public static void main(String[] args) throws Exception {
        Path countPath = Path.of("fake-bootstrap-count.txt");
        int count = Files.exists(countPath)
                ? Integer.parseInt(Files.readString(countPath, StandardCharsets.UTF_8).trim())
                : 0;
        Files.writeString(countPath, Integer.toString(count + 1), StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
        if (count == 0) Files.deleteIfExists(Path.of("config", "transition-setting.txt"));
        Files.writeString(Path.of("packwiz.json"), "{}\n", StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
    }
}
