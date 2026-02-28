# GTNH Solar Tower 50k Controller (OpenComputers) - Decision-Complete Plan

## Summary
Implement an OpenComputers Lua controller that maximizes sustained Hot Solar Salt output by holding Solar Tower heat at `50,000` (half of `100,000` max), using exact GTNH code behavior instead of outdated wiki math.  
Startup condition is fixed: `heat starts at 100,000`.  
Safety condition is strict: if heat is below `50,000`, insert `0` cold salt until recovered.

## Source of Truth
Use GTNH implementation logic from:
- `MTESolarTower.checkProcessing()` in `GT5-Unofficial`
- Formula and cycle order from code, not wiki shorthand

## Public Interfaces / Contracts
Create adapter contracts so control logic is independent of specific OC hardware bindings:

- `Tower.read_heat() -> integer`
- `Tower.read_reflector_count() -> integer`
- `Env.is_day() -> boolean`
- `Env.is_raining_effective() -> boolean`
- `Valve.inject_exact(liters:int) -> boolean`
- `Optional.read_hot_salt_delta() -> integer`

If any adapter call fails or returns invalid values, controller enters fail-safe (`insert = 0`).

## Exact Control Math (GTNH-Correct)
Given current heat `H`:

1. Heat efficiency:
   - `eff = (7000 - abs(H - 50000)^0.8) / 7000`

2. Gain term (`rings=5 -> bonus=16`, `reflectors=340`):
   - Clear day: `gain = floor(340 * eff * 26)`
   - Rain day (GTNH integer-halved heaters): `gain = floor(170 * eff * 26)`
   - Night: `gain = 0`

3. Apply GTNH heat step order:
   - `h = H + gain`
   - if `h > 0`:
     - if `h > 100000` then `h = 100000`
     - else `h = h - 10`

4. Conversion gate and insertion target:
   - If `H < 50000`: `insert = 0` (recovery mode)
   - Else if `h < 30000`: `insert = 0`
   - Else: `insert = clamp(h - 50000, 0, MAX_INSERT_PER_CYCLE)`

This makes post-conversion heat land at `~50000` whenever conditions permit.

## Startup Behavior (Heat = 100000)
At first cycle:
- Day clear: `h` clamps to `100000` -> `insert = 50000`
- Day rain: `h` clamps to `100000` -> `insert = 50000`
- Night: `h = 99990` -> `insert = 49990`

After first cycle, controller converges to steady setpoints near:
- Clear day: `~8830 L / 10s`
- Rain day: `~4410 L / 10s`
- Night: `0 L / 10s`

## State Machine
- `INIT`
  - Validate adapters, reflector count (`340`), and config bounds.
- `RUN`
  - Every `10s`, read telemetry, compute insertion, command valve.
- `RECOVERY`
  - Active when `heat < 50000`: force `insert = 0` until recovered.
- `FAULT`
  - Any telemetry/actuation error: force `insert = 0`, retry; require `N` stable cycles to leave fault.

## Deliverables
- `plan.md` (this plan)
- `oc/solar_tower/config.lua`
- `oc/solar_tower/io.lua`
- `oc/solar_tower/control.lua`
- `oc/solar_tower/main.lua`
- `oc/solar_tower/README.md`
- `oc/solar_tower/sim_test.lua` (offline math/state simulation)

## Implementation Steps
1. Discover actual OC component methods in your world and map them to adapters above.
2. Implement `io.lua` with strict validation, timeouts, and typed return normalization.
3. Implement `control.lua` with exact GTNH math and state machine.
4. Implement cycle scheduler aligned to 10s boundaries.
5. Add structured logging per cycle: `state, H, eff, gain, weather, insert, fault`.
6. Run simulation tests for transition/fault scenarios before in-world deployment.
7. Deploy with valve output clamped; monitor 50 cycles and confirm stability.

## Test Cases / Acceptance
1. `H=100000` startup, clear day -> first insert `50000`, then stabilizes near `8830`.
2. `H=100000` startup, rain -> first insert `50000`, then stabilizes near `4410`.
3. `H=100000` startup, night -> first insert `49990`, then `0` thereafter.
4. Forced drop to `H=48000` -> no insertion until `H>=50000`.
5. Rain/clear transition -> insertion updates next cycle without overshoot.
6. Sensor read failure -> immediate fault mode and `insert=0`.
7. Reflector mismatch (`!=340`) -> refuse RUN and stay safe.

## Assumptions and Defaults
- Runtime is OpenComputers Lua.
- Heat is readable directly from tower telemetry.
- Day/rain signals are available.
- Valve supports exact batch insertion per cycle.
- Reflector count is fixed at maximum (`340`).
- Goal is sustained max output at `50k`, not temporary burst production.
