local function normalize_path(path)
  return (path or ""):gsub("\\", "/")
end

local function prepend_unique_path(prefix)
  if type(prefix) ~= "string" or prefix == "" then
    return
  end
  if package.path:find(prefix, 1, true) then
    return
  end
  package.path = prefix .. ";" .. package.path
end

local function setup_local_module_paths()
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  source = normalize_path(source)

  local base = source:match("^(.*)/main%.lua$")
  if base == nil then
    return
  end

  local parent = base:match("^(.*)/solar_tower$")
  if parent ~= nil then
    prepend_unique_path(parent .. "/?.lua")
    prepend_unique_path(parent .. "/?/init.lua")
  end

  prepend_unique_path(base .. "/?.lua")
  prepend_unique_path(base .. "/?/init.lua")
end

setup_local_module_paths()

local config = require("solar_tower.config")

local ok_component, component = pcall(require, "component")
if not ok_component or component == nil then
  io.stderr:write((config.log_prefix or "[solar_tower]") .. " missing component library\n")
  return
end

local ok_computer, computer = pcall(require, "computer")
local ok_event, event = pcall(require, "event")

local SIDES = {
  down = 0,
  up = 1,
  north = 2,
  south = 3,
  west = 4,
  east = 5,
}

local function now()
  if ok_computer and computer and type(computer.uptime) == "function" then
    return computer.uptime()
  end
  return os.clock()
end

local function sleep_seconds(seconds)
  if seconds == nil or seconds <= 0 then
    return
  end
  if ok_event and event and type(event.pull) == "function" then
    event.pull(seconds)
    return
  end
  if ok_computer and computer and type(computer.pullSignal) == "function" then
    computer.pullSignal(seconds)
    return
  end
  local t0 = os.clock()
  while (os.clock() - t0) < seconds do end
end

local function parse_side(side)
  if type(side) == "number" then
    side = math.floor(side)
    if side >= 0 and side <= 5 then
      return side
    end
    return nil
  end
  if type(side) == "string" then
    return SIDES[side:lower()]
  end
  return nil
end

local function resolve_component(spec, default_type, required)
  local address = nil
  local ctype = default_type
  if type(spec) == "table" then
    if type(spec.address) == "string" and spec.address ~= "" then
      address = spec.address
    end
    if type(spec.component_type) == "string" and spec.component_type ~= "" then
      ctype = spec.component_type
    end
  end

  if address ~= nil then
    local ok_proxy, proxy = pcall(component.proxy, address)
    if ok_proxy and proxy ~= nil then
      return proxy, address
    end
    return nil, nil, "failed to proxy address " .. tostring(address)
  end

  if ctype == nil then
    if required then
      return nil, nil, "neither address nor component_type configured"
    end
    return nil, nil
  end

  local iter = component.list(ctype)
  if iter == nil then
    if required then
      return nil, nil, "component type not found: " .. tostring(ctype)
    end
    return nil, nil
  end

  for addr, _ in iter do
    local ok_proxy, proxy = pcall(component.proxy, addr)
    if ok_proxy and proxy ~= nil then
      return proxy, addr
    end
  end

  if required then
    return nil, nil, "no component instance found for type " .. tostring(ctype)
  end
  return nil, nil
end

local function strip_mc_codes(line)
  line = tostring(line or "")
  line = line:gsub("\194\167.", "")
  line = line:gsub("\167.", "")
  return line
end

local function flatten_strings(value, out, seen)
  if type(value) == "string" then
    out[#out + 1] = value
    return
  end
  if type(value) ~= "table" then
    return
  end
  if seen[value] then
    return
  end
  seen[value] = true

  for _, v in ipairs(value) do
    flatten_strings(v, out, seen)
  end
  for _, v in pairs(value) do
    flatten_strings(v, out, seen)
  end
end

local function parse_sensor_info(payload)
  local lines = {}
  flatten_strings(payload, lines, {})

  local heat = nil
  local reflectors = nil
  for i = 1, #lines do
    local line = strip_mc_codes(lines[i])
    if heat == nil then
      local h = line:match("[Ii]nternal%s*[Hh]eat%s*[Ll]evel:%s*(-?%d+)")
      if h ~= nil then
        heat = tonumber(h)
      end
    end
    if reflectors == nil then
      local r = line:match("[Cc]onnected%s*[Ss]olar%s*[Rr]eflectors:%s*(%d+)")
      if r ~= nil then
        reflectors = tonumber(r)
      end
    end
  end

  return heat, reflectors
end

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local function compute_efficiency(heat)
  local delta = math.abs(heat - config.target_heat)
  local eff = (7000 - (delta ^ 0.8)) / 7000
  return clamp(eff, 0, 1)
end

local function compute_insert(heat, is_day, is_rain)
  local eff = compute_efficiency(heat)
  local gain = 0
  if is_day then
    local heaters = config.heater_count
    if is_rain then
      heaters = math.floor(heaters / 2)
    end
    gain = math.floor(heaters * eff * (10 + config.tier_bonus))
  end

  local pre = heat + gain
  if pre > 0 then
    if pre > config.max_heat then
      pre = config.max_heat
    else
      pre = pre - config.passive_loss_per_cycle
    end
  end

  local insert = 0
  local reason = "NORMAL"
  if heat < config.min_insert_heat then
    reason = "RECOVERY_HEAT_BELOW_TARGET"
  elseif pre < config.min_convert_heat then
    reason = "PRE_HEAT_BELOW_CONVERSION_GATE"
  else
    insert = clamp(pre - config.target_heat, 0, config.max_insert_per_cycle)
  end

  return insert, pre, gain, eff, reason
end

local function detect_weather(geolyzer, redstone, day_side, day_threshold)
  local ok_sun, sun_visible = pcall(geolyzer.isSunVisible)
  local clear_day = ok_sun and sun_visible == true

  local is_day = clear_day
  if redstone ~= nil and type(redstone.getInput) == "function" then
    local ok_level, level = pcall(redstone.getInput, day_side)
    if ok_level and type(level) == "number" then
      is_day = level > day_threshold
    end
  end

  local is_rain = is_day and (not clear_day)
  return is_day, is_rain
end

local function weather_name(is_day, is_rain)
  if not is_day then
    return "NIGHT"
  end
  if is_rain then
    return "DAY_RAIN"
  end
  return "DAY_CLEAR"
end

local function transfer_exact(transposer, source_side, sink_side, source_tank, amount)
  if amount <= 0 then
    return true, 0
  end

  local ok_transfer, r1, r2
  if source_tank ~= nil then
    ok_transfer, r1, r2 = pcall(transposer.transferFluid, source_side, sink_side, amount, source_tank)
  else
    ok_transfer, r1, r2 = pcall(transposer.transferFluid, source_side, sink_side, amount)
  end

  if not ok_transfer then
    return false, 0, "transferFluid call failed: " .. tostring(r1)
  end

  local moved = 0
  local success = false
  if type(r1) == "boolean" then
    success = r1
    moved = tonumber(r2) or 0
  else
    moved = tonumber(r1) or 0
    success = moved > 0
  end

  if (not success) or moved < amount then
    return false, moved, "partial transfer " .. tostring(math.floor(moved)) .. "/" .. tostring(amount)
  end

  return true, moved
end

local function log(parts)
  print(table.concat(parts, " "))
end

local sensor, sensor_addr, sensor_err = resolve_component(config.sensor, nil, true)
if sensor == nil then
  io.stderr:write((config.log_prefix or "[solar_tower]") .. " sensor init failed: " .. tostring(sensor_err) .. "\n")
  return
end

local sensor_method_name = ((config.sensor or {}).method) or "getSensorInformation"
if type(sensor[sensor_method_name]) ~= "function" then
  io.stderr:write((config.log_prefix or "[solar_tower]") .. " sensor missing method: " .. tostring(sensor_method_name) .. "\n")
  return
end

local transposer, transposer_addr, transposer_err = resolve_component(config.transposer, "transposer", true)
if transposer == nil then
  io.stderr:write((config.log_prefix or "[solar_tower]") .. " transposer init failed: " .. tostring(transposer_err) .. "\n")
  return
end
if type(transposer.transferFluid) ~= "function" then
  io.stderr:write((config.log_prefix or "[solar_tower]") .. " transposer missing transferFluid\n")
  return
end

local geolyzer, geolyzer_addr, geolyzer_err = resolve_component(config.geolyzer, "geolyzer", true)
if geolyzer == nil then
  io.stderr:write((config.log_prefix or "[solar_tower]") .. " geolyzer init failed: " .. tostring(geolyzer_err) .. "\n")
  return
end
if type(geolyzer.isSunVisible) ~= "function" then
  io.stderr:write((config.log_prefix or "[solar_tower]") .. " geolyzer missing isSunVisible\n")
  return
end

local redstone, redstone_addr = resolve_component(config.redstone_day, "redstone", false)

local source_side = parse_side((config.transposer or {}).source_side)
local sink_side = parse_side((config.transposer or {}).sink_side)
if source_side == nil or sink_side == nil then
  io.stderr:write((config.log_prefix or "[solar_tower]") .. " invalid transposer source/sink side\n")
  return
end

local day_side = parse_side(((config.redstone_day or {}).side) or "north") or SIDES.north
local day_threshold = tonumber((config.redstone_day or {}).threshold) or 0
local source_tank = (config.transposer or {}).source_tank

log({
  config.log_prefix or "[solar_tower]",
  "start",
  "sensor=" .. tostring(sensor_addr),
  "transposer=" .. tostring(transposer_addr),
  "geolyzer=" .. tostring(geolyzer_addr),
  "redstone=" .. tostring(redstone_addr),
})

local cycle = 0
while true do
  cycle = cycle + 1
  local ts = string.format("%.2f", now())

  local ok_info, payload = pcall(sensor[sensor_method_name])
  if not ok_info then
    log({
      config.log_prefix or "[solar_tower]",
      "ts=" .. ts,
      "cycle=" .. tostring(cycle),
      "state=FAULT",
      "insert=0",
      "reason=sensor read failed: " .. tostring(payload),
    })
  else
    local heat, reflectors = parse_sensor_info(payload)
    if type(heat) ~= "number" then
      log({
        config.log_prefix or "[solar_tower]",
        "ts=" .. ts,
        "cycle=" .. tostring(cycle),
        "state=FAULT",
        "insert=0",
        "reason=unable to parse Internal Heat Level",
      })
    elseif config.enforce_reflector_count and reflectors ~= config.expected_reflector_count then
      log({
        config.log_prefix or "[solar_tower]",
        "ts=" .. ts,
        "cycle=" .. tostring(cycle),
        "state=FAULT",
        "heat=" .. tostring(heat),
        "reflectors=" .. tostring(reflectors),
        "insert=0",
        "reason=reflector mismatch expected " .. tostring(config.expected_reflector_count),
      })
    else
      local is_day, is_rain = detect_weather(geolyzer, redstone, day_side, day_threshold)
      local insert, pre, gain, eff, reason = compute_insert(heat, is_day, is_rain)
      local ok_inject, moved, inject_err = transfer_exact(transposer, source_side, sink_side, source_tank, insert)

      log({
        config.log_prefix or "[solar_tower]",
        "ts=" .. ts,
        "cycle=" .. tostring(cycle),
        "state=" .. (ok_inject and "RUN" or "FAULT"),
        "heat=" .. tostring(heat),
        "reflectors=" .. tostring(reflectors),
        "weather=" .. weather_name(is_day, is_rain),
        "eff=" .. string.format("%.6f", eff),
        "gain=" .. tostring(gain),
        "pre=" .. tostring(pre),
        "insert=" .. tostring(ok_inject and insert or 0),
        "moved=" .. tostring(math.floor(moved or 0)),
        "reason=" .. tostring(ok_inject and reason or inject_err),
      })
    end
  end

  if config.align_to_cycle_boundary then
    local t = now()
    local next_boundary = (math.floor(t / config.cycle_seconds) + 1) * config.cycle_seconds
    sleep_seconds(next_boundary - t)
  else
    sleep_seconds(config.cycle_seconds)
  end
end
