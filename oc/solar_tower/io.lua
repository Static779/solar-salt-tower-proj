local M = {}

local function try_require(name)
  local ok, mod = pcall(require, name)
  if ok then
    return mod
  end
  return nil
end

local component = try_require("component")

local function pack(...)
  return { n = select("#", ...), ... }
end

local function parse_integer(value)
  local t = type(value)
  if t == "number" then
    if value ~= value then
      return nil
    end
    return math.floor(value)
  end
  if t == "string" then
    local n = value:match("-?%d+")
    if n then
      return tonumber(n, 10)
    end
    return nil
  end
  if t == "table" then
    for _, v in ipairs(value) do
      local parsed = parse_integer(v)
      if parsed ~= nil then
        return parsed
      end
    end
    for _, v in pairs(value) do
      local parsed = parse_integer(v)
      if parsed ~= nil then
        return parsed
      end
    end
    return nil
  end
  return nil
end

local function parse_boolean(value)
  local t = type(value)
  if t == "boolean" then
    return value
  end
  if t == "number" then
    return value ~= 0
  end
  if t == "string" then
    local normalized = value:lower()
    if normalized == "true" or normalized == "yes" or normalized == "on" or normalized == "1" then
      return true
    end
    if normalized == "false" or normalized == "no" or normalized == "off" or normalized == "0" then
      return false
    end
  end
  return nil
end

local function pick_integer(results, start_index)
  local first = start_index or 1
  for i = first, results.n do
    local parsed = parse_integer(results[i])
    if parsed ~= nil then
      return parsed
    end
  end
  return nil
end

local function pick_boolean(results, start_index)
  local first = start_index or 1
  for i = first, results.n do
    local parsed = parse_boolean(results[i])
    if parsed ~= nil then
      return parsed
    end
  end
  return nil
end

local Adapter = {}
Adapter.__index = Adapter

function Adapter.new(config)
  local self = setmetatable({}, Adapter)
  self.config = config or {}
  self.providers = self.config.providers or {}
  self.hardware = self.config.hardware or {}
  self._tower_proxy = nil
  self._valve_proxy = nil
  return self
end

function Adapter:_resolve_proxy(spec, cache_key)
  local cached = self[cache_key]
  if cached ~= nil then
    return cached
  end

  if component == nil then
    return nil, "OpenComputers component library not available"
  end

  if type(spec) ~= "table" then
    return nil, "missing hardware spec"
  end

  local address = spec.address
  if address ~= nil then
    local ok, proxy = pcall(component.proxy, address)
    if not ok or proxy == nil then
      return nil, "failed to resolve component address: " .. tostring(address)
    end
    self[cache_key] = proxy
    return proxy
  end

  local ctype = spec.component_type
  if ctype ~= nil then
    local iter = component.list(ctype)
    if iter == nil then
      return nil, "component.list returned nil for type: " .. tostring(ctype)
    end
    local found = nil
    for addr, _ in iter do
      found = addr
      break
    end
    if found == nil then
      return nil, "no component found for type: " .. tostring(ctype)
    end
    local ok, proxy = pcall(component.proxy, found)
    if not ok or proxy == nil then
      return nil, "failed to proxy component type: " .. tostring(ctype)
    end
    self[cache_key] = proxy
    return proxy
  end

  return nil, "neither address nor component_type configured"
end

function Adapter:_call_provider_or_method(provider_name, proxy_spec, cache_key, method_name, ...)
  local provider = self.providers[provider_name]
  if type(provider) == "function" then
    local ok, a, b, c, d = pcall(provider, ...)
    if not ok then
      return false, "provider " .. provider_name .. " failed: " .. tostring(a)
    end
    return true, pack(a, b, c, d)
  end

  local proxy, err = self:_resolve_proxy(proxy_spec, cache_key)
  if proxy == nil then
    return false, err
  end

  local fn = proxy[method_name]
  if type(fn) ~= "function" then
    return false, "missing method on component: " .. tostring(method_name)
  end

  local ok, a, b, c, d = pcall(fn, proxy, ...)
  if not ok then
    return false, "component method failed: " .. tostring(a)
  end
  return true, pack(a, b, c, d)
end

function Adapter:read_heat()
  local tower = self.hardware.tower or {}
  local methods = tower.methods or {}
  local ok, result_or_err = self:_call_provider_or_method(
    "read_heat",
    tower,
    "_tower_proxy",
    methods.read_heat or "readHeat"
  )
  if not ok then
    return nil, result_or_err
  end

  local value = pick_integer(result_or_err, 1)
  if value == nil then
    return nil, "read_heat returned non-numeric value"
  end
  return value
end

function Adapter:read_reflector_count()
  local tower = self.hardware.tower or {}
  local methods = tower.methods or {}
  local ok, result_or_err = self:_call_provider_or_method(
    "read_reflector_count",
    tower,
    "_tower_proxy",
    methods.read_reflector_count or "readReflectorCount"
  )
  if not ok then
    return nil, result_or_err
  end

  local value = pick_integer(result_or_err, 1)
  if value == nil then
    return nil, "read_reflector_count returned non-numeric value"
  end
  return value
end

function Adapter:is_day()
  local tower = self.hardware.tower or {}
  local methods = tower.methods or {}
  local ok, result_or_err = self:_call_provider_or_method(
    "is_day",
    tower,
    "_tower_proxy",
    methods.is_day or "isDay"
  )
  if not ok then
    return nil, result_or_err
  end

  local value = pick_boolean(result_or_err, 1)
  if value == nil then
    return nil, "is_day returned non-boolean value"
  end
  return value
end

function Adapter:is_raining_effective()
  local tower = self.hardware.tower or {}
  local methods = tower.methods or {}
  local ok, result_or_err = self:_call_provider_or_method(
    "is_raining_effective",
    tower,
    "_tower_proxy",
    methods.is_raining_effective or "isRainingEffective"
  )
  if not ok then
    return nil, result_or_err
  end

  local value = pick_boolean(result_or_err, 1)
  if value == nil then
    return nil, "is_raining_effective returned non-boolean value"
  end
  return value
end

function Adapter:inject_exact(liters)
  if type(liters) ~= "number" then
    return false, "inject_exact liters must be a number"
  end

  local amount = math.floor(liters)
  if amount <= 0 then
    return true
  end

  local valve = self.hardware.valve or {}
  local methods = valve.methods or {}
  local ok, result_or_err = self:_call_provider_or_method(
    "inject_exact",
    valve,
    "_valve_proxy",
    methods.inject_exact or "injectColdSaltExact",
    amount
  )
  if not ok then
    return false, result_or_err
  end

  if result_or_err.n == 0 then
    return true
  end

  local first = result_or_err[1]
  if type(first) == "boolean" then
    if not first then
      return false, "inject_exact returned false"
    end
    local transferred = pick_integer(result_or_err, 2)
    if transferred ~= nil and transferred < amount then
      return false, "inject_exact transferred less than requested: " .. tostring(transferred)
    end
    return true
  end

  if type(first) == "number" then
    local transferred = math.floor(first)
    if transferred < amount then
      return false, "inject_exact transferred less than requested: " .. tostring(transferred)
    end
    return true
  end

  if first == nil then
    return true
  end

  return true
end

function Adapter:read_hot_salt_delta()
  local provider = self.providers.read_hot_salt_delta
  local tower = self.hardware.tower or {}
  local methods = tower.methods or {}
  local method_name = methods.read_hot_salt_delta or "readHotSaltDelta"

  if type(provider) ~= "function" then
    local proxy, err = self:_resolve_proxy(tower, "_tower_proxy")
    if proxy == nil then
      return nil, err
    end
    if type(proxy[method_name]) ~= "function" then
      return nil, "read_hot_salt_delta is unavailable"
    end
  end

  local ok, result_or_err = self:_call_provider_or_method(
    "read_hot_salt_delta",
    tower,
    "_tower_proxy",
    method_name
  )
  if not ok then
    return nil, result_or_err
  end

  local value = pick_integer(result_or_err, 1)
  if value == nil then
    return nil, "read_hot_salt_delta returned non-numeric value"
  end
  return value
end

function M.new(config)
  local adapter = Adapter.new(config or {})
  local api = {}

  api.Tower = {}
  api.Env = {}
  api.Valve = {}
  api.Optional = {}

  function api.Tower.read_heat()
    return adapter:read_heat()
  end

  function api.Tower.read_reflector_count()
    return adapter:read_reflector_count()
  end

  function api.Env.is_day()
    return adapter:is_day()
  end

  function api.Env.is_raining_effective()
    return adapter:is_raining_effective()
  end

  function api.Valve.inject_exact(liters)
    return adapter:inject_exact(liters)
  end

  function api.Optional.read_hot_salt_delta()
    return adapter:read_hot_salt_delta()
  end

  api._adapter = adapter
  return api
end

return M
