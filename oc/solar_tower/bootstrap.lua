-- One-shot bootstrap installer for OpenComputers.
-- This script is intended to be downloaded and executed directly.

local OWNER = "Static779"
local REPO = "solar-salt-tower-proj"
local BRANCH = "main"
local TARGET = "/home/lib/solar_tower"

local ok_internet, internet = pcall(require, "internet")
if not ok_internet or internet == nil then
  io.stderr:write("[solar_tower bootstrap] internet library unavailable\n")
  return
end

local install_url = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPO .. "/" .. BRANCH .. "/oc/solar_tower/install.lua"
io.write("[solar_tower bootstrap] fetching installer\n")
io.write("[solar_tower bootstrap] " .. install_url .. "\n")

local handle, req_err = internet.request(install_url)
if handle == nil then
  io.stderr:write("[solar_tower bootstrap] request failed: " .. tostring(req_err) .. "\n")
  return
end

local chunks = {}
for chunk in handle do
  chunks[#chunks + 1] = chunk
end
local script = table.concat(chunks)

if script == nil or script == "" then
  io.stderr:write("[solar_tower bootstrap] empty installer payload\n")
  return
end

local loader = load
local fn, load_err = loader(script, "=solar_install")
if fn == nil and type(loadstring) == "function" then
  fn, load_err = loadstring(script)
end

if fn == nil then
  io.stderr:write("[solar_tower bootstrap] load failed: " .. tostring(load_err) .. "\n")
  return
end

fn(OWNER, REPO, BRANCH, TARGET)
