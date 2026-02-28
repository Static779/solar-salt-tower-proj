local M = {}

M.constants = {
  target_heat = 50000,
  min_insert_heat = 50000,
  min_convert_heat = 30000,
  max_heat = 100000,
  passive_loss_per_cycle = 10,
  heater_count = 340,
  tier_bonus = 16,
}

M.runtime = {
  cycle_seconds = 10,
  telemetry_timeout_sec = 2,
  fault_hold_cycles = 3,
  align_to_cycle_boundary = true,
}

M.safety = {
  max_insert_per_cycle = 60000,
  enforce_reflector_count = true,
  expected_reflector_count = 340,
}

M.logging = {
  enabled = true,
  prefix = "[solar_tower]",
  include_hot_salt_delta = false,
}

-- Real in-game OpenComputers integration mode.
-- When enabled, provider functions are built automatically from:
-- 1) valve_mode "transposer_exact": direct transposer.transferFluid(...)
-- 2) valve_mode "sfm_pulse": redstone pulses into SFM trigger
-- 3) geolyzer weather checks
-- 4) optional redstone daylight sensor input
-- 5) model-based heat state seeded from initial_heat
M.ingame = {
  enable = false,
  initial_heat = 100000,
  valve_mode = "transposer_exact", -- "transposer_exact" or "sfm_pulse"

  -- Heat telemetry mode:
  -- "model"  -> deterministic internal model (default, no tower adapter needed)
  -- "sensor" -> read live heat from a configured adapter/peripheral component
  heat_mode = "model", -- "model" | "sensor"

  transposer = {
    -- Fill either address OR component_type.
    address = nil,
    component_type = "transposer",

    -- Absolute world sides: down/up/north/south/west/east or 0..5.
    source_side = "west",
    sink_side = "east",

    -- Optional tank index passed to transferFluid(sourceTank).
    source_tank = nil,
  },

  geolyzer = {
    -- Fill either address OR component_type.
    address = nil,
    component_type = "geolyzer",
  },

  controller_sensor = {
    -- Used only when heat_mode == "sensor".
    -- Point this at the adapter/peripheral that can read tower heat.
    enable = false,
    strict = true,

    -- Fill either address OR component_type.
    address = nil,
    component_type = nil,

    -- Optional direct methods (preferred if available).
    read_heat_method = "readHeat",
    read_reflector_count_method = "readReflectorCount",

    -- Optional text/table telemetry method for fallback parsing.
    -- Example payload can include:
    -- "Internal Heat Level: 50000"
    -- "Connected Solar Reflectors: 340"
    sensor_info_method = "getSensorInformation",
  },

  redstone = {
    -- Optional daylight sensor input.
    -- If omitted, day fallback is geolyzer.isSunVisible(), which cannot
    -- distinguish night from rainy daytime in all cases.
    address = nil,
    component_type = "redstone",
    daylight_sensor_side = "north",
    day_threshold = 0,
  },

  sfm = {
    -- Used only when valve_mode == "sfm_pulse".
    -- One SFM trigger execution must transfer exactly this many liters.
    liters_per_pulse = 1000,

    -- "floor" is conservative (never intentionally over-inserts this cycle).
    -- "nearest" reduces quantization error but may over/under-shoot per cycle.
    round_mode = "floor", -- "floor" | "nearest"

    -- Hard upper limit of pulses emitted in one 10s controller cycle.
    max_pulses_per_cycle = 45,

    -- OC redstone output to SFM trigger input.
    trigger_side = "south",
    pulse_strength = 15,
    pulse_on_sec = 0.0,
    pulse_off_sec = 0.0,
  },

  hot_salt_monitor = {
    -- Optional monitor for output delta logging.
    enable = false,
    side = "south",
    tank = nil,

    -- Optional wrap support if tank can roll over/void.
    wrap_capacity = nil,
  },
}

M.hardware = {
  tower = {
    -- Fill either address OR component_type.
    address = nil,
    component_type = nil,
    methods = {
      read_heat = "readHeat",
      read_reflector_count = "readReflectorCount",
      is_day = "isDay",
      is_raining_effective = "isRainingEffective",
      read_hot_salt_delta = "readHotSaltDelta",
    },
  },
  valve = {
    -- Fill either address OR component_type.
    address = nil,
    component_type = nil,
    methods = {
      inject_exact = "injectColdSaltExact",
    },
  },
}

-- Providers override hardware methods. Use this when your OC setup
-- reads telemetry through custom wrappers instead of direct component calls.
M.providers = {
  -- read_heat = function() return 50000 end,
  -- read_reflector_count = function() return 340 end,
  -- is_day = function() return true end,
  -- is_raining_effective = function() return false end,
  -- inject_exact = function(liters) return true, liters end,
  -- read_hot_salt_delta = function() return 0 end,
}

if M.ingame.enable then
  local ok, integration = pcall(require, "solar_tower.providers.ingame_model")
  if ok and integration and type(integration.build) == "function" then
    local providers, err = integration.build(M)
    if providers ~= nil then
      M.providers = providers
    else
      error("[solar_tower] in-game provider init failed: " .. tostring(err))
    end
  else
    error("[solar_tower] failed to load in-game provider module")
  end
end

return M
