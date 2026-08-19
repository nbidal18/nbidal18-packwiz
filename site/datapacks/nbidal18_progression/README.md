# nbidal18 progression

Two things live here, both added in v4.3.0 when Jobs+ was replaced by LevelZ and JobsAddon.

## `data/levelz/skill/nbidal18.json` — the pack's skill table

LevelZ ships its own table as `data/levelz/skill/default.json`. The pack sets
`defaultSkills: false` in `config/levelz.json5` and ships this file instead, so the whole
table is ours rather than a set of overrides layered on someone else's.

It is LevelZ's table with four deliberate departures. Everything else — every bonus, every
other attribute, every level cap — is exactly as LevelZ ships it.

**1. Three hearts, and twenty levels give back exactly one row.**
`generic.max_health` has `base: 6` and `value: 0.7`, so a new player has three hearts and a
player with Constitution 20 has 6 + 14 = 20 health, one full row and never more. The row is a
ceiling by construction rather than by tuning. Gear is deliberately exempt: rings, TieredZ
modifiers and Epic Knights may push past it, because those are earned and equipped.

Worth knowing: **LevelZ already lowers this base to 8 on its own.** A pack that installs LevelZ
untouched starts its players at four hearts, not ten. The three-heart base is a change of two
points, not a change from vanilla.

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

- every **10** skill levels (10, 20) for all twelve skills
- every **25** job levels (25, 50, 75, 100) for all eight jobs
- every **25** overall LevelZ levels (25, 50, 75, 100)

Regenerate with `scripts\Build-ProgressionDatapack.ps1` rather than editing by hand; it also
mirrors this whole datapack to the server and managed-host copies and verifies them by hash.
