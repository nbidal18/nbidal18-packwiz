# nbidal18 changelog

Every published release of the nbidal18 modpack, newest first.

An entry is appended **only when something is actually published to GitHub** — that is, when
`main` is pushed and the update channel changes. Local builds, experiments, and work that was
built and tested but never released do not appear here. If it never reached a player, it is
not a release.

## How to read this

- **Digest** — the manifest digest, shown as the first 16 characters. This is the SHA-256 of
  `site/sync-manifest.json` and it identifies exactly which set of files a client received.
  The live server only lets a client connect if its digest is the server's `expected-`
  digest or one of the `accepted-` ones, so this column is what you match against
  `config/nbidal18-integrity.properties` when diagnosing a rejected login. The full 64
  characters live in that file.
- **Files / Mods** — managed file count and mod JAR count in the published index.
- Rows sharing a digest published changed *tooling* (updater, scripts, workflow) without
  changing any managed file, so no client had to re-download anything.
- Unless stated otherwise, players update by closing Minecraft and clicking **Play**. No
  re-import, no manual download.

## Adding a new entry

Write it after the build and before the commit, so it ships in the same commit it describes.
Record:

1. Date, pack version, commit, and the new digest — plus the digest it replaced.
2. What changed, in terms a player would recognise, then anything maintainer-facing.
3. Whether the live server policy was deployed, and whether the server needed a restart.
4. Whether players must do anything beyond clicking **Play**. Say so loudly if they must.
5. Anything retired or removed, so a later "where did that go?" has an answer.

---

## v4.2.1-packwiz

Current release. Live digest `5745945329aeb210…`. 620 managed files, 244 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-18 | `5be18a7` | `5745945329aeb210` | 620 | 244 | **First release under one-version-per-publish.** Fixes the HUD showing things it should not. Auto HUD's screen-wide reveal ignores each component's own policy, so breaking a block revealed the armour bar, the experience bar and the mount jump bar along with the hotbar. It now reveals the hotbar group instead of the whole HUD, and those three carry an explicit never-show guard. Saddle health joined the group, so it appears with the hotbar rather than alone. Temperature stopped pinning the HUD open: the overlay revealed the hearts on every tick any temperature effect was active, so standing somewhere cold held the whole group on screen indefinitely — it now reveals only when the reading moves by at least half a heart. The server MOTD advertised `v4.1.3` for the whole of 4.2.0 and now tracks the release, checked by the build. Maintainer-facing: the pack version was written by hand in about twenty-five places across eleven scripts, which is how the 4.1.3 cut shipped a client whose integrity helper rejected its own manifest; it now lives only in `PACK-VERSION.txt` and the build fails if any script spells it out again. The published setup archive lost its version suffix and is simply `nbidal18-client.zip`, so the download link no longer changes each release. `Test-ConfigStability.ps1` now compares an instance against the manifest it actually installed rather than the newest build, which would otherwise have reported drift at every version cut. Client tweaks 1.3.6 to 1.3.7. |

### Server deployment

Required a stopped server: the integrity helper JAR carries the pack version, and `server.properties`
is not hot-reloadable. Deployed the integrity policy, the helper JAR, `bcc-common.toml` and the MOTD
line of `server.properties` — only that one line of sixty-four, leaving ports, whitelist, world name
and every provider setting untouched. Previous copies are backed up under
`Z:\.nbidal18-deploy-backups\2026-08-18-v4.2.1\`.

### A note on 4.2.0

v4.2.0 was published five times: the original cut and four fixes, all reusing the same version.
That is why its section below has several rows sharing one heading. From v4.2.1 onward a version
number is published once and never reused, so a post-release fix is a version bump.

## v4.2.0-packwiz

Superseded by v4.2.1. Final digest `a5d5229243d6b922…`. 620 managed files, 244 mods.

The first release since 4.1.3 to add gameplay content, and the version identity moves with it.
Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-18 | `8994501` | `a5d5229243d6b922` | 620 | 244 | **Fixes two things v4.2.0 got wrong in the interface.** The armour bar is configured to stay hidden, but enabling the place/break HUD reveals made it appear alongside the hotbar every time a block was broken. Auto HUD's `Disabled` policy only means "do not reveal when your own value changes"; the screen-wide triggers call `revealAll()`, which reveals every component whatever its policy. A component set to `Disabled` is now never revealed by any trigger, so the config reads the way it behaves. Second, the accessory popup by the offhand slot opened over the player model's feet instead of the offhand, and the row looked wrong. Trinkets keeps one anchor point per group and uses it both to paint the popup backing and as the cell that opens it on hover, so 4.2.0's attempt to widen the painted area by shifting that anchor left also dragged the hover target off the offhand slot. The anchor is back where Trinkets puts it and the four accessory slots moved instead, laid out to the right of the offhand as offhand, ring, ring, hand, hand, all inside the painted area and all with their grey backing. Maintainer-facing: two hardcoded client-tweaks version assertions now derive from the mod's `gradle.properties`, having broken the build at every previous version bump. Client tweaks 1.3.5 to 1.3.6. |
| 2026-08-18 | `43928a1` | `e188263fe73463a8` | 620 | 244 | **Hotfix: every player was locked out at login again, this time by Nullscape.** Cristel Lib creates `config/cristellib/<mod>/` for every structure mod while the game starts, so adding Nullscape produced two config files that were never in the manifest. `config/` was strictly exact-match, so they were reported as intruders — and the loop could not be broken: the pre-launch updater deleted them, the game recreated them during mod init, and login was refused again. "Close and reopen your game" could never clear it. Those two files are now published, and unmanaged files under `config/` are tolerated instead of refusing the login. `mods`, `datapacks`, `resourcepacks` and `shaderpacks` stay strictly exact-match — they are the only roots Minecraft loads code or content from — and every managed config file is still hash-checked, so no tamper protection was given up. Maintainer-facing: all 263 published config files now carry an explicit classification in `scripts/config-classification.json` (133 gameplay, 122 support, 8 player-owned), and the build refuses to run while any is unclassified, so adding a mod forces a deliberate decision instead of silently inheriting enforcement. Support-class files — libraries, performance, rendering, UI, input, diagnostics — are restored by the updater but no longer enforced at login, since they are not in-game content. Gameplay config remains fully enforced, including the 54 rules covering files their own mod rewrites at startup: measured against a played instance those rewrites are byte-identical, so enforcing them costs nothing. New `scripts/Test-ConfigStability.ps1` measures this against a real instance and fails the release if an enforced config no longer round-trips. |
| 2026-08-18 | `2afa521` | `e9744a20519aa5ac` | 618 | 244 | **Hotfix: every player was locked out at login.** The integrity helper hardcodes the pack version it will accept and still said `4.1.3-packwiz`, so after the version cut it refused to parse its own `last-successful-manifest.json` and the server rejected the attestation with "Modpack integrity change detected". Only the client parses that file, so no server restart was needed. `Build-IntegrityInfrastructure.ps1` now derives the expected version from the release folder and fails the build if the helper disagrees, so a future version cut cannot repeat this. |
| 2026-08-18 | `a056546` | `6b068efa6ce8b9ca` | 618 | 244 | Raised the updater's minimum accepted pack version from 4.1.3 to 4.2.0. It is a floor on what the updater will install from the channel, so once a client runs this build, publishing anything below 4.2.0 is refused rather than installed. Raise it with each release. |
| 2026-08-18 | `3e32af4` | `d324ed2f2302285d` | 618 | 244 | **Released v4.2.0-packwiz.** Nullscape reshapes the End, installed before any End chunk had generated so no terrain is lost; YUNG's Better End Island keeps the central island and dragon fight, and the two share no files. Resting within 3 blocks of a lit campfire restores health. 58 modded slab families can be crafted back into blocks, including dirt slabs — Frostiful's cut-ice slabs are deliberately excluded because their stonecutter path would have allowed a 4× duplication. Auto HUD reveals while placing and breaking blocks and shows vehicle health only while changing, reissued once to existing instances. Fixes a chisel integrity false positive that was kicking players, restores the missing grey backing behind the ring accessory slots, and stops Immersive Aircraft and Machinery forcing a camera perspective when boarding. Adds a temporary diagnostic guard for the intermittent stuck-attack fault. Credits Nullscape, Incendium, Structory and Structory: Towers under the Stardust Labs licence, which the pack had been omitting. |

### Server deployment

The `a5d52292` fix is client-only: it changes the client-tweaks mod and nothing the server loads, so only the integrity policy was deployed. The previous policy is backed up under ``Z:\.nbidal18-deploy-backups\2026-08-18-autohud-trinkets-fix\``.

The `e188263f` hotfix needed only the integrity policy, which the helper reloads per login. The
server happened to be stopped, so the server-side integrity helper JAR was brought up to date in
the same window; it had been lagging since the `e9744a20` build. Nothing else server-side changed,
and the previous policy and JAR are backed up under
`Z:\.nbidal18-deploy-backups\2026-08-18-config-classification\`.

The original v4.2.0 rollout required a stopped server: the Nullscape JAR, the
`nbidal18_campfire_rest` datapack, `config/slabstoblocks.json`, and the integrity policy all
changed server-side. Recipes and world generation are server-authoritative, so a client-only
rollout would desynchronise them.

## v4.1.3-packwiz

Superseded by v4.2.0. Final digest `1f4d3adc9a999c6be24decb586c2b27c25827d22012d8f4caf4dd2649960df1f`.

Started as the transition build that moved every client onto the Packwiz channel, then spent
the rest of its life on the Inmis backpack and container interface work, and finally on
build-system repairs. 612 managed files, 243 mods.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-18 12:29 | `fb30689` | `1f4d3adc9a999c6b` | 612 | 243 | Rebuilt `nbidal18-jei-hidden-default` from reconstructed source. It had shipped as a prebuilt binary with no source since v3.0.2. The JEI dependency became a minimum instead of an exact pin and the mixin became optional, so a JEI update no longer silently disables hidden-by-default. All seven first-party mods now build automatically. |
| 2026-08-18 11:57 | `01d0f2a` | `901bb7e75e56c8a7` | 612 | 243 | Renamed the maintainer tree `5. development` → `5. modpack source` and gave the three hand-compiled bridge mods real build scripts. Published change was the licence notice text, which names where retained source lives. |
| 2026-08-18 11:31 | `bd739e0` | `ff91e20cdb85d9d6` | 612 | 243 | Allowed Sodium's generated hardware fingerprint to stay player-owned instead of being flagged as tampering. |
| 2026-08-18 10:44 | `bc83931` | `24ff8ccd4df36e49` | 613 | 243 | Retired Colourful Containers and clarified documentation. One mod and four files removed. |
| 2026-08-18 10:18 | `10298c0` | `796ad2f7eb390057` | 617 | 244 | Hid the hover wash on opened container slots. |
| 2026-08-18 10:04 | `3c2b5ba` | `974a3039e055e7e8` | 617 | 244 | Matched generated slots to Colorful Containers. |
| 2026-08-18 09:50 | `7357d5e` | `36cb483eceb49556` | 617 | 244 | Added OLED support for immersive vehicle containers. |
| 2026-08-18 05:14 | `29f2e66` | `2bf05488157b9c1e` | 617 | 244 | Used exact Colorful Containers shadow bounds. |
| 2026-08-18 05:07 | `e89f536` | `584c78659f952e12` | 617 | 244 | Matched Inmis inventory shadow thickness. |
| 2026-08-18 05:00 | `1ccc343` | `9bf8166497be2c27` | 617 | 244 | Matched the Inmis inventory frame to Colorful Containers. |
| 2026-08-18 04:49 | `4d4e559` | `2abf416058871fa7` | 617 | 244 | Extended the Inventory label through the backpack left cap. |
| 2026-08-18 04:41 | `c21c6d8` | `53e708328ddacf89` | 617 | 244 | Combined Trinkets hand slots with the offhand popup. |
| 2026-08-18 04:29 | `21874de` | `fc0623a1100c2813` | 617 | 244 | Fixed dyed backpack rendering and separator corners. |
| 2026-08-18 04:16 | `0bf2a88` | `a1f294b8946b5a85` | 617 | 244 | Stabilised the Inmis config integrity hash. |
| 2026-08-18 04:10 | `9b43528` | `e2fb5dbeb51cd218` | 617 | 244 | Fixed backpack dyeing and inventory slot layout. |
| 2026-08-18 03:48 | `d647c4e` | `c5fcaf7de0b475a0` | 616 | 244 | Fixed OLED backpack and offhand slot layout. |
| 2026-08-18 03:30 | `ac29e6a` | `14f986bf4934b50a` | 616 | 244 | Aligned the Inmis UI with Colourful Containers. |
| 2026-08-18 03:19 | `ca8f6ca` | `94bbece58620d4c5` | 616 | 244 | Fixed the detached OLED inventory panel. |
| 2026-08-18 03:05 | `a0a3e52` | `7cdd1b8d62bcefcd` | 616 | 244 | Replaced container visuals and migrated existing clients. |
| 2026-08-18 02:22 | `7b3ecd1` | `56aa50990c92afda` | 615 | 244 | Normalised managed config hashes across platforms, so Windows, macOS, and Linux clients stopped disagreeing about the same file. |
| 2026-08-18 02:06 | `8800cde` | `81341dee44025be0` | 615 | 244 | Reported integrity paths on failure and exempted JEI runtime state. |
| 2026-08-18 01:48 | `87f64aa` | `129f7fa0cd780fc6` | 615 | 244 | Enforced managed configs and gated self-updates before launch. |
| 2026-08-18 00:55 | `94f330a` | `7a7fd3c4f792db81` | 601 | 244 | Fixed runtime integrity false positives. |
| 2026-08-18 00:32 | `e7ba682` | `9515a09d1ce3d751` | 601 | 244 | Used a stable `nbidal18-client` Prism name. Tooling only — no managed file changed. |
| 2026-08-18 00:27 | `6b59077` | `9515a09d1ce3d751` | 601 | 244 | Fixed Packwiz version migration and neutralised the instance name. Tooling only. |
| 2026-08-18 00:12 | `f60154a` | `9515a09d1ce3d751` | 601 | 244 | Enforced the v4.1.3 client integrity policy. Tooling only. |
| 2026-08-18 00:00 | `46c0eb2` | `9515a09d1ce3d751` | 601 | 244 | **Released v4.1.3-packwiz.** Transition build: three mods added, six files added. |

## v4.1.2-packwiz

The first release on the direct-file update channel, and the version that established
click-**Play** updating. 595 managed files, 241 mods.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-17 19:10 | `0a15551` | `b4ee3796606b4c38` | 595 | 241 | Added the Deep Ocean main menu panorama. |
| 2026-08-17 18:38 | `f61ba8c` | `413c52d4842328bf` | 595 | 241 | Reused the updater Java runtime on Prism. Tooling only. |
| 2026-08-17 18:32 | `2f1dde0` | `413c52d4842328bf` | 595 | 241 | Made the Prism updater cross-platform. Tooling only. |
| 2026-08-17 18:14 | `b9706e2` | `413c52d4842328bf` | 595 | 241 | Preserved player-specific client settings across updates. |
| 2026-08-17 18:01 | `88a83d0` | `285d6fcae5d650e6` | 595 | 241 | Bundled the Packwiz installer for reliable launch updates. |
| 2026-08-17 17:48 | `5918431` | `d1766397f5b114c4` | 595 | 241 | Retried the Pages deployment. Tooling only. |
| 2026-08-17 17:47 | `7cfc287` | `d1766397f5b114c4` | 595 | 241 | Kept the updater responsive during migration. Tooling only. |
| 2026-08-17 17:26 | `d547b82` | `d1766397f5b114c4` | 595 | 241 | **Published the 4.1.2-packwiz direct-file update channel.** First release carrying a manifest digest. |

## v3.x — before manifest pinning

These releases predate `sync-manifest.json`, so they have no manifest digest; integrity was
enforced differently. Descriptions are the original commit subjects — this section was
reconstructed from git history on 2026-08-18 and no richer record survives.

| Date | Commit | Version | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-12 21:55 | `afa02d6` | 3.2.8 | 500 | 219 | HUD mixin hotfix. |
| 2026-08-12 21:01 | `42b01e8` | 3.2.7 | 500 | 219 | HUD integration. Two mods removed. |
| 2026-08-12 14:46 | `8752121` | 3.2.6 | 502 | 221 | Relaunch hotfix. |
| 2026-08-12 14:06 | `bddd8d3` | 3.2.5 | 502 | 221 | Release. |
| 2026-08-12 09:43 | `ca95dbc` | 3.2.4 | 502 | 221 | Release. One mod removed. |
| 2026-08-11 22:31 | `997a379` | 3.2.3 | 505 | 222 | Hotfix. One mod removed. |
| 2026-08-11 16:55 | `37076b5` | 3.2.2 | 507 | 223 | Release. |
| 2026-08-11 08:41 | `e0866ad` | 3.2.1 | 507 | 223 | Integrity hotfix. |
| 2026-08-11 07:37 | `eb316e4` | 3.2.0 | 505 | 223 | Skin update. Two mods added. |
| 2026-08-11 06:53 | `a2001e3` | 3.1.1 | 503 | 221 | Fixed client integrity startup ordering. |
| 2026-08-11 06:22 | `e223ed0` | 3.1.1 | 503 | 221 | Used the Pages uploader with hidden-file support. |
| 2026-08-11 06:18 | `dba8a2d` | 3.1.1 | 503 | 221 | Deployed hidden strict updater files. |
| 2026-08-11 01:46 | `325a665` | 3.1.1 | 503 | 221 | **Released the strict v3.1.1 integrity channel.** |
| 2026-08-10 23:54 | `3e80a8a` | 3.1.0 | 487 | 221 | Fixed Prism 9.4 pre-launch serialization. |
| 2026-08-10 23:46 | `e577cf2` | 3.1.0 | 487 | 221 | Documented the live updater release. |
| 2026-08-10 23:41 | `014e480` | 3.1.0 | 487 | 221 | Used the configured GitHub Pages site. |
| 2026-08-10 23:37 | `0c680da` | 3.1.0 | 487 | 221 | Enabled GitHub Pages during deployment. |
| 2026-08-10 23:35 | `12f6e2c` | 3.1.0 | 487 | 221 | Configured the public Packwiz update URL. |
| 2026-08-10 20:54 | `820d49c` | 3.1.0 | 487 | 221 | **Prepared the nbidal18 3.1.0 Packwiz update site.** First commit in this repository. |

---

## Note on the accepted-digest list

`nbidal18-integrity.properties` carries more digests in `accepted-manifest-sha256` than there
are rows above. Every run of `BUILD-UPDATE-SITE.bat` demotes the previous expected digest into
that list, including runs that were never committed — so local rebuilds leave digests behind.
Six such digests exist as of 2026-08-18 with no corresponding release. They are harmless, but
a digest in the policy that is missing from this changelog was never published, and no client
ever held it.
