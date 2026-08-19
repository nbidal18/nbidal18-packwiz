# Third-party notices

The v4.2.0 Packwiz release distributes the reviewed third-party client files through its managed update channel. Project links and retained attributions for notable components follow.

## Fancy Crops and Enhanced Grass

The byte-exact `(Bee's) Fancy Crops` 1.3 archive from Modrinth project/version `UGEVQ6t9` / `ZJEBZjg6` is bundled and enabled. Project: <https://modrinth.com/resourcepack/fancy-crops>. The project declares All Rights Reserved.

The byte-exact Enhanced Grass V1.4 archive from Modrinth project/version `alsKcwM3` / `y5tAorFa` is bundled and enabled. It changes only short/tall grass blockstates and models. Project: <https://modrinth.com/resourcepack/enhanced-grass>. The project declares All Rights Reserved.

## Deep Ocean Panorama

The exact panorama image assets from Deep Ocean Panorama 1.0 (Modrinth project/version `5kprjmWo` / `jJgxY4Ke`) are incorporated into the already-enabled `No Atlas Player Markers.zip` nbidal18 override pack so existing updater installations receive and activate the new title-screen background without replacing player-owned `options.txt`. Project: <https://modrinth.com/resourcepack/deep-ocean-panorama>. The upstream project declares All Rights Reserved.

## Skin Overrides

The byte-exact `skin_overrides-2.6.0+1.21.1.jar` from Modrinth project/version `GON0Fdk5` / `Z99ddIuX` is bundled on both client and server so its multiplayer skin-update receiver is available. Project/source: <https://modrinth.com/mod/skin-overrides> and <https://codeberg.org/rose_bush/skin-overrides>.

## Player Emotes

The byte-exact `playeremotes-fabric-1.21.1-0.1.0.jar` from Modrinth project/version `TfUCUpDy` / `t1bvALQN` is bundled as a standalone dependency. Project: <https://modrinth.com/mod/player-emotes>. The project license text is retained at `licenses/Player-Emotes-Apache-2.0.txt`.

`playeremotes-with-fixes-0.1.0+patch-1.3.0+1.21.1.jar` is a separate nbidal18 compatibility component and contains no Player Emotes JAR.

## More Villagers / Numismatic compatibility

`nbidal18-morevillagers-numismatic-bridge-1.0.0+1.21.1.jar` is a source-retained nbidal18 compatibility component. It converts More Villagers' late-registered emerald offers to Numismatic Overhaul currency at 125 coin value per emerald. Its MIT license is retained at `licenses/MoreVillagers-Numismatic-Bridge-MIT.txt`, and complete source is retained under `5. modpack source/custom mods/nbidal18-morevillagers-numismatic-bridge` in the organized release folder.

`nbidal18-playeremotes-fa-bridge-1.2.1+1.21.1.jar` is a source-retained nbidal18 client compatibility component. It coordinates Player Emotes and Carry On with EMF/Fresh Animations so emotes and Carry On's raised-arm pose are not overwritten, and it pauses custom animation only for reconstructed carried-entity UUIDs to prevent their jitter. Its MIT license is retained at `licenses/PlayerEmotes-FA-CarryOn-Bridge-MIT.txt`, and its complete source is retained under `5. modpack source/custom mods/nbidal18-playeremotes-fa-bridge` in the organized release folder.

`nbidal18-grave-currency-1.0.0+1.21.1.jar` is a source-retained nbidal18 compatibility component. It stores a player's Numismatic Overhaul purse in their gravestone on death and returns it when the grave is collected, so banked money and carried coins behave the same way; without it the purse is the only thing death leaves untouched. Its MIT license is retained at `licenses/Grave-Currency-MIT.txt`, and complete source is retained under `5. modpack source/custom mods/nbidal18-grave-currency` in the organized release folder.

`nbidal18-held-heat-1.0.0+1.21.1.jar` is a source-retained nbidal18 compatibility component. Frostiful warms an entity from the block light at its feet, so a placed lantern warms whoever stands beside it while a carried one does nothing — the pack's dynamic lighting is client-side and never changes the light the server reads. This adds the missing half through Thermoo's temperature event, reading Frostiful's own configuration rather than restating its numbers. Its MIT license is retained at `licenses/Held-Heat-MIT.txt`, and complete source is retained under `5. modpack source/custom mods/nbidal18-held-heat` in the organized release folder.

## Vanilla Refresh

The byte-exact `vanilla-refresh-1.4.26_1.21.jar` from Modrinth project/version `gWO6Zqey` / `kmDSUUKd` is bundled as a standalone dependency. Project: <https://modrinth.com/mod/vanilla-refresh>.

`vanilla-refresh-all-in-one-1.4.26+config-1.1.0+1.21.1.jar` is a separate nbidal18 configuration component and contains no Vanilla Refresh JAR.

## Bombs by Juix and Juix Resources

`nbidal18_bombs_by_juix_v1.1_power60.zip` is a modified distribution based on Bombs by Juix 1.1 from Modrinth project/version `4xpND0VK` / `D8mk5eLK`. It changes the Atomic Bomb's explosion power and displayed lore from 20 to 60; complete modified source and an in-pack modification notice are retained under `5. modpack source/reference/datapack source`. The unmodified upstream datapack is not bundled separately. The historically matching, byte-exact `Juix Resources [1.3] 1.18-1.21.10.zip` from `E8IgiHZK` / `P246CAqt` remains bundled and enabled. Projects: <https://modrinth.com/datapack/bombs-by-juix> and <https://modrinth.com/resourcepack/juix-resources>. Both projects declare CC0-1.0.

## Realistic Health

`nbidal18_realistic_health_v3.6_optimized` is a modified distribution based on Realistic Health v3.6 from Modrinth project/version `tVXpaKa8` / `4eO6dWtQ`. It retains the upstream gameplay content and attribution while incorporating nbidal18's optimized scheduled functions into the same datapack. The unmodified ZIP is not bundled separately.

## ServerCore

The byte-exact `servercore-fabric-1.5.19+1.21.1.jar` from Modrinth project/version `4WWQxlQP` / `GQ2a51Rl` is bundled on both client and server. Project/source: <https://modrinth.com/mod/servercore> and <https://github.com/Wesley1808/ServerCore>. License: MIT.

## Noisium Forked

The byte-exact `noisium-fabric-2.7.0+mc1.21-1.21.1.jar` from Modrinth project/version `hasdd01q` / `bQdp8Lez` is bundled on both client and server. Its internal mod identity remains `noisium`. Project/source: <https://modrinth.com/mod/noisiumforked> and <https://github.com/coredex-source/noisium-forked>. License: LGPL-3.0.

## Terralith, Tectonic, and Lithostitched

The byte-exact `Terralith_1.21.x_v2.6.2.jar` from Modrinth project/version `8oi3bsk5` / `eWDLFabb`, `tectonic-3.0.22-fabric-21.1.jar` from `lWDHr9jE` / `cXSQRWNy`, and `lithostitched-1.7.13-fabric-21.1.jar` from `XaDC71GB` / `JWtSqSeY` are bundled on both client and server. Projects/sources: <https://modrinth.com/mod/terralith>, <https://github.com/Stardust-Labs-MC/Terralith>, <https://modrinth.com/mod/tectonic>, <https://github.com/Apollounknowndev/tectonic>, <https://modrinth.com/mod/lithostitched>, and <https://github.com/Apollounknowndev/lithostitched>. The bundled mod metadata declares MIT licensing.

## Nullscape, Incendium, and Structory

The byte-exact `Nullscape_1.21.x_v1.2.14.jar` from Modrinth project/version `LPjGiSO4` / `3fv8O3xX`, `Incendium_1.21.x_v5.4.4.jar` from `ZVzW5oNS` / `7mVvV9Th`, `Structory_1.21.x_v1.3.14.jar` from `aKCwCJlY` / `MXU49bpN`, and `Structory_Towers_1.21.x_v1.0.15.jar` from `j3FONRYr` / `lefqbuOP` are bundled unmodified on both client and server. All four are created by Stardust Labs. Projects: <https://modrinth.com/mod/nullscape>, <https://modrinth.com/mod/incendium>, <https://modrinth.com/mod/structory>, and <https://modrinth.com/mod/structory-towers>; author site: <https://www.stardustlabs.net/>. The bundled mod metadata declares the Stardust Labs License, which permits inclusion in a publicly distributed modpack provided the mods are used whole and unmodified and Stardust Labs is credited with a link to each project. Terralith is also a Stardust Labs project but declares MIT and is covered above.

## Terrain Slabs

The byte-exact `terrain_slabs-fabric-3.1.2.jar` from Modrinth project/version `SJu6sklj` / `7uy3h3Wu` is bundled on both client and server. It supplies the pack's broad material-specific terrain-slab blocks and generation pass. Project: <https://modrinth.com/mod/terrain-slabs>. The bundled metadata declares CC0-1.0 licensing.

## ChoiceTheorem's Overhauled Village

The byte-exact `[Fabric]ctov-3.6.3.jar` from Modrinth project/version `fgmhI8kH` / `dqaObRbU` is bundled on both client and server. This update uses CTOV's Lithostitched 1.6+ village-injection implementation and is compatible with the bundled Lithostitched 1.7.13. Project/source: <https://modrinth.com/mod/ct-overhaul-village> and <https://github.com/ChoiceTheorem/ChoiceTheorem-s-overhauled-village>. License: CC BY-NC-ND 4.0.

## Vein Mining

The byte-exact `veinmining-fabric-5.0.0-beta+1.21.jar` from Modrinth project/version `bRAPbNyF` / `5pbJBcoH` is bundled on both client and server. Project/source: <https://modrinth.com/mod/vein-mining> and <https://github.com/illusivesoulworks/veinmining>. License: LGPL-3.0-or-later.

## Automobility

The byte-exact `automobility-0.5.0.h+1.21.1-fabric.jar` from Modrinth project/version `rqIsPf9F` / `vvzu2A6h` is bundled on both client and server. Project/source: <https://modrinth.com/mod/automobility> and <https://github.com/FoundationGames/Automobility>. License: MIT.

## Nature's Compass - nbidal18 Minimal Fork

`naturescompass-minimal-nbidal18-1.21.1-2.6.0-fabric+nbidal18.1.jar` is an adapted build based on the official Nature's Compass `fabric-1.21.1` source commit `0342b1900f6230b8ecba11253404fe584dcd2b3d` and upstream version 1.21.1-2.6.0. Upstream project/source: <https://modrinth.com/mod/natures-compass> and <https://github.com/MattCzyr/NaturesCompass>. The complete adapted source, build files, original attribution, and license are retained in `5. modpack source/custom mods/natures-compass-minimal`. License: CC BY-NC-SA 4.0.

## HT's TreeChop

The byte-exact HT's TreeChop 0.19.3a file from Modrinth project/version `gHoB7SHO` / `YK5sxWxT` is bundled. Its attribution is retained at `licenses/TreeChop-MIT.txt`.

## Bandages Plus+

`bandagesplus-configurable-fabric-1.2.0+1.21.1.jar` is a configurable rebuild whose original art assets and recipe data are by Xanthian. The upstream attribution is retained both inside the JAR and at `licenses/BandagePlus-Xanthian-MIT.txt`. Original project: <https://www.curseforge.com/minecraft/mc-mods/bandages-plus-fabric>.

## Advancement Plaques and Iceberg

The byte-exact `AdvancementPlaques-1.21.1-fabric-1.6.8.jar` from Modrinth project/version `9NM0dXub` / `g0SNjiMq` and its byte-exact `Iceberg-1.21.1-fabric-1.3.2.jar` dependency from `5faXoLqX` / `7ITFAyW8` are bundled on the client. Projects: <https://modrinth.com/mod/advancement-plaques> and <https://modrinth.com/mod/iceberg>. Their bundled metadata declares CC BY-NC-ND 4.0.

## What Are They Up To

The byte-exact `watut-fabric-1.21.0-1.2.7.jar` from Modrinth project/version `AtB5mHky` / `iHAQTK0N` is bundled on both client and server. Project/source: <https://modrinth.com/mod/what-are-they-up-to> and <https://github.com/Corosauce/WATUT>. The project declares All Rights Reserved. The pack changes configuration only: simple activity indicators remain, while detailed GUI imagery and item-transfer contents are disabled.

## Jobs+

The byte-exact Jobs+ 9.0.0 (`hxGLlCnq` / `uMx9l222`) is bundled with UI Lib 9.0.0 (`AOEDs9Al` / `54ffhTnM`), YAML Config 9.0.0 (`L1FFB418` / `ZkxIJR6Z`), Arc Lib 9.0.0 (`H3eKhxi7` / `dophvkyy`), and Item Restrictions 9.0.0 (`rU60qFq2` / `2UCGjLwS`). Projects: <https://modrinth.com/mod/jobsplus>, <https://modrinth.com/mod/ui-lib>, <https://modrinth.com/mod/yaml-config>, <https://modrinth.com/mod/arc>, and <https://modrinth.com/mod/item-restrictions>. These projects declare Apache-2.0. Knot is deliberately not bundled because Jobs+ does not declare it as a loader dependency and Knot 9.1.0 failed Minecraft 1.21.1 dedicated startup.

## Bountiful and Kambrik

The byte-exact Bountiful 8.0.0-beta.2 (`BpwWFOVM` / `LFm1BWOE`) and Kambrik 8.0.0-beta.2 (`zfbCkvdZ` / `eMIEIbFZ`) are bundled on both sides. Projects: <https://modrinth.com/mod/bountiful> and <https://modrinth.com/mod/kambrik>. Bountiful declares LGPL-3.0-only; Kambrik declares MPL-2.0.

## Sawmill and Moonlight

The byte-exact Sawmill 1.8.0 (`WRaRZdTd` / `1Z66lBRN`) is bundled on both sides. Its required Moonlight library is updated to the byte-exact 1.21.1-3.3.3 build (`twkfQtEc` / `hveZJByF`). Projects: <https://modrinth.com/mod/universal-sawmill> and <https://modrinth.com/mod/moonlight>. Sawmill declares All Rights Reserved; Moonlight declares LGPL with its additional dependency clause.

## Jewelry

The byte-exact Jewelry 2.3.3 (`sNJAIjUm` / `U02aRsgR`) is bundled with Spell Power Attributes 1.6.0 (`8ooWzSQP` / `IyVyrKj8`), Structure Pool API 1.2.1 (`LrYZi08Q` / `Y6aBoKEl`), and Ranged Weapon API 2.3.3 (`AqaIIO6D` / `j6w0ptJx`). Projects: <https://modrinth.com/mod/jewelry>, <https://modrinth.com/mod/spell-power>, <https://modrinth.com/mod/structure-pool-api>, and <https://modrinth.com/mod/ranged-weapon-api>. Jewelry declares All Rights Reserved, Spell Power Attributes declares LGPL-3.0-only, and both Fabric Extras APIs declare MIT.

## Gacha Addiction - Fabric Lootr edition

`gachaaddiction-fabric-1.1.4+fabric.1.21.1-nbidal18.4.jar` is an adapted Fabric build based on Gacha Addiction source commit `d6a74631b8bbdc289f65d1ce4cfd28772757f3bf` from <https://github.com/Wang-Xiao-Jing/GachaAddiction>. The adaptation retains the original slot-machine presentation, targets Lootr on Fabric 1.21.1, and changes first-open handling to one server-authoritative 20% roll per player/container with safe reward transfer. Complete adapted source is retained under `5. modpack source/custom mods/gacha-addiction-fabric`. License: LGPL-3.0-or-later; the license is bundled at `licenses/GachaAddiction-LGPL-3.0.txt`.

## Realistic Death Visuals

`realistic-death-visuals-1.0.2+mc1.21.1-nbidal18.2.jar` is an Apache-2.0 source reconstruction and Minecraft 1.21.1 backport of the official Fabric 1.21.11 release (`iCCdpXAR` / `r0Oxib4E`) from <https://modrinth.com/mod/realistic-death-visuals>. Upstream did not publish a source repository URL. This revision holds the screen black for 10 seconds before respawn. The complete adapted source and pinned provenance are retained under `5. modpack source/custom mods/realistic-death-visuals-mc1211`; the license is bundled at `licenses/Realistic-Death-Visuals-Apache-2.0.txt`.
