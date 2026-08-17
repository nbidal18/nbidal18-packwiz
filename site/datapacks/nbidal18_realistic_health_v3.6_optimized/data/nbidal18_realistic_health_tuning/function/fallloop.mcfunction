execute as @a[scores={rhealth.fallen=330..}] if entity @s[nbt={HurtTime:10s}] run function nbidal18_realistic_health_tuning:apply_fall_damage
scoreboard players reset @a[scores={rhealth.fallen=1..}] rhealth.fallen
schedule function rhealth:loops/fallloop 1t replace
