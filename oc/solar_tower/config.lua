local M = {}

-- Target behavior.
M.target_heat = 50000
M.min_insert_heat = 50000
M.min_convert_heat = 30000
M.max_heat = 100000
M.passive_loss_per_cycle = 10

-- Solar Tower constants for max reflector build.
M.heater_count = 340
M.tier_bonus = 16

-- Runtime.
M.cycle_seconds = 10
M.align_to_cycle_boundary = true
M.max_insert_per_cycle = 60000

-- Safety.
M.enforce_reflector_count = true
M.expected_reflector_count = 340

-- Logging.
M.log_prefix = "[solar_tower]"

-- Controller sensor component (gt_machine).
M.sensor = {
  address = "1c567e0f-3c93-4368-b597-570799b3ca7c",
  component_type = "gt_machine", -- used only if address is nil
  method = "getSensorInformation",
}

-- Transposer for cold salt insertion.
M.transposer = {
  address = nil,
  component_type = "transposer",
  source_side = "west",
  sink_side = "east",
  source_tank = nil, -- set number if needed
}

-- Environment sensing (used for clear/rain/night gain math).
M.geolyzer = {
  address = nil,
  component_type = "geolyzer",
}

-- Optional daylight sensor to distinguish rain vs night.
-- If missing, non-sunny time is treated as NIGHT (conservative).
M.redstone_day = {
  address = nil,
  component_type = "redstone",
  side = "north",
  threshold = 0,
}

return M
