scoreboard objectives add rhealth.fallen minecraft.custom:minecraft.fall_one_cm
scoreboard objectives add rhealth.health health
scoreboard objectives add rhealth.cooldown dummy
scoreboard objectives add rhealth.stimer dummy
scoreboard objectives add rhealth.spending dummy
scoreboard objectives add rhealth.sday dummy
scoreboard objectives add rhealth.sgrace dummy
scoreboard objectives add rhealth.quit minecraft.custom:minecraft.leave_game

function rhealth:loops/damageloop
function rhealth:loops/sleeploop
function rhealth:loops/fallloop
function rhealth:loops/effectloop
