# Tap to Move

**Tap to Move** adds modern touch and mouse navigation to **Pokémon Gen1Recomp**, with full support for **Red / Blue / Yellow / Gold** in v2.3.3.

Tap a destination in the overworld and the player walks there using collision-aware A* pathfinding. The mod drives normal Gen1Recomp movement input rather than rewriting player coordinates, so collisions, encounters, ledges, scripts, trainers and movement timing remain controlled by the game. On Gold it uses Gold's native collision, field-move and overworld rules rather than forcing Gen 1 map mechanics onto Gen 2.


## v2.3.3

- Replaces the overlapping **Battle Touch Controls** and **Menu Touch Controls** settings with one unified **UI Touch Controls** switch. It covers direct hit-testing for supported battle UI, Party, Bag/Pack, Options and other native menu surfaces.
- **UI Touch Controls defaults to OFF** on fresh installs because third-party UI mods can move or reshape native UI elements and require their own compatibility layer before direct hit-testing is safe.
- Uses the new `ui_touch_controls` option key, so an upgrade does **not** inherit a previously saved ON value from either legacy touch setting. Players explicitly opt in after updating.
- **Touch Confirmations** remains immediately after UI Touch Controls and still defaults to **Two Clicks**. Directional Swipes remains separate and enabled by default.
- Battle Art 1.9.0 compatibility from v2.3.2 and the v2.3.1 native-menu alignment fix are unchanged.

## v2.3.2

- Adds an explicit **Battle Art 1.9.0 compatibility provider** under its real manifest id `BATTLE_ART_VOXEL_FORK`.
- Battle Art 1.9.0 exports the same `exports.lib` VoxelState/Voxel3D scene contract as the Dramatic family, but does not identify itself as `DRAMATIC_SHAPE`; older Tap to Move builds therefore saw Battle Art's 3D `worldOverride` while failing to discover any Voxel provider and overworld taps ended in `no_view`.
- Battle Art is now an optional dependency so its exported 3D scene API is available before Tap to Move performs provider discovery.
- Existing Dramatic Shape, Potato Voxel, vanilla, Gold, battle touch and menu touch paths are unchanged.

## v2.3.1

- Fixes **Menu Touch Controls alignment**, especially in Gold/Gen 2 PARTY, PACK and OPTION screens. Two-line rows now keep their second line (HP / quantity / option value) inside the same tappable item instead of incorrectly selecting the following row.
- Captures the exact UI scale/origin from the rendered frame before pointer input, preventing drift when zoom/DYNAMIC UI or display scaling changes the visible menu transform.
- Battle touch and overworld Tap to Move logic are intentionally unchanged.

## v2.3.0

- Adds **Menu Touch Controls** (default ON) for direct taps on standard UI choices outside battle.
- Party Pokémon, Bag/Pack items, Options rows, Start-menu entries, generic list/menu rows, submenus and YES/NO prompts can be selected by touching the visible item.
- **Touch Confirmations** now applies to both battle and menu direct touch: with **Two Clicks**, the first tap only moves the native cursor/highlight and the second tap on the same item confirms it.
- Keeps normal engine input semantics: direct touch selects the engine's own cursor/index, then confirms through the regular A input instead of bypassing menu logic.
- Preserves Gen 1 + Gold support and the existing Battle Touch / Directional Swipe behavior.

## v2.2.0

- Reworked touch options: the legacy dialogue/battle swipe layer is now a single **Directional Swipes** toggle.
- **Battle Touch Controls** now specifically means direct tapping of the visible battle choice: FIGHT / PKMN / ITEM / RUN or an exact move slot.
- Added **Touch Confirmations** immediately after Battle Touch Controls with **One Click** and **Two Clicks**. The default is **Two Clicks**.
- Under **Two Clicks**, the first tap only moves the game's native battle cursor so the target is visibly highlighted; tapping that same target a second time emits the normal A input and confirms it. Tapping a different target only moves the highlight to the new target.
- Fresh installs now enable the normal gameplay/control features by default, including Directional Swipes, Battle Touch Controls, START/SELECT hold, FULL Path Preview, Resume After Wild and desktop mouse shortcuts. **DEBUG OVERLAY** and the mutually-exclusive **Experimental Simple Mode** remain opt-in because enabling either would change normal presentation/navigation rather than merely activate a control surface.
- Existing battle rules remain authoritative: the mod still never calls a move/item/run action directly; confirmation goes through the native A path.


## v2.1.0

- Added **direct battle UI tapping** on top of the existing Battle Touch Control / desktop LMB=A layer.
- Tapping **FIGHT / PKMN / ITEM / RUN** now targets that exact native battle-menu slot before confirming with the game's normal A input.
- Tapping a visible move selects the exact move slot (including Gen 1 WIDE 2x2 move layout) and then confirms it through native battle logic.
- Supports classic Gen 1, Gen 1 WIDE, Gold/Gen 2, high-DPI scaling and Battle Size FILL; the hit test follows the engine UI canvas, so 3D battle backgrounds such as Dramatic Shape do not require screenshot-resolution-specific coordinates.
- Message phases and party/bag/other overlays deliberately fall back to the existing tap=A / swipe=D-pad / hold=B controls instead of mutating a covered BattleState.
- No new public option was added: mobile uses the existing **BATTLE TOUCH CONTROL**, while desktop uses the existing **MOUSE LMB/RMB=A/B** option.
- All v2.0.5 TILT, Gold entrance-intent and Game-Speed/Hold-Steer fixes are preserved.


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
- **Resume After Wild Encounter** is enabled by default on fresh installs.
- Mobile **Directional Swipes** is enabled by default. **UI Touch Controls** defaults to **OFF** so UI mods cannot silently invalidate direct hitboxes.
- **Touch Confirmations** defaults to **Two Clicks** whenever UI Touch Controls is enabled.
- **START/SELECT touch control** defaults to **Hold Player Sprite**.
- Desktop mouse walk, LMB/RMB, wheel and side-button shortcuts are enabled by default.

## Voxel support

Tap to Move supports full 3D navigation with:

- **Dramatic Shape Voxel Mod**
- **Battle Art Voxel Fork 1.9.0+**
- **PotatoVoxel**

Dramatic Shape, Battle Art and PotatoVoxel use the same Tap to Move navigation engine through a shared **Voxel Provider Adapter**. The adapter reads the active renderer's exported camera and scene capabilities, so 3D ray picking, NPC targeting, doors, hidden-event fixtures, Smart Exits, connected maps, avatar hit testing and Path Preview use the actual Voxel scene.

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

No Voxel mod is required. Dramatic Shape and PotatoVoxel are optional integrations.

## Notes

Tap to Move intentionally uses normal Gen1Recomp movement and interaction systems whenever possible. It does not reveal secret hidden items merely because their event data exists. Hidden treasure is never displayed or remotely exposed by the mod. It can be selected by an exact tap, or by the Gold post-arrival finisher when the player has already stopped directly beside it; collection still happens through Gen1Recomp's normal faced-cell A interaction. Fixed hidden-event fixtures are likewise treated as pathfinding targets rather than being activated remotely.

### Gold interaction tolerance

- Indoor taps that would otherwise become Smart Exit/barrier-door intent now first check a small rendered-space halo around real reachable NPCs, visible item-ball entities and fixed Gold bg-event interactions.
- Exact native door/carpet/hole/interaction taps remain authoritative, so the tolerance cannot disable ordinary room exits.
- The assist is screen-space aware, so the same practical miss tolerance is preserved across zoom and TILT.
