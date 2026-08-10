package dev.nbidal18.packcompat;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RuntimeSettingsVerifierTest {
    @TempDir
    Path temporary;

    private TestPackFixture fixture;
    private StrictManifest manifest;
    private RuntimeSettingsVerifier verifier;

    @BeforeEach
    void prepare() throws Exception {
        fixture = new TestPackFixture(temporary);
        manifest = fixture.writeManifest();
        verifier = new RuntimeSettingsVerifier(temporary);
    }

    @Test
    void acceptsOnlyTheNarrowSecurityPolicyAndIgnoresUnrelatedSettings() throws Exception {
        assertTrue(verifier.verify(manifest).clean());

        fixture.write("options.txt", TestPackFixture.OPTIONS_TEXT.replace("fov:0.5", "fov:1.0"));
        fixture.write("config/iris.properties", TestPackFixture.IRIS_TEXT.replace("other=value", "other=changed"));
        fixture.write("config/controlify.json",
                "{\"unrelated\":123,\"global\":{\"other\":false,\"reach_around\":\"OFF\"}}\n");
        assertTrue(verifier.verify(manifest).clean());
    }

    @Test
    void rejectsResourcePackIrisAndReachAroundPolicyChanges() throws Exception {
        fixture.write("options.txt", TestPackFixture.OPTIONS_TEXT.replace("incompatibleResourcePacks:[]",
                "incompatibleResourcePacks:[\\\"unknown\\\"]"));
        assertFalse(verifier.verify(manifest).clean());

        fixture.write("options.txt", TestPackFixture.OPTIONS_TEXT);
        fixture.write("config/iris.properties", "allowUnknownShaders=true\nshaderPack=\n");
        assertFalse(verifier.verify(manifest).clean());

        fixture.write("config/iris.properties", TestPackFixture.IRIS_TEXT);
        fixture.write("config/controlify.json", "{\"global\":{\"reach_around\":\"ON\"}}\n");
        assertFalse(verifier.verify(manifest).clean());
    }

    @Test
    void rejectsAChangedCanonicalSeedTemplate() throws Exception {
        fixture.write(".nbidal18/defaults/options.txt", TestPackFixture.OPTIONS_TEXT + "changed:true\n");
        assertFalse(verifier.verify(manifest).clean());
    }
}
