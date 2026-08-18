# Runs once per second. Any living player standing within 3 blocks of a lit campfire
# (or soul campfire) has Regeneration refreshed, so resting at a fire heals them.
#
# The 5 second duration is deliberate: vanilla Regeneration I only heals on ticks where
# the remaining duration is a multiple of 50, so a shorter refresh would reset the timer
# forever and never actually heal. 100 ticks is the shortest whole-second duration that
# satisfies that, and refreshing it every second yields a steady heal while seated.
execute as @a[gamemode=!spectator] at @s if function nbidal18_campfire_rest:detect run effect give @s minecraft:regeneration 5 0 true
schedule function nbidal18_campfire_rest:loop 20t replace
