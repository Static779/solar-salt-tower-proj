local M = {}

local SIDE_MAP = {
  down = 0,
  up = 1,
  north = 2,
  south = 3,
  west = 4,
  east = 5,
}

local function to_integer(value)
  if type(value) == "number" then
    return math.floor(value)
  end
  if type(value) == "string" then
    local n = tonumber(value)
    if n ~= nil then
      return math.floor(n)
    end
  end
  return nil
end

local function to_number(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value)
  end
  return nil
end

local function clamp_integer(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

local function parse_side(value)
  if type(value) == "number" then
    local side = math.floor(value)
    if side >= 0 and side <= 5 then
      return side
    end
    return nil
  end

  if type(value) == "string" then
    local normalized = value:lower()
    return SIDE_MAP[normalized]
  end

  return nil
end

local function resolve_component(component_lib, spec, default_type, required)
  local target_type = default_type
  local address = nil

  if type(spec) == "table" then
    if type(spec.address) == "string" and spec.address ~= "" then
      address = spec.address
    end
    if type(spec.component_type) == "string" and spec.component_type ~= "" then
      target_type = spec.component_type
    end
  end

  if address ~= nil then
    local ok, proxy = pcall(component_lib.proxy, address)
    if ok and proxy ~= nil then
      return proxy
    end
    return nil, "failed to resolve component address: " .. tostring(address)
  end

  if target_type == nil then
    if required then
      return nil, "missing component type"
    end
    return nil
  end

  local iter = component_lib.list(target_type)
  if iter == nil then
    if required then
      return nil, "component.list returned nil for type: " .. tostring(target_type)
    end
    return nil
  end

  local found = nil
  for addr, _ in iter do
    found = addr
    break
  end

  if found == nil then
    if required then
      return nil, "no component found for type: " .. tostring(target_type)
    end
    return nil
  end

  local ok, proxy = pcall(component_lib.proxy, found)
  if ok and proxy ~= nil then
    return proxy
  end

  if required then
    return nil, "failed to proxy component type: " .. tostring(target_type)
  end
  return nil
end

local function compute_efficiency(heat, target_heat)
  local delta = math.abs(heat - target_heat)
  local eff = (7000 - (delta ^ 0.8)) / 7000
  if eff < 0 then
    return 0
  end
  if eff > 1 then
    return 1
  end
  return eff
end

local function compute_gain(heat, is_day, is_rain, constants)
  local eff = compute_efficiency(heat, constants.target_heat)
  if not is_day then
    return 0, eff
  end

  local heaters = constants.heater_count
  if is_rain then
    heaters = math.floor(heaters / 2)
  end

  local gain = math.floor(heaters * eff * (10 + constants.tier_bonus))
  if gain < 0 then
    gain = 0
  end
  return gain, eff
end

local function apply_cycle(heat, is_day, is_rain, inserted, constants)
  local gain, _ = compute_gain(heat, is_day, is_rain, constants)
  local pre = heat + gain
  if pre > 0 then
    if pre > constants.max_heat then
      pre = constants.max_heat
    else
      pre = pre - constants.passive_loss_per_cycle
    end
  end

  local converted = 0
  if pre >= constants.min_convert_heat then
    converted = inserted
    if converted > pre then
      converted = pre
    end
  end

  local next_heat = pre - converted
  if next_heat < 0 then
    next_heat = 0
  end

  return next_heat
end

local function sleep_seconds(seconds)
  if seconds == nil or seconds <= 0 then
    return
  end

  local ok_event, event = pcall(require, "event")
  if ok_event and event ~= nil and type(event.pull) == "function" then
    event.pull(seconds)
    return
  end

  local ok_computer, computer = pcall(require, "computer")
  if ok_computer and computer ~= nil and type(computer.pullSignal) == "function" then
    computer.pullSignal(seconds)
    return
  end

  local start = os.clock()
  while (os.clock() - start) < seconds do
    -- Fallback for non-OC simulation environments.
  end
end

function M.build(config)
  local ok_component, component = pcall(require, "component")
  if not ok_component or component == nil then
    return nil, "OpenComputers component library is unavailable"
  end

  local constants = config.constants or {}
  local safety = config.safety or {}
  local ingame = config.ingame or {}
  local valve_mode = tostring(ingame.valve_mode or "transposer_exact"):lower()
  if valve_mode ~= "transposer_exact" and valve_mode ~= "sfm_pulse" then
    return nil, "invalid ingame.valve_mode (expected transposer_exact or sfm_pulse)"
  end

  local redstone_cfg = ingame.redstone or {}
  local transposer_cfg = ingame.transposer or {}
  local hot_cfg = ingame.hot_salt_monitor or {}
  local sfm_cfg = ingame.sfm or {}

  local geolyzer, geolyzer_err = resolve_component(component, ingame.geolyzer, "geolyzer", true)
  if geolyzer == nil then
    return nil, geolyzer_err
  end
  if type(geolyzer.isSunVisible) ~= "function" then
    return nil, "geolyzer is missing isSunVisible()"
  end

  local transposer = nil
  local needs_transposer = (valve_mode == "transposer_exact") or (hot_cfg.enable == true)
  if needs_transposer then
    local transposer_err
    transposer, transposer_err = resolve_component(component, transposer_cfg, "transposer", true)
    if transposer == nil then
      return nil, transposer_err
    end
  else
    transposer = select(1, resolve_component(component, transposer_cfg, "transposer", false))
  end

  local explicit_redstone =
    (type(redstone_cfg.address) == "string" and redstone_cfg.address ~= "")
    or (type(redstone_cfg.component_type) == "string" and redstone_cfg.component_type ~= "")
  local redstone_required = valve_mode == "sfm_pulse"
  local redstone = nil
  if explicit_redstone then
    local redstone_err
    redstone, redstone_err = resolve_component(component, redstone_cfg, "redstone", redstone_required)
    if redstone == nil and redstone_required then
      return nil, redstone_err
    end
  else
    local redstone_err
    redstone, redstone_err = resolve_component(component, { component_type = "redstone" }, "redstone", redstone_required)
    if redstone == nil and redstone_required then
      return nil, redstone_err
    end
  end

  local source_side = nil
  local sink_side = nil
  local source_tank = nil
  if valve_mode == "transposer_exact" then
    source_side = parse_side(transposer_cfg.source_side or "west")
    sink_side = parse_side(transposer_cfg.sink_side or "east")
    if source_side == nil or sink_side == nil then
      return nil, "invalid transposer source/sink side"
    end

    if transposer_cfg.source_tank ~= nil then
      source_tank = to_integer(transposer_cfg.source_tank)
      if source_tank == nil then
        return nil, "invalid transposer source_tank"
      end
    end
  end

  local day_sensor_side = parse_side(redstone_cfg.daylight_sensor_side or "north")
  local day_threshold = to_integer(redstone_cfg.day_threshold)
  if day_threshold == nil then
    day_threshold = 0
  end
  if day_sensor_side == nil then
    day_sensor_side = SIDE_MAP.north
  end

  local sfm_liters_per_pulse = to_integer(sfm_cfg.liters_per_pulse) or 1000
  if sfm_liters_per_pulse <= 0 then
    return nil, "ingame.sfm.liters_per_pulse must be > 0"
  end

  local sfm_round_mode = tostring(sfm_cfg.round_mode or "floor"):lower()
  if sfm_round_mode ~= "floor" and sfm_round_mode ~= "nearest" then
    return nil, "ingame.sfm.round_mode must be floor or nearest"
  end

  local sfm_max_pulses = to_integer(sfm_cfg.max_pulses_per_cycle)
  if sfm_max_pulses == nil then
    sfm_max_pulses = 45
  end
  if sfm_max_pulses < 0 then
    return nil, "ingame.sfm.max_pulses_per_cycle must be >= 0"
  end

  local sfm_trigger_side = parse_side(sfm_cfg.trigger_side or "south")
  if sfm_trigger_side == nil then
    return nil, "invalid ingame.sfm.trigger_side"
  end
  local sfm_pulse_strength = to_integer(sfm_cfg.pulse_strength) or 15
  sfm_pulse_strength = clamp_integer(sfm_pulse_strength, 0, 15)
  local sfm_pulse_on_sec = to_number(sfm_cfg.pulse_on_sec)
  if sfm_pulse_on_sec == nil then
    sfm_pulse_on_sec = 0.0
  end
  if sfm_pulse_on_sec < 0 then
    sfm_pulse_on_sec = 0
  end
  local sfm_pulse_off_sec = to_number(sfm_cfg.pulse_off_sec)
  if sfm_pulse_off_sec == nil then
    sfm_pulse_off_sec = 0.0
  end
  if sfm_pulse_off_sec < 0 then
    sfm_pulse_off_sec = 0
  end

  if valve_mode == "sfm_pulse" then
    if redstone == nil then
      return nil, "sfm_pulse mode requires a redstone component"
    end
    if type(redstone.setOutput) ~= "function" then
      return nil, "redstone component is missing setOutput()"
    end
    pcall(redstone.setOutput, sfm_trigger_side, 0)
  end

  local hot_side = parse_side(hot_cfg.side or "south")
  local hot_tank = nil
  if hot_cfg.tank ~= nil then
    hot_tank = to_integer(hot_cfg.tank)
  end
  local hot_wrap = nil
  if hot_cfg.wrap_capacity ~= nil then
    hot_wrap = to_integer(hot_cfg.wrap_capacity)
  end

  local model_constants = {
    target_heat = to_integer(constants.target_heat) or 50000,
    min_convert_heat = to_integer(constants.min_convert_heat) or 30000,
    max_heat = to_integer(constants.max_heat) or 100000,
    passive_loss_per_cycle = to_integer(constants.passive_loss_per_cycle) or 10,
    heater_count = to_integer(constants.heater_count) or 340,
    tier_bonus = to_integer(constants.tier_bonus) or 16,
  }

  local state = {
    initialized = false,
    heat = to_integer(ingame.initial_heat) or 100000,
    pending_insert = 0,
    previous_day = true,
    previous_rain = false,
    cached_day = nil,
    cached_rain = nil,
    hot_previous_level = nil,
    sfm_carry_liters = 0,
  }

  local function clear_weather_cache()
    state.cached_day = nil
    state.cached_rain = nil
  end

  local function read_day_from_redstone()
    if redstone == nil or type(redstone.getInput) ~= "function" then
      return nil
    end
    local ok, level = pcall(redstone.getInput, day_sensor_side)
    if not ok or type(level) ~= "number" then
      return nil
    end
    return level > day_threshold
  end

  local function detect_day_and_rain()
    local redstone_day = read_day_from_redstone()
    local ok_sun, sun_visible = pcall(geolyzer.isSunVisible)
    if not ok_sun then
      return nil, nil, "geolyzer.isSunVisible failed: " .. tostring(sun_visible)
    end
    local sun = sun_visible == true

    local day
    if redstone_day ~= nil then
      day = redstone_day
    else
      day = sun
    end

    local rain = false
    if day and (not sun) then
      rain = true
    end

    return day, rain, nil
  end

  local function advance_model()
    local current_day, current_rain, env_err = detect_day_and_rain()
    if env_err ~= nil then
      return nil, env_err
    end

    if state.initialized then
      state.heat = apply_cycle(
        state.heat,
        state.previous_day,
        state.previous_rain,
        state.pending_insert,
        model_constants
      )
      state.pending_insert = 0
    else
      state.initialized = true
    end

    state.previous_day = current_day
    state.previous_rain = current_rain
    state.cached_day = current_day
    state.cached_rain = current_rain

    return state.heat
  end

  local providers = {}

  function providers.read_heat()
    local heat, err = advance_model()
    if heat == nil then
      return nil, err
    end
    return heat
  end

  function providers.read_reflector_count()
    return to_integer(safety.expected_reflector_count) or 340
  end

  function providers.is_day()
    if state.cached_day == nil then
      local day, rain, err = detect_day_and_rain()
      if err ~= nil then
        return nil, err
      end
      state.cached_day = day
      state.cached_rain = rain
    end
    return state.cached_day
  end

  function providers.is_raining_effective()
    if state.cached_rain == nil then
      local day, rain, err = detect_day_and_rain()
      if err ~= nil then
        return nil, err
      end
      state.cached_day = day
      state.cached_rain = rain
    end
    return state.cached_rain
  end

  function providers.inject_exact(liters)
    local amount = to_integer(liters)
    if amount == nil then
      return false, "invalid insert amount"
    end
    if amount <= 0 then
      state.pending_insert = 0
      return true, 0
    end

    if valve_mode == "transposer_exact" then
      local ok_call, ok, moved
      if source_tank ~= nil then
        ok_call, ok, moved = pcall(transposer.transferFluid, source_side, sink_side, amount, source_tank)
      else
        ok_call, ok, moved = pcall(transposer.transferFluid, source_side, sink_side, amount)
      end
      if not ok_call then
        return false, "transferFluid call failed: " .. tostring(ok)
      end
      if ok ~= true then
        return false, "transferFluid returned false"
      end

      local moved_amount = to_integer(moved) or 0
      if moved_amount < amount then
        return false, "partial transfer " .. tostring(moved_amount) .. "/" .. tostring(amount)
      end

      state.pending_insert = moved_amount
      clear_weather_cache()
      return true, moved_amount
    end

    local request_liters = amount + state.sfm_carry_liters
    local pulses
    if sfm_round_mode == "nearest" then
      pulses = math.floor((request_liters / sfm_liters_per_pulse) + 0.5)
    else
      pulses = math.floor(request_liters / sfm_liters_per_pulse)
    end
    if pulses < 0 then
      pulses = 0
    end
    if pulses > sfm_max_pulses then
      pulses = sfm_max_pulses
    end

    local moved_amount = pulses * sfm_liters_per_pulse
    state.sfm_carry_liters = request_liters - moved_amount

    for i = 1, pulses do
      local ok_high, err_high = pcall(redstone.setOutput, sfm_trigger_side, sfm_pulse_strength)
      if not ok_high then
        pcall(redstone.setOutput, sfm_trigger_side, 0)
        return false, "SFM pulse high failed: " .. tostring(err_high)
      end
      sleep_seconds(sfm_pulse_on_sec)

      local ok_low, err_low = pcall(redstone.setOutput, sfm_trigger_side, 0)
      if not ok_low then
        return false, "SFM pulse low failed: " .. tostring(err_low)
      end

      if i < pulses then
        sleep_seconds(sfm_pulse_off_sec)
      end
    end

    state.pending_insert = moved_amount
    clear_weather_cache()

    -- In sfm_pulse mode insertion is quantized; return success only.
    -- io.lua treats a boolean-only success as a valid actuation.
    return true
  end

  function providers.read_hot_salt_delta()
    if hot_cfg.enable ~= true then
      return nil, "hot salt monitor disabled"
    end
    if hot_side == nil then
      return nil, "invalid hot monitor side"
    end
    if transposer == nil then
      return nil, "hot salt monitor requires transposer"
    end

    local ok_level, level
    if hot_tank ~= nil then
      ok_level, level = pcall(transposer.getTankLevel, hot_side, hot_tank)
    else
      ok_level, level = pcall(transposer.getTankLevel, hot_side)
    end
    if not ok_level then
      return nil, "transposer.getTankLevel failed: " .. tostring(level)
    end
    if type(level) ~= "number" then
      return nil, "unable to read hot salt tank level"
    end

    local now = math.floor(level)
    if state.hot_previous_level == nil then
      state.hot_previous_level = now
      return 0
    end

    local delta = now - state.hot_previous_level
    if delta < 0 and hot_wrap ~= nil then
      delta = delta + hot_wrap
    end
    state.hot_previous_level = now
    return delta
  end

  return providers
end

return M
