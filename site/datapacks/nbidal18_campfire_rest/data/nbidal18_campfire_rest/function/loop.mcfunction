# Runs once per second. Any living player standing within 3 blocks of a lit campfire
# (or soul campfire) has Regeneration refreshed, so resting at a fire heals them.
#
# Regeneration only heals on ticks where the remaining duration is a multiple of (50 >> amplifier),
# so the duration and the refresh interval have to be chosen together: the span of durations
# counted down between two refreshes must contain one of those points, or the timer is reset
# forever and the player never heals at all.
#
# Refreshing every second counts down 20 ticks. Regeneration II procs every 25, so a 2 second
# (40 tick) effect counts 40 down to 21 and always crosses 25 - exactly one heal per second.
#
# This was Regeneration I for 5 seconds, which healed at the same rate but lingered five seconds
# after walking away, so running past a fire was worth free health. Two seconds is the shortest
# that still works: one second is 20 ticks, counts 20 down to 1, and crosses no proc point at any
# amplifier, so the effect would refresh forever and heal nothing.
execute as @a[gamemode=!spectator] at @s if function nbidal18_campfire_rest:detect run effect give @s minecraft:regeneration 2 1 true
schedule function nbidal18_campfire_rest:loop 20t replace
