# Tap to Move

**Tap to Move** adds modern touch and mouse navigation to **Pokémon Gen1Recomp**, with full support for **Red / Blue / Yellow / Gold** in v2.0.7.

Tap a destination in the overworld and the player walks there using collision-aware A* pathfinding. The mod drives normal Gen1Recomp movement input rather than rewriting player coordinates, so collisions, encounters, ledges, scripts, trainers and movement timing remain controlled by the game. On Gold it uses Gold's native collision, field-move and overworld rules rather than forcing Gen 1 map mechanics onto Gen 2.


## v2.0.7

- Added native **Dramaless Shape Voxel Mod** compatibility for `DRAMALESS_SHAPE` (verified against Dramaless v2.0.1).
- Dramaless is discovered through the existing shared Voxel Provider Adapter and uses its fork-preserved `VoxelState`, `Voxel3D`, `VoxelScene`, `Structures`, `TileShape` and `FirstPerson` exports for real 3D picking and Path Preview.
- Added Dramaless as an optional dependency so its exported Voxel scene is available before Tap to Move performs provider discovery.
- Dramaless free-camera/first-person touch ownership remains authoritative because its raw `Game:touch*` handlers are loaded before Tap to Move and claimed camera touches never reach Tap-to-Move navigation.
- Dramatic Shape, Battle Art, PotatoVoxel, normal 2D rendering and Gold behavior are otherwise unchanged.

## v2.0.6

- Added native **Battle Art Voxel Fork** compatibility for `BATTLE_ART_VOXEL_FORK` (verified against Battle Art v1.9.0).
- Battle Art is discovered through the existing shared Voxel Provider Adapter and uses its fork-preserved `VoxelState`, `Voxel3D`, `VoxelScene`, `Structures` and `TileShape` exports for real 3D picking and Path Preview.
- Added Battle Art as an optional dependency so its exported Voxel scene is available before Tap to Move performs provider discovery.
- Battle Art's **1ST** first-person input ownership remains authoritative: when Battle Art claims a pointer for camera/A/B control, Tap to Move does not also start navigation.
- Dramatic Shape, PotatoVoxel, normal 2D rendering and Gold behavior are otherwise unchanged.


## v2.0.5

- Fixed **HOLD STEER DELAY × Game Speed** timing. The previous implementation multiplied the configured milliseconds by Game Speed but then measured the delay on the equally accelerated fixed-step clock, cancelling the multiplier in real time.
- `150 ms` at `3X` now really waits about `450 ms` before Hold-to-Steer retargeting begins (and analogously for other Game Speed values).
- Initial Tap-to-Move routing, Hold Retarget Rate, TILT handling and Gold entrance intent are otherwise unchanged.


## v2.0.4

- Gold entrance intent now uses a route-relative safety budget instead of a hard door-to-tap radius.
- Tapping high on a tall building can once again route to its nearest valid entrance, while entrances requiring more than roughly four extra steps beyond the requested travel distance are still rejected.

## v2.0.3 — Gold local door-intent guard

- Stops an invalid tap on a Gold building/facade from routing to an unrelated entrance tens of tiles away.
- Normal barrier-door inference now accepts only entrances roughly within four gameplay tiles of the pointer (4.5-cell centre/edge tolerance).
- It also rejects entrances whose executable route is more than four steps longer than the pointer's apparent travel distance, preventing huge detours around connected walls/facades.
- The narrow visual door magnet is unchanged, and explicit connected-map gatehouse/portal rescue keeps its long-range behavior.
- Gen 1, TILT handling, settings, and ordinary pathfinding are otherwise unchanged.

## v2.0.2 — TILT input fix

- Fixes Tap to Move becoming unusable when Gen1Recomp TILT is set to 15, 35, or 50.
- Gen 1 now captures the grown TILT world-canvas geometry and inverse-projects pointer coordinates through the exact v0.1.86 perspective equation before pathfinding.
- Player hit-testing and path-preview projection now follow the same upright-billboard / tilted-ground transform as the engine.
- Flat rendering, Gold support, Voxel support, options, and pathfinding behavior are otherwise unchanged.


## Features

- **Tap to Move** with A* pathfinding around walls, buildings, NPCs and other obstacles.
- **Hold to Steer** with speed-aware retarget delay.
- **NPC and interaction targeting** for trainers, visible items, signs, PCs, counters, bookshelves and other supported fixtures.
- **Hidden treasure interaction** — exact taps still target hidden items directly, and the Gold post-arrival semantic finisher can also use a hidden interaction that is cardinal-adjacent to the final stopped cell. Hidden data is never rendered as a marker or exposed remotely.
- **Smart doors and exits**, including directional warps, carpets, map-edge exits, scripted holes and multi-floor exit journeys.
- **Connected-map navigation** across normal Route/Town connections, including a single tap onto a visible Gold map rendered multiple seamless connection hops away.
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
- **Battle Art Voxel Fork**
- **Dramaless Shape Voxel Mod**
- **PotatoVoxel**

All supported Voxel renderers use the same Tap to Move navigation engine through a shared **Voxel Provider Adapter**. The adapter reads the active renderer's exported camera and scene capabilities, so 3D ray picking, NPC targeting, doors, hidden-event fixtures, Smart Exits, connected maps, avatar hit testing and Path Preview use the actual Voxel scene.

PotatoVoxel's HIGH, MEDIUM, LOW and POTATO render scales are handled from the renderer's live internal canvas dimensions rather than hardcoded scale values.

All Voxel mods are optional. Without a supported Voxel renderer, Tap to Move automatically uses its normal 2D targeting path.

## Experimental Simple Mode

**EXPERIMENTAL: Simple Mode** is a renderer-agnostic fallback for visual or Voxel mods that cannot expose enough scene information for normal Tap to Move targeting.

It directly converts the finger direction into normal movement input instead of using 2D/3D target picking and A* pathfinding.

Simple Mode is **OFF by default** and is **not required for PotatoVoxel, Dramatic Shape, Battle Art or Dramaless**.

Its available tuning options remain:

- Center Deadzone
- Axis Deadzone
- Dominance Ratio

## What's new in v2.0.1

- Migrated platform detection for the Gen1Recomp v0.1.86 sandbox: the mod no longer accesses blocked `love.system` directly.
- Preserves Android/iOS/Desktop/Switch host gating through Gen1Recomp's engine-side `Platform` compatibility helper.
- Keeps the existing Red / Blue / Yellow / Gold behavior and settings unchanged.

## What's new in v2.0.0

- Added full **Pokémon Gold / Gen 2** support while preserving the established Red / Blue / Yellow behavior.
- Gold pathfinding uses native Gen 2 collision, ledges, one-way movement, ice/current behavior, warps, carpets, doors, stairs and map connections.
- Added reliable **connected-map navigation**: a single tap can cross seamless Route/Town boundaries, continue through multiple visible map connections, and replan from the real landing cell after each native transition.
- Added **smart portal/gatehouse routing**. When a visible remote destination cannot be reached by a direct seamless connection, Tap to Move can infer the appropriate doorway, cross the intervening interior and resume toward the original remote target.
- Door intent is **tap-centric**: when a click is slightly beyond a building, the building and door closest to the actual click are preferred rather than whichever door is closest to the player.
- Added Gold-native interaction targeting for NPCs, trainers, visible items, counters, signs, fixed bg events and collision-standard fixtures such as **PCs, bookshelves, radios, town maps, mart shelves, TVs, windows and incense burners**.
- Added a post-arrival interaction finisher: after reaching the correct approach cell, Tap to Move releases movement, turns the player, verifies the real facing and turn completion, and only then presses **A**.
- Hidden items remain secret and are never displayed remotely; exact taps and legitimate adjacent post-arrival interactions still use the game's normal faced-cell A interaction.
- Added conservative near-miss tolerance around interactive NPCs/objects before Smart Exit is chosen, while exact door/carpet/hole taps remain authoritative.
- Added native Gold CUT and Surf routing through the game's own field-move eligibility and execution paths.
- Added Gold-aware battle resume classification, touch controls, START/SELECT gestures, accurate flat/TILT picking and matching Path Preview projection.
- Preserved manual-input priority and moved Gold automated walking to one synthetic direction press per actual cell step, preventing old-direction spillover at corners.

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

No Voxel mod is required. Dramatic Shape, Battle Art, Dramaless and PotatoVoxel are optional integrations.

## Notes

Tap to Move intentionally uses normal Gen1Recomp movement and interaction systems whenever possible. It does not reveal secret hidden items merely because their event data exists. Hidden treasure is never displayed or remotely exposed by the mod. It can be selected by an exact tap, or by the Gold post-arrival finisher when the player has already stopped directly beside it; collection still happens through Gen1Recomp's normal faced-cell A interaction. Fixed hidden-event fixtures are likewise treated as pathfinding targets rather than being activated remotely.

### Gold interaction tolerance

- Indoor taps that would otherwise become Smart Exit/barrier-door intent now first check a small rendered-space halo around real reachable NPCs, visible item-ball entities and fixed Gold bg-event interactions.
- Exact native door/carpet/hole/interaction taps remain authoritative, so the tolerance cannot disable ordinary room exits.
- The assist is screen-space aware, so the same practical miss tolerance is preserved across zoom and TILT.
