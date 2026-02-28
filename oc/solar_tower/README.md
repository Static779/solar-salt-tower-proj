# Solar Tower 50k Controller (OpenComputers)

This controller keeps GTNH Solar Tower heat at `50,000` for max sustained hot solar salt output, using the exact GTNH logic in `MTESolarTower.checkProcessing()`.

## Files
- `config.lua`: constants, safety bounds, hardware mapping, provider overrides
- `io.lua`: adapter contract implementation
- `control.lua`: state machine + math + cycle scheduler
- `main.lua`: entrypoint
- `sim_test.lua`: offline behavior tests
- `discover.lua`: in-game component/method discovery helper
- `DEPLOYMENT_TRANSPOSER.md`: strict in-game deployment runbook (recommended)

## State machine
- `INIT`: validates adapters/config, then enters `RUN` or `RECOVERY`
- `RUN`: computes exact insertion per 10s cycle
- `RECOVERY`: if heat `< 50,000`, inserts `0` until recovered
- `FAULT`: any read/write failure or reflector mismatch, inserts `0`

## Formula used (GTNH-correct)
- `eff = (7000 - abs(H - 50000)^0.8) / 7000`
- Clear day gain: `floor(340 * eff * 26)`
- Rain day gain: `floor(170 * eff * 26)` (integer-halved heaters)
- Night gain: `0`
- Pre-conversion heat:
  - `h = H + gain`
  - if `h > 0`: if `h > 100000` then `h=100000` else `h=h-10`
- Insertion:
  - if `H < 50000` -> `0`
  - else if `h < 30000` -> `0`
  - else `clamp(h - 50000, 0, MAX_INSERT_PER_CYCLE)`

## Expected steady inserts with max reflectors
- Clear day near target: `8830 L / 10s`
- Rain near target: `4410 L / 10s`
- Night near target: `0 L / 10s`

## In-game modes
Set `ingame.enable = true` in `config.lua`.

### Mode A: `transposer_exact` (recommended)
Uses OC `transposer.transferFluid(source, sink, count[, sourceTank])` for exact liters per cycle.

Required:
- OC `transposer`
- OC `geolyzer`
- Optional OC `redstone` + daylight sensor for clean day/night detection

Config keys:
- `ingame.valve_mode = "transposer_exact"`
- `ingame.transposer.source_side`
- `ingame.transposer.sink_side`
- optional `ingame.transposer.source_tank`

### Mode B: `sfm_pulse`
Uses OC redstone pulses to trigger SFM; each pulse must move a fixed amount.

Required:
- OC `redstone`
- OC `geolyzer`
- SFM trigger graph configured to transfer exactly `ingame.sfm.liters_per_pulse` cold solar salt on each high pulse

Config keys:
- `ingame.valve_mode = "sfm_pulse"`
- `ingame.sfm.liters_per_pulse`
- `ingame.sfm.trigger_side`
- `ingame.sfm.pulse_strength`
- `ingame.sfm.pulse_on_sec`
- `ingame.sfm.pulse_off_sec`
- `ingame.sfm.max_pulses_per_cycle`
- `ingame.sfm.round_mode` (`floor` or `nearest`)

Notes:
- `sfm_pulse` is quantized, not perfectly exact per cycle.
- The provider carries residual liters between cycles to reduce long-term error.

## Provider override mode
If your setup does not expose those exact methods, define `providers` in `config.lua`:
- `read_heat() -> integer`
- `read_reflector_count() -> integer`
- `is_day() -> boolean`
- `is_raining_effective() -> boolean`
- `inject_exact(liters) -> bool[, transferred]`
- optional `read_hot_salt_delta() -> integer`

Providers take priority over component calls.

## Wiring reference
### Transposer exact path
1. Put an OC transposer so one side touches the cold-salt source tank and another side touches Solar Tower input plumbing.
2. Set `source_side` to the source tank side and `sink_side` to the tower input side.
3. Keep `max_insert_per_cycle` high enough for startup (`>= 50000` recommended).

### Cold salt transfer options (transposer)
- `transferFluid(sourceSide, sinkSide, liters[, sourceTank])`:
  - This is what the controller uses in `transposer_exact` mode.
  - Use this when both source and destination expose fluid tanks/hatches.
- `transferFluidFromContainerToTank(...)`:
  - Use this if your cold salt is in fluid containers (cells/cans) in an inventory and you need a buffer tank.
- `transferFluidFromTankToContainer(...)`:
  - Use this to fill containers from a buffer tank (usually for logistics, not tower feed).
- `transferFluidBetweenContainers(...)`:
  - Container-to-container moves when both ends are inventory-held fluid containers.

For this project, keep tower feed as tank/hatch to tank/hatch and use `transferFluid` for deterministic dosing.

### Hot salt output
- Keep hot solar salt extraction on a separate always-on export line from the tower output hatch.
- The controller does not throttle hot salt export; it only meters cold salt insertion.
- Optional `hot_salt_monitor` in config is telemetry only.

### SFM pulse path
1. Build an SFM manager program:
   - Trigger type: redstone, `On High Redstone Pulse`.
   - On trigger: move cold solar salt from source to tower input.
   - Liquid setting amount must be fixed to exactly `liters_per_pulse`.
2. Wire OC redstone output side to the SFM trigger input.
3. Match `ingame.sfm.trigger_side` to that OC output side.
4. Start with `liters_per_pulse = 1000`, `pulse_on_sec = 0`, `pulse_off_sec = 0`, `max_pulses_per_cycle = 45`.
5. Increase extra pulse timing only if your SFM edge detection misses pulses.

OC note:
- OC `setOutput` already has a default `redstoneDelay` of `0.1s` per call in config, so additional pulse sleeps are usually unnecessary.

## Important runtime assumption
GTNH OC GregTech integration exposes `sensorInformation = getInfoData()` but not `getExtraInfoData()`.
Solar Tower heat is in `getExtraInfoData()` in GTNH code, so this script uses a deterministic internal heat model, seeded by `ingame.initial_heat` (set to `100000` by default).

## Run
From OC shell:
- `lua /home/lib/solar_tower/main.lua`
- Optional preflight:
  - `lua /home/lib/solar_tower/discover.lua`

## Local emulator (offline)
- Files:
  - `oc/solar_tower/emulator/mock_oc.lua`
  - `oc/solar_tower/emulator/run_transposer_demo.lua`
  - `oc/solar_tower/emulator/run_transposer_demo.ps1`
- Windows quick run:
  - `powershell -ExecutionPolicy Bypass -File oc/solar_tower/emulator/run_transposer_demo.ps1`
- Direct Lua run:
  - `"C:\Program Files (x86)\Lua\5.1\lua.exe" oc/solar_tower/emulator/run_transposer_demo.lua`

## GitHub raw install (OpenComputers)
After this project is pushed to GitHub, install directly on OC with:

```sh
wget -f https://raw.githubusercontent.com/<owner>/<repo>/<branch>/oc/solar_tower/install.lua /tmp/solar_install.lua
lua /tmp/solar_install.lua <owner> <repo> <branch> /home/lib/solar_tower
lua /home/lib/solar_tower/main.lua
```

If your default branch is `main`, use `main`. If it is `master`, use `master`.

### One-liner bootstrap (this repo)
```sh
wget -f https://raw.githubusercontent.com/Static779/solar-salt-tower-proj/main/oc/solar_tower/bootstrap.lua /tmp/solar_boot.lua; lua /tmp/solar_boot.lua; lua /home/lib/solar_tower/main.lua
```

## Offline test
From repo root:
- `lua oc/solar_tower/sim_test.lua`
