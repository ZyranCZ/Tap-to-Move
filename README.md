# Tap to Move

> **v1.3.22:** Fixed avatar-click rescue in Dramatic Shape/Voxel mode. Player hit-testing now follows Dramatic Shape's actual live 16x16 leaning billboard instead of approximating the avatar as a vertical column. Avatar ownership is snapshotted on pointer-down, and a confirmed adjacent interaction is resolved before 3D raycasting/Smart Exit, so tapping the player beside a PC can reliably turn toward it and press A.
>
> **v1.3.21:** A short tap on the player now performs a one-tile interaction rescue scan in strict **UP → DOWN → RIGHT → LEFT** priority. If a genuine adjacent NPC/PC/sign/bookshelf/counter or other supported interaction exists, Tap to Move turns toward it and presses A; this bypasses unreliable 3D object picking while never probing empty cells. If no adjacent interaction exists, the previous front-cell avatar proxy remains available.
>
> **v1.3.20:** Smart Exit is now direction-gated. An off-map click above/below/left/right of an interior may only choose a real exit that leaves in the same direction; if no matching exit exists, Tap to Move does nothing instead of sending the player through an unrelated door. Hold-to-Steer retarget samples can no longer create a new Smart Exit solely because camera movement moves the map out from under a held pointer.

> **v1.3.19:** Fixed wall-mounted fixed interactions in Dramatic Shape/Voxel mode, especially Pokémon Center PCs. If the primary 3D ground ray lands outside/behind the room or on non-semantic structure geometry, Tap to Move now performs a semantic-only projected hit recovery; a real PC/sign/bookshelf/counter/NPC can reclaim the tap before Smart Exit, while ordinary scenery cannot.

> **v1.3.18:** Fixed true map-edge warps such as the Cerulean robbed-house wall hole. Edge activation is now independent of carpet rules, so a warp on the top/bottom/left/right boundary always retains its outward D-pad step; direct taps on a directional wall opening also prefer traversal over the fixed background description on the same cell.

**Tap to Move** adds modern touch navigation to **Pokémon Gen1Recomp**.

Tap anywhere in the overworld and your character starts walking toward that point using collision-aware pathfinding. Hold your finger on the world to continuously steer as the camera moves.

The mod does **not** write player coordinates or invent destinations. It drives real Gen1Recomp movement input, so normal collisions, encounters, ledges, scripts, trainers and movement timing remain controlled by the game. For a validated directional exit that fails to consume synthetic input, the mod may invoke Gen1Recomp's own standard warp transition for that exact live warp record.

## Features

- **Tap to walk** — movement normally starts immediately on pointer press. With **PINCH OR SPREAD** selected, the first mobile world touch gets a brief 0.20 s two-finger pairing tolerance (quick single taps are replayed on release).
- **Hold to steer** — keep your finger down and the destination updates as the world moves under it.
- **A\* pathfinding** around walls, buildings, NPCs and other obstacles.
- **Nearest legal destination** — tapping/holding an unreachable wall, building or object still moves you as close to it as the game legally allows.
- **Sticky doors** — once a real door/warp is targeted, temporary invalid samples caused by camera movement do not cancel the route.
- **NPC targeting** — tapping or holding over an NPC makes the player approach that NPC, including moving NPCs.
- **Release-gated interactions** — reaching an NPC while the finger is still held does not accidentally press A; interaction occurs only once the gesture has been released.
- Optional **START/SELECT touch control** — choose either a one-second hold on the player sprite for START, or two-finger pinch/spread controls for SELECT/START.
- Optional **Dialogue Touch Control** — a catch-all for every non-overworld, non-battle UI screen: tap-and-release sends A, a stationary one-second hold sends B, and swiping sends UP/DOWN/LEFT/RIGHT. In the overworld START menu specifically, a tap outside the visible menu box sends B to close it instead of A.
- Optional **Battle Touch Control** — the same tap/hold/swipe scheme throughout battles: release tap = A, stationary one-second hold = B, swipe = D-pad; battle touches are reserved for controls instead of 3D battle camera dragging.
- **Contextual Tap to Interact** for NPCs, trainers, visible item balls, signs, PCs, counters and other supported fixed interaction surfaces.
- **Ledge-aware routing**, including legal one-way jumps and ledges that cross directly into another connected map.
- **Seamless connected-map movement** — routes can continue through normal Route/Town map connections without requiring another tap.
- **Smart interior exits** — tapping outside an interior tells the mod to find a real path out **only when the empty-space click points through the same side of the map as that exit** (UP/DOWN/LEFT/RIGHT). If no real exit matches that direction, no automatic exit is started. When several valid same-direction exits exist, the exit closest to the off-map click is preferred before walking distance from the player. Directional openings use the game's real warp semantics: Tap to Move routes to the actual warp source and appends UP/DOWN/LEFT/RIGHT when required. Scripted dungeon holes are treated as on-step transition targets. In Dramatic Shape Voxel mode, a guarded outside-behind-wall ray can also express a genuine outside-map tap. In multi-floor/interconnected interiors Smart Exit can continue through internal stairs/warps until it reaches the outside.
- **Path Preview** — optional SHORT or FULL breadcrumb visualization of the planned route.
- **Dynamic replanning** when NPCs move into the route or runtime collision results differ from the initial plan.
- **Manual controls always win** — D-pad/controller input immediately takes priority over Tap to Move. A touch that begins on any visible Gen1Recomp virtual control is owned exclusively by that control and cannot also become Tap to Move or a custom gesture.
- Optional **Resume After Wild Encounter**.
- Optional **two-finger START/SELECT mode** — spread simulates START, pinch simulates SELECT, and native pinch/spread zoom is automatically disabled while this mode is selected.
- Optional **controls-free UI input** — on mobile, enable **DIALOG TOUCH CONTROL** to use A/B/D-pad touch gestures on any UI screen outside the bare overworld and battles.
- Optional **controls-free battle input** — enable **BATTLE TOUCH CONTROL** for A/B/D-pad battle gestures without the 3D camera competing for the same drag.
- **Shake to B** on supported phones — a deliberate back-and-forth shake can simulate B without an on-screen button.
- **Optional desktop mouse shortcuts** — all mouse features default OFF. You can separately enable LMB world walking, LMB/RMB A/B shortcuts, wheel UP/DOWN navigation, optional wheel-tilt LEFT/RIGHT navigation, and Mouse 5/Mouse 4 START/SELECT shortcuts.

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

There is normally no delay before the player starts walking. The one deliberate exception is mobile **PINCH OR SPREAD** mode: the first world touch is reserved for up to **0.20 seconds** so a slightly later second finger cannot create a false walking step before the pinch/spread is recognized. A quick one-finger tap that releases inside this window is replayed immediately on release.

1. **Press:** navigation starts immediately, except for the short PINCH OR SPREAD pairing tolerance described above.
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

## START/SELECT touch control

The Mods menu contains one **START/SELECT TOUCH CONTROL** choice with three modes:

- **OFF — default**: the mod adds no START/SELECT touch gesture.
- **HOLD PLAYER SPRITE**: hold directly on the visible player character for **1 second** to simulate **START**.
- **PINCH OR SPREAD**: **spread two fingers apart → START** and **pinch two fingers together → SELECT**.

In **PINCH OR SPREAD** mode the mod takes ownership of the two-finger gesture and automatically disables the native pinch/spread zoom action. Mouse-wheel / keyboard zoom remain untouched.

The gesture fires once after the finger separation changes far enough to clearly identify the direction. On the bare mobile overworld, the **first finger is held for a 0.20-second pairing grace period before Tap to Move sees it**. If finger #2 arrives during that window, both contacts become exclusively owned by the pinch/spread classifier and no single-touch route is ever started. If no second finger arrives, the first touch is promoted normally; a quick single tap that releases before the timer expires is replayed as an ordinary tap. Visible virtual Game Boy controls are not delayed by this tolerance. Starting a two-finger gesture also cancels any already-active Tap to Move route and suppresses pending dialogue/battle/player-hold input, preventing duplicate button presses.

## Controls-free dialogue, battle and B input

Tap to Move can also reduce reliance on the visible Game Boy controls.

### DIALOG TOUCH CONTROL

**Default: OFF**

When **DIALOG TOUCH CONTROL** is enabled on Android/iOS, it acts as a **catch-all touch controller for every game UI/state except battles and the bare overworld**. This intentionally avoids a fragile allowlist of known TextBoxes and menus: a newly added menu, choice screen, confirmation, PC/party interface, naming screen, modal overlay or other non-overworld UI automatically receives the same touch controls.

- **Tap and release -> A**
- **Hold nearly still for 1 second -> B**
- **Swipe up -> UP**
- **Swipe down -> DOWN**
- **Swipe left -> LEFT**
- **Swipe right -> RIGHT**

A is deliberately **not** pressed when the finger first touches the screen. If the finger stays within a small movement tolerance for one second, **B fires immediately once** and release sends nothing else. If the finger moves beyond that hold tolerance first, the B candidate is permanently cancelled for that contact. Once movement crosses the swipe threshold it is latched as a swipe, so returning near the starting point cannot turn it back into A or resurrect B.

The two exclusions are deliberate:

- **Bare overworld:** DIALOG TOUCH CONTROL does nothing, so Tap to Move / Hold to Steer and normal overworld touch behavior keep ownership.
- **Any battle context:** DIALOG TOUCH CONTROL does nothing even if a TextBox, Party screen, item screen or another overlay is currently above BattleState. Battle touch behavior is controlled only by **BATTLE TOUCH CONTROL**.

The catch-all applies to the game surface, **but never steals a touch that starts on one of Gen1Recomp's visible virtual controls**. A/B/START/SELECT/D-pad presses keep their native zero-latency behavior. Ownership is decided at touch-down: a world/UI gesture that merely passes across a virtual control later is not reclassified, which keeps Hold to Steer practical.

The overworld **START menu** has one additional spatial rule. A release tap inside the actually rendered START-menu box sends **A**; a release tap outside that box sends **B**, which closes the menu. The hit-test follows the menu's live size, UI scale and top-right anchor rather than assuming a fixed rectangle. Swipes and the one-second hold-B gesture keep their normal meanings.

### BATTLE TOUCH CONTROL

**Default: OFF**

When **BATTLE TOUCH CONTROL** is enabled on Android/iOS, the same one-finger gesture language is available for the complete battle context, including battle menus and screens temporarily pushed above the BattleState:

- **Tap and release -> A**
- **Hold nearly still for 1 second -> B**
- **Swipe up -> UP**
- **Swipe down -> DOWN**
- **Swipe left -> LEFT**
- **Swipe right -> RIGHT**

As with dialogue control, touch-down itself sends nothing. A nearly stationary one-second hold fires **B** immediately and consumes the gesture, so releasing afterward cannot also send A. Moving beyond the hold tolerance cancels only the B candidate; the contact can still become a sticky swipe or a normal release-A tap.

While this setting is enabled, a touch that starts during battle is owned by Tap to Move for its whole physical lifecycle. It is not forwarded to the game's normal touch stream. This deliberately gives battle controls priority over touch-drag camera look in 3D battle presentation, including Dramatic Shape's steerable 3D battle camera. If the battle ends while a finger is still held, that same contact remains swallowed until release so it cannot become a late camera drag or accidental input on the screen revealed underneath.

**DIALOG TOUCH CONTROL never takes ownership inside a battle.** If both settings are ON, the complete battle stack — including battle TextBoxes and pushed Party/Item/choice screens — is handled exclusively by **BATTLE TOUCH CONTROL**. This keeps the two gesture systems mutually exclusive.

### HOLD PLAYER SPRITE

Select **START/SELECT TOUCH CONTROL → HOLD PLAYER SPRITE** to enable this gesture. On mobile, press directly on the visible player character and keep the finger nearly stationary for **1 second** to simulate **START**.

If the finger moves far enough before the one-second threshold, the START candidate is cancelled and the gesture hands control back to normal Tap to Move / Hold to Steer.

A **short tap on the player sprite** is also an interaction rescue. Tap to Move first checks the four cells exactly one tile from the player in strict **UP → DOWN → RIGHT → LEFT** priority. The first genuine supported interaction it finds (for example an NPC, Pokémon Center PC, sign, bookshelf or counter interaction) is selected: the player turns toward it and presses **A**. Direction-gated hidden events are only selected from a side the game itself accepts, and empty cells are never probed with blind A presses. This deliberately bypasses 3D picking when a wall-mounted object is hard to hit. If none of the four adjacent cells contains an interaction, the older front-cell proxy remains available for a real door/warp or interaction directly in the player's current facing. With **HOLD PLAYER SPRITE** enabled, release before one second may use this rescue; reaching one second still fires START and consumes the gesture exactly as before.

### Bottom-edge system gesture protection

On Android/iOS, a real **bare-overworld world touch** that starts in a narrow strip along the bottom edge is briefly reserved before Tap to Move may act on it. If the contact develops into a clearly vertical **bottom -> up swipe**, only the mod's **world-movement intent** is discarded as a probable phone-system Home/app-switch gesture.

This guard no longer acts as an application-wide touch dead zone. If the touch starts on Gen1Recomp's visible virtual D-pad/A/B/START/SELECT — including controls the player deliberately positioned along the bottom edge — it bypasses the guard and is delivered to native TouchControls immediately. DIALOG/BATTLE touch surfaces also do not enter the bottom-edge movement guard. A world contact that turns clearly sideways/downward is promoted back into normal gameplay; a stationary/short world contact is replayed on release. If the OS cancels the physical touch without a normal release callback, the reservation is pruned rather than replayed later.

### Mobile shake -> B

On Android/iOS, a deliberate **back-and-forth shake of the phone** can simulate B. The detector looks for two strong opposite motion impulses rather than one isolated jolt, and includes a cooldown so one shake should not produce a burst of B presses.

The mod uses gyroscope data when available and accelerometer motion as a fallback. Accelerometer readings are gravity-compensated. On Android builds where Gen1Recomp deliberately disables the old accelerometer-as-joystick path, Tap to Move reads SDL2's independent sensor subsystem instead; it does **not** re-enable tilt-to-walk joystick input.

Phone sensor response varies by device. The detection logic is covered by simulated sensor tests, but physical-device sensitivity may still need tuning if a particular handset is unusually sensitive or unusually damped.

### Desktop mouse

All mouse features are **opt-in and default OFF**. Their settings are grouped at the very bottom of the Mods menu because they are secondary to the mobile-first touch controls.

Available mouse features:

- **MOUSE WALK CONTROL** — allows LMB to act as Tap to Move in the free overworld.
- **MOUSE LMB/RMB=A/B** — when enabled, RMB = B everywhere and LMB = A on dialogue/menu/battle/other non-overworld screens.
- **MOUSE WHEEL ▲/▼** — OFF / ON / ON FLIPPED. ON maps wheel up → UP and wheel down → DOWN. ON FLIPPED swaps them. While ON, the mod consumes the vertical wheel event instead of Gen1Recomp's native survey-zoom wheel behavior.
- **MOUSE WH.TILT L/R** — OFF / ON / ON FLIPPED. On supported mice, ON maps wheel tilt left → LEFT and tilt right → RIGHT; ON FLIPPED swaps them. If the mouse/driver does not report horizontal wheel events, this setting simply has no effect.
- **MOUSE SIDE ST/SEL** — OFF / ON / ON FLIPPED. ON maps Mouse 5 → START and Mouse 4 → SELECT. ON FLIPPED swaps those two mappings.

Mouse features are independent. For example, wheel navigation can be enabled while mouse walking remains disabled.

## Mods Options

### TAP TO MOVE
Enable or disable the mod.


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

### DIALOG TOUCH CONTROL
Controls catch-all mobile UI gestures outside battles and the bare overworld.

- **OFF — default:** the mod does not add this catch-all UI touch behavior.
- **ON:** on every non-overworld, non-battle game screen, tap-and-release simulates **A**, a nearly stationary **1-second hold simulates B**, and swipe simulates **UP / DOWN / LEFT / RIGHT**. Long-hold B fires once and suppresses release-A; a recognized swipe never also sends A.

### BATTLE TOUCH CONTROL
Controls all mobile battle tap/swipe gestures as one feature.

- **OFF — default:** battle touches are left to the normal game/mod touch handlers.
- **ON:** tap-and-release simulates **A**, a nearly stationary **1-second hold simulates B**, and swipe simulates **UP / DOWN / LEFT / RIGHT**. Long-hold B fires once and suppresses release-A; a recognized swipe never also sends A. Touch-drag camera look is suppressed for contacts that begin during battle so the control gesture has priority.

### START/SELECT TOUCH CONTROL
Selects one START/SELECT touch-control scheme.

- **OFF — default:** no START/SELECT touch shortcut.
- **HOLD PLAYER SPRITE:** hold the visible player for **1 second** to simulate **START**. Moving before the timer expires cancels the candidate and returns the touch to normal movement control.
- **PINCH OR SPREAD:** spread simulates **START**, pinch simulates **SELECT**, and native pinch/spread zoom is automatically disabled.


### SHAKE -> B
On supported Android/iOS devices, a deliberate back-and-forth phone shake simulates **B**. Gyroscope is preferred when available; accelerometer motion is also supported.

**Default: ON**

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

### MOUSE WALK CONTROL
Allow left mouse click to control Tap to Move in the free overworld.

- **OFF — default**
- **ON**

### MOUSE LMB/RMB=A/B
Enable the existing desktop click shortcuts.

- **OFF — default**
- **ON:** RMB = **B**. LMB = **A** when a non-overworld screen is active; free-overworld LMB is controlled separately by **MOUSE WALK CONTROL**.

### MOUSE WHEEL ▲/▼
Map the vertical mouse wheel to D-pad taps.

- **OFF — default:** Tap to Move does not remap the wheel; Gen1Recomp keeps its native wheel behavior (including overworld survey zoom).
- **ON:** wheel up = **UP**, wheel down = **DOWN**.
- **ON FLIPPED:** wheel up = **DOWN**, wheel down = **UP**.

### MOUSE WH.TILT L/R
Map horizontal wheel tilt to LEFT/RIGHT on mice that expose horizontal wheel events.

- **OFF — default:** no horizontal-wheel remapping.
- **ON:** tilt left = **LEFT**, tilt right = **RIGHT**.
- **ON FLIPPED:** tilt left = **RIGHT**, tilt right = **LEFT**.
- Hardware/driver support is required; many mouse wheels do not support tilt.

### MOUSE SIDE ST/SEL
Map the two common side buttons independently of mouse walking/click shortcuts.

- **OFF — default**
- **ON:** **Mouse 5 = START**, **Mouse 4 = SELECT**.
- **ON FLIPPED:** **Mouse 5 = SELECT**, **Mouse 4 = START**.


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

## Updates

Tap to Move declares its official GitHub repository in `manifest.json`, so Gen1Recomp's native mod updater can check GitHub Releases for newer versions and install a ZIP release from the launcher.

The update check is handled by Gen1Recomp itself; Tap to Move does not run a separate background network checker during gameplay. Release ZIP assets should keep a name beginning with `tap_to_move`, for example `tap_to_move_v1.3.17.zip`.

## Compatibility philosophy

Tap to Move does not hard-lock itself to one specific Gen1Recomp version. It attempts to run on newer versions and should only require an update when an actual API/runtime incompatibility appears.

The Dramatic Shape integration uses its exported companion-library interface where available rather than modifying Voxel rendering behavior.

## Version


**1.3.21**

- Short player-avatar taps now scan exactly one tile away for a real interaction in strict **UP → DOWN → RIGHT → LEFT** priority.
- The selected adjacent interaction turns the player toward the object and uses the normal release-gated **A** interaction flow; no blind A presses are sent into empty cells.
- Direction-restricted hidden interactions (including Pokémon Center PCs) are only accepted from a side the engine itself permits.
- Counter proxies are only accepted when the player is on the side that actually faces through the counter toward the actor.
- The avatar rescue clears stale Voxel/outside-map metadata so a recovered PC/NPC/sign cannot be stolen by Smart Exit.
- If no adjacent interaction exists, the previous current-facing front-cell door/warp proxy is retained unchanged.

**1.3.20**

- Smart Exit now requires directional agreement between the off-map click and the real exit: UP↔UP, DOWN↔DOWN, LEFT↔LEFT, RIGHT↔RIGHT.
- Opposite/sideways exits are excluded before walking-distance scoring, so a click near Nurse Joy or a right-wall PC cannot fall back to a bottom exit.
- Diagonal outside clicks may consider only the two crossed sides, ordered by how far the pointer extends beyond each boundary.
- Continuous Hold-to-Steer samples cannot create a new Smart Exit after camera motion moves the map away from a held pointer.
- Debug overlay adds `EXIT-DIR A/R/H` counters for accepted/rejected/held-suppressed exit intents.

**1.3.19**

- Wall-mounted semantic interaction recovery for Voxel/Dramatic Shape taps (Pokémon Center PCs, signs, bookshelves, counters and other real interaction cells).
- Semantic recovery runs before Smart Exit and can only select an actual engine interaction; generic wall/floor geometry is never promoted.
- Debug overlay adds `SEM-HIT` to count recovered interaction taps.

**1.3.18**

- Fixed **true edge warps**: a real warp record on the top/bottom/left/right map boundary now always retains the outward **UP/DOWN/LEFT/RIGHT** activation used by Gen1Recomp `Warp.onEdge`, even when the same tileset also uses function2 carpet rules.
- This specifically covers the Cerulean robbed-house rear hole at `(3,0)`: Smart Exit routes to the real warp source and commits **UP** instead of stopping on the warp cell.
- Direct taps on a cell that is both a fixed background interaction and a confirmed directional warp now choose the warp traversal (NPCs still keep interaction priority).
- Existing click-biased multi-exit selection from v1.3.17 is retained.

**1.3.17**

- Smart Exit now uses the off-map click position to choose between equally valid exits before considering walking distance from the player.
- Directional wall openings use a constrained final approach so UP/DOWN/LEFT/RIGHT is already held as the player lands on the warp source.
- If a validated directional warp still does not fire from input, Tap to Move invokes Gen1Recomp's normal `takeWarp` transition for that exact live warp record after a short grace period.

**1.3.16**

- Fixed the asymmetry where only **DOWN** exit carpets always retained their final activation input. Unique **UP / LEFT / RIGHT** `ExtraWarpCheck` directions are now retained too, even when the source cell also looks like a normal warp tile.
- Smart Exit now routes to the real warp source and then sends the required final direction for any unique directional exit.
- Direct clicks on the warp source inherit the same rule; clicks on the visible adjacent opening still resolve source + direction as before.
- Ambiguous multi-direction warp sources are not guessed; the existing DOWN-carpet compatibility preference remains.
- The final exit-goal A*/collision exception remains limited to the exact validated warp source.

**1.3.15**

- Generalized directional special-warp targeting from DOWN-only carpets to **UP / DOWN / LEFT / RIGHT** using Gen1Recomp's actual `ExtraWarpCheck` semantics.
- Tapping the visible front/opening cell can now resolve to the adjacent real warp source, route there, then append the required direction. This covers rear/top/side openings and other function2-style special entrances without hardcoded tile ids.
- Added explicit support for scripted dungeon **hole** cells (`warpPadOrHoleAt == "hole"`): exact hole taps route onto the walkable on-step trigger, and a solid Voxel hit can snap to a unique adjacent engine-recognized hole. Ordinary floor taps are never redirected and ambiguous adjacent holes are never guessed.
- Existing exit-goal A*/collision safeguards remain scoped to real warp records only; scripted holes do not receive collision overrides.

**1.3.14**

- Removed the **exact Voxel `void` → EXIT** heuristic. Voxel tile/class data remains diagnostic only.
- Removed the **boundary-connected blank-shell → EXIT** flood-fill heuristic.
- Kept the Voxel **outside-behind-wall** fallback, but real interactions and warp semantics on the hit cell now have priority.
- Smart Exit remains driven by actual warp/carpet records, genuine outside-map intent, and multi-leg exit routing.
- Renamed the bottom mouse rows for the compact 160px Mods screen: **MOUSE LMB/RMB=A/B**, **MOUSE WHEEL ▲/▼**, **MOUSE WH.TILT L/R**, **MOUSE SIDE ST/SEL**.
- ▲/▼ are native Gen I font glyphs; the vanilla charmap does not provide a matching left/right arrow pair, so horizontal rows use L/R.

**1.3.13**

- Added **MOUSE WHEEL TILT** at the bottom of the Mods menu, default **OFF**.
- **ON:** horizontal wheel tilt left/right sends **LEFT/RIGHT**.
- **ON FLIPPED:** swaps LEFT/RIGHT.
- Vertical **MOUSE WHEEL CONTROL** remains independent and unchanged.
- Mixed horizontal/vertical wheel events use the dominant axis so a single wheel/trackpad event cannot emit two D-pad taps.
- If the mouse or driver does not expose horizontal wheel movement, the option has no effect.

**1.3.12**

- Fixed the core A* legality bug that prevented Tap to Move from routing BACK onto certain exit warp/carpet source cells after the player had stepped away.
- A validated directional EXIT warp source (for example a DOWN carpet/mat) may now be the final A* destination even when `mapOverview()` reports that cell as blocked/blank. The exception applies only to the exact final exit goal; the same warp cell is still forbidden as an ordinary intermediate route node.
- Added a narrowly scoped `movement.collision` exception for the exact active directional exit goal when the engine rejects that actual warp-record cell solely because its tile is not in the ordinary walkable list. Entity collisions, map bounds and tile-pair/elevation collisions are not bypassed.
- Confirmed carpet/warp exit intents no longer get rewritten into `move_nearest`, and multi-leg Smart Exit no longer re-rejects an actual warp source through the compact `.`/`+` terrain check.
- DEBUG OVERLAY adds **EXIT-GOAL PASS** so a physical non-walkable warp-source override can be confirmed during testing.

**1.3.11**

- Added deterministic **DOWN exit-carpet / exit-mat targeting** using Gen1Recomp warp semantics rather than visual tile-number guesses.
- Clicking a warp cell whose valid activation directions include DOWN now always arms an additional DOWN after the route reaches that cell.
- Also supports `warpCarpets` / function2 layouts where the visible carpet cell is directly south of the actual warp record: clicking the carpet routes to the source cell immediately above it, then sends DOWN.
- DOWN is retained even when `isWarpTileCell()` says arrival may warp. If arrival really does transition maps, navigation is retired before the extra press can fire; otherwise the queued DOWN supplies the missing carpet activation.
- Smart Exit-selected DOWN mats use the same forced-DOWN safety behavior. Existing Voxel `void` and boundary-shell heuristics remain fallbacks, but carpet clicks no longer depend on either.
- DEBUG OVERLAY adds a **CARPET-DOWN** counter so a successful carpet semantic match is visible immediately during testing.

**1.3.10**

- Added **exact Voxel void-tile Smart Exit**: the camera ray now keeps the exact 8×8 visual tile under the tap and reads Dramatic Shape's resolved `shape.class`.
- A tile classified by Dramatic Shape as **`void`** inside a room-style building is treated as explicit **EXIT intent**, while interaction/warp semantics on the owning gameplay cell keep priority.
- Added DEBUG OVERLAY line **`V-TILE <id> <class> @tx,ty`** plus an **EXACT-VOID** counter so problem tiles can be identified directly in-game. Existing `VOXEL` / `RAY` numbers remain cumulative counters, not tile ids.
- Raw tile numbers are deliberately not hardcoded because tile ids are local to each tileset; the stable semantic signal is Dramatic Shape's own `void` classification.
- The v1.3.9 boundary-connected collision-shell heuristic remains as a fallback for room-style interiors and older/partial Voxel integrations.

**1.3.9**

- Added the boundary-connected blank/solid shell fallback for small room-style building interiors, allowing in-bounds padding cells to feed Smart Exit instead of nearest-legal obstacle movement.

**1.3.8**

- Renamed **MOUSE CONTROL** to **MOUSE WALK CONTROL** and changed its default to **OFF**.
- Moved every mouse-related setting to the bottom of the Mods menu.
- Added **MOUSE WHEEL CONTROL**: OFF / ON / ON FLIPPED. ON maps wheel up/down to UP/DOWN; FLIPPED reverses the pair. OFF preserves native Gen1Recomp wheel behavior.
- Added **MOUSE SIDE BUTTONS**: OFF / ON / ON FLIPPED. ON maps Mouse 5 → START and Mouse 4 → SELECT; FLIPPED swaps them.
- Changed the existing **DESKTOP MOUSE A/B** shortcut default to **OFF**, so every mouse feature is opt-in.
- Non-left mouse-button releases are isolated from the LMB navigation pointer so pressing Mouse 4/5 or RMB while walking cannot accidentally terminate an active mouse-walk gesture.

**1.3.7**

- Added **START-menu spatial tap semantics** for DIALOG TOUCH CONTROL: a short tap that starts inside the live START-menu box sends **A**, while a short tap that starts outside sends **B** to close it. The hit-test follows the menu's runtime `tx/ty/tw/th`, UI scale, centered/dynamic layout and top-right anchor.
- Added **native virtual-control ownership priority**: any real touch that starts on visible Gen1Recomp **D-pad / A / B / START / SELECT** bypasses Tap to Move, DIALOG/BATTLE classifiers, pinch grace and bottom-edge filtering for its complete lifecycle.
- Ownership remains **press-origin based**: a Tap-to-Move / Hold-to-Steer finger that starts on the world may pass over a virtual control later without being stolen by it.
- Re-scoped **bottom-edge system gesture protection** to bare-overworld world movement only. Virtual controls positioned along the bottom edge now work immediately, and DIALOG/BATTLE UI touch handling is no longer globally reserved by the edge filter.
- Added cleanup/reset bookkeeping for native-control-owned touches and bottom-edge reservations.

**1.3.6**

- Added a **0.20-second first-finger pairing grace window** for mobile overworld touches when **START/SELECT TOUCH CONTROL -> PINCH OR SPREAD** is selected.
- During the grace window the first touch is not forwarded to TouchControls or Tap to Move, so a second finger can claim the pair without the first finger starting a walking step.
- If no second finger arrives, a held single touch is promoted after the tolerance; a quick single tap that releases sooner is replayed immediately on release.
- Visible virtual Game Boy controls bypass the grace window, so ordinary on-screen button responsiveness is unchanged.
- If finger #2 arrives after the first touch was already promoted, the two-finger gesture still suppresses navigation and the first forwarded touch receives only the cleanup release it needs; no duplicate route is created.

**1.3.5**

- Added **player-avatar interaction proxy**: a short tap on the visible player targets a real interaction surface directly in front of the player's current facing when the avatar visually blocks it.
- The proxy covers supported NPC/fixed interactions and door/warp semantics, but does not turn an avatar tap into an implicit step onto empty floor.
- **HOLD PLAYER SPRITE** keeps its existing one-second START behavior; a short release can proxy the front interaction, while a completed START hold consumes the gesture and never also interacts.
- Added automatic **bottom-edge upward-swipe protection** on Android/iOS. Contacts beginning in the protected bottom strip are reserved before gameplay, so probable OS Home/app-switch swipes produce no Tap-to-Move route, D-pad swipe, A press, virtual/native touch action or 3D battle camera drag from this mod path.
- Non-system bottom-edge contacts are promoted/replayed back into the ordinary touch pipeline, avoiding a permanent dead strip.
- Added cancellation cleanup using LÖVE's active-touch list when the host/OS removes a reserved contact without a normal release event.

**1.3.4**

- Added **hold -> B** to **DIALOG TOUCH CONTROL** and **BATTLE TOUCH CONTROL** independently.
- Holding one finger nearly stationary for **1 second** fires **B once**; releasing after B does not also send A.
- The hold allows a small **22-unit** movement tolerance. Crossing it permanently cancels B for that contact, while normal tap/swipe classification can continue.
- The bare overworld is explicitly unaffected by hold-B, preserving Tap to Move / Hold to Steer ownership.
- DIALOG hold-B never runs in battle; BATTLE hold-B never runs outside a battle context.

**1.3.3**

- Expanded **DIALOG TOUCH CONTROL** from literal dialogue detection to a catch-all for every mobile UI/state outside the bare overworld and battles.
- Bare overworld remains reserved for Tap to Move / Hold to Steer and normal overworld touch behavior.
- Any stack containing BattleState is explicitly excluded, even when a TextBox, Party, Item or other screen is pushed above it.
- When both DIALOG and BATTLE TOUCH CONTROL are ON, battle input is now exclusively handled by **BATTLE TOUCH CONTROL**; the two classifiers never overlap.
- Generic menus, choice screens, naming/confirmation screens and future non-overworld UI states inherit release-A and sticky D-pad swipes automatically without needing per-screen recognition.

**1.3.2**

- Added **BATTLE TOUCH CONTROL** (**OFF/ON**, default **OFF**).
- When enabled, battle tap is resolved on release as **A** and sticky swipes map to **UP / DOWN / LEFT / RIGHT**.
- Battle touch ownership spans the full BattleState stack, so pushed battle menus/screens remain controllable.
- A battle gesture never reaches the underlying touch handler, preventing the same drag from steering a 3D battle camera.
- A contact that outlives the battle remains swallowed until physical release, preventing late camera movement or accidental input on the next screen.
- Two-finger **PINCH OR SPREAD** keeps priority over pending one-finger battle input, so START/SELECT never also produces battle A.
- If dialogue and battle touch controls overlap during a battle TextBox, dialogue semantics win without duplicate Game Boy input.

**1.3.1**

- Replaced the separate dialogue gesture toggles with **DIALOG TOUCH CONTROL** (**OFF/ON**, default **OFF**).
- Enabling Dialogue Touch Control activates both release-only **A** taps and sticky **D-pad swipes** as one feature.
- Replaced **DISABLE PINCH ZOOM**, **SPREAD -> START**, **PINCH -> SELECT**, and **HOLD PLAYER -> START** with one **START/SELECT TOUCH CONTROL** choice.
- START/SELECT modes are **OFF** (default), **HOLD PLAYER SPRITE**, and **PINCH OR SPREAD**.
- **PINCH OR SPREAD** always suppresses native two-finger zoom while mapping spread to START and pinch to SELECT.
- **HOLD PLAYER SPRITE** activates only the one-second player-hold START gesture.

**1.3.0**

- Added **HOLD PLAYER -> START**: hold the visible player for one second to press START.
- Player-hold START is cancelled by meaningful finger movement and hands the gesture back to normal Tap to Move.
- Reworked mobile dialogue input so **A fires only on release** after a true tap.
- Added **DIALOG SWIPE -> D-PAD** for UP/DOWN/LEFT/RIGHT swipes.
- Swipe classification latches once recognized, preventing the same gesture from also becoming A.
- Two-finger START/SELECT gestures supersede pending one-finger dialogue/player-hold gestures without duplicate input.

**1.2.3**

- Fixed **SPREAD -> START** and **PINCH -> SELECT** on physical touchscreens.
- START/SELECT recognition now uses raw `Game:touch*` contacts before TouchControls can capture the second finger.
- The old `input.pointer` recognizer remains only as a compatibility fallback when the raw touch bridge is unavailable.
- Native pinch/spread zoom suppression remains tied to the same contact pair, preventing zoom and mapped button input from diverging.

**1.2.2**

- Fixed **DISABLE PINCH ZOOM** so it observes raw game touches before TouchControls/input.pointer.
- Added a short post-gesture zoom suppression latch to catch delayed native pinch callbacks.
- Restores the pre-gesture survey zoom before input processing and before frame composition, preventing a native zoom change from leaking through visually.
- Mouse-wheel / keyboard zoom remain available outside the brief active/recent two-finger gesture window.

**1.2.1**

- Added native Gen1Recomp launcher update support via the official `github` manifest field (`ZyranCZ/Tap-to-Move`).
- No gameplay/pathfinding/input behavior changes.

**1.2.0**
