# Tap to Move

> **v1.0.1:** Fixes Voxel smart-exit detection when an exterior 3D wall is built over a gameplay cell that the 2D collision overview still reports as walkable.

**Tap to Move** adds modern touch navigation to **Pokémon Gen1Recomp**.

Tap anywhere in the overworld and your character immediately starts walking toward that point using collision-aware pathfinding. Hold your finger on the world to continuously steer as the camera moves.

The mod does **not** teleport the player. It drives the real Gen1Recomp movement input, so normal collisions, encounters, warps, ledges, scripts, trainers and movement timing remain controlled by the game.

## Features

- **Tap to walk** — movement starts immediately on pointer press.
- **Hold to steer** — keep your finger down and the destination updates as the world moves under it.
- **A\* pathfinding** around walls, buildings, NPCs and other obstacles.
- **Nearest legal destination** — tapping/holding an unreachable wall, building or object still moves you as close to it as the game legally allows.
- **Sticky doors** — once a real door/warp is targeted, temporary invalid samples caused by camera movement do not cancel the route.
- **NPC targeting** — tapping or holding over an NPC makes the player approach that NPC, including moving NPCs.
- **Release-gated interactions** — reaching an NPC while the finger is still held does not accidentally press A; interaction occurs only once the gesture has been released.
- **Contextual Tap to Interact** for NPCs, trainers, visible item balls, signs, PCs, counters and other supported fixed interaction surfaces.
- **Ledge-aware routing**, including legal one-way jumps and ledges that cross directly into another connected map.
- **Seamless connected-map movement** — routes can continue through normal Route/Town map connections without requiring another tap.
- **Smart interior exits** — tapping outside an interior tells the mod to find a real path out. In multi-floor/interconnected interiors it can continue through internal stairs/warps until it reaches the outside.
- **Path Preview** — optional SHORT or FULL breadcrumb visualization of the planned route.
- **Dynamic replanning** when NPCs move into the route or runtime collision results differ from the initial plan.
- **Manual controls always win** — D-pad/controller input immediately takes priority over Tap to Move.
- Optional **Resume After Wild Encounter**.

## Dramatic Shape / VOXEL support

Tap to Move includes native compatibility with the **Dramatic Shape Voxel Mod**.

Instead of pretending the 3D scene is still a flat 2D grid, the mod reads Dramatic Shape's live Voxel camera and scene information. Touches are resolved through the actual 3D view so buildings, walls, raised surfaces, NPCs and ground are interpreted from the same scene the player sees.

Voxel support includes:

- native 3D ray-based target picking;
- live Voxel camera/view-projection handling;
- raised structure and ground-height awareness;
- curved-world compatibility;
- Android/high-DPI framebuffer handling;
- Voxel-aware Path Preview;
- Voxel-aware Hold to Steer;
- Voxel-aware smart interior exits;
- directly connected map targeting.

Dramatic Shape is an **optional dependency**. If it is not installed or Voxel mode is disabled, Tap to Move automatically uses its normal 2D targeting path.

## Tap, hold and interactions

There is no longer a delay before the player starts walking.

1. **Press:** navigation starts immediately.
2. **Keep holding:** after the configured Hold Steer Delay, the mod begins periodically retargeting the world position under your finger.
3. **Release:** continuous steering stops. If the destination is an armed interactive target and the player has reached the correct interaction position, the mod may then press A.

This makes long Hold Steer delays useful without making ordinary taps feel sluggish.

### Doors while steering

Doors are treated as semantic targets. If a Hold to Steer sample hits a real door and later samples temporarily land on nearby wall geometry, the door route remains active. A new genuinely legal movement target replaces the door target immediately.

### NPCs while steering

NPCs are also semantic targets. The mod tracks the NPC by identity rather than only remembering the tile that was originally touched. If the NPC moves, the route can follow it.

If the player reaches the NPC while the finger is still down, Tap to Move waits. It does not press A until the gesture has been released.

## Entering buildings

Entering a real room-style building from outdoors creates a deliberate gesture boundary.

If you were holding your finger while entering the building, that old held gesture is ignored inside until you release it and press again. This prevents the same finger position from immediately steering the player back out through the entrance.

Normal connected-map transitions such as Route → Route or Town → Route are not treated this way and remain continuous.

## Mods Options

### TAP TO MOVE
Enable or disable the mod.

### MOUSE CONTROL
Allow left mouse click as world input. Useful for desktop play/testing.

### TAP TO INTERACT
Allow interactive world targets to be approached and activated after release.

### HOLD TO STEER
Enable continuous destination retargeting while a world touch remains held.

### HOLD STEER DELAY
How long a touch must remain held before continuous retargeting starts.

**Default: 800 ms**

This does **not** delay the initial movement. Walking begins immediately on press.

### PERFORMANCE INPUT FREQUENCY
Controls how often expensive held-pointer input/retarget work is performed.

- **LOW** — most responsive / highest cost
- **MEDIUM**
- **BALANCE** — default
- **HIGH**
- **ULTRA** — lowest input-check frequency / lowest cost

### VOXEL PATH RATE
Controls how often Voxel Path Preview points are reprojected through the live 3D camera.

Options:

- **0.25/S — default**
- **1/S**
- **2/S**
- **5/S**
- **10/S**

The already calculated breadcrumbs remain visible between updates, so very low values can substantially reduce Voxel rendering overhead without making the preview blink.

### TAP FEEDBACK
Show brief destination/invalid-target feedback.

### PATH PREVIEW
- **OFF**
- **SHORT**
- **FULL**

### RESUME AFTER WILD
Continue a stored route after a wild encounter.

**Default: OFF**

### DEBUG OVERLAY
Show navigation/debug diagnostics.

**Default: OFF**

## Safety and game rules

Tap to Move intentionally leaves gameplay authority with Gen1Recomp.

The mod:

- never teleports the player;
- never directly writes player coordinates;
- does not reveal hidden items;
- does not automatically use CUT, SURF or STRENGTH;
- does not solve Strength or other overworld puzzles;
- does not force movement through a collision the game rejects;
- stops or yields when scripts, menus, trainer engagement or other engine-owned states take control.

Warp tiles may be valid destinations, but the pathfinder does not intentionally use unrelated warps as shortcuts through a route.

## Installation

Install the mod through Gen1Recomp's normal mod installation method, then enable **Tap to Move** in the Mods menu.

For 3D overworld play, install/enable **Dramatic Shape Voxel Mod** as well. Tap to Move detects it automatically; no separate compatibility toggle is required.

## Compatibility philosophy

Tap to Move does not hard-lock itself to one specific Gen1Recomp version. It attempts to run on newer versions and should only require an update when an actual API/runtime incompatibility appears.

The Dramatic Shape integration uses its exported companion-library interface where available rather than modifying Voxel rendering behavior.

## Version

**1.0.0**
