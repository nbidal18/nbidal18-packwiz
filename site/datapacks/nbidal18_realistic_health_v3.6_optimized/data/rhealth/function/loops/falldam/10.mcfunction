#FF 1
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":1}] run effect give @s minecraft:slowness 8 7 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":1}] run effect give @s minecraft:nausea 10 7 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":1}] run effect give @s minecraft:blindness 8 7 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":1}] run effect give @s minecraft:mining_fatigue 8 1 true

#FF 2
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":2}] run effect give @s minecraft:slowness 6 7 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":2}] run effect give @s minecraft:nausea 8 7 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":2}] run effect give @s minecraft:blindness 6 7 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":2}] run effect give @s minecraft:mining_fatigue 6 1 true

#FF 3
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":3}] run effect give @s minecraft:slowness 4 7 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":3}] run effect give @s minecraft:nausea 6 7 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":3}] run effect give @s minecraft:blindness 4 7 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":3}] run effect give @s minecraft:mining_fatigue 4 1 true
#FF 4 does nothing
#If no feather falling
execute as @s unless predicate rhealth:has_feather_falling run effect give @s minecraft:slowness 10 7 true
execute as @s unless predicate rhealth:has_feather_falling run effect give @s minecraft:nausea 12 7 true
execute as @s unless predicate rhealth:has_feather_falling run effect give @s minecraft:blindness 10 7 true
execute as @s unless predicate rhealth:has_feather_falling run effect give @s minecraft:mining_fatigue 10 1 true
