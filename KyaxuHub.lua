-- Legacy entry point. New integrations should use Kyaxu/Main.lua.
local kyaxuFolder = script.Parent:FindFirstChild("Kyaxu")
local mainModule = kyaxuFolder and kyaxuFolder:FindFirstChild("Main")

if not mainModule then
	return warn("Kyaxu Main module was not found.")
end

return require(mainModule)
