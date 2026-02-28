# GTNH Solar Tower Controller Deployment (Transposer Mode)

This guide is the canonical in-game setup for this project.
It is intentionally strict to avoid ambiguous interpretation.

## 1. Scope

This deployment uses only:
- OpenComputers `transposer` for cold salt insertion.
- OpenComputers `geolyzer` for sun/rain detection.
- Optional OpenComputers `redstone` input from daylight sensor for cleaner day/night detection.

This deployment does not use SFM pulse mode.

## 2. Required Blocks and Connections

You need:
- 1 OpenComputers computer running OpenOS.
- 1 OpenComputers transposer.
- 1 OpenComputers geolyzer.
- Optional 1 OpenComputers redstone I/O and 1 daylight sensor.
- A cold solar salt source tank/hatch.
- Solar Tower input plumbing/hatch.
- Solar Tower output plumbing/hatch with always-on hot salt export.

Hard rule:
- Hot salt output must be exported independently.
- The controller meters only cold salt insertion.

## 3. Side Mapping Rule (No Guessing)

OpenComputers uses absolute world sides:
- `down=0`, `up=1`, `north=2`, `south=3`, `west=4`, `east=5`.

Choose one fixed mapping and keep it everywhere.

Recommended mapping:
- Transposer `west` side touches cold salt source.
- Transposer `east` side touches tower input line.
- Daylight sensor into redstone input `north`.

If your build is different, change `source_side`, `sink_side`, and `daylight_sensor_side` to match your actual world sides.

## 4. Install Files on OC

Place the `solar_tower` folder at:
- `/home/lib/solar_tower`

Expected entrypoint:
- `/home/lib/solar_tower/main.lua`

Alternative (recommended after GitHub publish): raw installer
- `wget -f https://raw.githubusercontent.com/<owner>/<repo>/<branch>/oc/solar_tower/install.lua /tmp/solar_install.lua`
- `lua /tmp/solar_install.lua <owner> <repo> <branch> /home/lib/solar_tower`

## 5. Preflight Discovery (Mandatory)

Run on OC:
- `lua /home/lib/solar_tower/discover.lua`

Confirm:
- At least one `transposer` with `transferFluid` and `getTankLevel`.
- At least one `geolyzer` with `isSunVisible`.
- Optional `redstone` with `getInput` if using daylight sensor input.

Do not continue until this passes.

## 6. Configure `config.lua` Exactly

Edit [config.lua](/c:/Users/amirw/OneDrive/Desktop/solar%20salt%20tower%20proj/oc/solar_tower/config.lua) and set:

```lua
M.ingame.enable = true
M.ingame.initial_heat = 100000
M.ingame.valve_mode = "transposer_exact"
M.ingame.heat_mode = "model"         -- default stable mode

M.ingame.transposer.component_type = "transposer"
M.ingame.transposer.source_side = "west"  -- cold source side
M.ingame.transposer.sink_side = "east"    -- tower input side
M.ingame.transposer.source_tank = 1       -- set only if needed

M.ingame.geolyzer.component_type = "geolyzer"

M.ingame.redstone.component_type = "redstone"
M.ingame.redstone.daylight_sensor_side = "north"
M.ingame.redstone.day_threshold = 0

M.safety.enforce_reflector_count = true
M.safety.expected_reflector_count = 340
M.safety.max_insert_per_cycle = 60000
```

Optional live-heat mode (adapter/peripheral):
- Set `M.ingame.heat_mode = "sensor"`.
- Configure `M.ingame.controller_sensor` with adapter address/type and method names.
- Keep `strict = true` so controller fails safe if heat telemetry breaks.
- Use this helper to discover adapter methods:
  - `lua /home/lib/solar_tower/inspect_component.lua <address_or_type>`

If you are not wiring a daylight sensor:
- Keep `redstone` unset or ignore it.
- Day/night fallback will use `geolyzer.isSunVisible()`.

## 7. Start Controller

Run:
- `lua /home/lib/solar_tower/main.lua`

Keep terminal open and watch logs.

## 8. Expected Log Behavior (Acceptance)

With heat starting at `100000`:

Clear day:
- Cycle 1 insertion should be `50000`.
- Then controller should stabilize near `8830 L / 10s`.

Rain day:
- Controller should stabilize near `4410 L / 10s`.

Night:
- Insertion should go to `0`.
- Heat drifts down by passive loss until day returns.

Recovery rule:
- If heat drops below `50000`, insertion remains `0` until heat reaches `>= 50000`.

## 9. Cold Salt Transfer Semantics

Controller insertion call in transposer mode:
- `transferFluid(sourceSide, sinkSide, liters[, sourceTank])`

Failure behavior:
- If moved liters are less than requested, controller enters fail-safe for that cycle.
- Fail-safe means effective insertion command is treated as failed and then recovered by controller state logic.

Do not use container-based methods for the main tower feed path:
- `transferFluidFromContainerToTank`
- `transferFluidFromTankToContainer`
- `transferFluidBetweenContainers`

Use tank-to-tank (or hatch-to-hatch) transfer only for deterministic dosing.

## 10. Hot Salt Export Requirement

Set hot salt output to immediate export using your normal fluid logistics.

Controller policy:
- It does not rate-limit hot salt output.
- Optional hot-salt monitoring is telemetry only and does not control output.

## 11. Troubleshooting

Symptom: `inject failed: partial transfer ...`
- Cause: Wrong side, wrong source tank index, empty source, or blocked sink.
- Fix: Verify transposer side mapping, `source_tank`, source supply, and destination capacity.

Symptom: `TELEMETRY_ERROR`
- Cause: Missing/invalid component methods.
- Fix: Re-run `discover.lua` and match config to real components.

Symptom: `REFLECTOR_MISMATCH`
- Cause: Tower not at max reflector count.
- Fix: Build/repair reflectors to `340` or disable enforcement intentionally.

Symptom: No insertion at night even near 50k heat
- Cause: Intended behavior in this control policy.
- Fix: None; this is by design.

## 12. Source-of-Truth References

Solar Tower cycle order and heat math:
- [MTESolarTower.java](/c:/Users/amirw/OneDrive/Desktop/solar%20salt%20tower%20proj/refs/GT5-Unofficial/src/main/java/gtPlusPlus/xmod/gregtech/common/tileentities/machines/multi/production/MTESolarTower.java)

OpenComputers transposer fluid transfer function:
- [InventoryTransfer.scala](/c:/Users/amirw/OneDrive/Desktop/solar%20salt%20tower%20proj/refs/OpenComputers/src/main/scala/li/cil/oc/server/component/traits/InventoryTransfer.scala)

OpenComputers geolyzer sun visibility:
- [Geolyzer.scala](/c:/Users/amirw/OneDrive/Desktop/solar%20salt%20tower%20proj/refs/OpenComputers/src/main/scala/li/cil/oc/server/component/Geolyzer.scala)
