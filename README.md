# Tap to Move

**Tap to Move** adds modern touch and mouse navigation to **Pokémon Gen1Recomp**.

Tap a destination in the overworld and the player walks there using collision-aware A* pathfinding. The mod drives normal Gen1Recomp movement input rather than rewriting player coordinates, so collisions, encounters, ledges, scripts, trainers and movement timing remain controlled by the game.

## Features

- **Tap to Move** with A* pathfinding around walls, buildings, NPCs and other obstacles.
- **Hold to Steer** with speed-aware retarget delay.
- **NPC and interaction targeting** for trainers, visible items, signs, PCs, counters, bookshelves and other supported fixtures.
- **Smart doors and exits**, including directional warps, carpets, map-edge exits, scripted holes and multi-floor exit journeys.
- **Connected-map navigation** across normal Route/Town connections.
- **Ledge-aware routing** with legal one-way jumps.
- **Dynamic replanning** when NPCs move into the planned path.
- **Path Preview** with SHORT and FULL modes.
- **Avatar semantic pass-through** — if an NPC, interaction, entrance, door or other meaningful target is visually behind the player sprite, tapping there targets that object instead of incorrectly treating the avatar as the destination.
- **Manual controls always take priority** over automatic movement.
- Optional **Resume After Wild Encounter**.
- Optional mobile **Dialogue Touch Control** and **Battle Touch Control**.
- Optional **START/SELECT touch gestures**, including player hold or pinch/spread.
- Optional **Shake to B** on supported phones.
- Optional desktop mouse shortcuts.

## Voxel support

Tap to Move supports full 3D navigation with:

- **Dramatic Shape Voxel Mod**
- **PotatoVoxel**

Both use the same Tap to Move navigation engine through a shared **Voxel Provider Adapter**. The adapter reads the active renderer's exported camera and scene capabilities, so 3D ray picking, NPC targeting, doors, hidden-event fixtures, Smart Exits, connected maps, avatar hit testing and Path Preview use the actual Voxel scene.

PotatoVoxel's HIGH, MEDIUM, LOW and POTATO render scales are handled from the renderer's live internal canvas dimensions rather than hardcoded scale values.

Both Voxel mods are optional. Without a supported Voxel renderer, Tap to Move automatically uses its normal 2D targeting path.

## Experimental Simple Mode

**EXPERIMENTAL: Simple Mode** is a renderer-agnostic fallback for visual or Voxel mods that cannot expose enough scene information for normal Tap to Move targeting.

It directly converts the finger direction into normal movement input instead of using 2D/3D target picking and A* pathfinding.

Simple Mode is **OFF by default** and is **not required for PotatoVoxel or Dramatic Shape**.

Its available tuning options remain:

- Center Deadzone
- Axis Deadzone
- Dominance Ratio

## What's new in v1.4.0

- Added full native **PotatoVoxel** support.
- Refactored Voxel integration into a shared provider-adapter architecture used by both PotatoVoxel and Dramatic Shape.
- Added live internal-canvas scaling so PotatoVoxel HIGH / MEDIUM / LOW / POTATO targeting stays aligned with the rendered scene.
- Added provider-aware cache invalidation and asynchronous Voxel readiness protection.
- Path Preview, avatar hit testing and 3D picking now share the same Voxel coordinate transform.
- Restored semantic click-through when a meaningful interaction or entrance is visually behind the player's avatar.
- Preserved existing Dramatic Shape compatibility and all normal 2D behavior.

## Installation

Install the mod normally through Gen1Recomp's mod system.

No Voxel mod is required. Dramatic Shape and PotatoVoxel are optional integrations.

## Notes

Tap to Move intentionally uses normal Gen1Recomp movement and interaction systems whenever possible. It does not reveal secret hidden items merely because their event data exists, and fixed hidden-event fixtures are treated as pathfinding targets rather than being activated remotely.
