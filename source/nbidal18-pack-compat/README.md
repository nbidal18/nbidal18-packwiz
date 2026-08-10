# nbidal18 Pack Compatibility Enforcer

This first-party Fabric companion performs the login-time pack identity check for nbidal18. It depends on the official Better Compatibility Checker 21.1.8 JAR and reads that mod's already-loaded `bcc-common.toml` identity through its public `getBetterStatus()` method. It does not contain, shade, or modify Better Compatibility Checker classes or assets.

The server sends a versioned login query on the first-party `nbidal18_pack_compat:version` channel. A client must understand the protocol and return the same pack name and version. Missing, malformed, unavailable, or mismatched responses are rejected before login completes.

## Reproducible build

The checked-in Gradle wrapper pins Gradle 9.2.1. Fabric Loom, Minecraft, Fabric Loader, Fabric API, and Better Compatibility Checker versions are pinned in the build files. Archive timestamps are disabled and entry order is deterministic.

```powershell
.\gradlew.bat clean remapJar
Get-FileHash .\build\libs\nbidal18-pack-compat-1.0.0+1.21.1.jar -Algorithm SHA256
```

The official Better Compatibility Checker dependency is resolved directly from Modrinth's Maven endpoint for compilation only; it is not bundled in the output.
