# nbidal18 v4.1.3-packwiz

This public repository publishes the files that the nbidal18 Prism instance downloads before Minecraft starts. Players normally use the player page or import ZIP; they do not need to clone this repository.

The Java pre-launch updater uses Prism's selected Java runtime and works on Windows, macOS, and Linux.

Player page: <https://nbidal18.github.io/nbidal18-packwiz/>

Packwiz endpoint: <https://nbidal18.github.io/nbidal18-packwiz/pack.toml>

## Repository map

| Path | Purpose | Edit by hand? |
| --- | --- | --- |
| `client` | Source for the stable updater/supervisor JARs. | Yes, when changing updater code. |
| `scripts` | Release builders and validation tests. | Yes, when changing the release process. |
| `templates` | Small template inputs used by the builders. | Yes. |
| `site` | Generated GitHub Pages download tree and Packwiz metadata. | No; rebuild it. |
| `BUILD-UPDATE-SITE.bat` | Runs the complete local build in the correct order. | Run it; normally do not edit it. |
| `UPDATE-URL.txt` | Published Packwiz endpoint. | Change only when moving the channel. |

The organized master client, server, and first-party source are in the sibling folder `nbidal18 v4.1.3-packwiz`. Build scripts read from that folder and write generated output here. In these docs, **manifest** means the official managed-file list, and **digest** means the single hash that identifies that list.

## How an update reaches a player

1. A maintainer changes the organized master files in the sibling release folder.
2. The build scripts compile first-party components and regenerate `site` plus the small Prism import ZIP.
3. Local tests install into a temporary instance and verify updating, repair, migration, and offline behavior.
4. The server accepts the new manifest digest during rollout.
5. Pushing this repository publishes the new files through GitHub Pages.
6. The player's next click on **Play** downloads the changes before Minecraft opens.

## Behaviour

- The first Play downloads the complete managed client from this repository.
- The organized setup archive is named `nbidal18-client.zip`, so Prism imports the instance with the stable name `nbidal18-client`.
- Every later Play checks the channel and updates all managed client content, including mods, configs, datapacks, resource packs, shaders, the integrity helper, Prism/Fabric metadata, and the updater/bootstrap JARs themselves. Re-importing the ZIP is never an update step.
- Prism starts a stable supervisor, not the replaceable update engine directly. If Packwiz downloads a newer staged engine or bootstrap, the supervisor activates it after the old process exits and reruns the update check. It returns success to Prism only when the newest engine confirms a complete release, so the Minecraft main menu cannot appear between updater phases.
- Unknown files in those loadable roots are moved to the recoverable `.nbidal18-packwiz/removed-local-files` folder before Minecraft starts.
- Fancy Crops 1.3 and Enhanced Grass V1.4 are installed and enabled by default. Enhanced Grass changes only short/tall grass models, so ores and other terrain remain untouched.
- Colourful Containers OLED, its first-party Inmis/vehicle container add-on, and the now-unused OptiGUI dependency are retired. Existing installations remove their archives and resource-pack option entries during the next update; vanilla and mod-provided container screens render normally.
- Gameplay and compatibility configs remain managed before launch and hash-enforced during multiplayer. Auto HUD, personal Voice Chat state, Iris shader selection, mod keybinds, controller state, base Sodium graphics/performance preferences, and narrowly identified support/cache files are runtime exceptions. Sodium's generated hardware fingerprint is never published. Sodium Extra's coordinate-display configuration remains enforced.
- Only the supplied Complementary and MakeUp shader ZIPs are accepted (or shaders off). Their normal quality settings are preserved, while Complementary's `GLOWING_ORE_MASTER` field is selectively forced to `0` online and during offline fallback.
- `options.txt`, `options.amecsapi.txt`, and `servers.dat` are supplied by the thin Prism ZIP and then remain player-owned. The updater has one narrow, idempotent `options.txt` migration that replaces retired nbidal18 resource-pack entries and enables their successors while preserving every unrelated player option and pack preference.
- If GitHub is unavailable, an instance that still matches its last successful manifest may start. A new or incomplete installation remains blocked until it can be repaired.
- Better Compatibility Checker 21.1.8 gives the Packwiz client identity `v4.1.3-packwiz`. The server now requires that exact BCC identity and `require-helper=true`, so older clients and clients without a valid helper attestation are rejected.
- The v4.1.3 client verifies managed artifacts from the last successful manifest during multiplayer login and monitors them while connected. Shipped config files are enforced except for the explicit runtime exception list. A confirmed protected-artifact change disconnects the client and remains sticky until Minecraft is restarted.
- Integrity disconnects list every detected path (up to the bounded protocol limit) and group them dynamically by top-level directory, making future false positives directly diagnosable on the connection screen.
- Managed text configs use an additional line-ending-normalized integrity hash. Windows CRLF and macOS/Linux LF serialization compare equally, while every actual setting, comment, ordering, and value remains enforced.
- The runtime helper uses only the already-installed local manifest and never contacts GitHub. The existing pre-launch updater remains responsible for repair and recoverable cleanup.
- Jobs+ blocks new job additions beyond one and awards fractional XP at quarter speed. Existing selections, levels, XP, power-ups, and Jobs coins are preserved; players already holding multiple jobs keep them until they remove extras. Jobs coins are separate from Numismatic Overhaul's bronze, silver, and gold currency. XP action-bar spam and level-up chat are disabled; a level-up instead appears once as a normal advancement notification rendered by Advancement Plaques.

This is client-side tamper deterrence, not proof against a deliberately patched or spoofed client. The server-side login gate and BCC version check are now enforced.

## Release workflow

Prerequisites: Java 21, PowerShell, Git, and the sibling organized release folder at the expected path. The server must be stopped for any helper JAR replacement.

1. Update the organized release source. For a new release identity, bump Packwiz and Better Compatibility Checker together.
2. Run `BUILD-UPDATE-SITE.bat` from this repository. Stop if any build step fails.
3. Run `scripts\Test-LocalSync.ps1` and review the generated `site`, Prism ZIP, server helper, and manifest policy.
4. Back up the server. Deploy the generated server helper and policy first, then fully restart if the helper JAR changed. During rollout, the policy accepts both the previous and current reviewed manifest digests.
5. Commit and push `main` to publish the client update.
6. Wait for the GitHub Pages workflow to succeed and verify both public links near the top of this README.
7. Confirm a clean client updates and connects. Keep `require-helper=true` and server BCC set to `v4.1.3-packwiz`.
8. Remove the previous accepted manifest digest only after healthy clients have updated.

Do not hand-edit `site` to prepare a release. Do not publish a client manifest before the server policy accepts it; otherwise updated clients can be locked out.

For a manifest-only false-positive hotfix after the reloading server helper is installed, copy the newly generated `nbidal18-integrity.properties` to the running server before publishing the client channel. The server reads it on the next login without a restart. Players only close and reopen the existing Prism instance; its pre-launch updater installs the fix automatically.

The hosted archives are direct files in this Git repository. The Packwiz index contains no Modrinth or CurseForge download metadata.
