local M = {}

local SIDE_MAP = {
  down = 0,
  up = 1,
  north = 2,
  south = 3,
  west = 4,
  east = 5,
}

local function to_side(value)
  if type(value) == "number" then
    local side = math.floor(value)
    if side >= 0 and side <= 5 then
      return side
    end
    return nil
  end
  if type(value) == "string" then
    return SIDE_MAP[value:lower()]
  end
  return nil
end

local function copy_side_table(default_value)
  local data = {}
  for i = 0, 5 do
    data[i] = default_value
  end
  return data
end

local function new_iterator(list)
  local i = 0
  return function()
    i = i + 1
    if i <= #list then
      return list[i][1], list[i][2]
    end
    return nil
  end
end

function M.create(options)
  local opts = options or {}

  local state = {
    time = 0,
    is_day = opts.is_day ~= false,
    is_raining = opts.is_raining == true,
    transfer_log = {},
    redstone_input = copy_side_table(0),
    redstone_output = copy_side_table(0),
    -- side -> { [tankIndex] = liters }
    tanks = {},
    -- side -> liters
    tank_capacity = {},
  }

  local function set_tank_level(side, tank_index, liters)
    local s = to_side(side)
    local idx = tank_index or 1
    if s == nil or idx < 1 then
      return
    end
    state.tanks[s] = state.tanks[s] or {}
    state.tanks[s][idx] = math.max(0, math.floor(liters or 0))
  end

  local function get_tank_level(side, tank_index)
    local s = to_side(side)
    local idx = tank_index or 1
    if s == nil then
      return 0
    end
    local side_tanks = state.tanks[s]
    if side_tanks == nil then
      return 0
    end
    return math.floor(side_tanks[idx] or 0)
  end

  local function get_tank_capacity(side)
    local s = to_side(side)
    if s == nil then
      return 0
    end
    local capacity = state.tank_capacity[s]
    if capacity == nil then
      return 2147483647
    end
    return math.max(0, math.floor(capacity))
  end

  local function set_redstone_input(side, level)
    local s = to_side(side)
    if s == nil then
      return
    end
    state.redstone_input[s] = math.max(0, math.min(15, math.floor(level or 0)))
  end

  local components = {}
  local component_rows = {}

  local function register_component(address, ctype, proxy)
    components[address] = { type = ctype, proxy = proxy }
    component_rows[#component_rows + 1] = { address, ctype }
  end

  local transposer = {}

  function transposer.transferFluid(source_side, sink_side, count, source_tank)
    local src = to_side(source_side)
    local dst = to_side(sink_side)
    local requested = math.max(0, math.floor(count or 0))
    local src_tank = source_tank or 1
    if src == nil or dst == nil or src_tank < 1 then
      return false, 0
    end

    local available = get_tank_level(src, src_tank)
    local sink_level = get_tank_level(dst, 1)
    local sink_space = get_tank_capacity(dst) - sink_level
    if sink_space < 0 then
      sink_space = 0
    end
    local moved = math.min(requested, available, sink_space)
    if moved < 0 then
      moved = 0
    end

    set_tank_level(src, src_tank, available - moved)
    set_tank_level(dst, 1, sink_level + moved)

    state.transfer_log[#state.transfer_log + 1] = {
      time = state.time,
      source_side = src,
      sink_side = dst,
      requested = requested,
      moved = moved,
    }

    return moved > 0, moved
  end

  function transposer.getTankLevel(side, tank)
    return get_tank_level(side, tank or 1)
  end

  function transposer.getFluidTransferRate()
    return math.floor(opts.fluid_transfer_rate or 16000)
  end

  local geolyzer = {}

  function geolyzer.isSunVisible()
    return state.is_day and (not state.is_raining)
  end

  function geolyzer.canSeeSky()
    return true
  end

  local redstone = {}

  function redstone.getInput(side)
    local s = to_side(side)
    if s == nil then
      return 0
    end
    return state.redstone_input[s] or 0
  end

  function redstone.getOutput(side)
    local s = to_side(side)
    if s == nil then
      return 0
    end
    return state.redstone_output[s] or 0
  end

  function redstone.setOutput(side, value)
    local s = to_side(side)
    if s == nil then
      return 0
    end
    local previous = state.redstone_output[s] or 0
    local next_level = math.max(0, math.min(15, math.floor(value or 0)))
    state.redstone_output[s] = next_level
    return previous
  end

  local component_api = {}

  function component_api.list(filter_type)
    local rows = {}
    if filter_type == nil then
      for i = 1, #component_rows do
        rows[#rows + 1] = component_rows[i]
      end
    else
      for i = 1, #component_rows do
        local row = component_rows[i]
        if row[2] == filter_type then
          rows[#rows + 1] = row
        end
      end
    end
    return new_iterator(rows)
  end

  function component_api.proxy(address)
    local entry = components[address]
    if entry == nil then
      error("no such component: " .. tostring(address))
    end
    return entry.proxy
  end

  local computer_api = {}

  function computer_api.uptime()
    return state.time
  end

  function computer_api.pullSignal(timeout)
    local delay = tonumber(timeout) or 0
    if delay > 0 then
      state.time = state.time + delay
    end
    return nil
  end

  local event_api = {}

  function event_api.pull(timeout)
    local delay = tonumber(timeout) or 0
    if delay > 0 then
      state.time = state.time + delay
    end
    return nil
  end

  local transposer_address = opts.transposer_address or "tr-0001"
  local geolyzer_address = opts.geolyzer_address or "geo-0001"
  local redstone_address = opts.redstone_address or "rs-0001"
  register_component(transposer_address, "transposer", transposer)
  register_component(geolyzer_address, "geolyzer", geolyzer)
  register_component(redstone_address, "redstone", redstone)

  if type(opts.tanks) == "table" then
    for side_key, tanks in pairs(opts.tanks) do
      local side = to_side(side_key)
      if side ~= nil and type(tanks) == "table" then
        for tank_index, level in pairs(tanks) do
          local idx = math.floor(tonumber(tank_index) or 1)
          if idx >= 1 then
            set_tank_level(side, idx, level)
          end
        end
      end
    end
  end

  if type(opts.tank_capacity) == "table" then
    for side_key, cap in pairs(opts.tank_capacity) do
      local side = to_side(side_key)
      if side ~= nil then
        state.tank_capacity[side] = math.max(0, math.floor(cap))
      end
    end
  end

  if type(opts.redstone_input) == "table" then
    for side_key, level in pairs(opts.redstone_input) do
      local side = to_side(side_key)
      if side ~= nil then
        set_redstone_input(side, level)
      end
    end
  end

  local api = {
    state = state,
    component = component_api,
    computer = computer_api,
    event = event_api,
    set_day = function(v) state.is_day = v == true end,
    set_raining = function(v) state.is_raining = v == true end,
    set_tank_level = set_tank_level,
    get_tank_level = get_tank_level,
    set_redstone_input = set_redstone_input,
    addresses = {
      transposer = transposer_address,
      geolyzer = geolyzer_address,
      redstone = redstone_address,
    },
  }

  return api
end

function M.install(options)
  local env = M.create(options)

  package.loaded.component = nil
  package.loaded.computer = nil
  package.loaded.event = nil

  package.preload.component = function()
    return env.component
  end
  package.preload.computer = function()
    return env.computer
  end
  package.preload.event = function()
    return env.event
  end

  return env
end

return M
