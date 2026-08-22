execute store result score #world rhealth.sday run time query day
scoreboard players set @a rhealth.stimer 0
scoreboard players add @a rhealth.spending 0
scoreboard players add @a rhealth.sday 0
scoreboard players add @a rhealth.sgrace 0
scoreboard players set @a[scores={rhealth.quit=1..}] rhealth.spending 0
scoreboard players set @a[scores={rhealth.quit=1..}] rhealth.sgrace 0
scoreboard players set @a[scores={rhealth.quit=1..}] rhealth.quit 0
# "data get entity" serialises the whole player to read one field, so this is the pack's most
# expensive recurring work. The cadence at the bottom is what reduces it.
# DO NOT gate this line on a block test. That was tried on 2026-08-22 and silently stopped sleep
# healing; the block test itself is fine - it was verified in game to be true while actually asleep -
# but conditioning THIS line changes when stimer reaches zero on waking, and the state machine below
# depends on that edge. The bed restriction lives on sleep_started instead, where it is only a
# question of which sleeps count and no timing depends on it.
execute as @a store result score @s rhealth.stimer run data get entity @s SleepTimer
# Only a real bed records a sleep, so Comforts' sleeping bags and hammocks shelter you and mend
# nothing (owner, 2026-08-22). A bed moves your spawn, so healing on the road costs you your home;
# the vanilla spawn rule does the balancing and nothing here needs a number.
execute as @a[scores={rhealth.stimer=1..,rhealth.spending=0}] at @s if block ~ ~ ~ #minecraft:beds run function nbidal18_realistic_health_tuning:sleep_started
execute as @a[scores={rhealth.stimer=1..,rhealth.spending=2}] at @s if block ~ ~ ~ #minecraft:beds run function nbidal18_realistic_health_tuning:sleep_started
execute as @a[scores={rhealth.stimer=0,rhealth.spending=1}] run function nbidal18_realistic_health_tuning:sleep_finished
execute as @a[scores={rhealth.stimer=0,rhealth.spending=2}] run function nbidal18_realistic_health_tuning:sleep_wait
# 4t rather than 1t: four times less of the serialisation above, and nothing here needs tick
# precision. SleepTimer stays non-zero for the whole sleep and for ten ticks after waking, so a
# four-tick poll cannot miss either edge, and sgrace is counted in loop iterations rather than ticks
# so the grace window widens from 5 ticks to 20 - more forgiving, not less.
schedule function rhealth:loops/sleeploop 4t replace
