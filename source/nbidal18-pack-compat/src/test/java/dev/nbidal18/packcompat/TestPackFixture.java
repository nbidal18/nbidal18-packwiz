package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

final class TestPackFixture {
    static final String OPTIONS_TEXT = "resourcePacks:[\\\"vanilla\\\",\\\"file/test.zip\\\"]\n"
            + "incompatibleResourcePacks:[]\n"
            + "fov:0.5\n";
    static final String IRIS_TEXT = "allowUnknownShaders=false\nshaderPack=\nother=value\n";
    static final String CONTROLIFY_TEXT = "{\"global\":{\"reach_around\":\"OFF\",\"other\":true}}\n";

    final Path root;
    final Map<String, byte[]> managed = new LinkedHashMap<>();
    final List<String> extraRecords = new ArrayList<>();

    TestPackFixture(Path root) throws IOException {
        this.root = root;
        for (String directory : List.of(
                "mods", "resourcepacks", "shaderpacks", "datapacks", "config", "defaultconfigs",
                "CustomSkinLoader", "moonlight-global-datapacks", "villagerpacks",
                "server-resource-packs", ".nbidal18/defaults"
        )) {
            Files.createDirectories(resolve(directory));
        }

        addManaged("mods/exact.jar", "managed mod");
        addManaged("resourcepacks/exact.zip", "managed resource pack");
        addManaged("shaderpacks/ComplementaryUnbound_r5.8.1.zip", "managed shader one");
        addManaged("shaderpacks/MakeUp-UltraFast-9.4b.zip", "managed shader two");
        addManaged("datapacks/public.zip", "managed datapack");
        addManaged("config/general.toml", "managed launch config");
        addManaged("defaultconfigs/default.toml", "managed default config");
        addManaged("CustomSkinLoader/Plugins/nbidal18-closed.marker", "managed empty-directory marker");
        addManaged("CustomSkinLoader/ExtraList/nbidal18-closed.marker", "managed empty-directory marker");
        addManaged(".nbidal18/defaults/options.txt", OPTIONS_TEXT);
        addManaged(".nbidal18/defaults/iris.properties", IRIS_TEXT);

        write("options.txt", OPTIONS_TEXT);
        write("config/iris.properties", IRIS_TEXT);
        write("config/controlify.json", CONTROLIFY_TEXT);

        extraRecords.add("optional\t" + hash("authorized private") + "\tdatapacks/private.zip");
        extraRecords.add("personal\tshaderpacks/ComplementaryUnbound_r5.8.1.zip.txt");
        extraRecords.add("personal\tshaderpacks/MakeUp-UltraFast-9.4b.zip.txt");
        extraRecords.add("personal\tconfig/controlify.json");
        extraRecords.add("runtime\tCustomSkinLoader/CustomSkinLoader.json");
        extraRecords.add("runtime\tCustomSkinLoader/CustomSkinLoader.log");
        extraRecords.add("runtime\tCustomSkinLoader/CustomSkinAPIPlus-ClientID");
        extraRecords.add("runtime\tconfig/runtime.json");
        extraRecords.add("runtime-prefix\tCustomSkinLoader/Core");
        extraRecords.add("runtime-prefix\tCustomSkinLoader/LocalSkin");
        extraRecords.add("runtime-prefix\tCustomSkinLoader/ProfileCache");
        extraRecords.add("runtime-prefix\tCustomSkinLoader/caches");
        extraRecords.add("runtime-prefix\tconfig/runtime-cache");
        extraRecords.add("seed\t.nbidal18/defaults/options.txt\toptions.txt");
        extraRecords.add("seed\t.nbidal18/defaults/iris.properties\tconfig/iris.properties");
        extraRecords.add("regenerate-prefix\tshaderpacks/ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3");
    }

    StrictManifest writeManifest() throws IOException, IntegrityException {
        List<String> lines = new ArrayList<>();
        lines.add("nbidal18-strict-manifest\t1");
        for (String directory : List.of(
                "mods", "resourcepacks", "shaderpacks", "datapacks", "config", "defaultconfigs",
                "CustomSkinLoader", "moonlight-global-datapacks", "villagerpacks", "server-resource-packs"
        )) {
            lines.add("strict-dir\t" + directory);
        }
        for (Map.Entry<String, byte[]> entry : managed.entrySet()) {
            lines.add("managed\t" + IntegrityFiles.sha256(entry.getValue()) + "\t" + entry.getKey());
        }
        lines.addAll(extraRecords);
        Path path = root.resolve(StrictManifest.RELATIVE_PATH);
        Files.createDirectories(path.getParent());
        Files.writeString(path, String.join("\n", lines) + "\n", StandardCharsets.UTF_8);
        return StrictManifest.load(root);
    }

    void writeAttestation(StrictManifest manifest, Instant verifiedAt) throws IOException {
        Path path = root.resolve(IntegrityAttestation.RELATIVE_PATH);
        Files.createDirectories(path.getParent());
        Files.writeString(
                path,
                "nbidal18-integrity-attestation\t1\n"
                        + "manifest-sha256\t" + manifest.sha256() + "\n"
                        + "verified-at-utc\t" + verifiedAt + "\n",
                StandardCharsets.UTF_8
        );
    }

    void addManaged(String relative, String content) throws IOException {
        byte[] bytes = content.getBytes(StandardCharsets.UTF_8);
        managed.put(relative, bytes);
        write(relative, content);
    }

    void write(String relative, String content) throws IOException {
        Path path = resolve(relative);
        Files.createDirectories(path.getParent());
        Files.writeString(path, content, StandardCharsets.UTF_8);
    }

    Path resolve(String relative) {
        return root.resolve(relative.replace('/', java.io.File.separatorChar));
    }

    static String hash(String content) {
        return IntegrityFiles.sha256(content.getBytes(StandardCharsets.UTF_8));
    }
}
