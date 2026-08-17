#FF 1
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":1}] run effect give @s minecraft:slowness 6 6 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":1}] run effect give @s minecraft:nausea 8 6 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":1}] run effect give @s minecraft:blindness 6 6 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":1}] run effect give @s minecraft:mining_fatigue 6 0 true

#FF 2
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":2}] run effect give @s minecraft:slowness 4 6 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":2}] run effect give @s minecraft:nausea 6 6 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":2}] run effect give @s minecraft:blindness 4 6 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":2}] run effect give @s minecraft:mining_fatigue 4 0 true

#FF 3
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":3}] run effect give @s minecraft:slowness 2 6 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":3}] run effect give @s minecraft:nausea 4 6 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":3}] run effect give @s minecraft:blindness 2 6 true
execute if items entity @s armor.feet #minecraft:foot_armor[minecraft:enchantments={"feather_falling":3}] run effect give @s minecraft:mining_fatigue 2 0 true
#FF 4 does nothing
#If no feather falling
execute as @s unless predicate rhealth:has_feather_falling run effect give @s minecraft:slowness 8 6 true
execute as @s unless predicate rhealth:has_feather_falling run effect give @s minecraft:nausea 10 6 true
execute as @s unless predicate rhealth:has_feather_falling run effect give @s minecraft:blindness 8 6 true
execute as @s unless predicate rhealth:has_feather_falling run effect give @s minecraft:mining_fatigue 8 0 true
