# nbidal18 progression

Two things live here, both added in v4.3.0 when Jobs+ was replaced by LevelZ and JobsAddon.
The skill table was revised in v4.3.1, which removed Constitution and restored vanilla hearts.

## `data/levelz/skill/nbidal18.json` — the pack's skill table

LevelZ ships its own table as `data/levelz/skill/default.json`. The pack sets
`defaultSkills: false` in `config/levelz.json5` and ships this file instead, so the whole
table is ours rather than a set of overrides layered on someone else's.

It is LevelZ's table with four deliberate departures. Everything else — every bonus, every
other attribute, every level cap — is exactly as LevelZ ships it.

**1. Constitution is removed, and hearts are vanilla.** No skill in this table touches
`generic.max_health`, so every player has the ordinary ten hearts and nothing takes them away or
sells them back.

This reverses v4.3.0, which set `base: 6` and had Constitution return the missing fourteen over
twenty levels. It read well and played badly: a death took your maximum health with your skills,
so respawning meant three hearts and a long walk. Gear is unaffected either way — rings, TieredZ
modifiers and Epic Knights still push past ten.

Worth knowing while reading LevelZ's own table: **LevelZ lowers this base to 8 on its own**, so a
pack that installs it untouched starts its players at four hearts. Removing the skill removes that
too, which is the whole point.

**Removing a skill means renumbering, and that is not cosmetic.** LevelZ's `SkillLoader` walks skill
ids `0..n-1` and throws `MissingResourceException` on a gap, and player levels are persisted against
those ids. Constitution was id 0, so every other skill moved down one and the attribute ids closed up
with them. **Any save written before that renumber will read its skill levels against the wrong
skills.** v4.3.1 handled this by resetting every player's skills on the same restart; a future
removal has to do the same or leave the id in place.


**2. LevelZ's lowered baselines are kept — deliberately.** LevelZ's table does not only add
bonuses; it also drops several vanilla starting values and sells them back through levels:

| Attribute | Vanilla | Here, at level 0 | At level 20 |
| --- | --- | --- | --- |
| `generic.movement_speed` | 0.1 | 0.09 | 0.11 |
| `player.sneaking_speed` | 0.3 | 0.2 | 0.4 |
| `player.block_break_speed` | 1.0 | **0.5** | 1.5 |
| `generic.luck` | 0 | **-1** | +2 |

These were briefly restored to vanilla during the v4.3.0 build, on the reasoning that skills should
be upside only. The owner's call reversed that, and the reasoning is better: they are the same shape
as the three-heart base, extended from your body to your competence. You do not start as a finished
adventurer who collects bonuses — you start unpractised and get better by spending points.

Two consequences worth knowing rather than rediscovering. **Luck −1 is the least visible thing in
this file**: it shifts every loot table in the pack, fishing and chests included, for an unlevelled
player. And because death zeroes every skill, a player who dies goes back to half mining speed and
negative luck along with their three hearts.


**3. Melee attack damage halved.** `generic.attack_damage` is `0.1` per level rather than
`0.2`, so Melee 20 gives **+2** attack damage instead of +4. A diamond sword does 7; +4 on top
of Epic Knights gear and TieredZ modifiers trivialised combat, which is where most of the
pack's content lives.

**4. Ranged damage is cut in `config/levelz.json5`, not here**, because LevelZ implements it as
a bonus rather than an attribute. `bowDamageBonus` and `crossbowDamageBonus` are `0.15` instead
of `0.5`, so Archery 20 adds +3 rather than +10 to a bow that does about 9.

## `data/nbidal18_progression/advancement/` — milestone plaques

LevelZ fires `levelz:level` and `levelz:skill`; JobsAddon fires `jobsaddon:job_up`. Advancement
Plaques renders any advancement, so level-ups need no code at all — only advancements that
trigger on those criteria.

These are **milestones, not every level**. One advancement per level would be roughly 1,100
files for 12 skills, 8 jobs and 100 overall levels, which would nearly triple the pack's managed
file count for a popup. The rule instead is:

- every **10** skill levels (10, 20) for all eleven skills
- every **25** job levels (25, 50, 75, 100) for all eight jobs
- every **25** overall LevelZ levels (25, 50, 75, 100)

Regenerate with `scripts\Build-ProgressionDatapack.ps1` rather than editing by hand; it also
mirrors this whole datapack to the server and managed-host copies and verifies them by hash.
