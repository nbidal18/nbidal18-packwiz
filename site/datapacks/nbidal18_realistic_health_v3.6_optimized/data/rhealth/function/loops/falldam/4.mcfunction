#FF 1
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":1}] run effect give @s minecraft:slowness 4 1 true
#FF 2
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":2}] run effect give @s minecraft:slowness 3 1 true
#FF 3
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":3}] run effect give @s minecraft:slowness 2 1 true
#FF 4 does nothing
#If no feather falling
execute as @s unless predicate rhealth:has_feather_falling run effect give @s minecraft:slowness 5 1 true
