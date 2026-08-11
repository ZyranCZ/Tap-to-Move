# Tap to Move

**Tap to Move** adds modern touch and mouse navigation to **Pokémon Gen1Recomp**.

Tap a destination in the overworld and the player walks there using collision-aware A* pathfinding. The mod drives normal Gen1Recomp movement input rather than rewriting player coordinates, so collisions, encounters, ledges, scripts, trainers and movement timing remain controlled by the game.

## Features

- **Tap to Move** with A* pathfinding around walls, buildings, NPCs and other obstacles.
- **Hold to Steer** with speed-aware retarget delay.
- **NPC and interaction targeting** for trainers, visible items, signs, PCs, counters, bookshelves and other supported fixtures.
- **Hidden treasure interaction** — tapping the exact ordinary tile containing an undiscovered hidden item/coin routes beside it, turns the player toward it and presses normal A; the mod does not reveal hidden treasure elsewhere on the map.
- **Smart doors and exits**, including directional warps, carpets, map-edge exits, scripted holes and multi-floor exit journeys.
- **Connected-map navigation** across normal Route/Town connections.
- **Ledge-aware routing** with legal one-way jumps.
- **CUT interaction targeting** — clicking a cuttable tree/plant routes beside it, turns the player correctly and uses Gen1Recomp's real CUT action, including the normal “hacked away with CUT!” text and animation. CUT trees remain ordinary obstacles for normal pathfinding and are never chosen automatically as shortcuts.
- **Seamless Surf routing** — when the party can legally use SURF, A* may route across water; at the shoreline Tap to Move turns the player toward the water, mounts Surf without the party-menu dialog/flash, and continues the same route with normal movement input. Returning to walkable land uses Gen1Recomp's normal automatic dismount.
- **Dynamic replanning** when NPCs move into the planned path.
- **Path Preview** with SHORT and FULL modes.
- **Avatar semantic pass-through** — if an NPC, interaction, entrance, door or other meaningful target is visually behind the player sprite, tapping there targets that object instead of incorrectly treating the avatar as the destination.
- **Manual controls always take priority** over automatic movement.
- **Performance tuning** — `PERFORMANCE BUDGET` limits A* node expansion, connected-map seam/nearest-target work and initial Smart Exit warp scoring. On bounded profiles, an over-budget click into a connected map gracefully becomes movement toward the nearest reachable edge point on the current map instead of being ignored. It exposes only VERY LOW / MEDIUM / FULL, with FULL as the default. VERY LOW and MEDIUM are intentionally aggressive low-CPU profiles. FULL preserves the original search scope; lower profiles trade difficult-route coverage for lower CPU cost. `HOLD RETARGET RATE` separately controls how often Hold to Steer recalculates its target. Voxel Path Preview reprojection is fixed at a conservative 0.25/s to protect weaker devices. Flat 2D Path Preview shares one camera transform per draw instead of rebuilding it for every marker. Map transitions flush map-sensitive runtime caches and wait for the new map authorities to agree before replanning.
- Optional **Resume After Wild Encounter**.
- Optional mobile **Dialogue Touch Control** and **Battle Touch Control**.
- Optional **START/SELECT touch gestures**, including player hold or pinch/spread.
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

## What's new in v1.5

- Added full native **PotatoVoxel** support.
- Refactored Voxel integration into a shared provider-adapter architecture used by both PotatoVoxel and Dramatic Shape.
- Added live internal-canvas scaling so PotatoVoxel HIGH / MEDIUM / LOW / POTATO targeting stays aligned with the rendered scene.
- Added provider-aware cache invalidation and asynchronous Voxel readiness protection.
- Path Preview, avatar hit testing and 3D picking now share the same Voxel coordinate transform.
- Restored semantic click-through when a meaningful interaction or entrance is visually behind the player's avatar.
- Added exact-tap collection support for Gen I hidden items/coins using the normal arrival/facing/A interaction flow.
- Added seamless A* routing across water when Gen1Recomp reports SURF as legally usable, including automatic dialog-free mounting at land→water transitions.
- Added semantic CUT tree targeting while preserving Gen1Recomp's normal CUT text, block swap, animation and SFX. CUT is only used after an explicit tree click; ordinary routes avoid cuttable trees.
- Preserved existing Dramatic Shape compatibility and all normal 2D behavior.
- Added configurable Performance Budget and renamed the old Performance Input option to the more accurate Hold Retarget Rate.
- Removed the nonfunctional Shake-to-B option and fixed Voxel Path Preview reprojection to 0.25/s instead of exposing unsafe higher rates.

## Installation

Install the mod normally through Gen1Recomp's mod system.

No Voxel mod is required. Dramatic Shape and PotatoVoxel are optional integrations.

## Notes

Tap to Move intentionally uses normal Gen1Recomp movement and interaction systems whenever possible. It does not reveal secret hidden items merely because their event data exists. Hidden treasure is considered only after the player explicitly taps its exact tile, and the item is still collected through Gen1Recomp's normal faced-cell A interaction. Fixed hidden-event fixtures are likewise treated as pathfinding targets rather than being activated remotely.
