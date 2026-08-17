scoreboard players add counter rhealth.cooldown 1
execute if score counter rhealth.cooldown matches 20.. run scoreboard players set counter rhealth.cooldown 0
execute if score counter rhealth.cooldown matches 7 as @a[scores={rhealth.health=..6}] at @s run playsound minecraft:entity.warden.heartbeat master @s
execute if score counter rhealth.cooldown matches 13 as @a[scores={rhealth.health=..2}] at @s run playsound minecraft:entity.warden.heartbeat master @s
execute if score counter rhealth.cooldown matches 0 as @a[scores={rhealth.health=..9}] run function nbidal18_realistic_health_tuning:apply_low_health_effects
schedule function rhealth:loops/effectloop 1t replace
