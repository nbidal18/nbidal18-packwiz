package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.List;

final class ClosedEmptyRootVerifier {
    static final List<Path> RELATIVE_ROOTS = List.of(
            Path.of("moonlight-global-datapacks"),
            Path.of("villagerpacks"),
            Path.of("server-resource-packs")
    );

    private final Path gameDirectory;

    ClosedEmptyRootVerifier(Path gameDirectory) throws IntegrityException {
        this.gameDirectory = StrictManifest.normalizedRoot(gameDirectory);
    }

    VerificationResult verify() {
        for (Path relativeRoot : RELATIVE_ROOTS) {
            VerificationResult result = verifyRoot(relativeRoot);
            if (!result.clean()) {
                return result;
            }
        }
        return VerificationResult.success();
    }

    private VerificationResult verifyRoot(Path relativeRoot) {
        Path root = gameDirectory.resolve(relativeRoot).normalize();
        String display = StrictManifest.portable(relativeRoot);
        try {
            if (!root.startsWith(gameDirectory)) {
                return VerificationResult.failure("Closed global-datapack root escaped the game directory");
            }
            BasicFileAttributes attributes = Files.readAttributes(
                    root,
                    BasicFileAttributes.class,
                    LinkOption.NOFOLLOW_LINKS
            );
            if (!attributes.isDirectory() || IntegrityFiles.isLinkOrReparse(root, attributes)) {
                return VerificationResult.failure(display + " is missing or unsafe");
            }
            try (DirectoryStream<Path> children = Files.newDirectoryStream(root)) {
                if (children.iterator().hasNext()) {
                    return VerificationResult.failure(
                            display + " must remain empty; injected loadable content was detected"
                    );
                }
            }
            return VerificationResult.success();
        } catch (IOException failure) {
            return VerificationResult.failure("Could not verify closed empty root " + display);
        }
    }

    boolean contains(Path relative) {
        return RELATIVE_ROOTS.stream().anyMatch(root -> StrictManifest.withinOrEqual(root, relative));
    }

    record VerificationResult(boolean clean, String message) {
        static VerificationResult success() {
            return new VerificationResult(true, "clean");
        }

        static VerificationResult failure(String message) {
            return new VerificationResult(false, message);
        }
    }
}
