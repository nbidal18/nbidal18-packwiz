# nbidal18 temperature (datapack)

The data half of the pack's temperature design. The code half is the `nbidal18-temperature` mod;
this file explains what each tag here is for and, where it matters, what it is deliberately not
doing.

## `scorchful:heat_resistance_modified` — emptied on purpose

Scorchful applies its tag-based heat resistance to everything in `#c:armors` through this tag.
The pack drives **both** halves of insulation from Thermoo attributes instead, so leaving the tag
path switched on would mean two systems modifying the same number from different directions.
Emptying this one tag turns the whole tag path off in a single file and leaves the mod as the
single source of truth.

Consequence worth knowing: the four `scorchful:heat_resistance/*` tags still exist and still list
their materials, but nothing reads them any more. Do not "fix" them — put the value in the mod.

## `scorchful:is_sun_protecting_hat` — the one axis that is not symmetric

A hat shades you; it does not insulate you. So hats help in the sun and do nothing in the cold,
which is the only legitimate break in the symmetry the rest of the design keeps.

Added here: the **turtle helmet**, every `#trinkets:head/hat` item, and Artifacts' head and face
slots. Vanilla puts the turtle helmet in Scorchful's `very_protective` heat tag; the pack treats it
as a hat instead, and since the tag path above is off, that reclassification happens by adding it
here rather than by removing it there.

**Epic Knights' `kettlehat` is deliberately absent.** It is a helmet with a brim, not a hat, and it
insulates like the metal it is made of.

## `thermoo:consumable/warming` and `cooling`

Both ship empty from Thermoo. Scorchful fills `cooling` with items from mods this pack does not
have — beachparty ice creams and similar — so in practice both were empty here too.

Filled from what the pack actually contains: vanilla soups and Farmer's Delight's hot dishes on the
warming side, fruit, milk, honey and drinks on the cooling side. Every modded entry is
`required: false`, so removing a food mod later degrades the tag instead of breaking datapack load.

These tags are **binary** — an item either warms or cools, with no magnitude. Graded food strength
would need code on top, and is not worth it until play shows the flat version is wrong.

## Climate tags for the pack's modded biomes — added in v4.4.3

**Why they were needed.** Thermoo's temperature model is authored in datapacks, not code:
`thermoo/environment/*.json` binds a biome selector to a provider, and the provider gives the
degrees. Frostiful and Scorchful ship those definitions already, keyed on climate tags — and
**those climate tags name no biomes directly.** Every one is built from convention tags such as
`#c:is_snowy`, `#c:is_taiga`, `#c:is_desert` and `#c:is_nether`.

So a biome that joins none of those matches no climate, gets no environment definition, and has
**no temperature behaviour at all** — not a weak one, none. Measured across all 254 jars before this
change: of the pack's 95 modded biomes, **13 had a climate and 82 did not.** Terralith supplies most
of the Overworld here, and only 2 of its 84 biomes were covered.

That, not any multiplier, is why the world did not feel cold.

**What is tagged, and where.** Each band is written to the extension tag its mod already declares as
`required: false` for exactly this purpose, so nothing here overrides a mod's own list:

| Band | Biomes | Written to |
| --- | --- | --- |
| freezing | 2 | `frostiful:freezing_biomes` |
| cold | 5 | `frostiful:cold_biomes` |
| cool | 17 | `frostiful:cool_biomes` |
| temperate | 38 | `c:is_temperate/overworld` |
| warm | 10 | `scorchful:warm_biomes` |
| scorching | 10 | `scorchful:scorching_biomes` |

Temperate is the one that is not a mod-specific extension tag, because neither mod declares one —
Frostiful reads `#c:is_temperate` and Scorchful reads `#c:is_temperate/overworld`, and the former
includes the latter, so a single file feeds both.

**How the bands were chosen.** Purely from each biome's own `temperature` value, against vanilla
reference points (`snowy_plains` 0.0, `taiga` 0.25, `plains` 0.8, `jungle` 0.95, `desert` 2.0):

```
t <= -0.45  freezing      0.35 < t <= 0.95  temperate
t <=  0.05  cold          0.95 < t <  2.0   warm
t <=  0.35  cool          t >= 2.0          scorching
```

No biome was judged by name, so a Terralith update that retunes a biome's temperature can be
re-derived rather than re-argued.

**Seasons come free with this.** Both mods' providers are `thermoo:seasonal/temperate` — a cold
biome is -5 °C in spring, **+5 in summer**, -5 in autumn and -15 in winter, and a warm one runs
30/40/30/20 against a 35 °C heat threshold. So summer genuinely warms a cold biome and pushes a warm
one over the line, which is the seasonal behaviour the design asked for. It needed biomes, not code.

**The Nether and the End were already fine** and are deliberately untouched: Incendium's 8 biomes are
in `#c:is_nether`, Nullscape's 3 are in `#c:is_end`, and Frostiful's `hell` and `void` environments
pick both up.

## Altitude and shelter — added in v4.4.3

The last two terms of the temperature design, and the only two that needed a new provider type
rather than a new tag. They live in `data/nbidal18/thermoo/environment/`, one file each, and each
file says at the top what deleting it would restore.

**Why they are not Scorchful's altitude provider.** Scorchful ships
`scorchful:sea_level_altitude_temperature` — the one that grades the Nether by height — and it was
the obvious candidate. It *sets* the temperature to `temperature_at_sea_level + elevation x rate`,
so used as a modifier it would overwrite the biome and the season with an absolute number and leave
every mountain in the world at the same temperature. All twelve provider types the pack already had
were read before writing code: none of the eight in Thermoo and none of the four in Scorchful
varies with the player's height except that one. So altitude is a first-party type,
`nbidal18:altitude`, and shelter is `nbidal18:cave_shelter`.

**Priority is doing real work here.** Thermoo applies *every* matching environment definition, in
priority order, highest first, onto one shared component builder — and a climate's provider sets
the temperature rather than adding to it. A shift therefore has to run after all of them or it is
simply overwritten. The default priority is 1000; altitude is 100 and shelter is 90, which is what
makes the order biome, then season, then height, then shelter.

| Term | Rule | Reached through |
| --- | --- | --- |
| altitude | 1 °C cooler per 10 blocks above y 63, capped at 25 °C | `nbidal18:altitude` |
| shelter | blend toward the biome's annual mean as sky and depth close in | `nbidal18:cave_shelter` |
| depth | 0.08 °C warmer per block below y 63, capped at 12 °C | the same provider |

**The rate is not the real one.** The atmosphere cools 6.5 °C per kilometre, which over the 256
blocks a player can climb is 1.7 °C — invisible against a comfort band 30 °C wide. 1 °C per 10
blocks is the same trade the rest of the pack makes: a mechanic a player can feel beats a number
that is correct and inert.

**A cave settles at the biome's own annual mean**, computed from the biome's vanilla `temperature`
value rather than judged by name — the same source the climate bands above were derived from. Snowy
plains settle at 8 °C, plains at 12.8, jungle at 13.7, desert at 20. All four are inside the comfort
band, which is the point: a cave is a refuge from *both* ends, cooler than a desert afternoon and
warmer than a taiga night, and it ignores the time of day and the season entirely.

**Shelter deliberately needs two things at once.** Losing the sky alone would make every hut a
climate-controlled room and trivialise winter; depth alone would count an open ravine at y 20 as a
cave. The two factors are multiplied, so a house four blocks under its own roof takes the edge off a
blizzard without ending it. The pack already has fires for the rest.

**Overworld only, and that is enforced by the biome selector.** `#minecraft:is_overworld` carries
every vanilla biome and, through Terralith's own addition of `#terralith:all_terralith_biomes`, all
84 of its biomes — the whole modded Overworld in this pack. Height means nothing in the Nether,
where the roof is at 128 and all of it is indoors, and the End has neither a sky nor a floor to
measure from. Both keep the behaviour they already had.
