package dev.nbidal18.packcompat;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class IntegrityVerifierTest {
    @TempDir
    Path temporary;

    private TestPackFixture fixture;
    private StrictManifest manifest;
    private IntegrityVerifier verifier;

    @BeforeEach
    void prepare() throws Exception {
        fixture = new TestPackFixture(temporary);
        manifest = fixture.writeManifest();
        verifier = new IntegrityVerifier(temporary);
    }

    @Test
    void verifiesExactRuntimeRootsButIgnoresGeneralConfigChurn() throws Exception {
        assertTrue(verifier.verifyFull(manifest, Map.of(), false).clean());

        fixture.write("config/general.toml", "trusted mod rewrote this config");
        fixture.write("config/unknown-runtime-cache.json", "allowed after launch");
        assertTrue(verifier.verifyFull(manifest, Map.of(), false).clean());

        fixture.write("mods/unknown.jar", "not allowed");
        assertFalse(verifier.verifyFull(manifest, Map.of(), false).clean());
        Files.delete(fixture.resolve("mods/unknown.jar"));

        Files.delete(fixture.resolve("mods/exact.jar"));
        assertFalse(verifier.verifyFull(manifest, Map.of(), false).clean());
    }

    @Test
    void optionalFileMayBeAbsentButMustMatchWhenPresent() throws Exception {
        assertTrue(verifier.verifyFull(manifest, Map.of(), false).clean());
        fixture.write("datapacks/private.zip", "wrong private archive");
        assertFalse(verifier.verifyFull(manifest, Map.of(), false).clean());
        fixture.write("datapacks/private.zip", "authorized private");
        assertTrue(verifier.verifyFull(manifest, Map.of(), false).clean());
    }

    @Test
    void declaredPersonalFileIsAllowedButOtherSidecarsAreNot() throws Exception {
        fixture.write("shaderpacks/ComplementaryUnbound_r5.8.1.zip.txt", "player selection metadata");
        assertTrue(verifier.verifyFull(manifest, Map.of(), false).clean());
        fixture.write("shaderpacks/unknown.zip.txt", "undeclared sidecar");
        assertFalse(verifier.verifyFull(manifest, Map.of(), false).clean());
    }

    @Test
    void regeneratedShaderTreeMustBeAbsentAtStartupThenLocksExactly() throws Exception {
        Path prefix = manifest.regeneratePrefixes().getFirst();
        fixture.write(StrictManifest.portable(prefix.resolve("shaders/program.glsl")), "first generated content");

        assertFalse(verifier.verifyFull(manifest, Map.of(), false).clean());
        IntegrityVerifier.VerificationResult learning = verifier.verifyFull(manifest, Map.of(), true);
        assertTrue(learning.clean());
        assertTrue(learning.detectedRegeneratePrefixes().contains(StrictManifest.key(prefix)));

        IntegrityVerifier.RegeneratedTree captured = verifier.captureRegeneratedTree(prefix);
        Map<String, IntegrityVerifier.RegeneratedTree> locked = Map.of(StrictManifest.key(prefix), captured);
        assertTrue(verifier.verifyFull(manifest, locked, false).clean());

        fixture.write(StrictManifest.portable(prefix.resolve("shaders/program.glsl")), "tampered later");
        assertFalse(verifier.verifyFull(manifest, locked, false).clean());
        fixture.write(StrictManifest.portable(prefix.resolve("extra.txt")), "extra later");
        assertFalse(verifier.verifyFull(manifest, locked, false).clean());
        Files.delete(fixture.resolve(StrictManifest.portable(prefix.resolve("extra.txt"))));
        Files.createDirectories(fixture.resolve(StrictManifest.portable(prefix.resolve("empty-extra-directory"))));
        assertFalse(verifier.verifyFull(manifest, locked, false).clean());
    }

    @Test
    void metadataCacheTriggersRehashWhenAFileChanges() throws Exception {
        IntegrityVerifier.VerificationResult first = verifier.verifyFull(manifest, Map.of(), false);
        assertTrue(first.clean());
        assertTrue(verifier.verifyMetadata(manifest, Map.of(), false, first.fingerprints()).unchanged());

        fixture.write("mods/exact.jar", "same path, different bytes");
        assertFalse(verifier.verifyMetadata(manifest, Map.of(), false, first.fingerprints()).unchanged());
        assertFalse(verifier.verifyFull(manifest, Map.of(), false).clean());
    }
}
