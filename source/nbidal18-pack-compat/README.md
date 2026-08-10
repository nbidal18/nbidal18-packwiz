# nbidal18 Pack Compatibility Enforcer

This first-party Fabric companion enforces the nbidal18 login identity and a secondary runtime integrity deterrent. It depends on the official Better Compatibility Checker 21.1.8 JAR and reads that mod's already-loaded `bcc-common.toml` identity through its public `getBetterStatus()` method. It does not contain, shade, or modify Better Compatibility Checker classes or assets.

Protocol 2 adds the client's strict-manifest SHA-256 and clean/dirty status to the existing login response. The server requires that digest to match `config/nbidal18-pack-compat.properties`:

```properties
expected-manifest-sha256=<64 lowercase hexadecimal characters>
```

The generated config is deliberately external to the JAR, so each release can update the expected digest without rebuilding this mod. A protocol-2 dedicated server rejects missing/malformed policy config, legacy clients, dirty clients, and digest mismatches. The login-query initializer is deliberately disabled in Fabric's client environment, so an integrated singleplayer server does not apply the dedicated-server gate. During the rollout, a 1.1 client still answers a legacy protocol-1 server's request with the old identity-only response; a 1.1 dedicated server never accepts protocol 1.

On the client, initialization requires a valid `.nbidal18/strict-manifest.tsv`, a matching successful `.nbidal18/integrity-attestation.tsv` no more than 15 minutes old, an independent exact set/type/hash pass over every loadable managed root, and the narrow resource-pack, Iris, and Controlify security settings. This deliberate second process-local hash pass closes the guard-to-game-JVM replacement window. General config files are attested only at pre-launch because trusted mods rewrite them during startup.

The client also hash-captures Fabric's `.fabric/processedMods` and `.fabric/remappedJars` generated-code caches and keeps their exact file, directory, type, size, metadata, and content baseline immutable. `moonlight-global-datapacks`, `villagerpacks`, and `server-resource-packs` must remain existing, completely empty directories. Moonlight may regenerate `dynamic-resource-pack-cache` during the initial resource reload, but protocol-2 login remains dirty/pending until `CLIENT_STARTED` synchronously captures the completed tree, verifies its deterministic aggregate against the reviewed release pin, and locks it. Missing, incomplete, or mismatched content fails closed. The root `hash.txt` fingerprint is excluded from only the deterministic aggregate because it varies with the companion version and is not mounted payload; it remains included in the per-process immutable baseline.

Any watcher event in an ordinary loadable strict root is a sticky immediate failure; only explicitly declared settings/runtime paths and generated-root writes before the `CLIENT_STARTED` finalization boundary are exempt. A metadata scan fills watcher gaps every 15 seconds, and a full hash scan runs every five minutes. Security seed templates are re-hashed during each targeted settings scan. The declared Euphoria shader tree is optional: if it exists when initial resource loading finishes, synchronous finalization requires its separately reviewed deterministic pin and then makes it immutable. If it is absent at that boundary, creating it later is a sticky failure and requires a clean relaunch. Every create, modify, or delete event in either generated root after finalization fails immediately; deleting or restoring transient content cannot return the process to clean. Failures disconnect the local client with a repair instruction; nothing is deleted or quarantined in game.

Generated-tree pins use UTF-8/LF records sorted by ordinal root-relative portable path: `D<TAB>path` for each descendant directory and `F<TAB>lowercase-file-sha256<TAB>path` for each file. The aggregate is SHA-256 of those records with a trailing LF per record. The reviewed Euphoria pin is `85d76c113189ad1792981aba9ae65aea145d7064525f1975fd70dc95ed14e313`; the dynamic resource-cache pin is `f367d4554b75cf037acb745d4e03dc8982215cff28f7e2db77dc7c91c6bc9cc0` after the stated `hash.txt` exclusion.

This is defense in depth, not remote attestation. A user who modifies the companion itself can forge client-reported state. Server protocol enforcement, exact expected digests, the separate pre-launch guard, and runtime monitoring raise the effort required but do not turn a user-controlled client into a trusted machine.

## Reproducible build

The checked-in Gradle wrapper pins Gradle 9.2.1. Fabric Loom, Minecraft, Fabric Loader, Fabric API, Better Compatibility Checker, and JUnit versions are pinned. Archive timestamps are disabled and entry order is deterministic.

```powershell
.\gradlew.bat clean test remapJar --no-daemon
Get-FileHash .\build\libs\nbidal18-pack-compat-1.1.0+1.21.1.jar -Algorithm SHA256
```

The Better Compatibility Checker dependency is resolved from Modrinth's Maven endpoint for compilation only; it is not bundled in the output.
