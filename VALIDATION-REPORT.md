# nbidal18 v3.1.0 Packwiz validation report

- Result: PASS
- Started: 2026-08-10 23:43:28 +02:00
- Completed: 2026-08-10 23:43:47 +02:00
- Packwiz site files: 491
- Exact Modrinth-managed archives: 225 (210 mods, 12 resource packs, 1 datapack, 2 shader packs)
- Reviewed internal-hosted archives: 15 (11 mods, 2 resource packs, 2 datapacks, 0 shader packs)
- Hosted datapack allowlist entries: 2
- Migration-only external files in the public manifest: 0

Validated:

- Packwiz refresh is reproducible and the checked-in manifest is current.
- Still Life, raw shader archives/sidecars, Iris state, VinURL helpers, player voice settings, Chat Heads aliases, and generated client fingerprints/warnings are absent from the public index.
- The strict thin migration ZIP contains only Prism metadata/icon and the updater bootstrap; it contains no Packwiz-managed payload, VinURL data, Still Life, shaders, or player state.
- The first updater run cold-installs and hash-verifies every managed payload, including the two supplied shaders from their exact official Modrinth files, before recording state.
- A second unchanged launch is a byte-for-byte no-op and does not request index.toml.
- A later release adds and removes JAR-named managed-file canaries in mods/ and overwrites a managed config correctly.
- The changed release reports exactly the two expected downloaded payloads and the one expected managed deletion.
- A deliberately unavailable payload produces a clear nonzero failure, retains the previous Packwiz manifest, and is repaired by the next successful release.
- Saves, screenshots, managed official and player-added shader files, shader sidecars, Iris selection, voice settings, separately installed Still Life, generated VinURL files, JEI world state, and unknown local mods survive updates unchanged.

External release gates are outside this isolated behavior report. `Build-Release.ps1` separately requires the anonymous HTTPS `pack.toml` and `index.toml` to match before it produces the final ZIP. Reaching the Minecraft menu, confirming that a failed pre-launch command blocks Minecraft, and production multiplayer compatibility remain manual checks.

Known limitation: Packwiz is not transaction-wide atomic. In the deliberate failure test, an available managed config was written before a later payload returned 404, although player-controlled files and the previous manifest remained intact. The next successful pre-launch run repaired the managed release. Final Prism testing must confirm a nonzero pre-launch result blocks Minecraft from starting.
