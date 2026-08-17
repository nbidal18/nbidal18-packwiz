# nbidal18 v4.1.2-packwiz

This public repository is the complete GitHub Pages update channel for the updater-enabled Prism edition of nbidal18 4.1.2.

Player page: <https://nbidal18.github.io/nbidal18-packwiz/>

Packwiz endpoint: <https://nbidal18.github.io/nbidal18-packwiz/pack.toml>

## Behaviour

- The first Play downloads the complete managed client from this repository.
- Later launches check for a release change, update changed files, and make `mods`, `config`, `datapacks`, `resourcepacks`, and `shaderpacks` match the published source.
- Unknown files in those loadable roots are moved to the recoverable `.nbidal18-packwiz/removed-local-files` folder before Minecraft starts.
- Gameplay and compatibility configs remain managed. Auto HUD, personal Voice Chat state, Iris shader selection, Sodium preferences, mod keybinds, and Controlify controller preferences are installed with defaults when available and then preserved.
- `options.txt`, `options.amecsapi.txt`, and `servers.dat` are supplied by the thin Prism ZIP and then remain player-owned.
- If GitHub is unavailable, an instance that still matches its last successful manifest may start. A new or incomplete installation remains blocked until it can be repaired.
- Better Compatibility Checker 21.1.8 gives the Packwiz client identity `v4.1.2-packwiz`. During the migration, the prepared server config deliberately leaves its version empty so 4.1.1, 4.1.2, and 4.1.2-packwiz players can still connect.

There is no launch guard, runtime integrity monitor, attestation, quarantine-based anti-cheat, compatibility companion, or automatic relaunch system.

## Release workflow

1. Update the organized release source and bump the Packwiz/BCC version together.
2. Run `BUILD-UPDATE-SITE.bat`.
3. Review and test the generated `site/` and Prism ZIP.
4. Commit and push `main`.
5. Wait for the Pages workflow and verify the public endpoint.
6. When the migration window ends, set the server BCC version to the matching client identity and fully restart the server.

The hosted archives are direct files in this Git repository. The Packwiz index contains no Modrinth or CurseForge download metadata.
