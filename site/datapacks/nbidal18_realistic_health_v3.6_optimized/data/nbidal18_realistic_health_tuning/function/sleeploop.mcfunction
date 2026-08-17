execute store result score #world rhealth.sday run time query day
scoreboard players set @a rhealth.stimer 0
scoreboard players add @a rhealth.spending 0
scoreboard players add @a rhealth.sday 0
scoreboard players add @a rhealth.sgrace 0
scoreboard players set @a[scores={rhealth.quit=1..}] rhealth.spending 0
scoreboard players set @a[scores={rhealth.quit=1..}] rhealth.sgrace 0
scoreboard players set @a[scores={rhealth.quit=1..}] rhealth.quit 0
execute as @a store result score @s rhealth.stimer run data get entity @s SleepTimer
execute as @a[scores={rhealth.stimer=1..,rhealth.spending=0}] run function nbidal18_realistic_health_tuning:sleep_started
execute as @a[scores={rhealth.stimer=1..,rhealth.spending=2}] run function nbidal18_realistic_health_tuning:sleep_started
execute as @a[scores={rhealth.stimer=0,rhealth.spending=1}] run function nbidal18_realistic_health_tuning:sleep_finished
execute as @a[scores={rhealth.stimer=0,rhealth.spending=2}] run function nbidal18_realistic_health_tuning:sleep_wait
schedule function rhealth:loops/sleeploop 1t replace
