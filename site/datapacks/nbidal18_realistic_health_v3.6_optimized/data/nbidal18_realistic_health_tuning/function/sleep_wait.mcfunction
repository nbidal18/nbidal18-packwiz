execute if score #world rhealth.sday > @s rhealth.sday run function nbidal18_realistic_health_tuning:apply_sleep_regeneration
execute if score @s rhealth.spending matches 2 run scoreboard players remove @s rhealth.sgrace 1
execute if score @s rhealth.spending matches 2 if score @s rhealth.sgrace matches ..0 run scoreboard players set @s rhealth.spending 0
