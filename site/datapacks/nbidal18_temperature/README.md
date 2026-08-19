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
