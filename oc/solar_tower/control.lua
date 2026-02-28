local M = {}

local function try_require(name)
  local ok, mod = pcall(require, name)
  if ok then
    return mod
  end
  return nil
end

local function clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

local function default_now()
  local computer = try_require("computer")
  if computer ~= nil and type(computer.uptime) == "function" then
    return computer.uptime()
  end
  return os.clock()
end

local function default_sleep(seconds)
  if seconds == nil or seconds <= 0 then
    return
  end

  local event = try_require("event")
  if event ~= nil and type(event.pull) == "function" then
    event.pull(seconds)
    return
  end

  local computer = try_require("computer")
  if computer ~= nil and type(computer.pullSignal) == "function" then
    computer.pullSignal(seconds)
    return
  end

  local started = os.clock()
  while (os.clock() - started) < seconds do
    -- Busy wait fallback only for non-OC environments.
  end
end

local Controller = {}
Controller.__index = Controller

local function format_eff(value)
  if type(value) ~= "number" then
    return "nil"
  end
  return string.format("%.6f", value)
end

local function format_value(value)
  if value == nil then
    return "nil"
  end
  return tostring(value)
end

function Controller:_emit(record)
  if self.logging.enabled == false then
    return
  end

  if type(self.logging.logger) == "function" then
    pcall(self.logging.logger, record)
    return
  end

  local parts = {
    self.logging.prefix or "[solar_tower]",
    "ts=" .. format_value(record.timestamp),
    "cycle=" .. format_value(record.cycle),
    "state=" .. format_value(record.state),
    "heat=" .. format_value(record.heat),
    "reflectors=" .. format_value(record.reflectors),
    "weather=" .. format_value(record.weather),
    "eff=" .. format_eff(record.eff),
    "gain=" .. format_value(record.gain),
    "pre=" .. format_value(record.pre_conversion_heat),
    "insert=" .. format_value(record.insert),
    "fault=" .. format_value(record.fault),
    "reason=" .. format_value(record.reason),
  }

  if record.note ~= nil then
    table.insert(parts, "note=" .. tostring(record.note))
  end
  if self.logging.include_hot_salt_delta and record.hot_salt_delta ~= nil then
    table.insert(parts, "hot_delta=" .. tostring(record.hot_salt_delta))
  end

  print(table.concat(parts, " "))
end

function Controller:_validate_config()
  if type(self.io) ~= "table" then
    return "io API table is required"
  end

  if type(self.io.Tower) ~= "table" or type(self.io.Tower.read_heat) ~= "function" then
    return "io.Tower.read_heat is required"
  end
  if type(self.io.Tower.read_reflector_count) ~= "function" then
    return "io.Tower.read_reflector_count is required"
  end
  if type(self.io.Env) ~= "table" or type(self.io.Env.is_day) ~= "function" then
    return "io.Env.is_day is required"
  end
  if type(self.io.Env.is_raining_effective) ~= "function" then
    return "io.Env.is_raining_effective is required"
  end
  if type(self.io.Valve) ~= "table" or type(self.io.Valve.inject_exact) ~= "function" then
    return "io.Valve.inject_exact is required"
  end

  if self.runtime.cycle_seconds <= 0 then
    return "runtime.cycle_seconds must be > 0"
  end
  if self.runtime.fault_hold_cycles <= 0 then
    return "runtime.fault_hold_cycles must be > 0"
  end
  if self.constants.heater_count <= 0 then
    return "constants.heater_count must be > 0"
  end
  if self.safety.max_insert_per_cycle <= 0 then
    return "safety.max_insert_per_cycle must be > 0"
  end

  return nil
end

function Controller:_enter_fault(code)
  self.state = "FAULT"
  self.fault_code = code
  self.fault_stable_cycles = 0
end

function Controller:_read_telemetry()
  local heat, err_heat = self.io.Tower.read_heat()
  if heat == nil then
    return nil, "read_heat failed: " .. tostring(err_heat)
  end

  local reflectors, err_ref = self.io.Tower.read_reflector_count()
  if reflectors == nil then
    return nil, "read_reflector_count failed: " .. tostring(err_ref)
  end

  local is_day, err_day = self.io.Env.is_day()
  if is_day == nil then
    return nil, "is_day failed: " .. tostring(err_day)
  end

  local is_rain, err_rain = self.io.Env.is_raining_effective()
  if is_rain == nil then
    return nil, "is_raining_effective failed: " .. tostring(err_rain)
  end

  return {
    heat = math.floor(heat),
    reflectors = math.floor(reflectors),
    is_day = is_day,
    is_rain = is_rain,
  }
end

function Controller:_compute_efficiency(heat)
  local delta = math.abs(heat - self.constants.target_heat)
  local eff = (7000 - (delta ^ 0.8)) / 7000
  if eff < 0 then
    return 0
  end
  if eff > 1 then
    return 1
  end
  return eff
end

function Controller:_weather_mode(is_day, is_rain)
  if not is_day then
    return "NIGHT"
  end
  if is_rain then
    return "DAY_RAIN"
  end
  return "DAY_CLEAR"
end

function Controller:_compute_gain(heat, is_day, is_rain)
  local eff = self:_compute_efficiency(heat)
  if not is_day then
    return 0, eff
  end

  local heater_count = self.constants.heater_count
  if is_rain then
    heater_count = math.floor(heater_count / 2)
  end

  local gain = math.floor(heater_count * eff * (10 + self.constants.tier_bonus))
  if gain < 0 then
    gain = 0
  end
  return gain, eff
end

function Controller:_apply_pre_conversion_heat(heat, gain)
  local h = heat + gain
  if h > 0 then
    if h > self.constants.max_heat then
      h = self.constants.max_heat
    else
      h = h - self.constants.passive_loss_per_cycle
    end
  end
  return h
end

function Controller:_plan_insertion(heat, is_day, is_rain)
  local gain, eff = self:_compute_gain(heat, is_day, is_rain)
  local pre = self:_apply_pre_conversion_heat(heat, gain)

  local insert = 0
  local reason = "NORMAL"

  if heat < self.constants.min_insert_heat then
    reason = "RECOVERY_HEAT_BELOW_TARGET"
  elseif pre < self.constants.min_convert_heat then
    reason = "PRE_HEAT_BELOW_CONVERSION_GATE"
  else
    insert = pre - self.constants.target_heat
    if insert < 0 then
      insert = 0
    end
    insert = clamp(insert, 0, self.safety.max_insert_per_cycle)
  end

  return {
    gain = gain,
    eff = eff,
    pre_conversion_heat = pre,
    insert = insert,
    reason = reason,
    weather = self:_weather_mode(is_day, is_rain),
  }
end

function Controller:_sleep_to_cycle_boundary()
  if not self.runtime.align_to_cycle_boundary then
    self.runtime.sleep(self.runtime.cycle_seconds)
    return
  end

  local now = self.runtime.now()
  local cycle = self.runtime.cycle_seconds
  local next_boundary = (math.floor(now / cycle) + 1) * cycle
  local delay = next_boundary - now
  if delay < 0 then
    delay = cycle
  end
  self.runtime.sleep(delay)
end

function Controller:step()
  self.cycle_counter = self.cycle_counter + 1
  local record = {
    timestamp = self.runtime.now(),
    cycle = self.cycle_counter,
    state = self.state,
    insert = 0,
    fault = self.fault_code,
  }

  if self.config_error ~= nil then
    self:_enter_fault("CONFIG_ERROR:" .. self.config_error)
    record.state = self.state
    record.fault = self.fault_code
    record.reason = self.config_error
    self:_emit(record)
    return record
  end

  local telemetry, telemetry_err = self:_read_telemetry()
  if telemetry == nil then
    self:_enter_fault("TELEMETRY_ERROR")
    record.state = self.state
    record.fault = self.fault_code
    record.reason = telemetry_err
    self:_emit(record)
    return record
  end

  record.heat = telemetry.heat
  record.reflectors = telemetry.reflectors

  if self.safety.enforce_reflector_count and telemetry.reflectors ~= self.safety.expected_reflector_count then
    self:_enter_fault("REFLECTOR_MISMATCH")
    record.state = self.state
    record.fault = self.fault_code
    record.reason = "expected " .. tostring(self.safety.expected_reflector_count)
      .. ", got " .. tostring(telemetry.reflectors)
    record.weather = self:_weather_mode(telemetry.is_day, telemetry.is_rain)
    self:_emit(record)
    return record
  end

  if self.state == "INIT" then
    if telemetry.heat < self.constants.min_insert_heat then
      self.state = "RECOVERY"
    else
      self.state = "RUN"
    end
  end

  if self.state == "FAULT" then
    self.fault_stable_cycles = self.fault_stable_cycles + 1
    record.reason = "FAULT_HOLD"
    record.weather = self:_weather_mode(telemetry.is_day, telemetry.is_rain)
    if self.fault_stable_cycles >= self.runtime.fault_hold_cycles then
      self.fault_stable_cycles = 0
      self.fault_code = nil
      if telemetry.heat < self.constants.min_insert_heat then
        self.state = "RECOVERY"
      else
        self.state = "RUN"
      end
      record.note = "FAULT_CLEARED"
    end
    record.state = self.state
    record.fault = self.fault_code
    self:_emit(record)
    return record
  end

  if self.state == "RECOVERY" and telemetry.heat < self.constants.min_insert_heat then
    record.state = "RECOVERY"
    record.reason = "HEAT_BELOW_TARGET"
    record.weather = self:_weather_mode(telemetry.is_day, telemetry.is_rain)
    self:_emit(record)
    return record
  end

  if self.state == "RECOVERY" and telemetry.heat >= self.constants.min_insert_heat then
    self.state = "RUN"
  end

  local plan = self:_plan_insertion(telemetry.heat, telemetry.is_day, telemetry.is_rain)
  record.state = self.state
  record.weather = plan.weather
  record.eff = plan.eff
  record.gain = plan.gain
  record.pre_conversion_heat = plan.pre_conversion_heat
  record.insert = plan.insert
  record.reason = plan.reason

  if plan.insert > 0 then
    local ok, inject_err = self.io.Valve.inject_exact(plan.insert)
    if not ok then
      self:_enter_fault("VALVE_ERROR")
      record.state = self.state
      record.fault = self.fault_code
      record.reason = "inject failed: " .. tostring(inject_err)
      record.insert = 0
      self:_emit(record)
      return record
    end
  end

  if self.logging.include_hot_salt_delta and self.io.Optional and type(self.io.Optional.read_hot_salt_delta) == "function" then
    local delta = self.io.Optional.read_hot_salt_delta()
    if delta ~= nil then
      record.hot_salt_delta = delta
    end
  end

  record.fault = self.fault_code
  self:_emit(record)
  return record
end

function Controller:run(max_cycles)
  local cycles = 0
  while true do
    self:step()
    cycles = cycles + 1
    if max_cycles ~= nil and cycles >= max_cycles then
      return true
    end
    if type(self.runtime.should_stop) == "function" and self.runtime.should_stop() then
      return true
    end
    self:_sleep_to_cycle_boundary()
  end
end

function M.new(config, io_api, runtime_override)
  local cfg = config or {}
  local constants = cfg.constants or {}
  local runtime_cfg = cfg.runtime or {}
  local safety = cfg.safety or {}
  local logging = cfg.logging or {}
  local runtime_override_safe = runtime_override or {}

  local self = setmetatable({}, Controller)
  self.io = io_api
  self.state = "INIT"
  self.fault_code = nil
  self.fault_stable_cycles = 0
  self.cycle_counter = 0

  self.constants = {
    target_heat = tonumber(constants.target_heat) or 50000,
    min_insert_heat = tonumber(constants.min_insert_heat) or 50000,
    min_convert_heat = tonumber(constants.min_convert_heat) or 30000,
    max_heat = tonumber(constants.max_heat) or 100000,
    passive_loss_per_cycle = tonumber(constants.passive_loss_per_cycle) or 10,
    heater_count = tonumber(constants.heater_count) or 340,
    tier_bonus = tonumber(constants.tier_bonus) or 16,
  }

  self.runtime = {
    now = runtime_override_safe.now or default_now,
    sleep = runtime_override_safe.sleep or default_sleep,
    cycle_seconds = tonumber(runtime_override_safe.cycle_seconds) or tonumber(runtime_cfg.cycle_seconds) or 10,
    fault_hold_cycles = tonumber(runtime_override_safe.fault_hold_cycles) or tonumber(runtime_cfg.fault_hold_cycles) or 3,
    align_to_cycle_boundary = runtime_cfg.align_to_cycle_boundary ~= false,
    should_stop = runtime_override_safe.should_stop,
  }

  self.safety = {
    max_insert_per_cycle = tonumber(safety.max_insert_per_cycle) or 60000,
    enforce_reflector_count = safety.enforce_reflector_count ~= false,
    expected_reflector_count = tonumber(safety.expected_reflector_count) or 340,
  }

  self.logging = {
    enabled = logging.enabled ~= false,
    prefix = logging.prefix or "[solar_tower]",
    include_hot_salt_delta = logging.include_hot_salt_delta == true,
    logger = logging.logger,
  }

  self.config_error = self:_validate_config()
  return self
end

return M
