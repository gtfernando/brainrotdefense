# Brainrot Wave Runtime Plan

## Goals
- Replace the legacy difficulty percentage system with an infinite wave model.
- Represent wave + agent state using JECS so per-plot controllers are lightweight and queryable.
- Keep battle mechanics (pathing, mutation effects, placement damage) intact.
- Give the client deterministic state packets: wave state, timer, and skip prompts.
- Only leverage JECS, Promise, and Signal from `ReplicatedStorage.Packages` to satisfy dependency constraints.

## High-Level Architecture
1. **WaveWorld (JECS)**
   - Each plot controller owns a JECS entity storing components: `ControllerRef`, `WaveNumber`, `WaveStatus`, `Spawned`, `Defeated`, `SkipThreshold`, `PromptIssued`.
   - The entity is authoritative for the HUD state we send to clients. Updates trigger local Signals so packets stay in sync.

2. **WaveController class (per plot)**
   - Responsible for transitioning through `idle -> arming -> spawning -> cooldown -> idle` loops.
   - Maintains spawn queues built from `ReplicatedStorage.Data.BrainrotWaves` schemas.
   - Uses `Promise.delay` for cooldown scheduling so ticks remain deterministic.
   - Emits events through `Signal` instances (`stateChanged`, `timerChanged`, `promptChanged`).

3. **Agent Runtime**
   - Reuses the existing agent movement + damage logic but annotates every agent with `waveIndex` and `spawnGroupId` for bookkeeping.
   - When an agent is removed, the owning `WaveController` increments defeated counts via JECS components and checks skip-eligibility.

4. **Networking**
   - `TourismPackets.WaveState`: fired every time the JECS data mutates (status, counts, prompt flag).
   - `TourismPackets.WaveTimer`: emitted on every timer update (~250ms resolution) to drive the HUD stopwatch.
   - `TourismPackets.WavePrompt`: pushed exactly once per wave when the skip window opens.
   - `TourismPackets.WaveControl`: handles `start` (resets to wave 1 and begins spawning) and `skip` (requires threshold) requests.

5. **Client UX**
   - Start button labelled `INICIAR JUEGO` appears whenever the wave status is `idle` or `defeated`.
   - Timer label always shows `Wave N - mm:ss` with mm:ss derived from `WaveTimer` packets; it resets on each transition.
   - A modal-style skip prompt with `Sí`/`No` buttons surfaces at 75% progress when the server says skipping is available.

6. **Legacy Removal Strategy**
   - Delete difficulty percent persistence, accumulator logic, and manual pause heuristics.
   - Remove the old controller cooldown heuristics that scaled with percent; cooldowns now come from explicit wave schema data.
   - Keep shared utilities (navigation, asset scanning, mutation modifiers) but wrap them inside the new classes for clarity.

## Data Flow Summary
```
Player clicks "INICIAR JUEGO"
    -> WaveControl:start -> WaveController:begin(1)
        -> build spawn groups -> WaveWorld updates -> WaveState packet
        -> heartbeat loop ticks WaveController:step() -> spawns bosses -> Agent logic unchanged
        -> each kill increments Defeated via JECS -> when >= 75% -> WavePrompt packet
        -> when all agents cleared (or skip) -> cooldown Promise -> next wave or reset
```

This plan keeps the combat feel identical while making wave progression deterministic, network-friendly, and easier to tune.
