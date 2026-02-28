local ok_component, component = pcall(require, "component")
if not ok_component or component == nil then
  io.stderr:write("[solar_tower] component library unavailable\n")
  return
end

local function bool_text(value)
  if value then
    return "yes"
  end
  return "no"
end

local function print_component_list(ctype, methods)
  io.write("\n[" .. ctype .. "]\n")
  local found = false
  for address in component.list(ctype) do
    found = true
    local proxy = component.proxy(address)
    io.write("  address: " .. tostring(address) .. "\n")
    for _, method_name in ipairs(methods) do
      io.write("    " .. method_name .. ": " .. bool_text(type(proxy[method_name]) == "function") .. "\n")
    end
  end
  if not found then
    io.write("  (none)\n")
  end
end

io.write("[solar_tower] component discovery\n")
io.write("sides: down=0 up=1 north=2 south=3 west=4 east=5\n")

print_component_list("transposer", {
  "transferFluid",
  "transferFluidFromContainerToTank",
  "transferFluidFromTankToContainer",
  "transferFluidBetweenContainers",
  "getTankLevel",
  "getFluidTransferRate",
})
print_component_list("geolyzer", { "isSunVisible", "canSeeSky", "analyze" })
print_component_list("redstone", { "getInput", "setOutput", "getOutput" })
