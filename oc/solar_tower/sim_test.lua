package.path = "./oc/?.lua;./oc/?/init.lua;./?.lua;" .. package.path

local base_config = require("solar_tower.config")
local control = require("solar_tower.control")

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

local function assert_true(condition, message)
  if not condition then
    error(message, 2)
  end
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assert_eq failed") .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual), 2)
  end
end

local function assert_near(actual, expected, tolerance, message)
  local diff = math.abs(actual - expected)
  if diff > tolerance then
    error((message or "assert_near failed")
      .. " expected=" .. tostring(expected)
      .. " actual=" .. tostring(actual)
      .. " tolerance=" .. tostring(tolerance), 2)
  end
end

local function weather_from_schedule(schedule, cycle_index)
  if type(schedule) == "function" then
    local day, rain = schedule(cycle_index)
    return day == true, rain == true
  end
  return true, false
end

local function compute_gain(constants, heat, is_day, is_rain)
  local eff = (7000 - (math.abs(heat - constants.target_heat) ^ 0.8)) / 7000
  if eff < 0 then
    eff = 0
  elseif eff > 1 then
    eff = 1
  end
  if not is_day then
    return 0
  end
  local heaters = constants.heater_count
  if is_rain then
    heaters = math.floor(heaters / 2)
  end
  return math.floor(heaters * eff * (10 + constants.tier_bonus))
end

local function apply_world_step(state, cfg, schedule)
  local constants = cfg.constants
  local cycle_index = state.cycle + 1
  local is_day, is_rain = weather_from_schedule(schedule, cycle_index)

  local gain = compute_gain(constants, state.heat, is_day, is_rain)
  local h = state.heat + gain
  if h > 0 then
    if h > constants.max_heat then
      h = constants.max_heat
    else
      h = h - constants.passive_loss_per_cycle
    end
  end

  local converted = 0
  if h >= constants.min_convert_heat then
    converted = math.min(state.pending_insert, h)
    h = h - converted
  end

  state.heat = h
  state.last_hot_delta = converted
  state.pending_insert = 0
  state.cycle = state.cycle + 1
end

local function run_scenario(name, options)
  local cfg = deep_copy(base_config)
  cfg.logging.enabled = false
  if options.fault_hold_cycles ~= nil then
    cfg.runtime.fault_hold_cycles = options.fault_hold_cycles
  end

  local state = {
    cycle = 0,
    heat = options.initial_heat or 100000,
    pending_insert = 0,
    last_hot_delta = 0,
  }

  local fail_heat_cycles = options.fail_heat_cycles or {}
  local fail_valve_cycles = options.fail_valve_cycles or {}
  local reflectors = options.reflectors or 340
  local schedule = options.schedule

  local io_api = {
    Tower = {
      read_heat = function()
        local next_cycle = state.cycle + 1
        if fail_heat_cycles[next_cycle] then
          return nil, "simulated heat telemetry failure"
        end
        return state.heat
      end,
      read_reflector_count = function()
        return reflectors
      end,
    },
    Env = {
      is_day = function()
        local day = weather_from_schedule(schedule, state.cycle + 1)
        return day
      end,
      is_raining_effective = function()
        local _, rain = weather_from_schedule(schedule, state.cycle + 1)
        return rain
      end,
    },
    Valve = {
      inject_exact = function(liters)
        local next_cycle = state.cycle + 1
        if fail_valve_cycles[next_cycle] then
          return false, "simulated valve failure"
        end
        state.pending_insert = math.floor(liters)
        return true, state.pending_insert
      end,
    },
    Optional = {
      read_hot_salt_delta = function()
        return state.last_hot_delta
      end,
    },
  }

  local runtime = {
    now = function()
      return state.cycle * cfg.runtime.cycle_seconds
    end,
    sleep = function(_)
      -- Not used by step-based simulation.
    end,
    cycle_seconds = cfg.runtime.cycle_seconds,
    fault_hold_cycles = cfg.runtime.fault_hold_cycles,
  }

  local controller = control.new(cfg, io_api, runtime)
  local records = {}
  local cycles = options.cycles or 8

  for i = 1, cycles do
    records[i] = controller:step()
    apply_world_step(state, cfg, schedule)
  end

  return records, state
end

local function run_tests()
  do
    local records = run_scenario("startup_clear", {
      initial_heat = 100000,
      schedule = function(_)
        return true, false
      end,
      cycles = 5,
    })
    assert_eq(records[1].insert, 50000, "clear startup cycle 1 insert")
    assert_eq(records[2].insert, 8830, "clear startup cycle 2 insert")
    assert_eq(records[5].insert, 8830, "clear steady insert")
  end

  do
    local records = run_scenario("startup_rain", {
      initial_heat = 100000,
      schedule = function(_)
        return true, true
      end,
      cycles = 4,
    })
    assert_eq(records[1].insert, 50000, "rain startup cycle 1 insert")
    assert_eq(records[2].insert, 4410, "rain startup cycle 2 insert")
  end

  do
    local records = run_scenario("startup_night", {
      initial_heat = 100000,
      schedule = function(_)
        return false, false
      end,
      cycles = 3,
    })
    assert_eq(records[1].insert, 49990, "night startup cycle 1 insert")
    assert_eq(records[2].insert, 0, "night cycle 2 insert")
  end

  do
    local records = run_scenario("recovery", {
      initial_heat = 48000,
      schedule = function(_)
        return true, false
      end,
      cycles = 4,
    })
    assert_eq(records[1].state, "RECOVERY", "recovery state when below target")
    assert_eq(records[1].insert, 0, "recovery insert should be zero")
    assert_true(records[2].insert >= 0, "controller continues after recovery cycle")
  end

  do
    local records = run_scenario("transition_clear_to_rain", {
      initial_heat = 100000,
      schedule = function(cycle_index)
        if cycle_index <= 3 then
          return true, false
        end
        return true, true
      end,
      cycles = 6,
    })
    assert_eq(records[2].insert, 8830, "transition clear insert")
    assert_eq(records[4].insert, 4410, "transition rain insert")
  end

  do
    local records = run_scenario("telemetry_fault", {
      initial_heat = 100000,
      schedule = function(_)
        return true, false
      end,
      fail_heat_cycles = { [2] = true },
      fault_hold_cycles = 2,
      cycles = 6,
    })
    assert_eq(records[2].state, "FAULT", "telemetry failure must enter fault")
    assert_eq(records[2].insert, 0, "fault must hold insert at zero")
    assert_true(records[4].state == "RUN" or records[4].state == "RECOVERY", "fault should clear after hold")
  end

  do
    local records = run_scenario("reflector_mismatch", {
      initial_heat = 100000,
      reflectors = 339,
      schedule = function(_)
        return true, false
      end,
      cycles = 3,
    })
    assert_eq(records[1].state, "FAULT", "reflector mismatch must fault")
    assert_eq(records[1].insert, 0, "reflector mismatch insert must be zero")
    assert_eq(records[3].state, "FAULT", "reflector mismatch remains in fault")
  end

  print("All simulation tests passed.")
end

run_tests()
