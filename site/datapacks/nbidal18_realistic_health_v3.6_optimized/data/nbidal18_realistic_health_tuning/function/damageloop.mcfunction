execute as @a at @s run function nbidal18_realistic_health_tuning:check_environmental_damage
# This health system is player-only; scanning every loaded mob was unnecessary.
# Keep the upstream cadence because environmental damage is applied per invocation.
schedule function rhealth:loops/damageloop 1t replace
