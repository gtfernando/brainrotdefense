# Brainrot Customization Guide

This guide summarizes every knob you can tweak to tailor the Brainrot invasion experience. All paths below are relative to the repo root.

## Quick Reference
- **Tankier/stronger bosses**: Edit stats in `src/ReplicatedStorage/Data/Brainrots.lua` (`maxHealth`, `attack.damage`, `reward` payouts).
- **How many bosses per wave**: Tweak `groups[].count`, duplicate groups, or add new ones inside `src/ReplicatedStorage/Data/BrainrotWaves.lua`.
- **Late-game pacing**: Adjust the math in `inflateWave` (same file) to change automatic counts, spawn spacing, or reward multipliers.
- **Runtime safeguards**: Skip prompts and auto-start timing live in `ServerScriptService/Work/Modules/BrainrotTourism/Runtime.lua`.

## Boss Stats (`src/ReplicatedStorage/Data/Brainrots.lua`)
- **`Defaults`**: Acts as the fallback for any stat you omit in an individual boss definition. Adjusting these values shifts the global baseline (speed, damage, reward, etc.).
- **Per-boss entries** (e.g., `GangsterFootera`): Override any subset of stats:
  - `tier`: Used for progression/UI sorting.
  - `unlockScore`: Score required before the boss can appear in randomly generated waves.
  - `maxHealth`, `moveSpeed`, `arrivalTolerance`. Raise `maxHealth` dramatically here to create mini-bosses with huge life pools; combine with `Defaults.maxHealth` if you want a global increase.
  - `attack` block: `interval`, `damage`, `radius`.
  - `reward` block: `money.min/max` and `progression` (wave progression score).
  - Optional metadata such as `animationId` can be appended as needed by gameplay.
- **`Order` array**: Controls which bosses the procedural wave generator cycles through once you run out of handcrafted waves. Reorder or duplicate names to bias the rotation.

## Wave Layout (`src/ReplicatedStorage/Data/BrainrotWaves.lua`)
- **`BASE_WAVES`**: Explicit definitions for the opening encounters. Each wave entry contains:
  - `index`: Wave number (1-based).
  - `label`: Optional display name.
  - `groups`: Array of spawn groups. Each group supports:
    - `brainrot`: Name from `Brainrots.lua`.
    - `count`: Total units spawned in this group. Increase this to send more of the same boss per wave, or add multiple groups referencing the same `brainrot` if you want staggered drops.
    - `interval`: Seconds between spawns (defaults to `DEFAULT_INTERVAL`).
    - `spawnDelay`: Delay before the first unit of this group drops.
    - `burst`: Boolean to emit the entire group without extra delays once the first unit spawns.
  - `skipThreshold`: Fraction (0-1) that determines when the skip prompt becomes available. Runtime clamps this to ≥75% to satisfy the latest design requirement.
  - `rewardMultiplier`: Scales the min/max coin payout for every Brainrot in the wave.
- **Procedural waves**: After the indices defined in `BASE_WAVES`, `inflateWave` autogenerates additional content using:
  - The `ORDER` table to choose primary/secondary/tertiary bosses.
  - A gradually shortening `interval` plus increasing `count` formulas.
  - Automatic reward scaling via `rewardMultiplier = 1 + ((index - 1) * 0.15)`.
  Adjust the math in `inflateWave` if you want different late-game pacing.

## Skip Prompt & Auto-start Behavior
- Skip prompts only appear after defeating at least 75% of a wave. You can raise the per-wave `skipThreshold`, but the runtime enforces the 75% floor.
- Once a wave is cleared, the server automatically schedules the next wave after `WAVE_START_DELAY` seconds. Leaving the session now records the upcoming wave, so players resume where they left off.

## Wave Persistence
- Player profiles (`src/ServerScriptService/Work/Modules/Profiles.lua`) now include `BrainrotProgress.currentWave` (version 3). Runtime writes to this field whenever:
  - A wave begins.
  - A wave is cleared (stores the next wave index).
  - The controller is marked as defeated.
- When a player rejoins their plot, the controller loads `currentWave` and resets the HUD to that number. To reset progress manually, edit this field in the player's profile (or bump the template default).

## Common Customization Scenarios
1. **Add a new boss**: Drop its mesh into `ReplicatedStorage/Assets/Brainrots/`, create a stats entry in `Brainrots.lua`, and append its name to `Order`.
2. **Change how many enemies spawn**: Edit the `count`, `interval`, or `spawnDelay` values in the relevant `BASE_WAVES` entry.
3. **Make early waves harder/easier**: Adjust per-wave `rewardMultiplier` and `skipThreshold`, or tweak the defaults that procedural waves inherit.
4. **Global difficulty pass**: Modify `Defaults` (e.g., raise `attack.damage` or lower `reward.money.max`) to affect every boss without touching individual definitions.
5. **Extra-strong boss showcase**: Create or edit a boss entry with high `maxHealth`, bump its `reward.progression`, and add multiple `groups` referencing it in the target wave.

### Example: Harder Wave 5
```luau
-- src/ReplicatedStorage/Data/BrainrotWaves.lua
BASE_WAVES[5] = {
  index = 5,
  label = "Mini Boss Onslaught",
  groups = {
    { brainrot = "GangsterFootera", count = 6, interval = 2 },
    { brainrot = "ChiefGula", count = 2, spawnDelay = 8, burst = true },
  },
  rewardMultiplier = 1.75,
  skipThreshold = 0.85,
}
```
Combine this with a `GangsterFootera` override that boosts `maxHealth` to, say, 10_000 to create a noticeable spike in difficulty.

Keep these files in sync and the Brainrot runtime will automatically pick up your changes the next time the server boots via `Runtime.Init()`.