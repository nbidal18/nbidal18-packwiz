# nbidal18 wash dyed items (datapack)

Craft any dyed thing together with a water bucket and it comes back white. Ten shapeless recipes,
no mod, no new items.

Upstream is **Wash Dyed Items 2.0** by Daniel Wang
(<https://modrinth.com/datapack/wash-dyed-items>), MIT, and the licence is retained verbatim beside
this file. The datapack form was taken rather than the mod: the mod version ships a 274 KiB JAR to
do what twelve JSON files already do, and this pack does not add a mod where a datapack will serve.

## What was changed, and why it could not ship as downloaded

**Two recipes and their tags were removed, because the items do not exist in 1.21.1.** Upstream
targets whatever the current Minecraft release is, and both of these arrived later:

| Removed | Why |
| --- | --- |
| `recipe/white_harness.json` and `tags/item/harnesses.json` | Harnesses are 1.21.9 content. `minecraft:white_harness` is not a 1.21.1 item |
| `recipe/bundle.json` and `tags/item/bundles.json` | Dyed bundles are 1.21.2 content. 1.21.1 has only `minecraft:bundle` |

This matters more than it looks. **Every entry in those tags is `required: true`**, so a single
missing item does not skip one line — it fails the whole tag, and the recipe pointing at it fails
with it. Shipping the pack unmodified would have put two tag-load errors in the log on every world
load, for two recipes that could never work.

**Every recipe's ingredients were rewritten into the 1.21.1 form.** Upstream lists them as bare
strings — `"minecraft:water_bucket"`, `"#washdyeditems:wools"` — which is the shape Minecraft
accepted from **1.21.2** onward. 1.21.1 wants objects, `{"item": ...}` and `{"tag": ...}`, and
rejects the short form outright: `Parsing error loading recipe washdyeditems:leather_boots`, and
every other recipe with it. This is not a subtle difference and it is not optional; the whole
datapack was inert as downloaded.

**`pack_format` was corrected from 1 to 48.** Upstream ships 1, which Minecraft reads as
incompatible with 1.21.1 and refuses to enable without a warning. 48 is the format 1.21.1 actually
wants, and every other datapack in this pack declares it.

**`pack.png` was dropped.** It is 131 KiB of icon for a pack that is loaded globally and never
appears in a selection screen, and every managed file is downloaded by every player.

## What survived

Ten recipes: leather helmet, chestplate, leggings and boots, plus candles, shulker boxes, banners,
beds, carpets and wool. Six tags feed them, one per dyeable family.

Recipes keep the upstream `washdyeditems` namespace rather than being renamed, so the ids match the
project they came from and a future update can be diffed against it directly.

## Re-checking this against a newer upstream

If Wash Dyed Items is ever updated, do not assume the same files are the only problem. Three checks,
in order:

1. **Ingredient shape.** Re-apply the string-to-object conversion above; upstream will keep writing
   the modern form.
2. **Item existence.** Read every `id` in `data/washdyeditems/tags/item/*.json` and confirm each one
   exists in 1.21.1. Anything newer has to go, along with the recipe referencing its tag. Every
   entry is `required: true`, so one missing item kills the whole tag.
3. **`pack_format`.** It must be 48.

`scripts\Test-DedicatedServer.ps1` catches all three — it caught two of them here — so run it before
believing any of this is right.
