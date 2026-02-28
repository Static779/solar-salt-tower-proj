-- OpenComputers installer for solar_tower.
-- Usage:
--   lua install.lua <github_owner> <github_repo> [branch] [target_dir]
-- Example:
--   lua /tmp/install.lua amirw solar-salt-tower-proj main /home/lib/solar_tower

local args = {...}
local owner = args[1]
local repo = args[2]
local branch = args[3] or "main"
local target_root = args[4] or "/home/lib/solar_tower"

if owner == nil or owner == "" or repo == nil or repo == "" then
  io.stderr:write("Usage: lua install.lua <github_owner> <github_repo> [branch] [target_dir]\n")
  return
end

local ok_internet, internet = pcall(require, "internet")
local ok_fs, fs = pcall(require, "filesystem")

if not ok_internet or internet == nil then
  io.stderr:write("[solar_tower installer] missing internet component/library\n")
  return
end
if not ok_fs or fs == nil then
  io.stderr:write("[solar_tower installer] missing filesystem library\n")
  return
end

local files = {
  "config.lua",
  "control.lua",
  "io.lua",
  "main.lua",
  "discover.lua",
  "inspect_component.lua",
  "bootstrap.lua",
  "README.md",
  "DEPLOYMENT_TRANSPOSER.md",
  "sim_test.lua",
  "providers/ingame_model.lua",
}

local function dirname(path)
  return path:match("^(.*)/[^/]+$") or ""
end

local function read_url(url)
  local handle, reason = internet.request(url)
  if handle == nil then
    return nil, reason or "request failed"
  end
  local parts = {}
  for chunk in handle do
    parts[#parts + 1] = chunk
  end
  return table.concat(parts)
end

local function write_file(path, data)
  local dir = dirname(path)
  if dir ~= "" and not fs.exists(dir) then
    fs.makeDirectory(dir)
  end
  local fh, err = io.open(path, "wb")
  if fh == nil then
    return nil, err or "open failed"
  end
  fh:write(data)
  fh:close()
  return true
end

local base = "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/" .. branch .. "/oc/solar_tower/"

if not fs.exists(target_root) then
  fs.makeDirectory(target_root)
end

io.write("[solar_tower installer] source: " .. base .. "\n")
io.write("[solar_tower installer] target: " .. target_root .. "\n")

for i = 1, #files do
  local rel = files[i]
  local url = base .. rel
  local out = target_root .. "/" .. rel
  io.write(string.format("[%d/%d] %s\n", i, #files, rel))
  local data, err = read_url(url)
  if data == nil then
    io.stderr:write("[solar_tower installer] download failed: " .. tostring(err) .. "\n")
    io.stderr:write("URL: " .. url .. "\n")
    return
  end
  local ok, werr = write_file(out, data)
  if not ok then
    io.stderr:write("[solar_tower installer] write failed: " .. tostring(werr) .. "\n")
    io.stderr:write("Path: " .. out .. "\n")
    return
  end
end

io.write("[solar_tower installer] install complete\n")
io.write("Run: lua " .. target_root .. "/main.lua\n")
