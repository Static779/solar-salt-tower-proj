local config = require("solar_tower.config")
local io_factory = require("solar_tower.io")
local control = require("solar_tower.control")

local io_api = io_factory.new(config)
local controller = control.new(config, io_api)

local ok, err = pcall(function()
  controller:run()
end)

if not ok then
  io.stderr:write("[solar_tower] fatal: " .. tostring(err) .. "\n")
end
