local function normalize_path(path)
  return (path or ""):gsub("\\", "/")
end

local script_path = normalize_path(arg and arg[0] or "")
local project_root = script_path:match("^(.*)/oc/solar_tower/emulator/run_transposer_demo%.lua$")
if project_root == nil then
  project_root = "."
end

package.path =
  project_root .. "/?.lua;" ..
  project_root .. "/?/init.lua;" ..
  project_root .. "/oc/?.lua;" ..
  project_root .. "/oc/?/init.lua;" ..
  package.path

local mock_oc = require("solar_tower.emulator.mock_oc")

local env = mock_oc.install({
  is_day = true,
  is_raining = false,
  redstone_input = {
    north = 15, -- daylight sensor "day"
  },
  tanks = {
    west = { [1] = 4000000 }, -- cold salt source tank
    east = { [1] = 0 },       -- tower input buffer
  },
  tank_capacity = {
    east = 10000000,
  },
})

package.loaded["solar_tower.config"] = nil
local config = require("solar_tower.config")

config.ingame.enable = true
config.ingame.valve_mode = "transposer_exact"
config.ingame.initial_heat = 100000
config.ingame.transposer.component_type = "transposer"
config.ingame.transposer.source_side = "west"
config.ingame.transposer.sink_side = "east"
config.ingame.transposer.source_tank = 1
config.ingame.geolyzer.component_type = "geolyzer"
config.ingame.redstone.component_type = "redstone"
config.ingame.redstone.daylight_sensor_side = "north"
config.ingame.redstone.day_threshold = 0

local integration = require("solar_tower.providers.ingame_model")
local providers, provider_err = integration.build(config)
if providers == nil then
  io.stderr:write("[emulator] provider build failed: " .. tostring(provider_err) .. "\n")
  os.exit(1)
end
config.providers = providers

local records = {}
config.logging.enabled = true
config.logging.logger = function(record)
  records[#records + 1] = record
end

local io_factory = require("solar_tower.io")
local control = require("solar_tower.control")
local io_api = io_factory.new(config)

local runtime = {
  now = function()
    return env.state.time
  end,
  sleep = function(seconds)
    local delay = tonumber(seconds) or 0
    if delay > 0 then
      env.state.time = env.state.time + delay
    end
  end,
}

local controller = control.new(config, io_api, runtime)
controller:run(12)

io.write("[emulator] completed 12 cycles\n")
for i = 1, #records do
  local rec = records[i]
  io.write(
    string.format(
      "cycle=%d state=%s heat=%s insert=%s weather=%s reason=%s\n",
      rec.cycle or -1,
      tostring(rec.state),
      tostring(rec.heat),
      tostring(rec.insert),
      tostring(rec.weather),
      tostring(rec.reason)
    )
  )
end

io.write(
  string.format(
    "[emulator] source_west_tank1=%d sink_east_tank1=%d transfers=%d\n",
    env.get_tank_level("west", 1),
    env.get_tank_level("east", 1),
    #env.state.transfer_log
  )
)
