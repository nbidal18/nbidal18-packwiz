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

## v4.3.1

Current release. Live digest `1d2d9c3baff562ed…`. 854 managed files, 252 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.
**Skill levels were reset for everyone by this release** — see below. Jobs, job levels, money,
gear and inventories are untouched.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-19 | `PENDING` | `1d2d9c3baff562ed` | 854 | 252 | **Hearts are vanilla again, and the Constitution skill is gone.** v4.3.0 started everyone at three hearts and had Constitution return the missing seven over twenty levels. It read well and played badly: because death wipes every skill, it took maximum health with it, so dying meant respawning at three hearts and walking back. Nothing in the skill table touches maximum health now — note that LevelZ lowers it to four hearts on its own, so removing the skill is what restores the full ten rather than merely undoing a pack value. **Everyone's skills were reset as part of this update, deliberately.** LevelZ requires skill ids to run 0..n-1 with no gaps and stores each player's levels against those ids, so removing Constitution renumbered the other eleven and any save written before the change would have read its levels against the wrong skills. A reset was the honest option; spent points were refunded. Skills are now Melee, Defense, Archery, Agility, Magic, Mining, Smithing, Farming, Cooking, Bartering and Luck. **The wiki button moved onto the pause-menu column.** It was floating in the bottom-left corner; it is now a knowledge-book icon beside the top row, in the same column where Field Guide's icon sits beside the bottom one. It anchors to vanilla's own button column rather than to the screen edge, so it lands correctly at any GUI scale, and it uses a rendered item rather than a shipped texture so there is no new asset to keep in step with a resource pack. Wiki 1.0.0 to 1.1.0. Maintainer-facing: `Test-LocalSync` derived first-party artifact names from each project's `gradle.properties` instead of listing them, after a routine version bump failed the suite for no reason. |

### Server deployment

Required a stopped server: the integrity helper JAR carries the pack version, `server.properties`
is not hot-reloadable, and the skill table is read at datapack load. A status ping refused the
connection immediately before the writes, which is the only proof accepted here.

Five files deployed and two retired advancements removed, verified by hash in a second pass. The
live server had drifted in roughly two dozen other configs while it ran — mods rewriting their
own settings — and none of it was touched. Backups under `Z:\.nbidal18-deploy-backups\2026-08-19-v4.3.1\`.

The stale-read problem recorded in v4.3.0 recurred and is now understood. It is not the live file
going stale: the mount served back a cached copy of what *this tooling* had written during the
previous deploy, while Minecraft had since rewritten `server.properties` on shutdown. The backup
hash check caught it both times. Read the file, verify the backup by hash, and redo it if it
disagrees — never assume a copy off this mount is current.

---

## v4.3.0

Superseded by v4.3.1. Live digest `ebed5418e2d932d7…`. 856 managed files, 252 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing. **Two things
will surprise people and both are intended:** everyone starts at three hearts and climbs back, and
all Jobs+ progress is gone with no migration.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-19 | `0e3d550` | `ebed5418e2d932d7` | 856 | 252 | **Jobs+ is gone, replaced by LevelZ and JobsAddon — and nobody's job progress carries over.** Everyone starts fresh, deliberately. You now hold up to two jobs at a time from eight (Lumberjack, Miner, Farmer, Warrior, Builder, Smith, Fisher, Brewer), each going to level 100; changing job takes two clicks and then locks for one real hour, and levelling one pays Numismatic coins straight into your purse rather than into a separate balance. **Twelve skills sit alongside them and gate nothing** — no item, block, recipe or mob is locked behind a level, so imported gear still works. **You start with three hearts.** Constitution gives back exactly the missing seven, landing on one full row and never more; gear can push past it, levelling cannot. You also start slower at mining, movement and luck, and earn those back the same way. **Death costs all of it**: every skill level, every unspent point, every job level, and the job itself. **Gear now rolls a tier when it is made** — a stat bonus written plainly on the item's name, with no rarity colours or borders anywhere. It cannot be rerolled: the anvil's reforge tab is gone, so if you want a different roll you craft the item again. Chests, mobs and traders roll too. **Temperature became a real choice.** Insulation now cuts both ways — whatever an armour piece is worth against cold it costs against heat, per piece, so a full set of leather is warm and bad in the sun, fur is the extreme of both, and metal is mild either way. Hats shade rather than insulate, so the best desert loadout is no body armour and a hat; the turtle helmet counts as a hat. Gold and netherite resist heat **only in the Nether**. A carried torch or lantern now works both ways too, where v4.2.8 let it only relieve cold: it will save you in a blizzard and cook you in a desert. Warming and cooling foods now do something. **Days are half as long**: an hour of daylight and an hour of night rather than two of each. **Mob farming in one spot stops paying** — twenty kills in the same chunk and they stop dropping until you move or open a chest; ordinary fighting never notices. **The pack now explains itself.** A new first-party wiki opens on **N** or from a button on the pause menu: eight sections covering health, skills, jobs, tiers, temperature, money and how to look things up, all readable from the first minute. It replaces the written book new players used to receive. Alongside it, Field Guide adds a scan-to-discover encyclopedia — every creature and plant has a named entry waiting, blank until you scan it yourself through a spyglass — and holding Ctrl over almost anything now describes what it does. **Two keybinds are set for you once**: J opens the skill screen and U opens the Field Guide, because their own defaults collide with the shader toggle and the backpack. Both stay rebindable. Maintainer-facing: the `-packwiz` suffix is retired from the version; `nbidal18-held-heat` is renamed and widened into `nbidal18-temperature`; `nbidal18-jobs-chat-suppressor` retires with Jobs+; new first-party `nbidal18-jobs-reset` and `nbidal18-wiki`; client tweaks 1.3.13 to 1.4.0 and the emotes bridge 1.2.1 to 1.3.0; the updater gained a declared row-level re-seeding mechanism for player-owned files and a one-time cleanup for files a retired mod left behind. |

### Server deployment

Required a stopped server: seven mods added, three removed, the integrity helper JAR carries the
pack version, and `server.properties` is not hot-reloadable. A status ping refused the connection
immediately before the writes and again immediately before the first one, which is the only proof
accepted here — the pack runs Server Pause, so an idle server writes no log lines for hours and
reading logs proves nothing.

Deployed as a file-level overlay of reviewed changes only: 237 files, verified by hash in a second
independent pass. The live server carries pre-existing drift in around two dozen other configs that
mods rewrite themselves; none of it was touched, because a folder sync would have silently
overwritten all of it. `server.properties` was edited one line at a time for the MOTD, leaving every
provider setting, port and world name exactly as the host had it. Backups under
`Z:\.nbidal18-deploy-backups\2026-08-19-v4.3.0\`.

Two mount problems worth recording, because both will recur. `Remove-Item` fails on this SFTP Cloud
Drive with "Incorrect function" and `[IO.File]::Delete` succeeds on the same path. And the mount
served a **stale read**: the first backup of `server.properties` came back holding a version four
hours older than the live file, and only failed its hash check by luck. The backup was redone with a
direct byte read and write, and every deployed file was then re-verified in a separate pass rather
than trusted from the copy operation.

---

## v4.2.8-packwiz

Superseded by v4.3.0. Final digest `1ee44d8a2e896b5d…`. 626 managed files, 246 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-19 | `27f4d2f` | `1ee44d8a2e896b5d` | 626 | 246 | **A torch or lantern in your hand now keeps you warm.** A placed one always did, but only by accident of how it works: Frostiful warms you from the *block light at your feet*, so standing beside a lantern is what warmed you, not carrying it. The pack's dynamic lighting is client-side and never changes the light the server reads, so carrying a light through a blizzard did nothing at all. A new first-party mod, `nbidal18-held-heat`, adds the missing half through Thermoo's temperature event. **It only ever relieves cold** — it does nothing in a warm biome and stops exactly at neutral, so carrying a light through the dark can never cook you. Strength comes from the item's own block light, so a lantern is worth more than a torch and a soul lantern half as much again, and it tops up only the difference over the light already around you: holding a lantern beside a bonfire is worth nothing extra. Torches, lanterns, jack o'lanterns and all forty-two of Macaw's lanterns and tiki torches count. Campfires deliberately do not — a campfire in your hand is not lit. **Atlas pins can have real names.** Antique Atlas never set a length on its label field, so it inherited the vanilla default of 32 characters and cut names off mid-word; it is now 128, and a long name wraps onto as many tooltip lines as it needs instead of running off the map. **Resting at a campfire is worth stopping for.** The healing effect lasted five seconds and was refreshed every second, so running past a fire was worth several free hearts. It heals at the same rate but now trails off after two seconds — the shortest that still heals at all, since Regeneration only heals on ticks where its remaining duration crosses a multiple of its interval, and a one-second effect would have refreshed forever and healed nothing. Client tweaks 1.3.12 to 1.3.13. |

### Server deployment

Required a stopped server: the integrity helper JAR carries the pack version, `server.properties` is
not hot-reloadable, and a new mod is only loaded at startup. A status ping refused the connection
immediately before the writes, which is the only proof accepted here — the pack runs Server Pause,
so an idle server writes no log lines for hours and reading logs proves nothing. Deployed the
integrity policy, the helper JAR, `bcc-common.toml`, the campfire datapack function, the new
`mods\nbidal18-held-heat-1.0.0+1.21.1.jar`, and the MOTD line of `server.properties` — that one file
was edited in place a line at a time rather than overwritten, so every provider setting, port and
world name was left exactly as the host had it. Every copied file was verified by hash against the
managed-host copy. Backups under `Z:\.nbidal18-deploy-backups\2026-08-19-v4.2.8-packwiz\`.

Two things were found by testing rather than by reading, and both are the reason the mod behaves as
it does. Applying warmth unconditionally drove the player up into Scorchful's heat, which made
carrying a light impossible — hence the cold-only guard. And reading a block's *default* state for
its light gives zero for Macaw's tiki torches, which carry an unlit variant and unlit pole segments,
so a tiki torch would silently have done nothing while a lantern worked; it now reads the brightest
state a block has, cached per block, and logs a warning if anything in the tag emits no light at all.

## v4.2.7-packwiz

Superseded by v4.2.8. Final digest `aee580fc61386d5f…`. 624 managed files, 245 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-19 | `8b32451` | `aee580fc61386d5f` | 624 | 245 | **Your money now goes in your grave.** It never did: Numismatic registers the purse with Cardinal Components' `ALWAYS_COPY` respawn strategy, so the balance quietly followed you through death untouched while the coins in your pockets went into the grave with everything else. Banked money and carried money behaved differently. A new first-party mod, `nbidal18-grave-currency`, hooks the Gravestones data-type API — the same mechanism Gravestones uses for Trinkets and experience — and moves the whole balance into the grave, returning it to your purse when you collect it, or dropping it as properly denominated coin stacks if the grave is broken instead. **This makes money losable, which it was not before:** a grave you never recover takes your balance with it. Any player can open any grave, so it can also be taken by someone else — that access setting is unchanged and can be made owner-only if wanted. **Jade now shows only what you are looking at.** Crop growth, furnace and campfire progress, baby-animal growth, harvest tool, item storage, breeding, horse stats, potion effects, enchantment power and the rest are all off; the block or mob name and the mod it came from are what remain. **Graves are blank.** Gravestones offers no setting for this — only the *format* of the death date, not whether it is carved — so the text is suppressed at the renderer. The stone, its decay stage and the optional head still render, and the grave still knows its owner internally, so access and the recovery commands are unaffected. **And both ring slots now sit inside the accessory panel's border.** Trinkets centres that panel on the off-hand rather than growing it rightwards, so the width has to satisfy both edges at once; it was computed as though the panel were one-sided, which enclosed the near ring and stranded the far one outside. Client tweaks 1.3.11 to 1.3.12. Maintainer-facing: `THIRD-PARTY-NOTICES.md` still credited the Player Emotes bridge as 1.2.0 when 4.2.4 shipped 1.2.1. |

### Server deployment

Required a stopped server: the integrity helper JAR carries the pack version, `server.properties` is
not hot-reloadable, and a new mod is only loaded at startup. The owner confirmed the shutdown and a
status ping refused the connection before and after every write. Deployed the integrity policy, the
helper JAR, `bcc-common.toml`, the MOTD line of `server.properties` — one line of sixty-four — and
the new `mods\nbidal18-grave-currency-1.0.0+1.21.1.jar`, which is what actually moves the purse into
the grave in multiplayer. The mod was new, so nothing was overwritten, and it was verified by hash
against the managed-host copy. Ports, whitelist, world name and every provider setting were left
untouched. Backups under `Z:\.nbidal18-deploy-backups\2026-08-19-v4.2.7-packwiz\`.

The grave currency mod reaches Numismatic by reflection rather than compiling against it: Loom
cannot remap Numismatic alongside Fabric API — it fails with "Unfixable conflicts" on
`ShopBlockEntity.getItems` — which is the same wall the More Villagers bridge hit and solved the same
way. It refuses to start rather than degrading if that reflection ever fails, because a currency
store that silently does nothing would send a player's balance to a grave that never recorded it.

## v4.2.6-packwiz

Superseded by v4.2.7. Final digest `d046b0fac40da0d8…`. 622 managed files, 244 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-19 | `02a8d86` | `d046b0fac40da0d8` | 622 | 244 | **Rings can be worn.** They never could. Jewelry ships 26 rings — copper through netherite plus ten unique ones — and tags every one of them for Trinkets' `hand/ring` and `offhand/ring` slots, but nothing in the pack ever gave the player those slots. The only datapack granting the player anything was Artifacts', which hands out hat, necklace, belt, both gloves and shoes and no ring. So the rings were craftable, lootable, tradeable and completely unequippable, and they are not trinkets in the decorative sense: they carry extra hearts, attack damage, ranged damage and spell power. A new datapack grants both ring slots, one per hand, so two rings can be worn at once as the mod intends. **This is a real power increase** — two sapphire rings is four extra hearts — and the values live in `config/jewelry/items_v8.json` if they need pulling back later. **Also removes the stray see-through cell** on the end of the accessory row, which was mine: the off-hand popup was hardcoded three cells wide, assuming two accessories to the right of the vanilla off-hand slot when the player had one, so Trinkets painted an empty cell with nothing behind it. The width is now counted from the slots actually present. With rings enabled the row reads `[ring][ring][off-hand][glove][glove]` — rings together on the left, gloves together on the right — and the two ring slots carry proper backings drawn from the vanilla inventory sheet, so they follow whichever resource pack is active. The popup still opens from the vanilla off-hand slot. Client tweaks 1.3.10 to 1.3.11. |

### Server deployment

Required a stopped server: the integrity helper JAR carries the pack version, `server.properties` is
not hot-reloadable, and a datapack is only read at startup. The owner confirmed the shutdown and a
status ping refused the connection before and after every write. Deployed the integrity policy, the
helper JAR, `bcc-common.toml`, the MOTD line of `server.properties` — one line of sixty-four — and
the new `datapacks\nbidal18_trinket_slots`, which is what actually grants the ring slots in
multiplayer. The datapack folder was new, so nothing was overwritten; both files were verified by
hash against the managed-host copy. Ports, whitelist, world name and every provider setting were
left untouched. Backups under `Z:\.nbidal18-deploy-backups\2026-08-19-v4.2.6-packwiz\`.

Note for any future release that touches slots: **granting a Trinkets slot is safe, removing one is
not.** New slots arrive empty, but taking a slot away drops or loses whatever was worn in it.

## v4.2.5-packwiz

Superseded by v4.2.6. Final digest `7e2d943c9a750e0f…`. 620 managed files, 244 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-18 | `a879626` | `7e2d943c9a750e0f` | 620 | 244 | **Fixes a crash on launch that made v4.2.3 and v4.2.4 unplayable.** The game stopped during startup with a mixin error naming `nbidal18-client-tweaks`, before the window ever opened, on every machine. The ring-slot backings added in 4.2.3 read the inventory's top-left corner through a `@Shadow` on `InventoryScreen`, but `leftPos` and `topPos` are declared one class up on `AbstractContainerScreen`. Mixin resolves an inherited *method* for an `@Inject` — which is why the neighbouring `render` injection has worked since 4.0 — but a shadowed *field* must be declared on the target class itself. It was not, so the mixin failed to apply, and a mixin that fails to apply takes the game down rather than switching itself off. The corner now comes from an accessor on the class that declares it. Nothing else changed: the accessory row, the ring backings and the Fresh Animations fix from 4.2.4 all behave as described. Client tweaks 1.3.9 to 1.3.10. Maintainer-facing, and the reason this shipped twice: no test started a client. `Test-LocalSync` syncs files and `Test-DedicatedServer` starts a server, so a client-only mixin was checked by neither, and nobody launched a client between the two releases. This fix was verified by launching a real client against a throwaway game directory and confirming every first-party mixin applied. |

### Server deployment

Required a stopped server: the integrity helper JAR carries the pack version and `server.properties`
is not hot-reloadable. The owner confirmed the shutdown and a status ping refused the connection
before and after every write. Deployed the integrity policy, the helper JAR, `bcc-common.toml` and
the MOTD line of `server.properties` — one line of sixty-four, leaving ports, whitelist, world name
and every provider setting untouched. Backups under
`Z:\.nbidal18-deploy-backups\2026-08-18-v4.2.5-packwiz\`.

The status-ping helper was corrected during this release. It read only the first 4 KB of the reply
and matched on keys that this server's long base64 favicon pushes past that window, so a running
server scored AMBIGUOUS rather than UP. Nothing was written — the deploy script proceeds only on an
explicit DOWN — but the one answer that tool must never produce by accident is a wrong one, so it
now reads the whole reply.

## v4.2.4-packwiz

Superseded by v4.2.5. Final digest `5bf5bfb4c70a2e23…`. 620 managed files, 244 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-18 | `c4e52dd` | `5bf5bfb4c70a2e23` | 620 | 244 | **Fresh Animations stops silently switching itself off, and boats get their rowing arms back.** A player whose animations had died could not fix it by any amount of resource-pack reordering, and only a full restart of Minecraft cleared it. The cause was ours. EMF pauses animations through a process-global set of player UUIDs that nothing ever empties — not even EMF's own reset — so whoever pauses a player owns resuming them for the rest of the session. Our Player Emotes / Carry On bridge paused on an emote or a carried block and resumed only when it *saw* the state flip back, which is exactly the moment it cannot see: disconnect while carrying and the world goes away before the carry ends, so the resume never happens and Fresh Animations stays off for that player until the game is restarted. Somebody walking out of your tracking range mid-carry did the same to them, from your side of the screen. The bridge now converges on the state a player should be in every tick instead of reacting to changes, and forgets what it applied when a world ends, so anyone it can no longer reach is asserted afresh — resumed included — the moment they reappear. Riding a boat now pauses EMF too, so vanilla's rowing animation shows while you paddle; being a single subclass check, that covers chest boats, rafts, boats added by wood mods and every Small Ships vessel, whose ships extend the vanilla boat. Piloted machines are left alone on purpose — Immersive Aircraft and the Immersive Machinery vehicles built on it draw their own pilot pose and are not rowed. Maintainer-facing: the server MOTD is corrected everywhere. The copy under `1. setup`, the one a self-hoster actually reads, had sat at `v4.1.3-packwiz required` ever since that release, because the build only checked the two copies that get deployed; all three now read `v4.2.4 - @nbidal18 on Discord` and all three are checked. Player emotes bridge 1.2.0 to 1.2.1. |

### Server deployment

Required a stopped server: the integrity helper JAR carries the pack version and `server.properties`
is not hot-reloadable. The owner confirmed the shutdown and a status ping refused the connection
before and after every write. Deployed the integrity policy, the helper JAR, `bcc-common.toml` and
the MOTD line of `server.properties` — one line of sixty-four, leaving ports, whitelist, world name
and every provider setting untouched. Backups under
`Z:\.nbidal18-deploy-backups\2026-08-18-v4.2.4-packwiz\`.

## v4.2.3-packwiz

Superseded by v4.2.4. Final digest `58719703d3e8042d…`. 620 managed files, 244 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-18 | `6902b54` | `58719703d3e8042d` | 620 | 244 | **The accessory slots are laid out properly, and the version is being prepared to lose its `-packwiz` suffix.** In the inventory, the vanilla off-hand slot now sits in the middle of the accessory row, with the two hand accessories to its right and the two rings to its left; the ring slots had been drawing as bare transparent holes and now carry the same grey slot backing as every other slot. Trinkets' hover popup stays anchored to the off-hand where it belongs — the 4.2.0 attempt moved the popup's rectangle, which is the same rectangle as its hover target, so it opened over the character's feet instead. Maintainer-facing, and the real reason this release exists: the updater now accepts a version with **or** without the `-packwiz` suffix. Packwiz is a known part of the pack and the number alone says enough, but the suffix cannot simply be dropped — the updater a player already has is the one that validates the next release, and every installed build so far demands the suffix. Publishing a bare `4.3.0` today would have been rejected as an unsupported manifest, the update abandoned, and that player left silently on their old build forever. This release teaches both forms so a later one can stop writing the suffix; both stay accepted permanently, since some client is always a release or two behind. The build's MOTD check was tied to the same literal string and now matches the release number instead, which frees the MOTD to be player-facing wording: it reads `v4.2.3 - @nbidal18 on Discord`. The lowest channel version the updater will install rises to 4.2.3. Client tweaks 1.3.8 to 1.3.9. |

### Server deployment

Required a stopped server: the integrity helper JAR carries the pack version and `server.properties`
is not hot-reloadable. The owner confirmed the shutdown and a status ping refused the connection
before and after every write. Deployed the integrity policy, the helper JAR, `bcc-common.toml` and
the MOTD line of `server.properties` — one line of sixty-four, leaving ports, whitelist, world name
and every provider setting untouched. Backups under
`Z:\.nbidal18-deploy-backups\2026-08-18-v4.2.3-packwiz\`.

## v4.2.2-packwiz

Superseded by v4.2.3. Final digest `74a0c27938bc8b72…`. 620 managed files, 244 mods.

Players update by closing Minecraft and clicking **Play**; nothing needs re-importing.

| Date | Commit | Digest | Files | Mods | Change |
| --- | --- | --- | --- | --- | --- |
| 2026-08-18 | `073a372` | `74a0c27938bc8b72` | 620 | 244 | **Placing a block now reveals the HUD.** It never did. The 4.2.0 request was to reveal while placing and breaking, and both were wired to Auto HUD triggers — but its two interaction events are "breaking a block" and "holding a usable item", and the second covers food, a drawn bow or a raised shield rather than placing. Breaking always worked; placing was never implemented, and the pair was reported as delivered. Placement now reveals the hotbar and, through it, the rest of the hotbar group, exactly as breaking does. Gated so that only a real placement counts: opening a chest or pressing a button leaves the HUD hidden, and placing from the off-hand still reveals. Auditing the rest of the HUD model against the code found nothing else wrong — armour, the experience bar and the mount jump bar stay hidden, the air bar still reveals alone, and Immersive Machinery vehicles were already covered because they extend the Immersive Aircraft engine vehicle. Client tweaks 1.3.7 to 1.3.8. |

### Server deployment

Required a stopped server: the integrity helper JAR carries the pack version and `server.properties`
is not hot-reloadable. Deployed the integrity policy, the helper JAR, `bcc-common.toml` and the MOTD
line of `server.properties` — one line of sixty-four, leaving ports, whitelist, world name and every
provider setting untouched. Backups under `Z:\.nbidal18-deploy-backups\2026-08-18-v4.2.2-packwiz\`.

A backup verified as stale during this deployment: copying `server.properties` across the SFTP
mount returned content from before the server had last rewritten it, at the correct byte length. The
deploy script now reads the bytes itself and verifies the backup against those, rather than trusting
the copy. Worth remembering for anything else that reads `Z:`.

## v4.2.1-packwiz

Superseded by v4.2.2. Final digest `5745945329aeb210…`. 620 managed files, 244 mods.

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
