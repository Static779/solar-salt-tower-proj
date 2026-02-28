local args = {...}

local ok_component, component = pcall(require, "component")
if not ok_component or component == nil then
  io.stderr:write("[solar_tower] component library unavailable\n")
  return
end

local target = args[1]
if target == nil or target == "" then
  io.stderr:write("Usage: lua inspect_component.lua <address_or_type>\n")
  return
end

local function is_address(value)
  if type(value) ~= "string" then
    return false
  end
  -- OC short/long component addresses use hex + dashes.
  return value:match("^[0-9a-fA-F%-]+$") ~= nil
end

local function resolve_target(value)
  if is_address(value) then
    local ok, proxy = pcall(component.proxy, value)
    if ok and proxy ~= nil then
      return value, component.type(value), proxy
    end
  end

  local iter = component.list(value)
  if iter == nil then
    return nil, nil, nil, "no component list for type: " .. tostring(value)
  end
  for addr, ctype in iter do
    local ok, proxy = pcall(component.proxy, addr)
    if ok and proxy ~= nil then
      return addr, ctype, proxy
    end
  end

  return nil, nil, nil, "no component found for type: " .. tostring(value)
end

local address, ctype, proxy, err = resolve_target(target)
if proxy == nil then
  io.stderr:write("[solar_tower] " .. tostring(err) .. "\n")
  return
end

io.write("[solar_tower] component inspect\n")
io.write("address: " .. tostring(address) .. "\n")
io.write("type: " .. tostring(ctype) .. "\n")

local methods = {}
for name, value in pairs(proxy) do
  if type(value) == "function" then
    methods[#methods + 1] = name
  end
end
table.sort(methods)

io.write("methods:\n")
for i = 1, #methods do
  io.write("  - " .. methods[i] .. "\n")
end
