package dev.nbidal18.launchguard;

import java.nio.file.Files;
import java.nio.file.Path;

/** Parses the producer's full manifest without mutating its fixture. */
public final class ManifestProbe {
    public static void main(String[] args) throws Exception {
        StrictManifest manifest = StrictManifest.parse(Files.readAllBytes(Path.of(args[0])));
        System.out.printf("Parsed producer manifest: %d managed, %d optional, %d personal, %d runtime, %d runtime-prefix, %d seed, %d regenerate-prefix%n",
                manifest.managed.size(), manifest.optional.size(), manifest.personal.size(),
                manifest.runtime.size(), manifest.runtimePrefixes.size(), manifest.seeds.size(),
                manifest.regeneratePrefixes.size());
    }
}
