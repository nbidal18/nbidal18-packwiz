# nbidal18 v4.1.3-packwiz

This public repository is the complete GitHub Pages update channel for the updater-enabled Prism edition of nbidal18 4.1.3-packwiz. Its Java pre-launch updater works through Prism's selected runtime on Windows, macOS, and Linux.

Player page: <https://nbidal18.github.io/nbidal18-packwiz/>

Packwiz endpoint: <https://nbidal18.github.io/nbidal18-packwiz/pack.toml>

## Behaviour

- The first Play downloads the complete managed client from this repository.
- The setup ZIP keeps the release version in its filename, while the imported Prism instance and folder use the stable name `nbidal18-client` so later updates do not leave an old version in the launcher name.
- Later launches check for a release change, update changed files, and make `mods`, `config`, `datapacks`, `resourcepacks`, and `shaderpacks` match the published source.
- Unknown files in those loadable roots are moved to the recoverable `.nbidal18-packwiz/removed-local-files` folder before Minecraft starts.
- Fancy Crops 1.3 and Nature X 12.2 are installed and enabled by default. Fancy Crops has priority over Nature X where both define crop visuals, and the client includes Nature X's required Polytone support.
- Gameplay and compatibility configs remain managed. Auto HUD, personal Voice Chat state, Iris shader selection, Sodium preferences, mod keybinds, and Controlify controller preferences are installed with defaults when available and then preserved.
- Only the supplied Complementary and MakeUp shader ZIPs are accepted (or shaders off). Their normal quality settings are preserved, while Complementary's `GLOWING_ORE_MASTER` field is selectively forced to `0` online and during offline fallback.
- `options.txt`, `options.amecsapi.txt`, and `servers.dat` are supplied by the thin Prism ZIP and then remain player-owned.
- If GitHub is unavailable, an instance that still matches its last successful manifest may start. A new or incomplete installation remains blocked until it can be repaired.
- Better Compatibility Checker 21.1.8 gives the Packwiz client identity `v4.1.3-packwiz`. The server now requires that exact BCC identity and `require-helper=true`, so older clients and clients without a valid helper attestation are rejected.
- The v4.1.3 client verifies the last successful manifest during multiplayer login and monitors protected files while connected. A confirmed change disconnects the client and remains sticky until Minecraft is restarted.
- The runtime helper uses only the already-installed local manifest and never contacts GitHub. The existing pre-launch updater remains responsible for repair and recoverable cleanup.
- Jobs+ blocks new job additions beyond one and awards fractional XP at quarter speed. Existing selections, levels, XP, power-ups, and Jobs coins are preserved; players already holding multiple jobs keep them until they remove extras. Jobs coins are separate from Numismatic Overhaul's bronze, silver, and gold currency. XP action-bar spam and level-up chat are disabled; a level-up instead appears once as a normal advancement notification rendered by Advancement Plaques.

This is client-side tamper deterrence, not proof against a deliberately patched or spoofed client. The server-side login gate and BCC version check are now enforced.

## Release workflow

1. Update the organized release source and bump the Packwiz/BCC version together.
2. Run `BUILD-UPDATE-SITE.bat`.
3. Review and test the generated `site/` and Prism ZIP.
4. Commit and push `main`.
5. Wait for the Pages workflow and verify the public endpoint.
6. Keep `require-helper=true` and server BCC set to `v4.1.3-packwiz`; fully restart the server after changing either server policy.

The hosted archives are direct files in this Git repository. The Packwiz index contains no Modrinth or CurseForge download metadata.
