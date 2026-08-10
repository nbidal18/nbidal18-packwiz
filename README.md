# nbidal18 incremental updater

This folder is the standalone public repository for the nbidal18 Packwiz update channel. The GitHub Pages workflow publishes only `site/`; never publish the complete organized modpack folder.

## Current state

- Pack: Minecraft 1.21.1, Fabric Loader 0.19.3, release 3.1.0.
- 210 of 221 mods use exact SHA-1-matched Modrinth metadata.
- The remaining 11 mods are pack-specific or reviewed compatibility components explicitly approved in `metadata/hosted-files.json`.
- Twelve resource packs use exact Modrinth metadata. The nbidal18 Atlas override and attributed Vanilla Tweaks bundle are hosted internally.
- Both supplied shader packs use exact official Modrinth metadata; no raw shader archive is hosted or placed in the migration ZIP.
- Realistic Health uses its exact official Modrinth archive plus a separate first-party tuning dispatcher. Two first-party datapack archives are explicitly approved for hosting; any new raw datapack archive fails closed until reviewed.
- Credits, third-party notices, and required license copies for Player Emotes, TreeChop, and Bandages Plus are managed with the client.
- Better Compatibility Checker is downloaded directly from its official all-rights-reserved Modrinth file; login enforcement is provided by the separate clean-room MIT `nbidal18-pack-compat` companion.
- Credits: Vanilla Tweaks: <https://vanillatweaks.net/>. Complementary Shaders - Unbound: <https://modrinth.com/shader/complementary-unbound>; any integration issue from its inclusion is the responsibility of the nbidal18 pack author. MakeUp - Ultra Fast: <https://modrinth.com/shader/makeup-ultra-fast-shaders> (LGPL-3.0-or-later).
- `VALIDATION-REPORT.md` records the passing local updater behavior test.

The player-facing manifest is live at <https://nbidal18.github.io/nbidal18-packwiz/pack.toml>. The guarded builder verified the live `pack.toml` and `index.toml`, reran the complete updater behavior test, and created `nbidal18-3.1.0-client.zip` outside this public repository with SHA-256 `B0AB6C3069A279CDECFE737F57A3AC24D5ACC21CF4222912AEE89FCADCEE85E5`.

## Files and scripts

- `site/` — complete static Packwiz site deployed by GitHub Pages.
- `metadata/modrinth-catalog.json` — exact hash-to-Modrinth resolution cache.
- `metadata/METADATA-REPORT.csv` — management source and hashes for every downloadable archive.
- `metadata/hosted-files.json` — explicit raw-hosting allowlist; new unmatched mods fail closed.
- `source/nbidal18-pack-compat/` — complete reproducible source for the first-party login enforcement companion.
- `TOOL-PROVENANCE.md` — verified sources and SHA-256 hashes for the local Packwiz tools.
- `BUILD-UPDATE-SITE.bat` — refresh Modrinth matches and regenerate `site/` from the canonical organized pack.
- `TEST-UPDATE-SITE.bat` — isolated A/B updater test; it never touches a live Prism instance.
- `SET-UPDATE-URL.bat` — validate and save the final anonymous HTTPS `pack.toml` URL.
- `BUILD-FINAL-MIGRATION-ZIP.bat` — verify the deployed site and create the final player ZIP.

## Managed files

Packwiz owns mods, pack configs, default configs, datapacks, resource packs, the two supplied shader archives, options, Amecs modifiers, credits, and `servers.dat`. A managed local edit is overwritten by the next release, and a file removed from the index is removed from the client.

These remain player-controlled and are deliberately absent from the public index:

- saves, screenshots, logs, crashes, caches, recordings, and other runtime state;
- player-added shader packs, shader sidecars, and per-shader settings (the two supplied archive filenames are managed);
- `config/iris.properties` and `config/iris-excluded.json`;
- Simple Voice Chat client/player volume and username state;
- Chat Heads aliases, Sodium's generated fingerprint, Presence Footsteps user/update state, and ETF warning state;
- generated `vinurl/` downloads and helper executables;
- the Patreon-only `datapacks/Still_Life-1.0-beta1.zip`;
- completely unknown local files.

The migration ZIP has a strict five-file allowlist: Prism metadata/icon and the updater bootstrap only. It contains no Packwiz-managed payload, VinURL data, Still Life, shaders, Iris state, or other player data. Packwiz downloads both supplied shaders from their official Modrinth files, and the player selects one in Iris. VinURL regenerates downloads and helper programs when needed. Still Life must be placed separately in `minecraft/datapacks` only by a user authorized by its creator; Packwiz then leaves that copy untouched.

The first click of **Play** on this thin instance downloads the complete managed client (roughly 294 MiB at the current pack size) before Minecraft starts. Later launches transfer only added or changed managed files.

## One-time GitHub setup

This folder is connected to the public <https://github.com/nbidal18/nbidal18-packwiz> repository, and GitHub Pages publishes only `site/`. The steps below document how that one-time setup is maintained or recreated; never use the release root as the public repository working tree.

1. Run `SET-UPDATE-URL.bat` with `https://OWNER.github.io/REPOSITORY/pack.toml` using the real names.
2. Initialize this folder on branch `main`, connect the remote, commit, and push.
3. In the repository's Pages settings, select **GitHub Actions** as the publishing source.
4. Wait for the included `Deploy Packwiz update site` workflow to finish.
5. Open the final `pack.toml` URL in a private browser window to confirm anonymous access.
6. Run `BUILD-FINAL-MIGRATION-ZIP.bat`. It refuses to build if the live `pack.toml` or `index.toml` differs from `site/`.

## Routine release workflow

1. Edit the canonical client under `3. modpack/client` and appearance defaults under `2. appearance`.
2. Update the matching server payload and bump `config/bcc-common.toml` when compatibility changes.
3. Run `BUILD-UPDATE-SITE.bat`.
4. Review `metadata/METADATA-REPORT.csv`; do not approve a new raw file without its redistribution basis.
5. Run `TEST-UPDATE-SITE.bat`.
6. Commit and push this updater repository, then wait for GitHub Pages deployment.
7. Upload matching files from `4. server/2. online-hosting` to GameHostBros and fully restart the server.

After the initial managed download, players continue using the same Prism instance. Packwiz checks for changed files whenever they click **Play**; players do not need Git, GitHub accounts, or a new ZIP for normal updates.

## Failure behavior

Packwiz returns a nonzero error when a payload cannot be downloaded. If a previous successful state exists, its manifest is retained; a brand-new thin import has no accepted manifest yet. Packwiz is not transaction-wide atomic, so either case may contain managed files written before a later payload fails. Treat every updater error as a blocked launch and retry after connectivity or hosting is restored; the next successful pre-launch run verifies and repairs the managed client. Real Prism failure handling is part of the final manual release check.

## Command-line equivalents

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Sync-Packwiz.ps1 -RefreshModrinth
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Packwiz.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Set-UpdateUrl.ps1 -UpdateUrl 'https://OWNER.github.io/REPOSITORY/pack.toml'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Packwiz format and updater behavior are documented at <https://packwiz.infra.link/>. GitHub Pages workflow setup is documented at <https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages>.
