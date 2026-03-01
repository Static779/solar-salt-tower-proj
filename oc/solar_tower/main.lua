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
