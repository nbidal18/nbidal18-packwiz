execute if block ~ ~ ~ minecraft:stonecutter run function rhealth:damages/stonecutter
execute if block ~ ~ ~ minecraft:rose_bush if block ~0.1 ~ ~ minecraft:rose_bush if block ~-0.1 ~ ~ minecraft:rose_bush if block ~ ~ ~0.1 minecraft:rose_bush if block ~ ~ ~-0.1 minecraft:rose_bush if block ~0.1 ~ ~0.1 minecraft:rose_bush if block ~-0.1 ~ ~0.1 minecraft:rose_bush if block ~0.1 ~ ~-0.1 minecraft:rose_bush if block ~-0.1 ~ ~-0.1 minecraft:rose_bush run function rhealth:damages/rose_bush
execute if block ~ ~ ~ #minecraft:corals run function rhealth:damages/coral
execute if block ~ ~ ~ #rhealth:amethyst run function rhealth:damages/amethyst
execute unless entity @s[type=#axolotl_hunt_targets] if block ~ ~-0.1 ~ #minecraft:coral_blocks run function rhealth:damages/coral
