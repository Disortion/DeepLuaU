-- string interpolation referencing locals, expressions, methods
local player = "Nova"
local score = 42
local items = { "sword", "shield", "potion" }

print(`Welcome, {player}!`)
print(`Score: {score} (x2 = {score * 2})`)
print(`You carry {#items} items: {table.concat(items, ", ")}`)

local function greet(name: string, lvl: number)
	return `[{lvl}] {name} is ready`
end
print(greet(player, 7))

local hp, max = 30, 100
print(`HP {hp}/{max} = {math.floor(hp / max * 100)}%`)
print(`nested: { ("hello " .. player):upper() }`)
print(`escaped \{braces\} stay literal, {score} does not`)
