# Changelog

## 2026-02-28

### Added
- Added practical in-game valve backends in `oc/solar_tower/providers/ingame_model.lua`:
  - `transposer_exact` for exact OC `transferFluid` insertion.
  - `sfm_pulse` for redstone-triggered SFM fixed-dose insertion.
- Added `ingame.valve_mode` and `ingame.sfm.*` configuration in `oc/solar_tower/config.lua`.
- Added SFM pulse quantization carry logic to reduce long-run dosing drift.
- Added `oc/solar_tower/discover.lua` to list OC component addresses and required methods in-world.
- Added local OC emulator harness:
  - `oc/solar_tower/emulator/mock_oc.lua`
  - `oc/solar_tower/emulator/run_transposer_demo.lua`
  - `oc/solar_tower/emulator/run_transposer_demo.ps1`
- Added `oc/solar_tower/DEPLOYMENT_TRANSPOSER.md` as the no-ambiguity in-game runbook.
- Added `oc/solar_tower/install.lua` for OpenComputers raw GitHub installation flow.

### Changed
- `ingame_model.lua` now:
  - makes transposer optional when using SFM pulse mode (unless hot salt monitor is enabled),
  - validates required OC methods for selected mode,
  - hardens component calls with `pcall`,
  - clamps SFM redstone pulse strength to `0..15`,
  - keeps redstone output low on initialization in `sfm_pulse` mode.
- Expanded `oc/solar_tower/README.md` with deployment wiring guidance for:
  - direct transposer dosing,
  - SFM redstone pulse dosing,
  - in-game assumptions and known telemetry limitation.
- Expanded `oc/solar_tower/README.md` with:
  - explicit transposer cold-salt transfer method options,
  - clear separation of hot-salt export from control loop,
  - offline emulator usage instructions.

## 2026-02-27

### Added
- Implemented `GTNH Solar Tower 50k Controller` plan in [plan.md](./plan.md).
- Added OpenComputers controller module files:
  - [oc/solar_tower/config.lua](./oc/solar_tower/config.lua)
  - [oc/solar_tower/io.lua](./oc/solar_tower/io.lua)
  - [oc/solar_tower/control.lua](./oc/solar_tower/control.lua)
  - [oc/solar_tower/main.lua](./oc/solar_tower/main.lua)
  - [oc/solar_tower/sim_test.lua](./oc/solar_tower/sim_test.lua)
  - [oc/solar_tower/README.md](./oc/solar_tower/README.md)

### Controller behavior implemented
- Exact GTNH heat efficiency and cycle order from `MTESolarTower.checkProcessing()`:
  - `eff = (7000 - abs(H - 50000)^0.8) / 7000`
  - Clear day gain: `floor(340 * eff * 26)`
  - Rain day gain: `floor(170 * eff * 26)` (integer-halved heaters)
  - Night gain: `0`
  - Pre-conversion heat step:
    - `h = H + gain`
    - if `h > 0`: if `h > 100000` then `h = 100000` else `h = h - 10`
  - Insertion target:
    - if `H < 50000` -> `0`
    - else if `h < 30000` -> `0`
    - else `clamp(h - 50000, 0, MAX_INSERT_PER_CYCLE)`

### State machine and safety
- Added `INIT`, `RUN`, `RECOVERY`, and `FAULT` states.
- Enforced failsafe `insert = 0` on:
  - telemetry read failures
  - valve actuation failures
  - reflector mismatch (`!= 340`) when enforcement is enabled
- Added configurable fault hold cycles before re-entry to normal operation.

### Interfaces implemented
- `Tower.read_heat() -> integer`
- `Tower.read_reflector_count() -> integer`
- `Env.is_day() -> boolean`
- `Env.is_raining_effective() -> boolean`
- `Valve.inject_exact(liters:int) -> boolean`
- `Optional.read_hot_salt_delta() -> integer` (optional)

### Logging and scheduling
- Added structured per-cycle log output with state, heat, weather mode, efficiency, gain, pre-conversion heat, insertion, and fault reason.
- Added 10-second cycle scheduler with optional cycle-boundary alignment.

### Testing
- Added offline simulation coverage in `sim_test.lua` for:
  - startup at `H=100000` (clear/rain/night)
  - steady-state setpoint behavior (`~8830` clear, `~4410` rain)
  - recovery mode below `50000`
  - weather transitions
  - telemetry fault handling
  - reflector mismatch behavior
- Runtime note: simulation could not be executed in this environment because Lua runtime is not installed (`lua` command unavailable).

### Deployment notes
- Configure real OC component addresses/method names (or provider overrides) in `config.lua` before in-world deployment.
- Run offline simulation where Lua is available, then run `main.lua` on the OC computer.
