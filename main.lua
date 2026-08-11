-- Tap to Move v1.3.12
-- Mobile-first collision-aware shortest-path navigation for Gen1Recomp.
--
-- Design rule: this mod never teleports or writes player coordinates.  It
-- plans a route, then drives the real Game Boy D-pad through mod.input.  The
-- engine therefore remains authoritative for collisions, ledges, encounters,
-- warps, scripts, trainers, movement speed and every other overworld rule.

local mod = ...

local VERSION = "1.3.12"
local TILE_SIZE = 16
local FIXED_TICKS_PER_SECOND = 60
local DEFAULT_HOLD_STEER_DELAY_MS = 800 -- delay before a held pointer starts continuous retargeting
local DEFAULT_PERFORMANCE_INPUT_FREQUENCY = "balance"
local DEFAULT_VOXEL_PATH_RATE = "0.25"

-- Performance preset = how often the expensive held-pointer INPUT work is
-- allowed to run. LOW prioritizes steering responsiveness; ULTRA prioritizes
-- frame time. Voxel Path Preview reprojection has its own independent tuning
-- row below so the user can test very low visual refresh rates without making
-- steering itself sluggish.
local PERFORMANCE_INPUT_PROFILES = {
  low =     { label = "LOW",     holdMs = 200 }, -- 5 Hz
  medium =  { label = "MEDIUM",  holdMs = 300 }, -- 3.3 Hz
  balance = { label = "BALANCE", holdMs = 400 }, -- 2.5 Hz
  high =    { label = "HIGH",    holdMs = 600 }, -- 1.7 Hz
  ultra =   { label = "ULTRA",   holdMs = 800 }, -- 1.25 Hz
}

-- Fixed-tick intervals for Voxel Path Preview screen-space reprojection.
-- The cached dots still draw every HUD frame; only the expensive live 3D
-- projection is throttled. Values intentionally extend well below one of the
-- old presets so real-device testing can find where visible lag begins.
local VOXEL_PATH_RATE_TICKS = {
  ["10"] = 6, ["5"] = 12, ["2"] = 30, ["1"] = 60,
  ["0.25"] = 240,
}

-- Optional two-finger shortcuts. Gen1Recomp/LÖVE can surface pinch/spread
-- as zoom input independently of the gameplay pointer stream, so the mod
-- recognizes the two contacts itself and also guards Game:zoomStep while a
-- gesture is reserved. A direction must move far enough from its initial
-- separation to avoid firing when the second finger merely lands.
local TWO_FINGER_TRIGGER_UNITS = 36
local TWO_FINGER_TRIGGER_RATIO = 0.18
local PINCH_ZOOM_GRACE_TICKS = 36 -- keep blocking delayed native zoom callbacks for ~0.6 s

-- Controls-free one-finger gestures. Holding directly on the player for one
-- second is an alternate START gesture. DIALOG TOUCH CONTROL is the catch-all
-- classifier for non-overworld, non-battle UI: a short stationary release
-- becomes A, a nearly stationary one-second hold becomes B, while a deliberate
-- swipe becomes one D-pad tap. Exactly one semantic action owns each contact.
local PLAYER_HOLD_START_TICKS = FIXED_TICKS_PER_SECOND -- exactly 1.0 s
local PLAYER_HOLD_MOVE_SLOP_UNITS = 22
local DIALOG_SWIPE_TRIGGER_UNITS = 30

-- Controls-free dialogue / mobile shake input. A shake is deliberately
-- recognized as an oscillation (two strong opposite impulses) rather than a
-- single jolt, so putting the phone down or rotating it once does not normally
-- press B. Accelerometer data is gravity-compensated; gyroscope data is used
-- directly. Android Gen1Recomp currently runs LÖVE 11.5 with the legacy
-- accelerometer-as-joystick disabled, so the mod talks to SDL2's independent
-- sensor subsystem through FFI instead. iOS/LÖVE 12 can use love.sensor.
local ControlsFree = {
  SHAKE_ACCEL_THRESHOLD = 5.5,       -- m/s^2 after gravity removal
  SHAKE_GYRO_THRESHOLD = 3.2,        -- rad/s
  SHAKE_RESET_RATIO = 0.45,          -- motion must relax before next impulse
  SHAKE_REVERSAL_DOT = -0.20,        -- opposite-enough vector direction
  SHAKE_MIN_IMPULSE_TICKS = 2,
  SHAKE_MAX_IMPULSE_TICKS = 30,      -- 0.5 s at 60 Hz
  SHAKE_COOLDOWN_TICKS = 45,         -- 0.75 s; one B per shake
  SHAKE_WARMUP_TICKS = 10,
  SHAKE_GRAVITY_ALPHA = 0.08,
  TOUCH_HOLD_B_TICKS = FIXED_TICKS_PER_SECOND, -- exactly 1.0 s
  TOUCH_HOLD_B_MOVE_SLOP_UNITS = 22,
  -- When PINCH OR SPREAD is selected, the first world touch is reserved for a
  -- brief pairing window before Tap to Move sees it. Human two-finger gestures
  -- rarely land on the exact same frame; without this grace the first finger
  -- can start one walking step before the second finger turns the pair into
  -- START/SELECT. Short ordinary taps are replayed immediately on release.
  PINCH_FIRST_TOUCH_GRACE_TICKS = 12, -- 0.20 s at 60 Hz
  -- Mobile OS navigation gestures commonly begin at the bottom edge. Reserve
  -- that narrow strip only for bare-overworld WORLD touches until intent is
  -- clear, so a Home/app-switch swipe cannot start a Tap-to-Move route. Native
  -- virtual controls and UI/battle touch handling are never reserved here.
  SYSTEM_EDGE_START_BAND_RATIO = 0.12,
  SYSTEM_EDGE_START_BAND_MIN_UNITS = 32,
  SYSTEM_EDGE_START_BAND_MAX_UNITS = 96,
  SYSTEM_EDGE_UP_TRIGGER_UNITS = 30,
  SYSTEM_EDGE_AXIS_RATIO = 1.15,
  SYSTEM_EDGE_SIDE_ESCAPE_UNITS = 34,
  SDL_INIT_SENSOR = 0x00008000,
  SDL_SENSOR_ACCEL = 1,
  SDL_SENSOR_GYRO = 2,
}
local VOXEL_COLUMN_HEIGHT = 48           -- semantic prism height in world px
local VOXEL_COLUMN_MID_HEIGHT = 24
local VOXEL_COLUMN_SNAP_UNITS = 24       -- touch-space tolerance in LOVE units
local VOXEL_COLUMN_SEARCH_Y_UNITS = 176  -- bound fallback work on mobile
local VOXEL_COLUMN_MAX_CANDIDATES = 64     -- cap extra height projections
local ENTITY_BLOCK_TICKS = 20
local DYNAMIC_RETRY_TICKS = 12
local MAX_DYNAMIC_WAIT_TICKS = 240     -- ~4 s total wait for wandering NPCs
local NO_PROGRESS_TICKS = 180            -- ~3 s safety watchdog while WALKING
local MAX_INTERACTION_REPLANS = 120     -- safety fuse; legitimate NPC chase does not consume it
local MAX_INTERACTION_AGE_TICKS = 1800   -- ~30 s following a wandering target
local MAX_BATTLE_RESUME_AGE_TICKS = 1800  -- ~30 s to return to free overworld

-- Deterministic order for equal-cost A* routes.  Keeping this stable avoids
-- route jitter when repeated replans have several equally short answers.
local DIRS = {
  { name = "up",    dx =  0, dy = -1, rank = 1 },
  { name = "left",  dx = -1, dy =  0, rank = 2 },
  { name = "right", dx =  1, dy =  0, rank = 3 },
  { name = "down",  dx =  0, dy =  1, rank = 4 },
}

local DIR_BY_NAME = {}
for _, d in ipairs(DIRS) do DIR_BY_NAME[d.name] = d end

mod.options:define({
  { key = "enabled", label = "TAP TO MOVE", type = "toggle", default = true },
  { key = "interact", label = "TAP TO INTERACT", type = "toggle", default = true },
  { key = "hold_steer", label = "HOLD TO STEER", type = "toggle", default = true },
  { key = "tap_hold_ms", label = "HOLD STEER DELAY", type = "number",
    default = DEFAULT_HOLD_STEER_DELAY_MS, min = 150, max = 800, step = 50 },
  { key = "performance_input_frequency", label = "PERFORMANCE INPUT FREQUENCY",
    type = "choice", default = DEFAULT_PERFORMANCE_INPUT_FREQUENCY,
    choices = {
      { "LOW", "low" }, { "MEDIUM", "medium" }, { "BALANCE", "balance" },
      { "HIGH", "high" }, { "ULTRA", "ultra" },
    } },
  { key = "voxel_path_rate", label = "VOXEL PATH RATE",
    type = "choice", default = DEFAULT_VOXEL_PATH_RATE,
    choices = {
      { "0.25/S", "0.25" }, { "1/S", "1" }, { "2/S", "2" },
      { "5/S", "5" }, { "10/S", "10" },
    } },
  { key = "dialog_touch_control", label = "DIALOG TOUCH CONTROL",
    type = "toggle", default = false },
  { key = "battle_touch_control", label = "BATTLE TOUCH CONTROL",
    type = "toggle", default = false },
  { key = "start_select_touch_control", label = "START/SELECT TOUCH CONTROL",
    type = "choice", default = "off",
    choices = {
      { "OFF", "off" },
      { "HOLD PLAYER SPRITE", "hold_player_sprite" },
      { "PINCH OR SPREAD", "pinch_or_spread" },
    } },
  { key = "shake_b", label = "SHAKE -> B",
    type = "toggle", default = true },
  { key = "feedback", label = "TAP FEEDBACK", type = "toggle", default = true },
  { key = "path_preview", label = "PATH PREVIEW", type = "choice", default = "off",
    choices = { { "OFF", "off" }, { "SHORT", "short" }, { "FULL", "full" } } },
  { key = "battle_resume", label = "RESUME AFTER WILD", type = "toggle", default = false },
  { key = "debug", label = "DEBUG OVERLAY", type = "toggle", default = false },

  -- Mouse options stay at the very bottom: all are opt-in.
  { key = "mouse", label = "MOUSE WALK CONTROL",
    type = "toggle", default = false },
  { key = "desktop_mouse_ab", label = "DESKTOP MOUSE A/B",
    type = "toggle", default = false },
  { key = "mouse_wheel_control", label = "MOUSE WHEEL CONTROL",
    type = "choice", default = "off",
    choices = {
      { "OFF", "off" }, { "ON", "on" }, { "ON FLIPPED", "on_flipped" },
    } },
  { key = "mouse_side_buttons", label = "MOUSE SIDE BUTTONS",
    type = "choice", default = "off",
    choices = {
      { "OFF", "off" }, { "ON", "on" }, { "ON FLIPPED", "on_flipped" },
    } },
})

local state = {
  tick = 0,
  view = nil,
  frame = nil,
  pointers = {},
  tapOwner = nil,
  nav = nil,
  pulse = nil,
  game = nil,
  lastStop = nil,
  pendingInteraction = nil,
  battleResume = nil,
  exitJourney = nil,
  previewCache = nil,
  exteriorVoidCache = nil,
  gestureTouches = {},
  twoFingerGesture = nil,
  zoomGuardInstalled = false,
  zoomGuardOriginal = nil,
  zoomModule = nil,
  rawZoomTouches = {},
  rawZoomGuardInstalled = false,
  rawZoomGuardOriginal = nil,
  nativeZoomSuppression = nil,
  dialogTouches = {},
  battleTouches = {},
  battleCameraOwnedTouches = {},
  playerHoldTouches = {},
  systemEdgeTouches = {},
  pinchGraceTouches = {},
  rawTouchDispatchPress = nil,
  rawTouchDispatchMove = nil,
  rawTouchDispatchRelease = nil,
  rawDispatchedTouches = {},
  nativeControlOwnedTouches = {},
  stats = {
    routesStarted = 0,
    routesArrived = 0,
    replans = 0,
    dynamicWaits = 0,
    collisions = 0,
    invalidTaps = 0,
    interactionsTriggered = 0,
    interactionsConfirmed = 0,
    interactionMisses = 0,
    interactionReleaseWaits = 0,
    interactionHoldDisarms = 0,
    immediatePressRoutes = 0,
    holdRetargets = 0,
    seamNeutralTicks = 0,
    seamHeldFastStarts = 0,
    entryGestureSuppressions = 0,
    exitJourneyLegs = 0,
    exitJourneyTransitions = 0,
    topologyCacheHits = 0,
    topologyCacheMisses = 0,
    overviewCacheHits = 0,
    overviewCacheMisses = 0,
    exitFallbacks = 0,
    exteriorVoidExitIntents = 0,
    voxelExactVoidExitIntents = 0,
    carpetDownIntents = 0,
    exitGoalCollisionOverrides = 0,
    retainedTargets = 0,
    nearestFallbacks = 0,
    stickySemanticRetains = 0,
    npcHoldTargets = 0,
    feedbackPulses = 0,
    previewProjectionRefreshes = 0,
    previewProjectionCacheHits = 0,
    voxelTargets = 0,
    voxelColumnTargets = 0,
    voxelRayTargets = 0,
    voxelRayOutside = 0,
    battleResumes = 0,
    battleResumeDrops = 0,
    twoFingerGestures = 0,
    gestureStartTriggers = 0,
    gestureSelectTriggers = 0,
    pinchZoomSuppressed = 0,
    dialogATaps = 0,
    dialogBHoldTriggers = 0,
    dialogSwipes = 0,
    dialogSwipeUp = 0,
    dialogSwipeDown = 0,
    dialogSwipeLeft = 0,
    dialogSwipeRight = 0,
    battleATaps = 0,
    battleBHoldTriggers = 0,
    battleSwipes = 0,
    battleSwipeUp = 0,
    battleSwipeDown = 0,
    battleSwipeLeft = 0,
    battleSwipeRight = 0,
    battleCameraTouchesSuppressed = 0,
    playerHoldStartTriggers = 0,
    playerAvatarInteractionProxies = 0,
    systemEdgeCandidates = 0,
    systemEdgeSwipesSuppressed = 0,
    systemEdgeTouchesPromoted = 0,
    nativeControlTouchesBypassed = 0,
    startMenuOutsideBTaps = 0,
    startMenuInsideATaps = 0,
    desktopATaps = 0,
    desktopBTaps = 0,
    shakeBTriggers = 0,
    sensorInitAttempts = 0,
    sensorUnavailable = 0,
    cancellations = 0,
  },
}

-- Forward declaration: interaction arrival is defined before the pointer hook
-- that supplies the concrete gesture lookup implementation.
local gestureIsDown
local pointerForGesture
local anyDirectionDown
local restoreNativeZoomSuppression

local function option(key, fallback)
  local value = mod.options:get(key)
  if value == nil then return fallback end
  return value
end

local function msToTicks(ms, fallback)
  local value = tonumber(ms)
  if not value then value = fallback end
  value = math.max(1, value)
  return math.max(1, math.floor(value * FIXED_TICKS_PER_SECOND / 1000 + 0.5))
end

local function holdSteerDelayTicks()
  return msToTicks(option("tap_hold_ms", DEFAULT_HOLD_STEER_DELAY_MS),
                   DEFAULT_HOLD_STEER_DELAY_MS)
end

local function performanceInputProfile()
  local name = tostring(option("performance_input_frequency",
                               DEFAULT_PERFORMANCE_INPUT_FREQUENCY) or ""):lower()
  local profile = PERFORMANCE_INPUT_PROFILES[name]
  if not profile then
    name = DEFAULT_PERFORMANCE_INPUT_FREQUENCY
    profile = PERFORMANCE_INPUT_PROFILES[name]
  end
  return profile, name
end

local function holdRefreshTicks()
  local profile = performanceInputProfile()
  return msToTicks(profile.holdMs, profile.holdMs)
end

local function previewRefreshTicks()
  local rate = tostring(option("voxel_path_rate", DEFAULT_VOXEL_PATH_RATE)
                         or DEFAULT_VOXEL_PATH_RATE)
  return VOXEL_PATH_RATE_TICKS[rate]
      or VOXEL_PATH_RATE_TICKS[DEFAULT_VOXEL_PATH_RATE]
end

local function key(x, y)
  return tostring(x) .. "," .. tostring(y)
end

local function edgeKey(x, y, nx, ny)
  return key(x, y) .. ">" .. key(nx, ny)
end

local function copyFlat(src)
  local out = {}
  for k, v in pairs(src or {}) do out[k] = v end
  return out
end

local function cellChar(overview, x, y)
  if not overview or x < 0 or y < 0
      or x >= overview.width or y >= overview.height then
    return nil
  end
  local row = overview.rows and overview.rows[y + 1]
  if not row then return nil end
  return row:sub(x + 1, x + 1)
end

local function evenCeil(n)
  local v = math.ceil(n)
  if v % 2 ~= 0 then v = v + 1 end
  return v
end

-- Renderer.worldViewSize() is intentionally inferred from the public
-- render.compose context instead of requiring Renderer/Zoom internals.
-- In the normal flat renderer the world canvas is even-sized ceil(P/s).
-- Tilt grows that canvas and a custom world pipeline exposes worldOverride,
-- so both fail closed instead of mapping a tap to the wrong cell.
local function inferFlatWorldScale(ctx, worldW, worldH)
  if not ctx or not worldW or not worldH then return nil end
  local fit = tonumber(ctx.scale) or 1
  local maxScale = math.max(16, math.ceil(fit * 2 + 8))

  local bases = {
    { tonumber(ctx.pw), tonumber(ctx.ph) },
  }

  -- Faithful Ratio on mobile sizes the world from the locked viewport rather
  -- than the entire drawable.  render.compose exposes enough information to
  -- recognize that case without requiring private renderer state.
  if ctx.uiw and ctx.uih then
    bases[#bases + 1] = { tonumber(ctx.uiw) * fit, tonumber(ctx.uih) * fit }
  end

  for _, base in ipairs(bases) do
    local bw, bh = base[1], base[2]
    if bw and bh and bw > 0 and bh > 0 then
      for s = 1, maxScale do
        if evenCeil(bw / s) == worldW and evenCeil(bh / s) == worldH then
          return s
        end
      end
    end
  end

  return nil
end

local function captureView(ctx)
  -- Keep framebuffer metadata even when a third-party render pipeline owns
  -- the world.  Voxel picking needs LOVE-units -> framebuffer conversion,
  -- while the normal flat path additionally needs the world-canvas geometry.
  if not ctx then
    state.frame = nil
    state.view = nil
    return
  end

  local dpiX, dpiY = tonumber(ctx.dpiX) or 1, tonumber(ctx.dpiY) or 1
  local pw, ph = tonumber(ctx.pw), tonumber(ctx.ph)
  if (not pw or not ph) and love and love.graphics
      and type(love.graphics.getPixelDimensions) == "function" then
    local ok, fw, fh = pcall(love.graphics.getPixelDimensions)
    if ok then pw, ph = tonumber(fw), tonumber(fh) end
  end
  if (not pw or not ph) and love and love.graphics
      and type(love.graphics.getDimensions) == "function" then
    local ok, uw, uh = pcall(love.graphics.getDimensions)
    if ok and uw and uh then
      pw, ph = tonumber(uw) * dpiX, tonumber(uh) * dpiY
    end
  end
  if dpiX <= 0 then dpiX = 1 end
  if dpiY <= 0 then dpiY = 1 end

  state.frame = {
    dpiX = dpiX, dpiY = dpiY,
    pw = pw, ph = ph,
    -- render.compose exposes ww/wh in LOVE units and pw/ph in framebuffer
    -- pixels.  A Voxel pipeline renders its canvas in framebuffer pixels, so
    -- keeping both lets the picker map a touch to the ACTUAL 3D canvas rather
    -- than assuming dpiX/dpiY happened to describe a third-party surface.
    ww = tonumber(ctx.ww) or (pw and pw / dpiX) or nil,
    wh = tonumber(ctx.wh) or (ph and ph / dpiY) or nil,
    worldActive = ctx.worldActive == true,
    worldOverride = ctx.worldOverride and true or false,
  }

  if not ctx.worldActive or not ctx.worldCanvas or ctx.worldOverride then
    state.view = nil
    return
  end

  local okW, worldW = pcall(ctx.worldCanvas.getWidth, ctx.worldCanvas)
  local okH, worldH = pcall(ctx.worldCanvas.getHeight, ctx.worldCanvas)
  if not okW or not okH or not worldW or not worldH then
    state.view = nil
    return
  end

  local scale = inferFlatWorldScale(ctx, worldW, worldH)
  if not scale or not pw or not ph then
    state.view = nil
    return
  end

  state.view = {
    worldW = worldW,
    worldH = worldH,
    scale = scale,
    pw = pw,
    ph = ph,
    dpiX = dpiX,
    dpiY = dpiY,
    ox = math.floor((pw - worldW * scale) / 2),
    oy = math.floor((ph - worldH * scale) / 2),
  }
end

local function overworldGate(game)
  if not game or not game.overworld or not game.stack
      or type(game.stack.top) ~= "function" then
    return false, "no_overworld"
  end

  local ow = game.overworld
  if game.stack:top() ~= ow then return false, "overlay_or_battle" end
  if ow.transitioning then return false, "transition" end

  -- Cycling Road's slope owns movement whenever the bicycle is mounted and
  -- the player is not braking.  Competing with that engine-owned forced move
  -- would make a planned route nondeterministic, so fail closed on any map
  -- listed in the running data's forcedMovement.slopeMaps.  This is data-
  -- driven rather than hard-coding Route 16/17/18 names, so modded maps can
  -- opt into the same rule.
  local fm = game.data and game.data.field and game.data.field.forcedMovement
  if game.save and game.save.onBike and fm and fm.slopeMaps and ow.map then
    for _, mapId in ipairs(fm.slopeMaps) do
      if mapId == ow.map.id then return false, "forced_bike_slope" end
    end
  end
  if ow.engaging then return false, "trainer_engagement" end
  if ow.emote then return false, "emote" end
  if ow.runner and ow.runner.isRunning and ow.runner:isRunning() then
    return false, "script"
  end

  local player = ow.player
  if player and player.inputLocked then return false, "input_locked" end
  if player and player.spinning then return false, "forced_movement" end
  if player and player.fishing then return false, "fishing" end
  return true
end

local function releaseHold(nav)
  if nav and nav.hold then
    mod.input:release(nav.hold)
    nav.hold = nil
    nav.holdDir = nil
    nav.expectedX = nil
    nav.expectedY = nil
  end
end

local function markStop(reason, nav)
  state.lastStop = {
    reason = reason or "unknown",
    tick = state.tick,
    mapId = nav and nav.mapId or nil,
    targetX = nav and (nav.requestedX or nav.targetX) or nil,
    targetY = nav and (nav.requestedY or nav.targetY) or nil,
  }
end

local function cancelRoute(reason)
  local nav = state.nav
  if not nav then return false end
  releaseHold(nav)
  markStop(reason or "cancelled", nav)
  if reason ~= "arrived" and reason ~= "retargeted"
      and reason ~= "hold_retargeted" then
    state.stats.cancellations = state.stats.cancellations + 1
  end
  if reason == "manual_override" and state.tapOwner then
    local pointer = state.pointers[state.tapOwner]
    if pointer then
      pointer.manualSuppressed = true
      pointer.gestureSuppressed = "manual_override"
    end
  end
  if nav.exitJourney then state.exitJourney = nil end
  state.nav = nil
  return true
end

local function finishRoute()
  local nav = state.nav
  if not nav then return end
  releaseHold(nav)
  state.stats.routesArrived = state.stats.routesArrived + 1
  markStop("arrived", nav)
  state.nav = nil
end

local function setPhase(nav, phase, reason)
  if not nav then return end
  nav.phase = phase
  nav.phaseReason = reason
end

local function setPulse(kind, x, y)
  if option("feedback", true) == false then return end
  state.stats.feedbackPulses = state.stats.feedbackPulses + 1
  state.pulse = {
    kind = kind or "accepted",
    x = x,
    y = y,
    untilTick = state.tick + 15,
  }
end

-- WorldAPI does not yet expose an iterator over all live collision entities.
-- Keep this single, read-only fallback centralized: the route is still
-- validated by the engine's final movement.collision verdict before a step can
-- happen, so stale or changed runtime details can only trigger a replan.
--
-- Returns three sets: all occupied cells, cells occupied by actors that can
-- move away (wandering or currently moving), and static blocking entities.
local function liveOccupancy(game)
  local all, dynamic, static = {}, {}, {}
  local ow = game and game.overworld
  for _, entity in ipairs((ow and ow.npcs) or {}) do
    if not entity.passable then
      local isDynamic = entity.wanders == true or entity.moving == true
      local dst = isDynamic and dynamic or static
      local function add(x, y)
        if type(x) == "number" and type(y) == "number" then
          local k = key(x, y)
          all[k] = true
          dst[k] = true
        end
      end
      add(entity.cellX, entity.cellY)
      add(entity.targetX, entity.targetY)
    end
  end
  return all, dynamic, static
end

local function entityById(game, id)
  local ow = game and game.overworld
  for _, entity in ipairs((ow and ow.npcs) or {}) do
    if entity.id == id then return entity end
  end
  return nil
end

local function entityIsInteractable(entity)
  if not entity or entity.passable then return false end
  if entity.pikachuFollower then return true end
  local def = entity.def or {}
  -- Strength boulders are movement puzzles, not tap-to-talk targets.
  if def.pushable == true or def.sprite == "SPRITE_BOULDER" then return false end
  return def.text ~= nil or def.item ~= nil or def.pokemon ~= nil
      or def.trainer ~= nil or def.trainerClass ~= nil or def.script ~= nil
end

local function counterAt(game, x, y)
  local map = game and game.overworld and game.overworld.map
  if not map or type(map.isCounterCell) ~= "function" then return false end
  local ok, yes = pcall(map.isCounterCell, map, x, y)
  return ok and yes == true
end

local function fieldRows(game, keyName, mapId)
  local field = game and game.data and game.data.field or {}
  local extras = field.hiddenExtras or {}
  local bucket = extras[keyName]
  if bucket == nil then bucket = field[keyName] end
  if type(bucket) ~= "table" then return {} end
  local perMap = bucket[mapId]
  if type(perMap) == "table" then return perMap end
  -- Some one-map extras (notably the Vermilion Gym trash puzzle) carry the
  -- map id on the record rather than nesting the rows by map.
  if bucket.map == mapId then
    if type(bucket.rows) == "table" then return bucket.rows end
    if type(bucket.cans) == "table" then return bucket.cans end
    if type(bucket.entries) == "table" then return bucket.entries end
  end
  return {}
end

local function staticInteractionAt(game, mapId, map, x, y)
  local function hit(kind, rows, facingFn)
    for _, row in ipairs(rows or {}) do
      if tonumber(row.x) == x and tonumber(row.y) == y then
        local facing = facingFn and facingFn(row) or row.facing
        return {
          kind = kind, x = x, y = y, mapId = mapId,
          requiredFacing = facing,
          clickedX = x, clickedY = y,
        }
      end
    end
  end

  -- These are the same extracted hidden-event surfaces the engine's own
  -- OverworldState:interact dispatches.  "Hidden" here means they are not NPC
  -- object_events, not that the mod should reveal hidden items: item/coin
  -- treasure tables are intentionally absent from this list.
  local out =
    hit("pc", fieldRows(game, "pcTiles", mapId))
    or hit("bench", fieldRows(game, "benchGuys", mapId),
           function(row) return row.textFacing or row.facing end)
    or hit("gym_statue", fieldRows(game, "gymStatues", mapId))
    or hit("trash", fieldRows(game, "printTrash", mapId),
           function() return nil end)
    or hit("slot", fieldRows(game, "slots", mapId))
    or hit("trash_can", fieldRows(game, "trashCans", mapId))
  if out then return out end

  -- Bill's cell-separator PC is a hand-ported hidden-event special rather
  -- than one of the generic PC rows in older/newer caches.
  if mapId == "BILLS_HOUSE" and x == 1 and y == 4 then
    return { kind = "bill_pc", x = x, y = y, mapId = mapId,
             requiredFacing = "up", clickedX = x, clickedY = y }
  end

  -- Bookshelves, town maps, elevator panels and "stuff" furniture are
  -- data-driven by tileset + collision tile.  Vanilla only activates these
  -- while facing up, so model that exact affordance rather than treating the
  -- whole wall as walkable.
  local shelves = game and game.data and game.data.field
      and game.data.field.bookshelves
  local byTileset = shelves and map and map.def and shelves[map.def.tileset]
  if byTileset and type(map.cellTile) == "function" then
    local ok, tile = pcall(map.cellTile, map, x, y)
    if ok and byTileset[tile] then
      return { kind = "bookshelf", x = x, y = y, mapId = mapId,
               requiredFacing = "up", clickedX = x, clickedY = y }
    end
  end

  local signs = map and map.def and map.def.signs or {}
  for _, sign in ipairs(signs) do
    if sign.x == x and sign.y == y then
      return { kind = "sign", x = x, y = y, mapId = mapId,
               clickedX = x, clickedY = y }
    end
  end
  return nil
end

local function entityInteraction(entity, x, y)
  return {
    kind = "entity", entityId = entity.id,
    clickedX = x, clickedY = y,
    chase = entity.wanders == true or entity.moving == true,
  }
end

local function interactionAt(game, x, y)
  local ow = game and game.overworld
  if not ow then return nil end

  -- The actor itself wins when the user taps its cell (or its reserved
  -- landing cell while walking).
  for _, entity in ipairs(ow.npcs or {}) do
    if entityIsInteractable(entity)
        and ((entity.cellX == x and entity.cellY == y)
          or (entity.targetX == x and entity.targetY == y)) then
      return entityInteraction(entity, x, y)
    end
  end

  local fixed = staticInteractionAt(game, ow.map and ow.map.id, ow.map, x, y)
  if fixed then return fixed end

  -- Counter context: the visible activation surface is often the counter
  -- tile, while the clerk/nurse actor is one cell farther away.  Tapping the
  -- counter itself therefore resolves to the actor behind it, exactly as the
  -- vanilla interact routine performs its second-cell lookup.
  if counterAt(game, x, y) then
    for _, d in ipairs(DIRS) do
      local bx, by = x + d.dx, y + d.dy
      for _, entity in ipairs(ow.npcs or {}) do
        if entityIsInteractable(entity)
            and ((entity.cellX == bx and entity.cellY == by)
              or (entity.targetX == bx and entity.targetY == by)) then
          local out = entityInteraction(entity, x, y)
          out.counterProxy = true
          -- From the player's side the actor lies in d, so the required
          -- facing through this counter is d.name.
          out.preferredFacing = d.name
          return out
        end
      end
    end
  end
  return nil
end

local function interactionTarget(game, interaction)
  if not interaction then return nil end
  if interaction.kind ~= "entity" then
    return interaction.x, interaction.y, nil
  end
  local entity = entityById(game, interaction.entityId)
  if not entity then return nil, nil, nil, "gone" end
  -- Follow identity, not the coordinate originally tapped.  While an NPC is
  -- mid-step, targetX/targetY is its reserved landing cell; as soon as it
  -- chooses another wander step the route is rebuilt toward the new one.
  local x = entity.moving and entity.targetX or entity.cellX
  local y = entity.moving and entity.targetY or entity.cellY
  x = type(x) == "number" and x or entity.cellX
  y = type(y) == "number" and y or entity.cellY
  return x, y, entity
end

local function cleanupTempBlocks(nav, dynamicNow)
  if not nav then return end
  for k, expires in pairs(nav.tempBlocked or {}) do
    -- A temporary entity block can be forgotten early once no dynamic actor
    -- currently occupies/reserves that cell.  Otherwise keep it until expiry
    -- to avoid immediately retrying the same moving collision on the next tick.
    if expires <= state.tick or (dynamicNow and not dynamicNow[k]) then
      nav.tempBlocked[k] = nil
    end
  end
end

local function passable(overview, x, y, goalX, goalY, waterMode,
                        occupied, tempBlocked, blockedEdges, blockedCells,
                        fromX, fromY, allowBlockedGoal)
  local ch = cellChar(overview, x, y)
  if not ch then return false end

  local k = key(x, y)
  if occupied and occupied[k] then return false end
  if blockedCells and blockedCells[k] then return false end
  local expires = tempBlocked and tempBlocked[k]
  if expires and expires > state.tick then return false end

  if fromX ~= nil and blockedEdges
      and blockedEdges[edgeKey(fromX, fromY, x, y)] then
    return false
  end

  -- Exit carpets are a special graph endpoint. Gen I can attach a warp
  -- record to a collision cell that is NOT ordinary walkable terrain and
  -- not reported as '+' by mapOverview. Such a cell must remain forbidden
  -- as an intermediate A* node (otherwise routing could accidentally warp),
  -- but an already-validated exit intent may explicitly allow that exact
  -- cell as the final destination.
  if allowBlockedGoal and x == goalX and y == goalY then return true end

  if ch == "." then return true end
  if ch == "~" then return waterMode end
  -- Warp cells are legal only as the requested destination.  Treating a
  -- random door/stair as an intermediate node could silently change maps.
  if ch == "+" then return x == goalX and y == goalY end
  return false
end

local function nodeLess(a, b)
  if a.f ~= b.f then return a.f < b.f end
  if a.h ~= b.h then return a.h < b.h end
  if a.g ~= b.g then return a.g < b.g end
  return a.seq < b.seq
end

local function heapPush(heap, node)
  local i = #heap + 1
  heap[i] = node
  while i > 1 do
    local p = math.floor(i / 2)
    if not nodeLess(heap[i], heap[p]) then break end
    heap[i], heap[p] = heap[p], heap[i]
    i = p
  end
end

local function heapPop(heap)
  if #heap == 0 then return nil end
  local root = heap[1]
  local tail = table.remove(heap)
  if #heap == 0 then return root end
  heap[1] = tail
  local i = 1
  while true do
    local l, r = i * 2, i * 2 + 1
    local best = i
    if l <= #heap and nodeLess(heap[l], heap[best]) then best = l end
    if r <= #heap and nodeLess(heap[r], heap[best]) then best = r end
    if best == i then break end
    heap[i], heap[best] = heap[best], heap[i]
    i = best
  end
  return root
end

local function parseKey(k)
  local sx, sy = k:match("^(-?%d+),(-?%d+)$")
  return tonumber(sx), tonumber(sy)
end

local function reconstruct(cameFrom, cameVia, goalKey)
  -- A* graph nodes are standable cells.  A ledge is a directed two-cell edge
  -- from the standing cell to its landing cell; the engine animates the ledge
  -- tile in between.  Re-insert that midpoint into the executable path so the
  -- existing route follower can observe either the intermediate scripted cell
  -- or a direct two-cell landing without treating faithful movement as an
  -- override.
  local rev = {}
  local k = goalKey
  while k do
    local x, y = parseKey(k)
    rev[#rev + 1] = { x = x, y = y, via = cameVia and cameVia[k] or nil }
    k = cameFrom[k]
  end
  local out = {}
  for i = #rev - 1, 1, -1 do
    local node = rev[i]
    local via = node.via
    if via and via.kind == "ledge" then
      out[#out + 1] = { x = via.midX, y = via.midY, forced = "ledge", dir = via.dir }
    end
    out[#out + 1] = { x = node.x, y = node.y, forced = via and via.kind or nil,
                      dir = via and via.dir or nil }
  end
  return out
end

local function findPath(overview, sx, sy, gx, gy, waterMode,
                        occupied, tempBlocked, blockedEdges, blockedCells, specialEdges,
                        allowBlockedGoal)
  if not overview then return nil end
  if sx == gx and sy == gy then return {} end

  occupied = copyFlat(occupied)
  occupied[key(sx, sy)] = nil -- the player occupies the start cell

  if not passable(overview, gx, gy, gx, gy, waterMode,
                  occupied, tempBlocked, blockedEdges, blockedCells,
                  nil, nil, allowBlockedGoal) then
    return nil
  end

  local startKey = key(sx, sy)
  local goalKey = key(gx, gy)
  local open = {}
  local gScore = { [startKey] = 0 }
  local cameFrom = {}
  local cameVia = {}
  local seq = 0
  local startH = math.abs(gx - sx) + math.abs(gy - sy)
  seq = seq + 1
  heapPush(open, { x = sx, y = sy, g = 0, h = startH, f = startH,
                   k = startKey, seq = seq })

  -- A map overview is finite, but a conservative expansion cap protects a
  -- malformed custom map from turning one tap into an unbounded search.
  local maxExpanded = math.max(1, (tonumber(overview.width) or 0)
                                   * (tonumber(overview.height) or 0) * 2)
  local expanded = 0

  while #open > 0 and expanded < maxExpanded do
    local cur = heapPop(open)
    if cur.g == gScore[cur.k] then
      expanded = expanded + 1
      if cur.k == goalKey then
        local path = reconstruct(cameFrom, cameVia, goalKey)
        return path
      end

      for _, d in ipairs(DIRS) do
        local nx, ny = cur.x + d.dx, cur.y + d.dy
        if passable(overview, nx, ny, gx, gy, waterMode,
                    occupied, tempBlocked, blockedEdges, blockedCells,
                    cur.x, cur.y, allowBlockedGoal) then
          local nk = key(nx, ny)
          local ng = cur.g + 1
          if gScore[nk] == nil or ng < gScore[nk] then
            gScore[nk] = ng
            cameFrom[nk] = cur.k
            cameVia[nk] = nil
            local h = math.abs(gx - nx) + math.abs(gy - ny)
            seq = seq + 1
            heapPush(open, { x = nx, y = ny, g = ng, h = h,
                             f = ng + h, k = nk, seq = seq })
          end
        end
      end

      -- Ledges are directed graph edges, not ordinary walkable cells.  The
      -- source/mid/landing geometry is derived from the same generated ledge
      -- table the vanilla overworld uses.  Only the landing cell participates
      -- in A*: the midpoint is injected later by reconstruct().
      for _, jump in ipairs((specialEdges and specialEdges[cur.k]) or {}) do
        local nx, ny = jump.x, jump.y
        local nk = key(nx, ny)
        local ch = cellChar(overview, nx, ny)
        local targetBlocked = not ch
          or (occupied and occupied[nk])
          or (blockedCells and blockedCells[nk])
          or (tempBlocked and tempBlocked[nk] and tempBlocked[nk] > state.tick)
          or (blockedEdges and blockedEdges[edgeKey(cur.x, cur.y, nx, ny)])
        if not targetBlocked then
          local ng = cur.g + (jump.cost or 2)
          if gScore[nk] == nil or ng < gScore[nk] then
            gScore[nk] = ng
            cameFrom[nk] = cur.k
            cameVia[nk] = jump
            local h = math.abs(gx - nx) + math.abs(gy - ny)
            seq = seq + 1
            heapPush(open, { x = nx, y = ny, g = ng, h = h,
                             f = ng + h, k = nk, seq = seq })
          end
        end
      end
    end
  end

  return nil
end

-- Find the reachable legal movement cell that gets as close as possible to an
-- arbitrary requested cell. This is the Hold-to-Steer "never ignore the
-- finger" fallback: a wall/building/solid prop is not a destination, but the
-- closest reachable floor beside it is. One Dijkstra pass replaces the old
-- no-op/retain behavior and keeps ledges + runtime blocked edges faithful.
local function findClosestReachablePath(overview, sx, sy, desiredX, desiredY,
                                        waterMode, occupied, tempBlocked,
                                        blockedEdges, blockedCells, specialEdges)
  if not overview then return nil end
  occupied = copyFlat(occupied)
  occupied[key(sx, sy)] = nil

  local function terrainOK(x, y)
    local ch = cellChar(overview, x, y)
    return ch == "." or (ch == "~" and waterMode)
  end

  local function stepOK(fromX, fromY, x, y)
    if not terrainOK(x, y) then return false end
    local k = key(x, y)
    if occupied and occupied[k] then return false end
    if blockedCells and blockedCells[k] then return false end
    local expires = tempBlocked and tempBlocked[k]
    if expires and expires > state.tick then return false end
    if blockedEdges and blockedEdges[edgeKey(fromX, fromY, x, y)] then return false end
    return true
  end

  local startKey = key(sx, sy)
  local open, cameFrom, cameVia = {}, {}, {}
  local gScore = { [startKey] = 0 }
  local seq = 0
  seq = seq + 1
  heapPush(open, { x=sx, y=sy, g=0, h=0, f=0, k=startKey, seq=seq })

  local bestKey, bestDist, bestCost, bestSeq
  local maxExpanded = math.max(1, (tonumber(overview.width) or 0)
                                   * (tonumber(overview.height) or 0) * 2)
  local expanded = 0

  while #open > 0 and expanded < maxExpanded do
    local cur = heapPop(open)
    if cur.g == gScore[cur.k] then
      expanded = expanded + 1
      if terrainOK(cur.x, cur.y) then
        local dist = math.abs(desiredX - cur.x) + math.abs(desiredY - cur.y)
        if bestDist == nil or dist < bestDist
            or (dist == bestDist and cur.g < bestCost)
            or (dist == bestDist and cur.g == bestCost and cur.seq < bestSeq) then
          bestKey, bestDist, bestCost, bestSeq = cur.k, dist, cur.g, cur.seq
        end
      end

      for _, d in ipairs(DIRS) do
        local nx, ny = cur.x + d.dx, cur.y + d.dy
        if stepOK(cur.x, cur.y, nx, ny) then
          local nk, ng = key(nx, ny), cur.g + 1
          if gScore[nk] == nil or ng < gScore[nk] then
            gScore[nk] = ng
            cameFrom[nk] = cur.k
            cameVia[nk] = nil
            seq = seq + 1
            heapPush(open, { x=nx, y=ny, g=ng, h=0, f=ng, k=nk, seq=seq })
          end
        end
      end

      for _, jump in ipairs((specialEdges and specialEdges[cur.k]) or {}) do
        local nx, ny = jump.x, jump.y
        if terrainOK(nx, ny) then
          local nk = key(nx, ny)
          local blocked = (occupied and occupied[nk])
            or (blockedCells and blockedCells[nk])
            or (tempBlocked and tempBlocked[nk] and tempBlocked[nk] > state.tick)
            or (blockedEdges and blockedEdges[edgeKey(cur.x, cur.y, nx, ny)])
          if not blocked then
            local ng = cur.g + (jump.cost or 2)
            if gScore[nk] == nil or ng < gScore[nk] then
              gScore[nk] = ng
              cameFrom[nk] = cur.k
              cameVia[nk] = jump
              seq = seq + 1
              heapPush(open, { x=nx, y=ny, g=ng, h=0, f=ng, k=nk, seq=seq })
            end
          end
        end
      end
    end
  end

  if not bestKey then return nil end
  local bx, by = parseKey(bestKey)
  return reconstruct(cameFrom, cameVia, bestKey), bx, by, bestDist
end

local function directionTo(x, y, nx, ny)
  local dx, dy = nx - x, ny - y
  if dx == 1 and dy == 0 then return "right" end
  if dx == -1 and dy == 0 then return "left" end
  if dx == 0 and dy == 1 then return "down" end
  if dx == 0 and dy == -1 then return "up" end
  return nil
end

local function mergeBlockedEdges(runtimeEdges, topologyEdges)
  local out = copyFlat(topologyEdges)
  for k, v in pairs(runtimeEdges or {}) do out[k] = v end
  return out
end

-- Ledge topology is generated from static map/tileset data, but before test8
-- every route rebuild rescanned every cell on the map. Hold-to-Steer can ask
-- for a new path several times per second, so that repeated O(map area) scan
-- was pure overhead. Cache by the loaded map object (weak keys avoid keeping
-- evicted maps alive), and include the generated ledge table + overview size
-- in the cache identity. A genuine map reload naturally gets a new map object.
local ledgeTopologyCache = setmetatable({}, { __mode = "k" })

local function invalidateLedgeTopologyCache()
  ledgeTopologyCache = setmetatable({}, { __mode = "k" })
end

-- Build one-way ledge topology from the live/generated map data used by
-- OverworldState:checkLedgeHop.  A ledge jump is legal only in the declared
-- direction and lands two cells away.  The reverse landing->ledge edge is
-- explicitly blocked so the planner understands the one-way topology before
-- runtime collision has to teach it.  Cross-map ledge landings remain owned
-- by the seam planner; this helper intentionally handles in-map jumps only.
local function ledgeTopology(game, map, overview)
  local ledges = game and game.data and game.data.field and game.data.field.ledges
  if map and overview then
    local cached = ledgeTopologyCache[map]
    if cached and cached.ledges == ledges
        and cached.width == overview.width and cached.height == overview.height
        and cached.tileset == (map.def and map.def.tileset) then
      state.stats.topologyCacheHits = state.stats.topologyCacheHits + 1
      return cached.topology
    end
  end

  local topology = { jumps = {}, blockedEdges = {}, seamJumps = {} }
  if not map or not overview or type(ledges) ~= "table"
      or type(map.cellTile) ~= "function" or type(map.isWalkableCell) ~= "function" then
    return topology
  end
  state.stats.topologyCacheMisses = state.stats.topologyCacheMisses + 1
  local tileset = map.def and map.def.tileset
  for y = 0, overview.height - 1 do
    for x = 0, overview.width - 1 do
      local okStanding, standing = pcall(map.cellTile, map, x, y)
      if okStanding then
        for _, ledge in ipairs(ledges) do
          local dirName = ledge.input or ledge.facing
          local d = DIR_BY_NAME[dirName]
          if d and ledge.facing == dirName
              and (ledge.tileset or "OVERWORLD") == tileset
              and ledge.standingTile == standing then
            local mx, my = x + d.dx, y + d.dy
            local lx, ly = x + d.dx * 2, y + d.dy * 2
            if mx >= 0 and my >= 0 and mx < overview.width and my < overview.height then
              local okFront, front = pcall(map.cellTile, map, mx, my)
              if okFront and front == ledge.ledgeTile then
                if lx >= 0 and ly >= 0 and lx < overview.width and ly < overview.height then
                  local okLand, landOK = pcall(map.isWalkableCell, map, lx, ly)
                  if okLand and landOK == true then
                    local sk = key(x, y)
                    topology.jumps[sk] = topology.jumps[sk] or {}
                    topology.jumps[sk][#topology.jumps[sk] + 1] = {
                      kind = "ledge", dir = dirName, x = lx, y = ly,
                      midX = mx, midY = my, cost = 2,
                    }
                    -- The faithful hop is one-way.  In particular, the landing
                    -- cell may never path back "up" through the ledge tile.
                    topology.blockedEdges[edgeKey(lx, ly, mx, my)] = true
                  end
                else
                  -- Vanilla also supports a ledge whose SECOND half crosses a
                  -- connected-map seam (Route 4 is the canonical case).  Keep
                  -- the source+edge midpoint so the cross-map planner can use
                  -- the normal engine ledge callback instead of pretending the
                  -- player can stand on the ledge tile and walk off normally.
                  topology.seamJumps[#topology.seamJumps + 1] = {
                    kind = "ledge_seam", dir = dirName,
                    sourceX = x, sourceY = y, midX = mx, midY = my, cost = 2,
                  }
                end
              end
            end
          end
        end
      end
    end
  end
  ledgeTopologyCache[map] = {
    ledges = ledges, width = overview.width, height = overview.height,
    tileset = tileset, topology = topology,
  }
  return topology
end

local function currentWaterMode(game, overview, cur)
  local player = game and game.overworld and game.overworld.player
  if player and player.surfing then return true end
  return cellChar(overview, cur.x, cur.y) == "~"
end

local function scheduleDynamicWait(nav, reason)
  releaseHold(nav)
  if not nav.dynamicWaitStarted then
    nav.dynamicWaitStarted = state.tick
    state.stats.dynamicWaits = state.stats.dynamicWaits + 1
  end
  nav.waitUntil = state.tick + DYNAMIC_RETRY_TICKS
  setPhase(nav, "WAITING_DYNAMIC", reason or "dynamic_obstacle")
end

local function buildPath(game, nav, cur)
  local overview = mod.world and mod.world:mapOverview()
  if not overview or overview.mapId ~= nav.mapId then return nil, "map" end

  local occupied, dynamic, static = liveOccupancy(game)
  cleanupTempBlocks(nav, dynamic)
  local waterMode = currentWaterMode(game, overview, cur)
  local topology = ledgeTopology(game, game.overworld and game.overworld.map, overview)
  local blockedEdges = mergeBlockedEdges(nav.blockedEdges, topology.blockedEdges)
  local allowExitGoal = nav.goalKind == "exit" and nav.exitIntent ~= nil
    and nav.exitDir ~= nil
  local path = findPath(overview, cur.x, cur.y,
                        nav.targetX, nav.targetY, waterMode,
                        occupied, nav.tempBlocked, blockedEdges, nav.blockedCells,
                        topology.jumps, allowExitGoal)
  if not path then
    -- Only wait when removing CURRENTLY-MOVABLE actors makes a path possible.
    -- A wall or a stationary NPC therefore fails immediately rather than
    -- pretending it might disappear just because some unrelated NPC wanders
    -- elsewhere on the map.
    local withoutDynamic = findPath(overview, cur.x, cur.y,
                                    nav.targetX, nav.targetY, waterMode,
                                    static, nil, blockedEdges, nav.blockedCells,
                                    topology.jumps, allowExitGoal)
    if withoutDynamic then return nil, "dynamic" end
    return nil, "blocked"
  end

  nav.path = path
  nav.index = 1
  nav.lastX, nav.lastY = cur.x, cur.y
  nav.lastProgressTick = state.tick
  nav.needsReplan = false
  nav.waitUntil = nil
  nav.dynamicWaitStarted = nil
  nav.previewUntil = state.tick + 18
  setPhase(nav, "WALKING")
  return true
end

local function buildNearestLegalPath(game, nav, cur, desiredX, desiredY)
  local overview = mod.world and mod.world:mapOverview()
  if not overview or overview.mapId ~= nav.mapId then return nil, "map" end

  local occupied, dynamic, static = liveOccupancy(game)
  cleanupTempBlocks(nav, dynamic)
  local waterMode = currentWaterMode(game, overview, cur)
  local topology = ledgeTopology(game, game.overworld and game.overworld.map, overview)
  local blockedEdges = mergeBlockedEdges(nav.blockedEdges, topology.blockedEdges)

  local path, tx, ty = findClosestReachablePath(
    overview, cur.x, cur.y, desiredX, desiredY, waterMode,
    occupied, nav.tempBlocked, blockedEdges, nav.blockedCells, topology.jumps)

  if not path then
    path, tx, ty = findClosestReachablePath(
      overview, cur.x, cur.y, desiredX, desiredY, waterMode,
      static, nil, blockedEdges, nav.blockedCells, topology.jumps)
    if path then return nil, "dynamic" end
    return nil, "blocked"
  end

  nav.targetX, nav.targetY = tx, ty
  nav.path = path
  nav.index = 1
  nav.lastX, nav.lastY = cur.x, cur.y
  nav.lastProgressTick = state.tick
  nav.needsReplan = false
  nav.waitUntil = nil
  nav.dynamicWaitStarted = nil
  nav.previewUntil = state.tick + 18
  setPhase(nav, "WALKING", "nearest_legal")
  return true
end

local function candidateTerrainOK(overview, x, y, waterMode)
  local ch = cellChar(overview, x, y)
  if ch == "." then return true end
  if ch == "~" and waterMode then return true end
  return false -- never stand on a warp just to interact
end

local function bestInteractionApproach(game, nav, cur, overview, occupied, topology)
  local interaction = nav.interaction
  local ix, iy, entity, err = interactionTarget(game, interaction)
  if not ix then return nil, err or "gone" end
  local waterMode = currentWaterMode(game, overview, cur)
  local best

  local function consider(cx, cy, faceDir, counter, rank)
    if interaction.requiredFacing and faceDir ~= interaction.requiredFacing then return end
    if interaction.preferredFacing and faceDir ~= interaction.preferredFacing then
      rank = rank + 100
    end
    if not candidateTerrainOK(overview, cx, cy, waterMode) then return end
    local blockedEdges = mergeBlockedEdges(nav.blockedEdges, topology and topology.blockedEdges)
    local path = findPath(overview, cur.x, cur.y, cx, cy, waterMode,
                          occupied, nav.tempBlocked, blockedEdges, nav.blockedCells,
                          topology and topology.jumps)
    if not path then return end
    local cand = { x = cx, y = cy, faceDir = faceDir, counter = counter,
                   path = path, cost = #path, rank = rank }
    if not best or cand.cost < best.cost
        or (cand.cost == best.cost and cand.rank < best.rank) then
      best = cand
    end
  end

  for _, d in ipairs(DIRS) do
    -- Normal adjacent interaction.  Fixed field surfaces such as a Pokémon
    -- Center PC may specify the only facing accepted by the engine.
    local cx, cy = ix - d.dx, iy - d.dy
    consider(cx, cy, d.name, false, d.rank * 2)

    -- Gen I counters: the player stands two cells from the clerk/nurse and
    -- faces across the counter tile.  This covers both tapping the actor and
    -- tapping the counter proxy in front of it.
    local mx, my = ix - d.dx, iy - d.dy
    if interaction.kind == "entity" and counterAt(game, mx, my) then
      local ccx, ccy = ix - d.dx * 2, iy - d.dy * 2
      consider(ccx, ccy, d.name, true, d.rank * 2 + 1)
    end
  end

  if not best then return nil, "blocked" end
  best.targetX, best.targetY, best.entity = ix, iy, entity
  return best
end

local function buildInteractionPath(game, nav, cur)
  local overview = mod.world and mod.world:mapOverview()
  if not overview or overview.mapId ~= nav.mapId then return nil, "map" end

  local occupied, dynamic, static = liveOccupancy(game)
  cleanupTempBlocks(nav, dynamic)
  local topology = ledgeTopology(game, game.overworld and game.overworld.map, overview)
  local best, why = bestInteractionApproach(game, nav, cur, overview, occupied, topology)
  if not best then
    if why == "gone" then return nil, "gone" end
    local withoutDynamic = bestInteractionApproach(game, nav, cur, overview, static, topology)
    if withoutDynamic then return nil, "dynamic" end
    return nil, "blocked"
  end

  nav.interaction.targetX = best.targetX
  nav.interaction.targetY = best.targetY
  nav.interaction.faceDir = best.faceDir
  nav.interaction.counter = best.counter
  nav.targetX, nav.targetY = best.x, best.y
  nav.path = best.path
  nav.index = 1
  nav.lastX, nav.lastY = cur.x, cur.y
  nav.lastProgressTick = state.tick
  nav.needsReplan = false
  nav.waitUntil = nil
  nav.dynamicWaitStarted = nil
  nav.previewUntil = state.tick + 18
  if not nav.interaction.chaseReplan then
    nav.interactionBuilds = (nav.interactionBuilds or 0) + 1
    if nav.interactionBuilds > MAX_INTERACTION_REPLANS then
      return nil, "interaction_replan_limit"
    end
  end
  nav.interaction.chaseReplan = nil
  setPhase(nav, "WALKING", "interaction_approach")
  return true
end

local function seamLanding(cross, sx, sy)
  local dest = cross.destOverview
  local off = (cross.conn and cross.conn.offset or 0) * 2
  if cross.dir == "up" then return sx - off, dest.height - 1 end
  if cross.dir == "down" then return sx - off, 0 end
  if cross.dir == "left" then return dest.width - 1, sy - off end
  return 0, sy - off
end

local function seamSourceCells(cross, overview)
  local out = {}
  if cross.dir == "up" or cross.dir == "down" then
    local y = cross.dir == "up" and 0 or overview.height - 1
    for x = 0, overview.width - 1 do out[#out + 1] = {x=x,y=y} end
  else
    local x = cross.dir == "left" and 0 or overview.width - 1
    for y = 0, overview.height - 1 do out[#out + 1] = {x=x,y=y} end
  end
  return out
end

local function chooseCrossSeam(game, nav, cur, occupancy)
  local cross = nav.cross
  local overview = mod.world and mod.world:mapOverview()
  if not cross or not overview or overview.mapId ~= cross.sourceMapId then return nil end
  local waterMode = currentWaterMode(game, overview, cur)
  local sourceTopology = ledgeTopology(game, game.overworld and game.overworld.map, overview)
  local sourceBlockedEdges = mergeBlockedEdges(nav.blockedEdges, sourceTopology.blockedEdges)
  local destTopology = ledgeTopology(game, cross.destMap, cross.destOverview)
  local best
  for _, src in ipairs(seamSourceCells(cross, overview)) do
    local sx, sy = src.x, src.y
    local sch = cellChar(overview, sx, sy)
    -- Standing on a warp square just to leave through a connection creates
    -- ambiguous warp-vs-seam semantics; pick another overlap cell.
    if sch and sch ~= "+" then
      local lx, ly = seamLanding(cross, sx, sy)
      local lch = cellChar(cross.destOverview, lx, ly)
      local landingOK = lch == "." or (lch == "~" and waterMode)
      local dx, dy = sx, sy
      if cross.dir == "up" then dy = sy - 1
      elseif cross.dir == "down" then dy = sy + 1
      elseif cross.dir == "left" then dx = sx - 1
      else dx = sx + 1 end
      if landingOK and not nav.blockedEdges[edgeKey(sx, sy, dx, dy)] then
        local pathHere = findPath(overview, cur.x, cur.y, sx, sy, waterMode,
          occupancy, nav.tempBlocked, sourceBlockedEdges, nav.blockedCells,
          sourceTopology.jumps)
        if pathHere then
          -- Static reachability inside the loaded neighbour keeps us from
          -- crossing through a seam that leads into a dead pocket. Runtime
          -- NPC occupancy is intentionally not baked in; it may move before
          -- the crossing and the active-map replan will handle it.
          local pathThere = findPath(cross.destOverview, lx, ly,
            cross.targetX, cross.targetY, waterMode, {}, {},
            destTopology.blockedEdges, {}, destTopology.jumps)
          if pathThere then
            local score = #pathHere + 1 + #pathThere
            if not best or score < best.score then
              best = { score=score, path=pathHere, sourceX=sx, sourceY=sy,
                       entryX=lx, entryY=ly }
            end
          end
        end
      end
    end
  end

  -- A faithful ledge may consume the edge tile as the first half of the hop
  -- and cross the map connection on its second half.  Such a route cannot be
  -- represented by the normal "stand on border cell, then step out" seam
  -- candidates because the border cell itself is a ledge tile.
  for _, jump in ipairs(sourceTopology.seamJumps or {}) do
    if jump.dir == cross.dir then
      local lx, ly = seamLanding(cross, jump.midX, jump.midY)
      local lch = cellChar(cross.destOverview, lx, ly)
      local landingOK = lch == "." or (lch == "~" and waterMode)
      if landingOK then
        local pathHere = findPath(overview, cur.x, cur.y,
          jump.sourceX, jump.sourceY, waterMode, occupancy, nav.tempBlocked,
          sourceBlockedEdges, nav.blockedCells, sourceTopology.jumps)
        if pathHere then
          local pathThere = findPath(cross.destOverview, lx, ly,
            cross.targetX, cross.targetY, waterMode, {}, {},
            destTopology.blockedEdges, {}, destTopology.jumps)
          if pathThere then
            local score = #pathHere + (jump.cost or 2) + #pathThere
            if not best or score < best.score then
              best = { score=score, path=pathHere,
                       sourceX=jump.sourceX, sourceY=jump.sourceY,
                       entryX=lx, entryY=ly, ledgeSeam=true,
                       ledgeMidX=jump.midX, ledgeMidY=jump.midY }
            end
          end
        end
      end
    end
  end
  return best
end

-- Neighbour-map equivalent of nearest-legal steering. A Voxel/survey view can
-- show a building/NPC/solid tile on the directly connected map; holding there
-- should not become a dead input merely because the requested neighbour cell
-- itself is not standable. Probe legal cells in increasing Manhattan rings and
-- keep the first one whose seam + destination route is actually reachable.
local function nearestReachableCrossTarget(game, cur, cross, desiredX, desiredY,
                                           excludeDesired)
  local dest = cross and cross.destOverview
  local source = mod.world and mod.world:mapOverview()
  if not dest or not source then return nil end
  local waterMode = currentWaterMode(game, source, cur)
  local all, _, static = liveOccupancy(game)
  local maxR = (tonumber(dest.width) or 0) + (tonumber(dest.height) or 0)

  local function legal(cx, cy)
    if cx < 0 or cy < 0 or cx >= dest.width or cy >= dest.height then return false end
    if excludeDesired and cx == desiredX and cy == desiredY then return false end
    local ch = cellChar(dest, cx, cy)
    return ch == "." or (ch == "~" and waterMode)
  end

  local function seamReachable(cx, cy, occupancy)
    local probe = {
      mapId = cur.mapId,
      blockedEdges = {}, blockedCells = {}, tempBlocked = {},
      cross = copyFlat(cross),
    }
    probe.cross.targetX, probe.cross.targetY = cx, cy
    return chooseCrossSeam(game, probe, cur, occupancy) ~= nil
  end

  for r = 0, maxR do
    local seen = {}
    local dynamicCandidate
    local y0, y1 = desiredY - r, desiredY + r
    for cy = y0, y1 do
      local dy = math.abs(cy - desiredY)
      local dx = r - dy
      local xs = { desiredX - dx }
      if dx ~= 0 then xs[#xs + 1] = desiredX + dx end
      for _, cx in ipairs(xs) do
        local k = key(cx, cy)
        if not seen[k] then
          seen[k] = true
          if legal(cx, cy) then
            if seamReachable(cx, cy, all) then
              return cx, cy, false
            end
            if not dynamicCandidate and seamReachable(cx, cy, static) then
              dynamicCandidate = { x=cx, y=cy }
            end
          end
        end
      end
    end
    -- "Closest to the object" beats taking a farther detour merely to avoid a
    -- moving actor. The normal cross planner will enter WAITING_DYNAMIC.
    if dynamicCandidate then
      return dynamicCandidate.x, dynamicCandidate.y, true
    end
  end
  return nil
end

local function buildCrossPath(game, nav, cur)
  local all, dynamic, static = liveOccupancy(game)
  local best = chooseCrossSeam(game, nav, cur, all)
  if not best then
    local withoutDynamic = chooseCrossSeam(game, nav, cur, static)
    if withoutDynamic then return nil, "dynamic" end
    return nil, "no_route"
  end
  nav.path = best.path
  nav.index = 1
  nav.targetX, nav.targetY = best.sourceX, best.sourceY
  nav.cross.sourceX, nav.cross.sourceY = best.sourceX, best.sourceY
  nav.cross.entryX, nav.cross.entryY = best.entryX, best.entryY
  nav.cross.ledgeSeam = best.ledgeSeam and true or false
  nav.cross.ledgeMidX, nav.cross.ledgeMidY = best.ledgeMidX, best.ledgeMidY
  nav.needsReplan = false
  nav.replanReason = nil
  nav.lastProgressTick = state.tick
  nav.previewUntil = state.tick + 18
  state.stats.replans = state.stats.replans + 1
  setPhase(nav, "WALKING", "connection_approach")
  return true
end

local function rebuildNavigation(game, nav, cur)
  if nav and nav.cross and not nav.cross.crossed then
    return buildCrossPath(game, nav, cur)
  end
  if nav and nav.interaction then
    return buildInteractionPath(game, nav, cur)
  end
  return buildPath(game, nav, cur)
end

local function playerPixel(game, cur)
  local player = game and game.overworld and game.overworld.player
  local px = player and tonumber(player.px) or cur.x * TILE_SIZE
  local py = player and tonumber(player.py) or cur.y * TILE_SIZE
  return px, py
end

local COMPASS_TO_DIR = {
  north = "up", south = "down", west = "left", east = "right",
}

local function mapCellSize(def, loaded)
  if loaded and loaded.widthCells and loaded.heightCells then
    return loaded.widthCells, loaded.heightCells
  end
  if not def then return nil end
  return tonumber(def.width) and def.width * 2 or nil,
         tonumber(def.height) and def.height * 2 or nil
end

local function loadedNeighborMap(game, mapId)
  local ow = game and game.overworld
  for _, nb in ipairs((ow and ow.neighbors) or {}) do
    if nb.map and nb.map.id == mapId then return nb.map, nb end
  end
  return nil
end

-- Build the same compact terrain alphabet WorldAPI.mapOverview uses, but only
-- for a neighbour map the engine has ALREADY loaded for survey rendering.
-- This is a read-only fallback used to reject impossible seam choices before
-- crossing; once the map becomes active, the public mapOverview is authority.
--
-- Survey neighbours are stable for the lifetime of one active map, yet test7
-- rebuilt every neighbour's entire compact grid on every Voxel ray/preview
-- lookup. Cache it by loaded map object and flush at map boundaries.
local loadedMapOverviewCache = setmetatable({}, { __mode = "k" })

local function invalidateLoadedMapOverviewCache()
  loadedMapOverviewCache = setmetatable({}, { __mode = "k" })
end

local function overviewFromLoadedMap(map)
  if not map or not map.widthCells or not map.heightCells then return nil end
  local cached = loadedMapOverviewCache[map]
  if cached and cached.width == map.widthCells and cached.height == map.heightCells then
    state.stats.overviewCacheHits = state.stats.overviewCacheHits + 1
    return cached.overview
  end
  state.stats.overviewCacheMisses = state.stats.overviewCacheMisses + 1
  local rows = {}
  for y = 0, map.heightCells - 1 do
    local row = {}
    for x = 0, map.widthCells - 1 do
      row[#row + 1] = map:isWarpTileCell(x, y) and "+"
        or map:isWaterCell(x, y) and "~"
        or map:isWalkableCell(x, y) and "." or " "
    end
    rows[#rows + 1] = table.concat(row)
  end
  local overview = { mapId = map.id, width = map.widthCells, height = map.heightCells,
                     rows = rows }
  loadedMapOverviewCache[map] = { width = map.widthCells, height = map.heightCells,
                                  overview = overview }
  return overview
end

-- Resolve a tap against the ACTUAL neighbour rectangles the overworld renderer
-- has already composed for survey view.  Using ow.neighbors[].ox/oy makes the
-- pointer hit-test share one source of truth with rendering instead of
-- re-deriving connection placement a second time from offsets.  Only a direct
-- connection is routable in this checkpoint; farther visible neighbours are
-- recognized but safely refused.
local function visibleNeighborTarget(game, worldX, worldY, overview)
  local ow = game and game.overworld
  local current = ow and ow.map
  local connections = current and current.def and current.def.connections
  if not ow or not connections then return nil end

  local directByMap = {}
  for _, compass in ipairs({ "north", "south", "west", "east" }) do
    local conn = connections[compass]
    if conn and conn.map then
      directByMap[conn.map] = { conn = conn, compass = compass,
                                dir = COMPASS_TO_DIR[compass] }
    end
  end

  local sawVisibleNeighbour = false
  for _, nb in ipairs(ow.neighbors or {}) do
    local map = nb.map
    local dw, dh = mapCellSize(map and map.def, map)
    local ox, oy = tonumber(nb.ox), tonumber(nb.oy)
    if map and dw and dh and ox and oy
        and worldX >= ox and worldY >= oy
        and worldX < ox + dw * TILE_SIZE
        and worldY < oy + dh * TILE_SIZE then
      sawVisibleNeighbour = true
      local direct = directByMap[map.id]
      if direct then
        local lx = math.floor((worldX - ox) / TILE_SIZE)
        local ly = math.floor((worldY - oy) / TILE_SIZE)
        local destOverview = overviewFromLoadedMap(map)
        if destOverview and lx >= 0 and ly >= 0
            and lx < destOverview.width and ly < destOverview.height then
          return {
            sourceMapId = overview.mapId, destMapId = map.id,
            dir = direct.dir, compass = direct.compass, conn = direct.conn,
            targetX = lx, targetY = ly,
            destOverview = destOverview, destMap = map,
            renderOx = ox, renderOy = oy,
          }, true
        end
      end
      return nil, true
    end
  end
  return nil, sawVisibleNeighbour
end

local function neighbourInteractionAt(game, cross, x, y)
  if not cross then return nil end
  local ow = game and game.overworld
  local ghosts = {}
  for _, ghost in ipairs((ow and ow.ghosts) or {}) do
    if ghost.map and ghost.map.id == cross.destMapId
        and entityIsInteractable(ghost.npc) then
      ghosts[#ghosts + 1] = ghost.npc
      local entity = ghost.npc
      if (entity.cellX == x and entity.cellY == y)
          or (entity.targetX == x and entity.targetY == y) then
        return entityInteraction(entity, x, y)
      end
    end
  end

  local fixed = staticInteractionAt(game, cross.destMapId, cross.destMap, x, y)
  if fixed then return fixed end

  -- Counter proxy on a rendered neighbour: use the loaded map's own counter
  -- classification and the visual ghost actors that will become real NPCs
  -- after the seamless crossing.
  local destMap = cross.destMap
  if destMap and type(destMap.isCounterCell) == "function" then
    local ok, isCounter = pcall(destMap.isCounterCell, destMap, x, y)
    if ok and isCounter then
      for _, d in ipairs(DIRS) do
        local bx, by = x + d.dx, y + d.dy
        for _, entity in ipairs(ghosts) do
          if (entity.cellX == bx and entity.cellY == by)
              or (entity.targetX == bx and entity.targetY == by) then
            local out = entityInteraction(entity, x, y)
            out.counterProxy = true
            out.preferredFacing = d.name
            return out
          end
        end
      end
    end
  end
  return nil
end


-- Dramatic Shape Voxel compatibility.  Dramatic Shape exports the same lib
-- namespace its renderer uses.  Read the live camera AND the cached scene
-- description from that seam; do not recreate a 2D camera approximation.
local voxelLibCache = { peer = nil, lib = nil }

local function voxelContext()
  if type(mod.find) ~= "function" then return nil end
  local okPeer, peer = pcall(mod.find, "DRAMATIC_SHAPE")
  if not okPeer or not peer or type(peer.exports) ~= "table" then return nil end
  local lib = peer.exports.lib
  if type(lib) ~= "table" or type(lib.require) ~= "function" then return nil end

  -- lib.require is internally cached by Dramatic Shape, but test7 still went
  -- through four protected lookups on every hold sample AND every preview
  -- frame. Cache the companion seam until the peer/lib identity changes (hot
  -- reload naturally replaces one of them).
  if voxelLibCache.peer ~= peer or voxelLibCache.lib ~= lib then
    local cache = { peer = peer, lib = lib }
    local okState, voxelState = pcall(lib.require, "VoxelState")
    local ok3d, voxel3d = pcall(lib.require, "Voxel3D")
    if okState then cache.voxelState = voxelState end
    if ok3d then cache.voxel3d = voxel3d end
    local okStructures, structures = pcall(lib.require, "Structures")
    if okStructures and type(structures) == "table"
        and type(structures.forMap) == "function" then
      cache.structures = structures
    end
    local okShape, tileShape = pcall(lib.require, "TileShape")
    if okShape and type(tileShape) == "table" then cache.tileShape = tileShape end
    voxelLibCache = cache
  end

  local voxelState, voxel3d = voxelLibCache.voxelState, voxelLibCache.voxel3d
  if type(voxel3d) ~= "table" or type(voxel3d.project) ~= "function" then
    return nil
  end
  if type(voxelState) == "table" and type(voxelState.active) == "function" then
    local okActive, active = pcall(voxelState.active)
    if not okActive or not active then return nil end
  end

  return voxelLibCache
end

local function pointInTriangle(px, py, ax, ay, bx, by, cx, cy)
  local v0x, v0y = cx - ax, cy - ay
  local v1x, v1y = bx - ax, by - ay
  local v2x, v2y = px - ax, py - ay
  local dot00 = v0x * v0x + v0y * v0y
  local dot01 = v0x * v1x + v0y * v1y
  local dot02 = v0x * v2x + v0y * v2y
  local dot11 = v1x * v1x + v1y * v1y
  local dot12 = v1x * v2x + v1y * v2y
  local denom = dot00 * dot11 - dot01 * dot01
  if math.abs(denom) < 0.000001 then return false end
  local inv = 1 / denom
  local u = (dot11 * dot02 - dot01 * dot12) * inv
  local v = (dot00 * dot12 - dot01 * dot02) * inv
  return u >= -0.001 and v >= -0.001 and (u + v) <= 1.001
end

local function pointInQuad(px, py, q)
  return pointInTriangle(px, py, q[1][1], q[1][2], q[2][1], q[2][2],
                         q[3][1], q[3][2])
      or pointInTriangle(px, py, q[1][1], q[1][2], q[3][1], q[3][2],
                         q[4][1], q[4][2])
end

local function pointSegmentDistance2(px, py, ax, ay, bx, by)
  local vx, vy = bx - ax, by - ay
  local len2 = vx * vx + vy * vy
  if len2 <= 0.000001 then
    local dx, dy = px - ax, py - ay
    return dx * dx + dy * dy
  end
  local t = ((px - ax) * vx + (py - ay) * vy) / len2
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local qx, qy = ax + vx * t, ay + vy * t
  local dx, dy = px - qx, py - qy
  return dx * dx + dy * dy
end

local function framebufferPoint(x, y, voxel3d)
  local frame = state.frame or {}
  local cw, ch
  if voxel3d and type(voxel3d.canvas) == "function" then
    local okC, canvas = pcall(voxel3d.canvas)
    if okC and canvas then
      local okW, w = pcall(canvas.getWidth, canvas)
      local okH, h = pcall(canvas.getHeight, canvas)
      if okW and okH then cw, ch = tonumber(w), tonumber(h) end
    end
  end

  -- Prefer the actual Voxel canvas / LOVE-unit ratio.  This survives odd
  -- Android DPI, anisotropic dpiX/dpiY and future pipeline canvas sizing.
  local ww, wh = tonumber(frame.ww), tonumber(frame.wh)
  local px, py
  if cw and ch and ww and wh and ww > 0 and wh > 0 then
    px, py = x * cw / ww, y * ch / wh
  else
    local dx, dy = tonumber(frame.dpiX) or 1, tonumber(frame.dpiY) or 1
    px, py = x * dx, y * dy
    cw, ch = cw or tonumber(frame.pw), ch or tonumber(frame.ph)
  end

  -- Renderer flips a window-resolution worldOverride vertically on iOS.
  -- Voxel3D.project itself stays in canvas Y-down coordinates, so mirror the
  -- pointer into that same canvas before unprojecting it.
  if ch and love and love.system and type(love.system.getOS) == "function" then
    local okOS, osName = pcall(love.system.getOS)
    if okOS and osName == "iOS" then py = ch - py end
  end
  return px, py, cw, ch
end

local function projectedPoint(voxel3d, wx, wy, height)
  local ok, sx, sy, depth = pcall(voxel3d.project, wx, height or 0, wy)
  if not ok or type(sx) ~= "number" or type(sy) ~= "number"
      or sx ~= sx or sy ~= sy then
    return nil
  end
  return { sx, sy, tonumber(depth) }
end

local voxelCandidateCache = { map = nil, neighbors = nil, connections = nil, entries = nil }

local function invalidateVoxelCandidateCache()
  voxelCandidateCache = { map = nil, neighbors = nil, connections = nil, entries = nil }
end

local function voxelCandidateMaps(game, overview)
  local ow = game and game.overworld
  if not ow or not ow.map then return {} end
  local connections = ow.map.def and ow.map.def.connections
  if voxelCandidateCache.map == ow.map
      and voxelCandidateCache.neighbors == ow.neighbors
      and voxelCandidateCache.connections == connections
      and voxelCandidateCache.entries then
    -- Active-map mapOverview is the one live piece (it can change after a
    -- block edit). Reuse the structural entry set but refresh that authority.
    voxelCandidateCache.entries[1].overview = overview
    return voxelCandidateCache.entries
  end

  local out = {
    { map = ow.map, mapId = ow.map.id, ox = 0, oy = 0, active = true,
      overview = overview },
  }
  local direct = {}
  for _, conn in pairs(connections or {}) do
    if conn and conn.map then direct[conn.map] = true end
  end
  for _, nb in ipairs(ow.neighbors or {}) do
    if nb.map and direct[nb.map.id] then
      out[#out + 1] = {
        map = nb.map, mapId = nb.map.id,
        ox = tonumber(nb.ox) or 0, oy = tonumber(nb.oy) or 0,
        active = false, overview = overviewFromLoadedMap(nb.map),
      }
    end
  end
  voxelCandidateCache = {
    map = ow.map, neighbors = ow.neighbors, connections = connections, entries = out,
  }
  return out
end

local function voxelStrongSemanticCell(game, entry, x, y)
  local map = entry and entry.map
  local ov = entry and entry.overview
  local ch = cellChar(ov, x, y)

  -- A visible wall/solid or warp is exactly where 3D geometry can cover a
  -- more distant floor quad. Treat those as occluding semantic surfaces.
  if ch == " " or ch == "+" then return true end

  if map and map.def then
    for _, w in ipairs(map.def.warps or {}) do
      if tonumber(w.x) == x and tonumber(w.y) == y then return true end
    end
    local fixed = staticInteractionAt(game, map.id, map, x, y)
    if fixed then return true end
    if type(map.isCounterCell) == "function" then
      local ok, yes = pcall(map.isCounterCell, map, x, y)
      if ok and yes then return true end
    end
  end

  local ow = game and game.overworld
  if entry and entry.active then
    for _, entity in ipairs((ow and ow.npcs) or {}) do
      if entityIsInteractable(entity)
          and ((entity.cellX == x and entity.cellY == y)
            or (entity.targetX == x and entity.targetY == y)) then
        return true
      end
    end
  else
    for _, ghost in ipairs((ow and ow.ghosts) or {}) do
      local entity = ghost.npc
      if ghost.map and map and ghost.map.id == map.id
          and entityIsInteractable(entity)
          and ((entity.cellX == x and entity.cellY == y)
            or (entity.targetX == x and entity.targetY == y)) then
        return true
      end
    end
  end
  return false
end

-- ------------------------------ native Voxel 3D ray picking -----------------
-- Voxel3D exposes the exact row-major view-projection matrix used by the
-- shader.  Invert it and cast the pointer back through the rendered scene.
-- This is the important distinction from the older compatibility layer:
-- the TOUCH is now interpreted in Voxel camera space first, and only then
-- translated back to a Gen1 gameplay cell.
local function invert4(m)
  if type(m) ~= "table" or #m < 16 then return nil end
  local a = {}
  for r = 1, 4 do
    a[r] = {}
    for c = 1, 4 do a[r][c] = tonumber(m[(r - 1) * 4 + c]) or 0 end
    for c = 1, 4 do a[r][c + 4] = (r == c) and 1 or 0 end
  end
  for c = 1, 4 do
    local pivot = c
    local best = math.abs(a[c][c])
    for r = c + 1, 4 do
      local v = math.abs(a[r][c])
      if v > best then best, pivot = v, r end
    end
    if best < 1e-12 then return nil end
    if pivot ~= c then a[c], a[pivot] = a[pivot], a[c] end
    local d = a[c][c]
    for j = 1, 8 do a[c][j] = a[c][j] / d end
    for r = 1, 4 do
      if r ~= c then
        local f = a[r][c]
        if math.abs(f) > 1e-15 then
          for j = 1, 8 do a[r][j] = a[r][j] - f * a[c][j] end
        end
      end
    end
  end
  local out = {}
  for r = 1, 4 do
    for c = 1, 4 do out[(r - 1) * 4 + c] = a[r][c + 4] end
  end
  return out
end

local function mulPoint4(m, x, y, z, w)
  return m[1]*x + m[2]*y + m[3]*z + m[4]*w,
         m[5]*x + m[6]*y + m[7]*z + m[8]*w,
         m[9]*x + m[10]*y + m[11]*z + m[12]*w,
         m[13]*x + m[14]*y + m[15]*z + m[16]*w
end

local function voxelRayFromPointer(x, y, voxel3d)
  local vp = voxel3d and voxel3d.vp
  if type(vp) ~= "table" then return nil end
  local px, py, cw, ch = framebufferPoint(x, y, voxel3d)
  if not (px and py and cw and ch and cw > 0 and ch > 0) then return nil end
  local inv = invert4(vp)
  if not inv then return nil end
  local nx, ny = px / cw * 2 - 1, py / ch * 2 - 1
  local x0,y0,z0,w0 = mulPoint4(inv, nx, ny, -1, 1)
  local x1,y1,z1,w1 = mulPoint4(inv, nx, ny,  1, 1)
  if math.abs(w0) < 1e-12 or math.abs(w1) < 1e-12 then return nil end
  x0,y0,z0 = x0/w0,y0/w0,z0/w0
  x1,y1,z1 = x1/w1,y1/w1,z1/w1
  local dx,dy,dz = x1-x0,y1-y0,z1-z0
  local len = math.sqrt(dx*dx + dy*dy + dz*dz)
  if len < 1e-9 then return nil end
  return { x=x0, y=y0, z=z0, dx=dx/len, dy=dy/len, dz=dz/len,
           px=px, py=py, canvasW=cw, canvasH=ch }
end

local function voxelCurveDrop(voxel3d, x, z)
  local k = tonumber(voxel3d and voxel3d.curveK) or 0
  if k <= 0 then return 0 end
  local cx = tonumber(voxel3d.curveX) or 0
  local cz = tonumber(voxel3d.curveZ) or 0
  local dx, dz = x - cx, z - cz
  return (dx*dx + dz*dz) * k
end

-- Intersect the live ray with the same curved ground equation Voxel3D.project
-- applies in its shader: y = -k * distance_from_focus^2.
local function rayGroundT(ray, voxel3d)
  local k = tonumber(voxel3d and voxel3d.curveK) or 0
  local cx = tonumber(voxel3d and voxel3d.curveX) or 0
  local cz = tonumber(voxel3d and voxel3d.curveZ) or 0
  if k <= 0 then
    if math.abs(ray.dy) < 1e-9 then return nil end
    local t = -ray.y / ray.dy
    return t >= 0 and t or nil
  end
  local rx, rz = ray.x - cx, ray.z - cz
  local A = k * (ray.dx*ray.dx + ray.dz*ray.dz)
  local B = ray.dy + 2*k*(rx*ray.dx + rz*ray.dz)
  local C = ray.y + k*(rx*rx + rz*rz)
  if math.abs(A) < 1e-12 then
    if math.abs(B) < 1e-12 then return nil end
    local t = -C / B
    return t >= 0 and t or nil
  end
  local disc = B*B - 4*A*C
  if disc < 0 then return nil end
  local root = math.sqrt(disc)
  local t1, t2 = (-B-root)/(2*A), (-B+root)/(2*A)
  local best
  if t1 >= 0 then best = t1 end
  if t2 >= 0 and (not best or t2 < best) then best = t2 end
  return best
end

local function rayAabbT(ray, x0,y0,z0,x1,y1,z1, maxT)
  local tmin, tmax = 0, maxT or math.huge
  local function axis(o, d, lo, hi)
    if math.abs(d) < 1e-10 then
      if o < lo or o > hi then return nil end
      return -math.huge, math.huge
    end
    local a, b = (lo-o)/d, (hi-o)/d
    if a > b then a,b = b,a end
    return a,b
  end
  for _, row in ipairs({{ray.x,ray.dx,x0,x1},{ray.y,ray.dy,y0,y1},{ray.z,ray.dz,z0,z1}}) do
    local a,b = axis(row[1],row[2],row[3],row[4])
    if not a then return nil end
    if a > tmin then tmin = a end
    if b < tmax then tmax = b end
    if tmax < tmin then return nil end
  end
  if tmax < 0 then return nil end
  if tmin < 0 then tmin = 0 end
  return tmin
end

local function voxelStructureKey(tx, ty)
  return (ty + 64) * 4096 + (tx + 64)
end

local function voxelStructuresFor(scene, entry)
  if not scene or not scene.structures or not entry or not entry.map then return nil end
  if entry._tapStructures ~= nil then
    return entry._tapStructures ~= false and entry._tapStructures or nil
  end
  local ok, S = pcall(scene.structures.forMap, entry.map)
  entry._tapStructures = (ok and type(S) == "table") and S or false
  return entry._tapStructures ~= false and entry._tapStructures or nil
end

local function voxelTileHeight(scene, entry, tx, ty)
  local S = voxelStructuresFor(scene, entry)
  if not S then return nil end
  local k = voxelStructureKey(tx, ty)
  local shape = S.shapeAt and S.shapeAt[k]
  if not shape then return nil end
  -- `skip` means the ordinary column was replaced by a voxelized object.
  -- Its profile height is still a useful conservative picking hull; the
  -- renderer's synthesized ground remains at y=0 below it.
  local run = S.runs and S.runs[k]
  local h = tonumber(run and run.h) or tonumber(shape.h) or 0
  if run and tonumber(run.rise) and run.rise > 0 then h = h + run.rise end
  if h <= 0 and S.skip and S.skip[k] then h = tonumber(shape.h) or 16 end
  return h, shape, S
end

-- Find which gameplay map owns a world X/Z point.  Connected Voxel maps are
-- rendered in one world coordinate system using the exact nb.ox/nb.oy model
-- translations, so no screen-space guessing is needed here.
local function voxelMapAtWorld(entries, wx, wz)
  local best
  for _, entry in ipairs(entries or {}) do
    local map = entry.map
    local w = map and (map.widthCells or (map.def and map.def.width and map.def.width*2))
    local h = map and (map.heightCells or (map.def and map.def.height and map.def.height*2))
    if w and h then
      local lx, lz = wx - entry.ox, wz - entry.oy
      if lx >= 0 and lz >= 0 and lx < w*TILE_SIZE and lz < h*TILE_SIZE then
        local hit = { entry=entry, x=math.floor(lx/TILE_SIZE),
                      y=math.floor(lz/TILE_SIZE), lx=lx, lz=lz }
        if entry.active then return hit end
        best = best or hit
      end
    end
  end
  return best
end

-- Traverse the ray through a map's 8x8 visual-tile grid and test the actual
-- structure heights Dramatic Shape cached for its ChunkMesher.  This catches
-- a building/wall/counter BEFORE the ground behind it, matching the depth
-- buffered scene well enough for semantic picking without duplicating the
-- renderer's enormous raw mesh in Lua memory.
local function voxelStructureHit(scene, entry, ray, maxT)
  if not scene.structures then return nil end
  local map = entry.map
  local tw = map and map.def and map.def.width and map.def.width*4
  local th = map and map.def and map.def.height and map.def.height*4
  if not (tw and th) then return nil end

  -- Clip the ray's X/Z segment to the map body, then sample each crossed
  -- visual tile.  Step size 4px is half a voxel tile: conservative enough to
  -- never leap over an 8px column, while bounded by the camera->ground span.
  local startT, stopT = 0, maxT
  local function clip(o,d,lo,hi)
    if math.abs(d) < 1e-10 then return (o>=lo and o<=hi) and -math.huge or nil, math.huge end
    local a,b=(lo-o)/d,(hi-o)/d; if a>b then a,b=b,a end; return a,b
  end
  local ax,bx=clip(ray.x,ray.dx,entry.ox,entry.ox+tw*8)
  local az,bz=clip(ray.z,ray.dz,entry.oy,entry.oy+th*8)
  if not ax or not az then return nil end
  startT=math.max(startT,ax,az); stopT=math.min(stopT,bx,bz)
  if stopT < startT then return nil end

  local horiz=math.sqrt(ray.dx*ray.dx+ray.dz*ray.dz)
  local dt = horiz > 1e-9 and (4/horiz) or (stopT-startT+1)
  if dt <= 0 then return nil end
  local seen, bestT, bestTX, bestTY = {}, nil, nil, nil
  local t=startT
  local guard=0
  while t <= stopT + 1e-6 and guard < 4096 do
    guard=guard+1
    local wx,wz=ray.x+ray.dx*t,ray.z+ray.dz*t
    local tx=math.floor((wx-entry.ox)/8)
    local ty=math.floor((wz-entry.oy)/8)
    if tx>=0 and ty>=0 and tx<tw and ty<th then
      local kk=tx..","..ty
      if not seen[kk] then
        seen[kk]=true
        local h=voxelTileHeight(scene,entry,tx,ty)
        if h and h>0 then
          local x0,z0=entry.ox+tx*8,entry.oy+ty*8
          local cx,cz=x0+4,z0+4
          local base=-voxelCurveDrop(scene.voxel3d,cx,cz)
          local hit=rayAabbT(ray,x0,base,z0,x0+8,base+h,z0+8,maxT)
          if hit and hit <= maxT and (not bestT or hit<bestT) then
            bestT,bestTX,bestTY=hit,tx,ty
          end
        end
      end
    end
    t=t+dt
  end
  if not bestT then return nil end
  local _, shape, S = voxelTileHeight(scene, entry, bestTX, bestTY)
  local k = voxelStructureKey(bestTX, bestTY)
  return {
    t=bestT, entry=entry, x=math.floor(bestTX/2), y=math.floor(bestTY/2),
    visualTX=bestTX, visualTY=bestTY,
    visualTile=S and S.tileAt and S.tileAt[k] or nil,
    visualClass=shape and shape.class or nil,
  }
end

local function voxelEntityHit(game, entries, ray, maxT, voxel3d)
  local ow=game and game.overworld
  local best
  local function one(entity, entry)
    if not entityIsInteractable(entity) then return end
    local cx=entity.targetX or entity.cellX
    local cy=entity.targetY or entity.cellY
    if type(cx)~="number" or type(cy)~="number" then return end
    local x0=entry.ox+cx*TILE_SIZE
    local z0=entry.oy+cy*TILE_SIZE
    local base=-voxelCurveDrop(voxel3d,x0+8,z0+8)
    local hit=rayAabbT(ray,x0,base,z0,x0+16,base+40,z0+16,maxT)
    if hit and (not best or hit<best.t) then
      best={t=hit,entry=entry,x=cx,y=cy}
    end
  end
  local active=entries and entries[1]
  if active then for _,e in ipairs((ow and ow.npcs) or {}) do one(e,active) end end
  for _,ghost in ipairs((ow and ow.ghosts) or {}) do
    for _,entry in ipairs(entries or {}) do
      if not entry.active and ghost.map and entry.map and ghost.map.id==entry.map.id then
        one(ghost.npc,entry); break
      end
    end
  end
  return best
end

local function voxelRayTargetFromTap(game, x, y, scene)
  local voxel3d=scene and scene.voxel3d
  if not (voxel3d and type(voxel3d.vp)=="table") then return nil end
  local free=overworldGate(game)
  if not free then return { error="busy" } end
  local cur=mod.world and mod.world:current()
  local overview=mod.world and mod.world:mapOverview()
  if not cur or not overview or cur.mapId~=overview.mapId then return { error="no_map" } end
  local ray=voxelRayFromPointer(x,y,voxel3d)
  if not ray then return nil end
  local tGround=rayGroundT(ray,voxel3d)
  if not tGround then return { error="outside_world", cur=cur, overview=overview } end
  local gx,gz=ray.x+ray.dx*tGround,ray.z+ray.dz*tGround
  local entries=voxelCandidateMaps(game,overview)

  local visible
  for _,entry in ipairs(entries) do
    local h=voxelStructureHit(scene,entry,ray,tGround)
    if h then h.kind = "structure" end
    if h and (not visible or h.t<visible.t) then visible=h end
  end
  local ent=voxelEntityHit(game,entries,ray,tGround,voxel3d)
  if ent then ent.kind = "entity" end
  if ent and (not visible or ent.t<visible.t) then visible=ent end

  local groundHit = voxelMapAtWorld(entries,gx,gz)

  -- Dramatic Shape already has a stronger answer than our 2D collision shell:
  -- Structures.forMap resolves every rendered 8x8 visual tile and classifies
  -- atlas-black/transparent interior darkness as shape.class == "void".
  -- Capture the EXACT ground visual tile under this ray before folding it back
  -- into Gen1's coarser 16x16 gameplay cell. A user can therefore tap the
  -- black tile they actually see and we can distinguish it from furniture or
  -- a wall that merely shares the same gameplay cell.
  local visualTile, visualClass, visualTX, visualTY
  if visible and visible.kind == "structure" then
    visualTile, visualClass = visible.visualTile, visible.visualClass
    visualTX, visualTY = visible.visualTX, visible.visualTY
  elseif groundHit and groundHit.entry then
    local e = groundHit.entry
    visualTX = math.floor((gx - e.ox) / 8)
    visualTY = math.floor((gz - e.oy) / 8)
    local S = voxelStructuresFor(scene, e)
    local k = voxelStructureKey(visualTX, visualTY)
    local shape = S and S.shapeAt and S.shapeAt[k] or nil
    visualTile = S and S.tileAt and S.tileAt[k] or nil
    visualClass = shape and shape.class or nil
  end
  local exactVoid = visible == nil and groundHit ~= nil
      and groundHit.entry and groundHit.entry.active
      and visualClass == "void"

  -- Keep the last exact Voxel pick visible in DEBUG OVERLAY. VOXEL/RAY are
  -- counters, not tile ids; this line is the authoritative per-tap tile/class.
  state.lastVoxelPick = {
    tile = visualTile, class = visualClass,
    tx = visualTX, ty = visualTY,
    cellX = groundHit and groundHit.x or nil,
    cellY = groundHit and groundHit.y or nil,
    exactVoid = exactVoid and true or false,
  }

  local outsideBehind = false
  if visible and visible.entry and visible.entry.active and not groundHit then
    local active = entries and entries[1]
    local map = active and active.map
    local w = map and (map.widthCells or (map.def and map.def.width and map.def.width * 2))
    local h = map and (map.heightCells or (map.def and map.def.height and map.def.height * 2))
    if active and w and h then
      local x0, z0 = active.ox, active.oy
      local x1, z1 = x0 + w * TILE_SIZE, z0 + h * TILE_SIZE
      local dx = gx < x0 and (x0 - gx) or (gx > x1 and (gx - x1) or 0)
      local dz = gz < z0 and (z0 - gz) or (gz > z1 and (gz - z1) or 0)
      outsideBehind = math.max(dx, dz) >= TILE_SIZE * 0.5
    end
  end

  local hit=visible or groundHit
  if not hit then
    state.stats.voxelRayOutside=state.stats.voxelRayOutside+1
    return { error="outside_world", cur=cur, overview=overview, ray=true }
  end
  state.stats.voxelTargets=state.stats.voxelTargets+1
  state.stats.voxelRayTargets=state.stats.voxelRayTargets+1
  if visible then state.stats.voxelColumnTargets=state.stats.voxelColumnTargets+1 end
  if hit.entry.active then
    return { x=hit.x,y=hit.y,cur=cur,overview=overview,
             outsideBehind = outsideBehind,
             visibleKind = visible and visible.kind or nil,
             visualTile = visualTile, visualClass = visualClass,
             visualTX = visualTX, visualTY = visualTY,
             exactVoid = exactVoid }
  end
  local wx=hit.entry.ox+(hit.x+0.5)*TILE_SIZE
  local wy=hit.entry.oy+(hit.y+0.5)*TILE_SIZE
  local cross,saw=visibleNeighborTarget(game,wx,wy,overview)
  if cross then
    cross.targetX,cross.targetY=hit.x,hit.y
    return { x=hit.x,y=hit.y,cur=cur,overview=overview,cross=cross }
  end
  return { error=saw and "connected_map" or "outside_map",cur=cur,overview=overview }
end

-- Hit-test the actual ground quads Dramatic Shape's current camera projects.
-- Grid intersections are projected once and shared by adjacent cells. Raised
-- semantic surfaces (actors, counters, walls, warps) may occlude a farther
-- ground quad, matching the renderer's depth-buffered presentation.
local function voxelTargetFromTap(game, x, y, voxel3d)
  local free = overworldGate(game)
  if not free then return nil, nil, nil, nil, "busy" end
  local cur = mod.world and mod.world:current()
  local overview = mod.world and mod.world:mapOverview()
  if not cur or not overview or cur.mapId ~= overview.mapId then
    return nil, nil, nil, nil, "no_map"
  end

  local px, py = framebufferPoint(x, y, voxel3d)
  local frame = state.frame or {}
  local dpiX, dpiY = tonumber(frame.dpiX) or 1, tonumber(frame.dpiY) or 1
  local snapRadius = VOXEL_COLUMN_SNAP_UNITS * math.max(1, (dpiX + dpiY) * 0.5)
  local snap2 = snapRadius * snapRadius
  local searchY = VOXEL_COLUMN_SEARCH_Y_UNITS * math.max(1, dpiY)

  local best, bestD2, bestDepth
  local columnCandidates = {}

  for _, entry in ipairs(voxelCandidateMaps(game, overview)) do
    local ov = entry.overview
    if ov and ov.width and ov.height then
      local points = {}
      for gy = 0, ov.height do
        local row = {}
        points[gy] = row
        for gx = 0, ov.width do
          row[gx] = projectedPoint(voxel3d,
            entry.ox + gx * TILE_SIZE,
            entry.oy + gy * TILE_SIZE)
        end
      end

      for cy = 0, ov.height - 1 do
        for cx = 0, ov.width - 1 do
          local a = points[cy][cx]
          local b = points[cy][cx + 1]
          local c = points[cy + 1][cx + 1]
          local d = points[cy + 1][cx]
          if a and b and c and d then
            local quad = { a, b, c, d }
            local mx = (a[1] + b[1] + c[1] + d[1]) * 0.25
            local my = (a[2] + b[2] + c[2] + d[2]) * 0.25
            local ddx, ddy = px - mx, py - my
            local d2 = ddx * ddx + ddy * ddy
            local depth = (tonumber(a[3]) or 0) + (tonumber(b[3]) or 0)
                        + (tonumber(c[3]) or 0) + (tonumber(d[3]) or 0)

            if pointInQuad(px, py, quad) then
              -- Exact projected top-down ground ownership always wins.
              if not best or d2 < bestD2
                  or (math.abs(d2 - bestD2) < 0.01 and depth > bestDepth) then
                best = { entry = entry, x = cx, y = cy, exact = true }
                bestD2, bestDepth = d2, depth
              end
            elseif math.abs(ddx) <= snapRadius * 2
                and math.abs(ddy) <= searchY then
              -- Voxel scenery is vertically extruded, while gameplay remains
              -- a 2D cell grid. Keep only screen-near semantic cells and, if
              -- no ground quad owns the tap, test the vertical screen segment
              -- rising from that cell. This makes NPC slabs, counters, doors,
              -- stairs and raised/tall scenery tappable without guessing at
              -- the renderer's private mesh topology or depth buffer.
              columnCandidates[#columnCandidates + 1] = {
                entry = entry, x = cx, y = cy,
                mx = mx, my = my, depth = depth, groundD2 = d2,
                strong = voxelStrongSemanticCell(game, entry, cx, cy),
              }
            end
          end
        end
      end
    end
  end

  if #columnCandidates > 0 then
    -- A depth-buffered 3D object can visually sit over a different cell's
    -- ground quad. Therefore exact ground ownership is not absolute: an
    -- actor/counter/wall/warp column may override it. Generic columns are
    -- considered only when no ground quad was hit, preventing invisible
    -- open-floor prisms from stealing ordinary walking taps.
    table.sort(columnCandidates, function(a, b)
      if a.strong ~= b.strong then return a.strong == true end
      return (a.groundD2 or math.huge) < (b.groundD2 or math.huge)
    end)
    local colBest, colD2, colDepth
    local limit = math.min(#columnCandidates, VOXEL_COLUMN_MAX_CANDIDATES)
    for i = 1, limit do
      local cand = columnCandidates[i]
      if not best or cand.strong then
        local wx = cand.entry.ox + (cand.x + 0.5) * TILE_SIZE
        local wy = cand.entry.oy + (cand.y + 0.5) * TILE_SIZE
        local mid = projectedPoint(voxel3d, wx, wy, VOXEL_COLUMN_MID_HEIGHT)
        local top = projectedPoint(voxel3d, wx, wy, VOXEL_COLUMN_HEIGHT)
        if mid and top then
          local d2a = pointSegmentDistance2(px, py,
            cand.mx, cand.my, mid[1], mid[2])
          local d2b = pointSegmentDistance2(px, py,
            mid[1], mid[2], top[1], top[2])
          local d2 = math.min(d2a, d2b)
          if d2 <= snap2 and (not colBest or d2 < colD2
              or (math.abs(d2 - colD2) < 0.01
                  and cand.depth > (colDepth or -math.huge))) then
            colBest, colD2, colDepth = cand, d2, cand.depth
          end
        end
      end
    end
    if colBest then
      local replacesGround = not best or colBest.strong
      if replacesGround then
        best = { entry = colBest.entry, x = colBest.x, y = colBest.y,
                 exact = false }
        state.stats.voxelColumnTargets = state.stats.voxelColumnTargets + 1
      end
    end
  end

  if not best then return nil, nil, cur, overview, "outside_world" end
  state.stats.voxelTargets = state.stats.voxelTargets + 1
  if best.entry.active then
    return best.x, best.y, cur, overview, nil, nil
  end

  -- Reuse the same direct-connection object the flat renderer path uses,
  -- feeding it the centre of the Voxel cell in the engine's common world
  -- coordinate space.
  local wx = best.entry.ox + (best.x + 0.5) * TILE_SIZE
  local wy = best.entry.oy + (best.y + 0.5) * TILE_SIZE
  local cross, saw = visibleNeighborTarget(game, wx, wy, overview)
  if cross then
    cross.targetX, cross.targetY = best.x, best.y
    return best.x, best.y, cur, overview, nil, cross
  end
  return nil, nil, cur, overview, saw and "connected_map" or "outside_map"
end

local function targetFromTap(game, x, y)
  local scene = voxelContext()
  if scene then
    local ray = voxelRayTargetFromTap(game, x, y, scene)
    if ray then
      if ray.error then
        return nil, nil, ray.cur, ray.overview, ray.error, nil, ray
      end
      return ray.x, ray.y, ray.cur, ray.overview, nil, ray.cross, ray
    end
    -- Older Dramatic Shape builds (or the very first frame before a VP has
    -- been established) retain the projection-based compatibility path.
    -- Once a live VP exists, the ray path above is authoritative.
    return voxelTargetFromTap(game, x, y, scene.voxel3d)
  end

  local view = state.view
  local free = overworldGate(game)
  if not view then return nil, nil, nil, nil, "no_view" end
  if not free then return nil, nil, nil, nil, "busy" end

  local cur = mod.world and mod.world:current()
  local overview = mod.world and mod.world:mapOverview()
  if not cur or not overview or cur.mapId ~= overview.mapId then
    return nil, nil, nil, nil, "no_map"
  end

  local tapPX, tapPY = x * view.dpiX, y * view.dpiY
  local right = view.ox + view.worldW * view.scale
  local bottom = view.oy + view.worldH * view.scale
  if tapPX < view.ox or tapPY < view.oy or tapPX >= right or tapPY >= bottom then
    -- Preserve the active map snapshot for higher-level intent resolution:
    -- an enclosed interior can interpret black/letterbox space as "exit".
    return nil, nil, cur, overview, "outside_world"
  end

  local canvasX = (tapPX - view.ox) / view.scale
  local canvasY = (tapPY - view.oy) / view.scale
  local ppx, ppy = playerPixel(game, cur)
  local ow = game and game.overworld
  -- Prefer the live camera when available: it is exactly what rendered the
  -- neighbour rectangles and also includes temporary camera pans.  The public
  -- player-follow formula remains a compatibility fallback.
  local cameraX = ow and ow.camera and tonumber(ow.camera.x)
    or (ppx - (view.worldW / 2 - 16))
  local cameraY = ow and ow.camera and tonumber(ow.camera.y)
    or (ppy - (view.worldH / 2 - 8))
  local worldX = cameraX + canvasX
  local worldY = cameraY + canvasY
  local tx = math.floor(worldX / TILE_SIZE)
  local ty = math.floor(worldY / TILE_SIZE)

  if tx < 0 or ty < 0 or tx >= overview.width or ty >= overview.height then
    local cross, sawNeighbour = visibleNeighborTarget(game, worldX, worldY, overview)
    if cross then
      return cross.targetX, cross.targetY, cur, overview, nil, cross
    end
    -- Survey can show maps more than one connection away.  Recognize that the
    -- tap really hit rendered world, but refuse it until every intervening seam
    -- can be validated rather than treating it as an arbitrary border tap.
    return nil, nil, cur, overview, sawNeighbour and "connected_map" or "outside_map"
  end

  return tx, ty, cur, overview, nil, nil
end

local function newNavigation(cur)
  return {
    mapId = cur.mapId,
    targetX = nil,
    targetY = nil,
    path = nil,
    index = 1,
    blockedEdges = {},
    blockedCells = {},
    tempBlocked = {},
    lastX = cur.x,
    lastY = cur.y,
    lastProgressTick = state.tick,
    phase = "PLANNING",
    createdTick = state.tick,
  }
end

local function deferUntilCurrentStepLands(game, nav)
  local player = game and game.overworld and game.overworld.player
  if not player or player.moving ~= true then return false end
  if type(player.targetX) ~= "number" or type(player.targetY) ~= "number" then
    return false
  end
  nav.pendingStartX, nav.pendingStartY = player.targetX, player.targetY
  releaseHold(nav)
  setPhase(nav, "WAITING_PLAYER_STEP", "tap_during_existing_step")
  return true
end

-- When the pointer is intentionally aimed outside an enclosed map, interpret
-- that as "leave this area" instead of requiring the player to hit a tiny
-- doorway tile.  Public mapOverview warp markers are the primary source; the
-- '+' terrain scan is a compatibility fallback for stale/older overviews.
-- Only maps with no seamless map connections opt into this affordance: on an
-- outdoor/connected map, off-map taps remain ordinary invalid targets rather
-- than silently choosing an unrelated door/ladder warp.
local function listHas(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then return true end
  end
  return false
end

-- Mirror the engine's Warp.extraCheck direction rules without taking control
-- away from the engine itself. We only choose which D-pad direction to hold;
-- Warp.onEdge / Warp.onCollision remains the authority on whether the warp
-- actually fires.
local function warpActivationDirections(game, map, x, y)
  if not map then return {} end
  local dirs = {}
  local carpets = game and game.data and game.data.field
      and game.data.field.warpCarpets
  local useCarpet = false
  if carpets then
    if listHas(carpets.edgeMaps, map.id) then
      useCarpet = false
    elseif listHas(carpets.function2Maps, map.id) then
      useCarpet = true
    else
      useCarpet = listHas(carpets.function2Tilesets,
                          map.def and map.def.tileset)
    end
  end

  local function facingEdge(dir)
    return (dir == "up" and y == 0)
        or (dir == "down" and y == map.heightCells - 1)
        or (dir == "left" and x == 0)
        or (dir == "right" and x == map.widthCells - 1)
  end

  for _, d in ipairs(DIRS) do
    local dir = d.name
    local ok = false
    if not useCarpet then
      ok = facingEdge(dir)
    else
      local tx, ty = x + d.dx, y + d.dy
      local front
      if type(map.cellTile) == "function" then
        local worked, value = pcall(map.cellTile, map, tx, ty)
        if worked then front = value end
      end
      local ss = carpets and carpets.ssAnneBow
      if ss and map.id == ss.map then
        ok = front == ss.tile
      else
        ok = listHas(carpets and carpets.tiles and carpets.tiles[dir], front)
      end
    end
    if ok then dirs[#dirs + 1] = dir end
  end
  return dirs
end

local function warpExitRank(game, warpDef)
  if not warpDef then return 2 end
  if warpDef.destMap == "LAST_MAP" then return 0 end
  local dest = game and game.data and game.data.maps
      and game.data.maps[warpDef.destMap]
  if dest and (dest.outdoor == true or dest.tileset == "OVERWORLD"
      or dest.tileset == "PLATEAU") then
    return 0
  end
  return 1
end

local function defLooksOutdoor(def)
  if type(def) ~= "table" then return false end
  if def.outdoor ~= nil then return def.outdoor == true end
  return def.tileset == "OVERWORLD" or def.tileset == "PLATEAU"
end

-- Cheap map-graph distance to the outside. This is deliberately topological:
-- the CURRENT map leg still uses real A* walking cost, while unloaded floors
-- contribute only the number of transitions required to reach LAST_MAP or an
-- outdoor map. That is enough to choose the correct staircase/door through a
-- multi-floor interior without loading or pathfinding every remote floor.
local function mapExitHopDistance(game, startMapId)
  if not startMapId or startMapId == "LAST_MAP" then return 0 end
  local maps = game and game.data and game.data.maps
  local start = maps and maps[startMapId]
  if not start then return nil end
  if defLooksOutdoor(start) then return 0 end

  local queue = { { id = startMapId, d = 0 } }
  local head, seen = 1, { [startMapId] = true }
  while head <= #queue do
    local node = queue[head]; head = head + 1
    if node.d < 24 then
      local def = maps[node.id]
      if def then
        local nextIds = {}
        for _, w in ipairs(def.warps or {}) do
          local dest = w.destMap
          if dest == "LAST_MAP" then return node.d + 1 end
          if type(dest) == "string" and dest ~= "" then nextIds[#nextIds+1] = dest end
        end
        for _, conn in pairs(def.connections or {}) do
          local dest = conn and conn.map
          if type(dest) == "string" and dest ~= "" then nextIds[#nextIds+1] = dest end
        end
        for _, dest in ipairs(nextIds) do
          local ddef = maps[dest]
          if ddef and defLooksOutdoor(ddef) then return node.d + 1 end
          if ddef and not seen[dest] then
            seen[dest] = true
            queue[#queue+1] = { id = dest, d = node.d + 1 }
          end
        end
      end
    end
  end
  return nil
end

local function warpExitHops(game, warpDef)
  if not warpDef then return nil end
  local dest = warpDef.destMap
  if dest == "LAST_MAP" then return 1 end
  local maps = game and game.data and game.data.maps
  local ddef = maps and maps[dest]
  if ddef and defLooksOutdoor(ddef) then return 1 end
  local tail = mapExitHopDistance(game, dest)
  return tail and (tail + 1) or nil
end

local function mapTransitionExitHops(game, destMapId)
  local maps = game and game.data and game.data.maps
  local ddef = maps and maps[destMapId]
  if ddef and defLooksOutdoor(ddef) then return 1 end
  local tail = mapExitHopDistance(game, destMapId)
  return tail and (tail + 1) or nil
end

local function actualWarpCells(map)
  local out, seen = {}, {}
  for i, w in ipairs((map and map.def and map.def.warps) or {}) do
    local x, y = tonumber(w.x), tonumber(w.y)
    if x and y then
      x, y = math.floor(x), math.floor(y)
      local k = key(x, y)
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = { x=x, y=y, def=w, index=i }
      end
    end
  end
  return out
end

local function warpIntentAt(game, map, cur, x, y)
  for _, w in ipairs(actualWarpCells(map)) do
    if w.x == x and w.y == y then
      local dirs = warpActivationDirections(game, map, x, y)
      local warpTile = false
      if type(map.isWarpTileCell) == "function" then
        local ok, yes = pcall(map.isWarpTileCell, map, x, y)
        warpTile = ok and yes == true
      end
      -- A DOWN-activated exit mat/carpet is deterministic user intent.  Even
      -- if the visual/collision tile also reports as an arrival warp, keep a
      -- follow-up DOWN armed as a safety net: a real arrival warp will change
      -- maps before we can send it, while a carpet/edge mat that needs an
      -- extra press will receive exactly the missing activation step.
      local exitDir = listHas(dirs, "down") and "down" or nil
      if not exitDir and (not warpTile or (cur and cur.x == x and cur.y == y)) then
        exitDir = dirs[1]
      end
      return {
        kind = "warp", x=x, y=y, def=w.def, warpDef=w.def,
        rank = warpExitRank(game, w.def), exitDir=exitDir,
        carpetDown = exitDir == "down",
      }
    end
  end
  return nil
end

-- Deterministic rescue path for Gen I exit carpets/mats.  There are two
-- representations in the engine data:
--   1) the clicked gameplay cell itself is the warp record and DOWN activates
--      it (common bottom-edge exit mats), or
--   2) the clicked visual/gameplay carpet cell is one cell IN FRONT of the
--      warp record; standing on that source and pressing DOWN triggers
--      Warp.extraCheck for warpCarpets/function2 tilesets.
--
-- Return the actual warp SOURCE cell plus a forced DOWN.  This deliberately
-- uses the same warpActivationDirections mirror as the rest of Tap to Move,
-- so it is keyed to Gen1Recomp's gameplay semantics rather than a fragile
-- tileset-local art number.
function ControlsFree.carpetDownIntentAt(game, map, cur, x, y)
  if not map or type(x) ~= "number" or type(y) ~= "number" then return nil end

  local direct = warpIntentAt(game, map, cur, x, y)
  if direct and direct.exitDir == "down" then
    direct.carpetDown = true
    direct.clickedCarpetX, direct.clickedCarpetY = x, y
    return direct
  end

  -- In function2 carpet maps the graphic the player points at can be the
  -- FRONT cell, while the warp record lives immediately north of it.  Ask the
  -- engine-mirrored direction test on that source; if DOWN is valid, this is
  -- exactly the carpet semantics we want.
  local sx, sy = x, y - 1
  for _, w in ipairs(actualWarpCells(map)) do
    if w.x == sx and w.y == sy then
      local dirs = warpActivationDirections(game, map, sx, sy)
      if listHas(dirs, "down") then
        return {
          kind = "warp", x = sx, y = sy, def = w.def, warpDef = w.def,
          rank = warpExitRank(game, w.def), exitDir = "down",
          carpetDown = true, clickedCarpetX = x, clickedCarpetY = y,
          carpetFrontCell = true,
        }
      end
    end
  end
  return nil
end

local function directConnectionExitIntents(game, overview, cur)
  local ow = game and game.overworld
  local current = ow and ow.map
  local out = {}
  if not current or not current.def or not current.def.connections then
    return out
  end

  local all, dynamic, static = liveOccupancy(game)
  local waterMode = currentWaterMode(game, overview, cur)
  local sourceTopology = ledgeTopology(game, current, overview)
  local warpKeys = {}
  for _, w in ipairs(actualWarpCells(current)) do warpKeys[key(w.x,w.y)] = true end

  local function scanConnection(compass, conn, occupancy, dynamicOnly)
    local destMap, nb = loadedNeighborMap(game, conn.map)
    local destOverview = overviewFromLoadedMap(destMap)
    local dir = COMPASS_TO_DIR[compass]
    if not destMap or not destOverview or not dir then return false end

    local crossBase = {
      sourceMapId = overview.mapId, destMapId = destMap.id,
      dir = dir, compass = compass, conn = conn,
      destOverview = destOverview, destMap = destMap,
      renderOx = nb and nb.ox, renderOy = nb and nb.oy,
    }

    local best = nil
    local function consider(sourceX, sourceY, entryX, entryY, cost, ledge)
      local lch = cellChar(destOverview, entryX, entryY)
      if lch ~= "." and not (lch == "~" and waterMode) then return end
      local path = findPath(overview, cur.x, cur.y, sourceX, sourceY, waterMode,
        occupancy, nil, sourceTopology.blockedEdges, nil, sourceTopology.jumps)
      if not path then return end
      local score = #path + (cost or 1)
      if not best or score < best.cost then
        local cross = copyFlat(crossBase)
        cross.targetX, cross.targetY = entryX, entryY
        if ledge then
          cross.exitLedge = true
          cross.exitLedgeMidX, cross.exitLedgeMidY = ledge.midX, ledge.midY
        end
        best = {
          kind = "connection", cross = cross,
          x = entryX, y = entryY, cost = score, rank = 0,
          exitHops = mapTransitionExitHops(game, cross.destMapId),
          dynamic = dynamicOnly,
        }
      end
    end

    -- Ordinary seamless seam: path to one source-edge cell, then one D-pad
    -- step out.  Skip any source cell that is itself an actual warp record,
    -- including plain-floor carpets not visible as '+' in mapOverview.
    for _, src in ipairs(seamSourceCells(crossBase, overview)) do
      local sch = cellChar(overview, src.x, src.y)
      if sch and sch ~= "+" and not warpKeys[key(src.x,src.y)] then
        local lx, ly = seamLanding(crossBase, src.x, src.y)
        consider(src.x, src.y, lx, ly, 1)
      end
    end

    -- A ledge may consume the boundary tile as the midpoint and land in the
    -- neighbour on its second forced cell.  Treat it as another exit seam.
    for _, jump in ipairs(sourceTopology.seamJumps or {}) do
      if jump.dir == dir and not warpKeys[key(jump.sourceX,jump.sourceY)] then
        local lx, ly = seamLanding(crossBase, jump.midX, jump.midY)
        consider(jump.sourceX, jump.sourceY, lx, ly, jump.cost or 2, jump)
      end
    end

    if best then
      out[#out + 1] = best
      return true
    end
    return false
  end

  for _, compass in ipairs({ "north", "south", "west", "east" }) do
    local conn = current.def.connections[compass]
    if conn and conn.map then
      local immediate = scanConnection(compass, conn, all, false)
      if not immediate then
        scanConnection(compass, conn, static, true)
      end
    end
  end
  return out
end

-- When the pointer is aimed at space that belongs to neither the current map
-- nor a rendered direct neighbour, interpret it as "leave this area". This
-- deliberately uses ACTUAL warp records (map.def.warps), not only the visual
-- '+' cells from mapOverview: Gen I interior exit carpets are warp records on
-- ordinary-looking floor cells and only fire when the player then walks off
-- the edge / into the carpet direction.
local function nearestExitTarget(game, overview, cur)
  local ow = game and game.overworld
  local map = ow and ow.map
  if not map or not overview or not cur then return nil end

  local candidates = {}
  local warps = actualWarpCells(map)
  local all, dynamic, static = liveOccupancy(game)
  local waterMode = currentWaterMode(game, overview, cur)
  local topology = ledgeTopology(game, map, overview)

  local warpKeys = {}
  for _, w in ipairs(warps) do warpKeys[key(w.x,w.y)] = true end

  local function pathToWarp(dst, occupied, dynamicOnly)
    if dst.x < 0 or dst.y < 0
        or dst.x >= overview.width or dst.y >= overview.height then
      return
    end
    local blocked = {}
    -- A real warp record may live on a plain '.' carpet cell, which means the
    -- compact overview would otherwise allow A* to use it as an intermediate
    -- node and accidentally leave through the wrong exit. Block every OTHER
    -- warp record while scoring this one.
    for k in pairs(warpKeys) do
      if k ~= key(dst.x,dst.y) then blocked[k] = true end
    end
    local dirs = warpActivationDirections(game, map, dst.x, dst.y)
    -- Only directional warp sources (edge/carpet semantics) may need the
    -- special non-walkable endpoint exception. Ordinary arrival warps must
    -- remain reachable through their normal terrain legality.
    local path = findPath(overview, cur.x, cur.y, dst.x, dst.y, waterMode,
      occupied, nil, topology.blockedEdges, blocked, topology.jumps, #dirs > 0)
    if not path then return end
    local warpTile = false
    if type(map.isWarpTileCell) == "function" then
      local ok, yes = pcall(map.isWarpTileCell, map, dst.x, dst.y)
      warpTile = ok and yes == true
    end
    -- DOWN-activated carpet/mat exits always keep the extra DOWN as a
    -- deterministic safety step. If arrival itself warps, the map transition
    -- retires navigation before this can fire; if it does not, the press is
    -- exactly what the engine's edge/carpet rule requires.
    local exitDir = listHas(dirs, "down") and "down" or nil
    -- Other plain-floor exit carpets still need their normal follow-up
    -- direction. A regular warp tile normally fires on arrival, except when
    -- we already start on it (for example after loading in a doorway).
    if not exitDir and (not warpTile or (cur.x == dst.x and cur.y == dst.y)) then
      exitDir = dirs[1]
    end

    candidates[#candidates + 1] = {
      kind = "warp", x = dst.x, y = dst.y,
      cost = #path, rank = warpExitRank(game, dst.def),
      exitHops = warpExitHops(game, dst.def),
      dynamic = dynamicOnly,
      exitDir = exitDir,
      carpetDown = exitDir == "down",
      warpDef = dst.def,
    }
  end

  for _, dst in ipairs(warps) do pathToWarp(dst, all, false) end

  local hasImmediateWarp = false
  for _, c in ipairs(candidates) do
    if c.kind == "warp" and not c.dynamic then
      hasImmediateWarp = true
      break
    end
  end
  if not hasImmediateWarp then
    for _, dst in ipairs(warps) do pathToWarp(dst, static, true) end
  end

  for _, c in ipairs(directConnectionExitIntents(game, overview, cur)) do
    candidates[#candidates + 1] = c
  end

  if #candidates == 0 then return nil end
  table.sort(candidates, function(a,b)
    local ah, bh = a.exitHops or 999999, b.exitHops or 999999
    if ah ~= bh then return ah < bh end
    if (a.rank or 9) ~= (b.rank or 9) then
      return (a.rank or 9) < (b.rank or 9)
    end
    if (a.cost or 999999) ~= (b.cost or 999999) then
      return (a.cost or 999999) < (b.cost or 999999)
    end
    if (a.y or 0) ~= (b.y or 0) then return (a.y or 0) < (b.y or 0) end
    return (a.x or 0) < (b.x or 0)
  end)
  return candidates[1]
end

local function routeFeedback(showFeedback, kind, x, y)
  if showFeedback then setPulse(kind, x, y) end
end

local function retireForRetarget(oldNav, continuous)
  if not oldNav then return end
  releaseHold(oldNav)
  markStop(continuous and "hold_retargeted" or "retargeted", oldNav)
end

local function startRoute(game, screenX, screenY, continuous, showFeedback, gestureId)
  if option("enabled", true) == false then return false end
  if showFeedback == nil then showFeedback = not continuous end

  -- The live pointer owns small semantic memory for Hold-to-Steer. A door/NPC
  -- is a deliberate object selection, while a wall sample one refresh later is
  -- often just camera motion moving that same screen point across geometry.
  local gesture = pointerForGesture and pointerForGesture(gestureId) or nil
  local function clearStickySemantic()
    if gesture then gesture.stickySemantic = nil end
  end
  local function setStickySemantic(kind, mapId, x, y, entityId)
    if gesture then
      gesture.stickySemantic = {
        kind = kind, mapId = mapId, x = x, y = y, entityId = entityId,
      }
    end
  end
  local function retainStickySemantic()
    if not (continuous and gesture and gesture.stickySemantic and state.nav) then
      return false
    end
    state.stats.retainedTargets = state.stats.retainedTargets + 1
    state.stats.stickySemanticRetains = state.stats.stickySemanticRetains + 1
    return true
  end

  -- A genuinely new pointer press supersedes a previous automatic
  -- multi-floor exit journey. Hold-to-Steer refreshes never reach here while
  -- an exit journey owns navigation, so only a fresh user intent cancels it.
  if gestureId ~= nil and state.exitJourney then state.exitJourney = nil end

  -- A fresh pointer intent supersedes any destination that was waiting to
  -- resume after a wild encounter. The CURRENT route is not retired until its
  -- replacement has a valid plan.
  state.battleResume = nil

  local tx, ty, cur, overview, targetErr, cross, targetMeta =
    targetFromTap(game, screenX, screenY)

  -- The player's sprite can visually cover the interaction surface directly in
  -- front of them (most noticeably when standing one step below a door/sign/PC
  -- or directly against an NPC). A short tap on the visible avatar therefore
  -- acts as a proxy for that FRONT cell, but only when the front cell actually
  -- has interaction/door semantics. Ordinary taps on the player do not become
  -- an implicit one-step walk. HOLD PLAYER SPRITE is unaffected because its
  -- stationary candidate is not routed until release, and a fired START marks
  -- the gesture suppressed before this path can run.
  if option("interact", true) ~= false and not continuous and gestureId ~= nil
      and ControlsFree.playerScreenHit and cur and overview then
    local gp = pointerForGesture and pointerForGesture(gestureId) or nil
    local sx, sy = gp and gp.startX or screenX, gp and gp.startY or screenY
    local pdx, pdy = screenX - sx, screenY - sy
    if pdx * pdx + pdy * pdy <= PLAYER_HOLD_MOVE_SLOP_UNITS * PLAYER_HOLD_MOVE_SLOP_UNITS
        and ControlsFree.playerScreenHit(game, sx, sy) then
      local player = game and game.overworld and game.overworld.player
      local dir = player and DIR_BY_NAME[player.facing] or nil
      if dir then
        local fx, fy = cur.x + dir.dx, cur.y + dir.dy
        local frontInteraction = interactionAt(game, fx, fy)
        local frontWarp = warpIntentAt(
          game, game and game.overworld and game.overworld.map, cur, fx, fy)
        local frontChar = cellChar(overview, fx, fy)
        if frontInteraction or frontWarp or frontChar == "+" then
          tx, ty, targetErr, cross = fx, fy, nil, nil
          targetMeta = targetMeta or {}
          targetMeta.playerAvatarProxy = true
          state.stats.playerAvatarInteractionProxies =
            (state.stats.playerAvatarInteractionProxies or 0) + 1
        end
      end
    end
  end
  local exitFallback = false
  local exitIntent = nil
  local nearestFallback = false
  local semanticKind, semanticEntityId

  -- v1.3.11 deterministic carpet rescue: before any "blank space" or Voxel
  -- heuristic can reinterpret the tap, ask the actual warp data whether the
  -- selected cell is a DOWN-activated exit mat/carpet.  Also accept the
  -- function2 representation where the clicked carpet graphic is the cell
  -- directly SOUTH of the warp record.  Route to the real source cell and
  -- remember the forced DOWN for the arrival phase.
  if tx and not cross and cur and overview and ControlsFree.carpetDownIntentAt then
    local map = game and game.overworld and game.overworld.map
    local carpetIntent = ControlsFree.carpetDownIntentAt(game, map, cur, tx, ty)
    if carpetIntent then
      targetMeta = targetMeta or {}
      targetMeta.carpetDownIntent = carpetIntent
      targetMeta.carpetClickedX, targetMeta.carpetClickedY = tx, ty
      tx, ty = carpetIntent.x, carpetIntent.y
      state.stats.carpetDownIntents = (state.stats.carpetDownIntents or 0) + 1
    end
  end

  -- In Voxel mode an exterior wall can be the first depth hit even though the
  -- ray's ground point is clearly beyond the current interior.
  if tx and targetMeta and targetMeta.outsideBehind
      and targetMeta.visibleKind == "structure" and cur and overview then
    local currentDef = game and game.overworld and game.overworld.map
        and game.overworld.map.def
    -- `outsideBehind` is already the strong geometric test: the visible hit
    -- belongs to the active map, but the SAME camera ray reaches the ground
    -- at least half a gameplay cell beyond every rendered current/neighbour
    -- map body. Do not additionally require mapOverview to call the hit cell
    -- blocked. Dramatic Shape works at 8x8 visual-tile granularity and can
    -- legitimately extrude an exterior wall over a 16x16 gameplay cell that
    -- mapOverview represents as ordinary `.` floor. That extra 2D filter was
    -- the v1.0.0 regression that turned a clear "tap outside this room" into
    -- nearest-legal movement toward the wall instead of Smart Exit.
    if not defLooksOutdoor(currentDef) then
      tx, ty, cross, targetErr = nil, nil, nil, "outside_map"
    end
  end

  -- v1.3.10: exact Voxel visual-tile semantics beat geometry guesses.
  -- Dramatic Shape itself labels completely black/transparent tiles as
  -- `void`. When the ray actually lands on one of those exact 8x8 tiles in
  -- a normal room-style building, interpret that visible black tile as EXIT
  -- intent. Do NOT hardcode a raw tile number: ids are tileset-local, while
  -- the resolved `void` class is stable across HOUSE/MART/CENTER/etc.
  -- Interaction/warp semantics on the owning gameplay cell still win.
  if tx and not cross and cur and overview and targetMeta
      and targetMeta.exactVoid == true then
    local map = game and game.overworld and game.overworld.map
    local def = map and map.def
    if ControlsFree.mapDefIsBuildingInterior
        and ControlsFree.mapDefIsBuildingInterior(def) then
      local exactInteraction = option("interact", true) ~= false
        and interactionAt(game, tx, ty) or nil
      local exactWarp = warpIntentAt(game, map, cur, tx, ty)
      if not exactInteraction and not exactWarp then
        tx, ty, cross, targetErr = nil, nil, nil, "outside_map"
        state.stats.voxelExactVoidExitIntents =
          (state.stats.voxelExactVoidExitIntents or 0) + 1
      end
    end
  end

  -- Small room-style interiors often contain a large collision-solid shell
  -- around the actually usable room. Visually this is just blank/empty space,
  -- but the tap still resolves INSIDE the map rectangle, so the old Smart Exit
  -- gate never saw outside_map and instead treated the blank shell as a generic
  -- obstacle (nearest-legal movement). Reclassify only boundary-connected
  -- blank cells as outside intent. Fixed interactions, NPCs and real warp cells
  -- keep priority, so a wall-mounted sign/PC/door cannot be stolen by this
  -- convenience path. This is deliberately room-building-only; caves, gates
  -- and technical indoor map segments keep their existing solid-tile behavior.
  if tx and not cross and cur and overview and ControlsFree.exteriorVoidCell
      and ControlsFree.exteriorVoidCell(game, overview, tx, ty) then
    local shellInteraction = option("interact", true) ~= false
      and interactionAt(game, tx, ty) or nil
    local shellWarp = warpIntentAt(
      game, game and game.overworld and game.overworld.map, cur, tx, ty)
    if not shellInteraction and not shellWarp then
      tx, ty, cross, targetErr = nil, nil, nil, "outside_map"
      targetMeta = targetMeta or {}
      targetMeta.exteriorVoid = true
      state.stats.exteriorVoidExitIntents =
        (state.stats.exteriorVoidExitIntents or 0) + 1
    end
  end

  -- Once this gesture has deliberately selected a door/NPC, an immediately
  -- following invalid sample does NOT steal the route. A genuinely walkable
  -- target (or another semantic target) will replace it below.
  if not tx and retainStickySemantic() then return true end

  if not tx and cur and overview
      and (targetErr == "outside_world" or targetErr == "outside_map") then
    exitIntent = nearestExitTarget(game, overview, cur)
    if exitIntent then
      exitFallback = true
      targetErr = nil
      if exitIntent.kind == "connection" then
        cross = exitIntent.cross
        tx, ty = exitIntent.x, exitIntent.y
      else
        tx, ty, cross = exitIntent.x, exitIntent.y, nil
      end
    end
  end

  if not tx then
    state.stats.invalidTaps = state.stats.invalidTaps + 1
    if continuous and state.nav then
      state.stats.retainedTargets = state.stats.retainedTargets + 1
    end
    if targetErr == "connected_map" or targetErr == "busy"
        or targetErr == "outside_world" or targetErr == "outside_map" then
      routeFeedback(showFeedback, "invalid", screenX, screenY)
    end
    return false
  end

  local requestedMapId = cross and cross.destMapId or (cur and cur.mapId)
  if continuous and state.nav
      and state.nav.goalKind ~= "move_nearest"
      and state.nav.requestedMapId == requestedMapId
      and state.nav.requestedX == tx and state.nav.requestedY == ty then
    return true
  end

  local oldNav = state.nav
  local candidate, buildStatus, buildWhy

  if cross then
    local rawTx, rawTy = tx, ty
    local rawInteraction = option("interact", true) ~= false
      and neighbourInteractionAt(game, cross, tx, ty) or nil
    local crossInteraction = rawInteraction
      and ((not continuous) or rawInteraction.kind == "entity")
      and rawInteraction or nil

    if crossInteraction and crossInteraction.kind == "entity" then
      semanticKind, semanticEntityId = "npc", crossInteraction.entityId
    end

    local targetChar = cellChar(cross.destOverview, tx, ty)
    local waterMode = currentWaterMode(game, overview, cur)
    local legalMovement = targetChar == "."
      or (targetChar == "~" and waterMode)
    local crossWarpIntent = warpIntentAt(game, cross.destMap, nil, tx, ty)
    if crossWarpIntent or targetChar == "+" then semanticKind = "door" end

    if legalMovement and not crossInteraction then clearStickySemantic() end

    local needsNearestCross = (targetChar ~= "." and targetChar ~= "+"
        and not (targetChar == "~" and waterMode) and not crossInteraction)
      or (continuous and rawInteraction ~= nil and not crossInteraction)

    if needsNearestCross then
      if retainStickySemantic() then return true end
      local nx, ny = nearestReachableCrossTarget(
        game, cur, cross, rawTx, rawTy,
        continuous and rawInteraction ~= nil)
      if not nx then
        state.stats.invalidTaps = state.stats.invalidTaps + 1
        if continuous and oldNav then
          state.stats.retainedTargets = state.stats.retainedTargets + 1
        elseif oldNav then
          cancelRoute("retargeted")
        end
        routeFeedback(showFeedback, "invalid", screenX, screenY)
        return false
      end
      cross = copyFlat(cross)
      cross.targetX, cross.targetY = nx, ny
      nearestFallback = true
      crossInteraction = nil
    end

    candidate = newNavigation(cur)
    candidate.goalKind = crossInteraction and "cross_interact"
      or (exitFallback and "exit_connection"
      or (nearestFallback and "cross_nearest" or "cross_move"))
    candidate.cross = cross
    if exitFallback then
      candidate.exitIntent = exitIntent
      candidate.exitJourney = not defLooksOutdoor(game and game.overworld
        and game.overworld.map and game.overworld.map.def)
    end
    candidate.crossInteraction = crossInteraction
    if crossInteraction and gestureId ~= nil then
      candidate.interactionGestureId = gestureId
      candidate.interactionRequiresRelease = true
    end
    candidate.requestedMapId = cross.destMapId
    candidate.requestedX, candidate.requestedY = rawTx, rawTy
    buildStatus, buildWhy = rebuildNavigation(game, candidate, cur)

    -- Even an apparently legal neighbour tile can be disconnected from every
    -- usable seam. Fall back toward the requested point rather than making the
    -- held input disappear.
    if not buildStatus and buildWhy ~= "dynamic"
        and not crossInteraction and semanticKind ~= "door" then
      local nx, ny = nearestReachableCrossTarget(game, cur, cross, rawTx, rawTy, false)
      if nx and (nx ~= cross.targetX or ny ~= cross.targetY) then
        cross = copyFlat(cross)
        cross.targetX, cross.targetY = nx, ny
        candidate = newNavigation(cur)
        candidate.goalKind = "cross_nearest"
        candidate.cross = cross
        candidate.requestedMapId = cross.destMapId
        candidate.requestedX, candidate.requestedY = rawTx, rawTy
        buildStatus, buildWhy = rebuildNavigation(game, candidate, cur)
        nearestFallback = buildStatus and true or nearestFallback
      end
    end
  else
    local rawInteraction = option("interact", true) ~= false
      and interactionAt(game, tx, ty) or nil
    local interaction = rawInteraction
      and ((not continuous) or rawInteraction.kind == "entity")
      and rawInteraction or nil

    if interaction and interaction.kind == "entity" then
      semanticKind, semanticEntityId = "npc", interaction.entityId
      candidate = newNavigation(cur)
      candidate.interaction = interaction
      candidate.goalKind = "interact"
      if gestureId ~= nil then
        candidate.interactionGestureId = gestureId
        candidate.interactionRequiresRelease = true
      end
      candidate.requestedMapId = cur.mapId
      candidate.requestedX, candidate.requestedY = tx, ty
      buildStatus, buildWhy = rebuildNavigation(game, candidate, cur)
    elseif interaction then
      -- Non-hold Tap-to-Interact keeps all fixed interaction surfaces.
      candidate = newNavigation(cur)
      candidate.interaction = interaction
      candidate.goalKind = "interact"
      if gestureId ~= nil then
        candidate.interactionGestureId = gestureId
        candidate.interactionRequiresRelease = true
      end
      candidate.requestedMapId = cur.mapId
      candidate.requestedX, candidate.requestedY = tx, ty
      buildStatus, buildWhy = rebuildNavigation(game, candidate, cur)
    else
      local ch = cellChar(overview, tx, ty)
      local waterMode = currentWaterMode(game, overview, cur)
      local directWarpIntent = targetMeta and targetMeta.carpetDownIntent
        or warpIntentAt(
          game, game and game.overworld and game.overworld.map, cur, tx, ty)
      local activeExitIntent = exitIntent or directWarpIntent
      local legalMovement = ch == "." or (ch == "~" and waterMode)
      local doorSelection = activeExitIntent ~= nil or ch == "+"

      if doorSelection then
        semanticKind = "door"
      elseif legalMovement and not rawInteraction then
        clearStickySemantic()
      end

      -- Fixed interaction surfaces during a HOLD are movement targets only:
      -- approach their nearest legal floor, never fire A. Generic solid
      -- geometry gets the same nearest-reachable behavior.
      local needsNearest = ((not legalMovement and ch ~= "+")
          and activeExitIntent == nil)
        or (continuous and rawInteraction ~= nil)

      if needsNearest then
        if retainStickySemantic() then return true end
        candidate = newNavigation(cur)
        candidate.goalKind = "move_nearest"
        candidate.requestedMapId = cur.mapId
        candidate.requestedX, candidate.requestedY = tx, ty
        -- A fixed interaction surface may live on a terrain cell that the
        -- compact overview calls walkable. During Hold-to-Steer it is still
        -- an OBJECT target, so do not let nearest-legal fallback choose the
        -- surface itself; stop beside it instead.
        if continuous and rawInteraction ~= nil then
          candidate.blockedCells[key(tx, ty)] = true
        end
        buildStatus, buildWhy = buildNearestLegalPath(game, candidate, cur, tx, ty)
        nearestFallback = buildStatus and true or false
      else
        candidate = newNavigation(cur)
        candidate.goalKind = activeExitIntent and "exit" or "move"
        candidate.targetX, candidate.targetY = tx, ty
        if activeExitIntent then
          candidate.exitIntent = activeExitIntent
          candidate.exitDir = activeExitIntent.exitDir
          candidate.exitJourney = exitFallback and not defLooksOutdoor(game and game.overworld
            and game.overworld.map and game.overworld.map.def) or false
        end
        candidate.requestedMapId = cur.mapId
        candidate.requestedX, candidate.requestedY = tx, ty
        buildStatus, buildWhy = rebuildNavigation(game, candidate, cur)

        -- A cell can look walkable yet be statically disconnected from the
        -- player. Do not revert to the previous route: move as close as the
        -- legal graph allows toward the newly selected position.
        if not buildStatus and buildWhy ~= "dynamic"
            and not activeExitIntent and legalMovement then
          candidate = newNavigation(cur)
          candidate.goalKind = "move_nearest"
          candidate.requestedMapId = cur.mapId
          candidate.requestedX, candidate.requestedY = tx, ty
          buildStatus, buildWhy = buildNearestLegalPath(game, candidate, cur, tx, ty)
          nearestFallback = buildStatus and true or false
        end
      end
    end
  end

  local dynamicallyReachable = buildWhy == "dynamic"
  if not buildStatus and not dynamicallyReachable then
    state.stats.invalidTaps = state.stats.invalidTaps + 1
    if continuous then
      if oldNav then state.stats.retainedTargets = state.stats.retainedTargets + 1 end
    else
      if oldNav then cancelRoute("retargeted") end
      state.nav = candidate
      if candidate and candidate.cross then
        cancelRoute("connection_no_route_" .. tostring(buildWhy))
      elseif candidate and candidate.interaction then
        cancelRoute("interaction_no_route_" .. tostring(buildWhy))
      else
        cancelRoute("no_route")
      end
    end
    routeFeedback(showFeedback, "invalid", screenX, screenY)
    return false
  end

  retireForRetarget(oldNav, continuous)
  state.nav = candidate
  state.stats.routesStarted = state.stats.routesStarted + 1
  if nearestFallback then
    state.stats.nearestFallbacks = state.stats.nearestFallbacks + 1
  end
  if semanticKind == "door" then
    setStickySemantic("door", requestedMapId, tx, ty)
  elseif semanticKind == "npc" then
    setStickySemantic("npc", requestedMapId, tx, ty, semanticEntityId)
    if continuous then state.stats.npcHoldTargets = state.stats.npcHoldTargets + 1 end
  end

  if exitFallback then state.stats.exitFallbacks = state.stats.exitFallbacks + 1 end
  if candidate.exitJourney then
    state.exitJourney = {
      startedTick = state.tick, legs = 1,
      visited = { [cur.mapId] = 1 },
    }
    state.stats.exitJourneyLegs = state.stats.exitJourneyLegs + 1
  end

  local feedbackKind = (candidate.interaction or candidate.crossInteraction)
      and "interaction" or "accepted"
  routeFeedback(showFeedback, feedbackKind, screenX, screenY)

  if deferUntilCurrentStepLands(game, candidate) then return true end

  if candidate.goalKind ~= "interact" and not candidate.cross
      and not (candidate.goalKind == "exit" and candidate.exitDir)
      and cur.x == candidate.targetX and cur.y == candidate.targetY then
    finishRoute()
    return true
  end

  if dynamicallyReachable then
    scheduleDynamicWait(candidate,
      candidate.cross and "initial_connection_dynamic"
      or candidate.interaction and "initial_interaction_dynamic"
      or "initial_dynamic_obstacle")
  end
  return true
end

-- Continue an off-map "leave this interior" request after an internal warp.
-- Each leg is planned only after the destination map becomes the live map, so
-- vanilla scripts/doors/NPCs remain authoritative. The map graph above picks
-- the warp that actually leads toward outdoors; local A* picks the shortest
-- reachable way to that warp from the player's current cell.
local function startExitJourneyLeg(game)
  local journey = state.exitJourney
  if not journey or state.nav then return false, "inactive" end
  if option("enabled", true) == false then
    state.exitJourney = nil
    return false, "disabled"
  end
  local free = overworldGate(game)
  if not free then return nil, "busy" end
  if anyDirectionDown and anyDirectionDown(game) then
    state.exitJourney = nil
    return false, "manual_override"
  end
  local cur = mod.world and mod.world:current()
  local overview = mod.world and mod.world:mapOverview()
  if not cur or not overview or cur.mapId ~= overview.mapId then
    return nil, "map_not_ready"
  end
  local def = game and game.overworld and game.overworld.map
      and game.overworld.map.def
  if defLooksOutdoor(def) then
    state.exitJourney = nil
    return false, "outside"
  end

  local intent = nearestExitTarget(game, overview, cur)
  if not intent then
    state.exitJourney = nil
    return false, "no_exit"
  end

  local candidate = newNavigation(cur)
  candidate.exitJourney = true
  candidate.exitIntent = intent
  candidate.requestedX, candidate.requestedY = intent.x, intent.y
  local ok, why
  if intent.kind == "connection" then
    candidate.goalKind = "exit_connection"
    candidate.cross = intent.cross
    candidate.requestedMapId = intent.cross and intent.cross.destMapId or cur.mapId
    ok, why = rebuildNavigation(game, candidate, cur)
  else
    -- nearestExitTarget is built from ACTUAL map warp records. Do not run its
    -- chosen endpoint back through mapOverview terrain legality: some Gen I
    -- exit carpets are deliberately non-walkable collision cells and would
    -- be rejected here even though they are the correct warp source.
    candidate.goalKind = "exit"
    candidate.targetX, candidate.targetY = intent.x, intent.y
    candidate.exitDir = intent.exitDir
    candidate.requestedMapId = cur.mapId
    ok, why = rebuildNavigation(game, candidate, cur)
  end

  local dynamic = why == "dynamic"
  if not ok and not dynamic then
    state.exitJourney = nil
    return false, why or "no_route"
  end

  state.nav = candidate
  journey.legs = (journey.legs or 0) + 1
  journey.visited = journey.visited or {}
  journey.visited[cur.mapId] = (journey.visited[cur.mapId] or 0) + 1
  if journey.visited[cur.mapId] > 4 or journey.legs > 24 then
    state.nav = nil
    state.exitJourney = nil
    return false, "journey_loop"
  end
  state.stats.routesStarted = state.stats.routesStarted + 1
  state.stats.exitJourneyLegs = state.stats.exitJourneyLegs + 1
  if dynamic then scheduleDynamicWait(candidate, "exit_journey_dynamic") end
  return true
end

local function advanceAlongKnownPath(nav, cur)
  local nextNode = nav.path and nav.path[nav.index]
  if nextNode and nextNode.x == cur.x and nextNode.y == cur.y then
    nav.index = nav.index + 1
    return true
  end

  -- Ledges can advance more than one cell.  If vanilla movement lands farther
  -- along the route, fast-forward rather than treating the faithful hop as an
  -- override.  Forced movement to somewhere NOT on the route still cancels.
  for i = (nav.index or 1) + 1, #(nav.path or {}) do
    local node = nav.path[i]
    if node.x == cur.x and node.y == cur.y then
      nav.index = i + 1
      return true
    end
  end

  return false
end

local function holdIsDown(game, nav)
  local input = game and game.input
  if not nav or not nav.holdDir or not input or type(input.isDown) ~= "function" then
    return true -- no public observation available: keep the safe old behavior
  end
  local ok, down = pcall(input.isDown, input, nav.holdDir)
  if not ok then return true end
  return down == true
end

local function requestReplan(nav, reason)
  if not nav then return end
  nav.needsReplan = true
  state.stats.replans = state.stats.replans + 1
  setPhase(nav, "REPLANNING", reason)
end

local function processPendingInteraction()
  local pending = state.pendingInteraction
  if not pending then return end
  if state.tick - pending.tick > 3 then
    state.pendingInteraction = nil
    state.stats.interactionMisses = state.stats.interactionMisses + 1
    state.lastStop = {
      reason = "interaction_unconfirmed",
      tick = state.tick,
      mapId = pending.mapId,
      targetX = pending.x,
      targetY = pending.y,
    }
  end
end

local function interactionAtDestination(game, nav, cur)
  local interaction = nav and nav.interaction
  if not interaction then return false end
  local ix, iy, entity, err = interactionTarget(game, interaction)
  if not ix then
    cancelRoute("interaction_target_" .. tostring(err or "gone"))
    return true
  end

  if state.tick - (nav.createdTick or state.tick) > MAX_INTERACTION_AGE_TICKS then
    cancelRoute("interaction_timeout")
    return true
  end

  -- A wandering NPC is not actually present at targetX/targetY until its
  -- current step lands.  Wait without holding a direction, then the next tick
  -- either interacts or replans if it chose another wander step.
  if entity and entity.moving then
    releaseHold(nav)
    setPhase(nav, "WAITING_INTERACTION_TARGET", "target_mid_step")
    return true
  end

  if ix ~= interaction.targetX or iy ~= interaction.targetY then
    releaseHold(nav)
    interaction.chaseReplan = true
    requestReplan(nav, "interaction_target_moved_at_arrival")
    return true
  end

  -- Movement begins on pointer press, but A belongs to pointer RELEASE. If the
  -- same gesture is still physically down when we reach the approach cell,
  -- wait here without walking or turning. A short tap therefore feels instant
  -- on long routes, while an adjacent NPC cannot interact before the OS has
  -- even delivered the finger-up event. NPCs deliberately remain valid
  -- semantic targets during Hold-to-Steer; the held-pointer gate is what makes
  -- that safe, because A cannot fire until this gesture actually disappears.
  if nav.interactionRequiresRelease and nav.interactionGestureId ~= nil
      and gestureIsDown(nav.interactionGestureId) then
    releaseHold(nav)
    if nav.phase ~= "WAITING_INTERACTION_RELEASE" then
      state.stats.interactionReleaseWaits =
        (state.stats.interactionReleaseWaits or 0) + 1
    end
    setPhase(nav, "WAITING_INTERACTION_RELEASE", "pointer_still_down")
    return true
  end

  local dir = interaction.faceDir
  if not dir then
    cancelRoute("interaction_no_facing")
    return true
  end

  local player = game and game.overworld and game.overworld.player
  if not player then
    cancelRoute("interaction_no_player")
    return true
  end

  if player.facing ~= dir then
    -- Never hold the facing direction for more than one fixed tick.  The first
    -- tick should only turn in place; if it somehow did not, releasing now is
    -- safer than letting the turn timer expire into an unintended step.
    if nav.phase == "FACING_INTERACTION"
        and nav.facePressTick and nav.facePressTick < state.tick then
      releaseHold(nav)
      cancelRoute("interaction_face_failed")
      return true
    end
    releaseHold(nav)
    nav.holdDir = dir
    nav.hold = mod.input:press(game, dir)
    nav.facePressTick = state.tick
    setPhase(nav, "FACING_INTERACTION", "face_" .. dir)
    return true
  end

  releaseHold(nav)
  mod.input:tap(game, "a")
  state.pendingInteraction = {
    tick = state.tick,
    mapId = nav.mapId,
    kind = interaction.kind,
    entityId = interaction.entityId,
    x = ix, y = iy,
  }
  state.stats.interactionsTriggered = state.stats.interactionsTriggered + 1
  markStop("interaction_triggered", nav)
  state.nav = nil
  return true
end

anyDirectionDown = function(game)
  local input = game and game.input
  if not input or not input.isDown then return false end
  return input:isDown("up") or input:isDown("down")
      or input:isDown("left") or input:isDown("right")
end

local function dropBattleResume(reason)
  if not state.battleResume then return false end
  state.stats.battleResumeDrops = state.stats.battleResumeDrops + 1
  state.lastStop = {
    reason = "battle_resume_" .. tostring(reason or "dropped"),
    tick = state.tick,
    mapId = state.battleResume.mapId,
    targetX = state.battleResume.x, targetY = state.battleResume.y,
  }
  state.battleResume = nil
  return true
end

local function tryBattleResume(game)
  local resume = state.battleResume
  if not resume or not resume.ready or state.nav then return false end
  if option("enabled", true) == false then
    dropBattleResume("mod_disabled")
    return false
  end
  if option("battle_resume", false) ~= true then
    dropBattleResume("disabled")
    return false
  end
  if state.tick - (resume.endedTick or state.tick) > MAX_BATTLE_RESUME_AGE_TICKS then
    dropBattleResume("timeout")
    return false
  end
  if resume.readyTick and state.tick < resume.readyTick then return false end

  local free = overworldGate(game)
  if not free then return false end
  -- Manual movement after the fight is a stronger signal than the stored tap.
  -- Do not fight the player for the first overworld tick back.
  if anyDirectionDown(game) then
    dropBattleResume("manual_override")
    return false
  end

  local cur = mod.world and mod.world:current()
  local overview = mod.world and mod.world:mapOverview()
  if not cur or not overview or cur.mapId ~= resume.mapId
      or overview.mapId ~= resume.mapId then
    dropBattleResume("map_changed")
    return false
  end

  local ch = cellChar(overview, resume.x, resume.y)
  local waterMode = currentWaterMode(game, overview, cur)
  if ch ~= "." and ch ~= "+" and not (ch == "~" and waterMode) then
    dropBattleResume("target_invalid")
    return false
  end

  local targetX, targetY = resume.x, resume.y
  state.battleResume = nil
  local nav = newNavigation(cur)
  nav.goalKind = "move"
  nav.targetX, nav.targetY = targetX, targetY
  nav.requestedX, nav.requestedY = targetX, targetY
  nav.resumedAfterBattle = true
  state.nav = nav
  state.stats.routesStarted = state.stats.routesStarted + 1
  state.stats.battleResumes = state.stats.battleResumes + 1

  if cur.x == targetX and cur.y == targetY then
    finishRoute()
    return true
  end
  local ok, why = rebuildNavigation(game, nav, cur)
  if ok then return true end
  if why == "dynamic" then
    scheduleDynamicWait(nav, "battle_resume_dynamic")
    return true
  end
  cancelRoute("battle_resume_no_route_" .. tostring(why))
  return false
end

local function currentWorldPointerHeld()
  local id = state.tapOwner
  local p = id and state.pointers[id]
  return p ~= nil and not p.ignored and not p.manualSuppressed
      and not p.gestureSuppressed
end

-- Seamless connections have one engine-specific wrinkle: checkEdgeExit only
-- runs when the player is ALREADY facing the edge direction. Autowalk can
-- arrive at a seam immediately after a corner while the vanilla turn-in-place
-- latch is still spent. Give the engine one fixed tick with no synthetic
-- direction held; its ordinary no-direction path re-arms turning. On the next
-- tick we hold the seam direction continuously, allowing vanilla to turn and
-- then cross without first treating the map edge as a wall.
local function prepareConnectionCross(nav)
  if not (nav and nav.cross and not nav.cross.crossed) then return false end
  releaseHold(nav)
  nav.connectionNeutralTick = state.tick
  state.stats.seamNeutralTicks = (state.stats.seamNeutralTicks or 0) + 1
  setPhase(nav, "WAITING_CONNECTION_FACE",
           "neutral_before_" .. tostring(nav.cross.dir))
  return true
end

local function pressConnectionCross(game, nav, cur)
  if not (nav and nav.cross and cur) then return false end
  releaseHold(nav)
  local dir = nav.cross.dir
  local dx, dy = cur.x, cur.y
  if nav.cross.ledgeSeam then
    dx, dy = nav.cross.ledgeMidX, nav.cross.ledgeMidY
  elseif dir == "up" then dy = dy - 1
  elseif dir == "down" then dy = dy + 1
  elseif dir == "left" then dx = dx - 1
  else dx = dx + 1 end
  nav.holdDir = dir
  nav.expectedX, nav.expectedY = dx, dy
  nav.hold = mod.input:press(game, dir)
  nav.lastProgressTick = state.tick
  nav.connectionPressTick = state.tick
  nav.connectionNeutralTick = nil
  setPhase(nav, "CROSSING_CONNECTION", "cross_" .. dir)
  return true
end

local function navigationTick(game)
  state.tick = state.tick + 1
  state.game = game
  processPendingInteraction()

  local nav = state.nav
  if not nav and state.exitJourney then
    startExitJourneyLeg(game)
    nav = state.nav
  end
  if not nav then
    tryBattleResume(game)
    nav = state.nav
    if not nav then return end
  end
  if option("enabled", true) == false then
    cancelRoute("disabled")
    return
  end

  local free, gateReason = overworldGate(game)
  if not free then
    cancelRoute("interrupt_" .. tostring(gateReason))
    return
  end

  local cur = mod.world and mod.world:current()
  if not cur or cur.mapId ~= nav.mapId then
    cancelRoute("map_changed")
    return
  end

  if nav.phase == "WAITING_CONNECTION_FACE" then
    releaseHold(nav)
    local player = game and game.overworld and game.overworld.player
    if player and player.moving then return end
    pressConnectionCross(game, nav, cur)
    return
  end

  -- The first seam-direction poll may legitimately be consumed by vanilla's
  -- turn-in-place state. Keep the SAME synthetic direction held on subsequent
  -- fixed ticks until crossConnection/map.entered actually takes over. Without
  -- this guard, arrival detection below would see the unchanged edge cell and
  -- re-enter WAITING_CONNECTION_FACE every tick, repeatedly releasing the
  -- direction before the engine got its second poll to walk across the seam.
  if nav.phase == "CROSSING_CONNECTION"
      and cur.x == nav.targetX and cur.y == nav.targetY then
    if state.tick - (nav.connectionPressTick or state.tick) > 45 then
      cancelRoute("connection_cross_timeout")
      return
    end
    if not holdIsDown(game, nav) then
      releaseHold(nav)
      nav.holdDir = nav.cross and nav.cross.dir or nav.holdDir
      if nav.holdDir then nav.hold = mod.input:press(game, nav.holdDir) end
    end
    return
  end

  if nav.phase == "WAITING_CONNECTION_STEP" then
    releaseHold(nav)
    local player = game and game.overworld and game.overworld.player
    if player and player.moving then return end
    if cur.x ~= nav.cross.entryX or cur.y ~= nav.cross.entryY then
      cancelRoute("connection_landing_mismatch")
      return
    end
    nav.lastX, nav.lastY = cur.x, cur.y
    nav.lastProgressTick = state.tick
    nav.path, nav.index = nil, 1
    if nav.crossInteraction then
      nav.interaction = nav.crossInteraction
      nav.crossInteraction = nil
      nav.goalKind = "interact"
    elseif cur.x == nav.targetX and cur.y == nav.targetY then
      finishRoute()
      return
    end
    local ok, why = rebuildNavigation(game, nav, cur)
    if not ok then
      if why == "dynamic" then
        scheduleDynamicWait(nav, "dynamic_after_connection")
        return
      end
      cancelRoute("connection_destination_no_route_" .. tostring(why))
      return
    end
  end

  if nav.phase == "WAITING_PLAYER_STEP" then
    releaseHold(nav)
    if cur.x == nav.pendingStartX and cur.y == nav.pendingStartY then
      nav.pendingStartX, nav.pendingStartY = nil, nil
      nav.lastX, nav.lastY = cur.x, cur.y
      nav.lastProgressTick = state.tick
      if not nav.interaction
          and not (nav.goalKind == "exit" and nav.exitDir)
          and cur.x == nav.targetX and cur.y == nav.targetY then
        finishRoute()
        return
      end
      local ok, why = rebuildNavigation(game, nav, cur)
      if not ok then
        if why == "dynamic" then
          scheduleDynamicWait(nav, "dynamic_after_existing_step")
          return
        end
        cancelRoute("post_step_plan_failed_" .. tostring(why))
        return
      end
    else
      -- The manually initiated step has not landed yet.  A normal player step
      -- is 16 frames (bike 8); this generous bound is only a stuck-state fuse.
      if state.tick - (nav.createdTick or state.tick) > 90 then
        cancelRoute("existing_step_timeout")
      end
      return
    end
  end

  if nav.interaction then
    if state.tick - (nav.createdTick or state.tick) > MAX_INTERACTION_AGE_TICKS then
      cancelRoute("interaction_timeout")
      return
    end
    local ix, iy, _, ierr = interactionTarget(game, nav.interaction)
    if not ix then
      cancelRoute("interaction_target_" .. tostring(ierr or "gone"))
      return
    end
    if ix ~= nav.interaction.targetX or iy ~= nav.interaction.targetY then
      releaseHold(nav)
      nav.interaction.chaseReplan = true
      requestReplan(nav, "interaction_target_moved")
    end
  end

  local _, dynamicNow = liveOccupancy(game)
  cleanupTempBlocks(nav, dynamicNow)

  if cur.x ~= nav.lastX or cur.y ~= nav.lastY then
    -- Cross-map ledges spend one scripted step on the current map's edge tile
    -- before the engine callback performs the seamless connection.  That
    -- midpoint is expected movement even though the normal approach path has
    -- already ended at the ledge's standing cell.
    if nav.phase == "CROSSING_CONNECTION" and nav.cross and nav.cross.ledgeSeam
        and cur.x == nav.cross.ledgeMidX and cur.y == nav.cross.ledgeMidY then
      nav.lastX, nav.lastY = cur.x, cur.y
      nav.lastProgressTick = state.tick
      releaseHold(nav) -- the scripted ledge callback owns the actual crossing
      return
    end

    local oldDir = nav.holdDir
    local matched = advanceAlongKnownPath(nav, cur)
    nav.lastX, nav.lastY = cur.x, cur.y
    nav.lastProgressTick = state.tick
    nav.dynamicWaitStarted = nil

    if not matched then
      cancelRoute("unexpected_movement")
      return
    end

    local nextNode = nav.path and nav.path[nav.index]
    local nextDir = nextNode and directionTo(cur.x, cur.y, nextNode.x, nextNode.y)
    if not nextDir or nextDir ~= oldDir then releaseHold(nav) end
  end

  if nav.phase == "WAITING_DYNAMIC" then
    releaseHold(nav)
    if nav.dynamicWaitStarted
        and state.tick - nav.dynamicWaitStarted > MAX_DYNAMIC_WAIT_TICKS then
      cancelRoute("dynamic_timeout")
      return
    end
    if nav.waitUntil and state.tick < nav.waitUntil then return end

    local ok, why = rebuildNavigation(game, nav, cur)
    if not ok then
      if why == "dynamic" then
        scheduleDynamicWait(nav, "dynamic_still_blocked")
        return
      end
      cancelRoute("replan_failed_" .. tostring(why))
      return
    end
  end

  if nav.needsReplan or nav.phase == "REPLANNING" then
    releaseHold(nav)
    local ok, why = rebuildNavigation(game, nav, cur)
    if not ok then
      if why == "dynamic" then
        scheduleDynamicWait(nav, "dynamic_after_replan")
        return
      end
      cancelRoute("replan_failed_" .. tostring(why))
      return
    end
  end

  if nav.phase == "EXITING_WARP" then
    -- Leave the direction held until the engine starts the warp/transition.
    -- overworldGate/map.entered will retire the route and source-safe release
    -- the token. A fuse protects malformed custom warp data from holding it.
    if state.tick - (nav.lastProgressTick or state.tick) > 45 then
      cancelRoute("exit_warp_timeout")
    end
    return
  end

  -- Resolve arrival only after any target-movement/collision replan above.
  -- This is especially important for Tap to Interact: an NPC can move while
  -- the player is standing on the OLD approach cell, and that stale arrival
  -- must not starve the replan forever.
  if cur.x == nav.targetX and cur.y == nav.targetY then
    if nav.cross and not nav.cross.crossed then
      local player = game and game.overworld and game.overworld.player
      -- When the user is actively HOLDING and vanilla already faces the seam,
      -- there is nothing to re-arm: begin the connection press on this very
      -- fixed tick. Released taps retain the neutral safety poll, and a held
      -- corner approach whose facing differs still gets that one safe poll to
      -- avoid the engine's edge-bonk turn-latch case.
      if currentWorldPointerHeld() and player
          and player.facing == nav.cross.dir then
        state.stats.seamHeldFastStarts =
          (state.stats.seamHeldFastStarts or 0) + 1
        pressConnectionCross(game, nav, cur)
      else
        prepareConnectionCross(nav)
      end
    elseif nav.interaction then
      interactionAtDestination(game, nav, cur)
    elseif nav.goalKind == "exit" and nav.exitDir then
      -- Gen I interior exit carpets are warp records on ordinary floor cells.
      -- Reaching the record is only half the action; the engine activates it
      -- when the player tries to move out / into the carpet direction.
      releaseHold(nav)
      nav.holdDir = nav.exitDir
      nav.hold = mod.input:press(game, nav.exitDir)
      nav.lastProgressTick = state.tick
      setPhase(nav, "EXITING_WARP", "exit_" .. nav.exitDir)
    else
      finishRoute()
    end
    return
  end

  if nav.phase == "WALKING" and nav.lastProgressTick
      and state.tick - nav.lastProgressTick > NO_PROGRESS_TICKS then
    cancelRoute("no_progress_timeout")
    return
  end

  local nextNode = nav.path and nav.path[nav.index]
  if not nextNode then
    requestReplan(nav, "stale_plan")
    return
  end

  local dir = directionTo(cur.x, cur.y, nextNode.x, nextNode.y)
  if not dir then
    cancelRoute("non_adjacent_plan")
    return
  end

  if nav.hold and nav.holdDir == dir then
    nav.expectedX, nav.expectedY = nextNode.x, nextNode.y
    -- Input recovery (focus loss, hotplug, resume) retires mod.input tokens.
    -- Verify the direction is genuinely down and acquire a fresh token if not.
    if not holdIsDown(game, nav) then
      releaseHold(nav)
      nav.holdDir = dir
      nav.hold = mod.input:press(game, dir)
    end
    return
  end

  releaseHold(nav)
  nav.expectedX, nav.expectedY = nextNode.x, nextNode.y
  nav.holdDir = dir
  nav.hold = mod.input:press(game, dir)
end

-- Keep a read-only frame description for precise tap -> world-cell mapping.
mod.hooks:wrap("render.compose", function(nextFn, renderer, ctx)
  -- Some mobile pinch implementations deliver the survey-zoom mutation after
  -- the touch callback which identified the gesture. Restore the reserved
  -- pre-gesture zoom immediately before composing the frame as a second line
  -- of defence, so a native pinch cannot visibly leak through for one frame.
  if restoreNativeZoomSuppression and state.game then
    restoreNativeZoomSuppression(state.game)
  end
  captureView(ctx)
  return nextFn()
end)

local function startSelectTouchMode()
  local value = tostring(option("start_select_touch_control", "off") or "off")
  if value == "hold_player_sprite" or value == "pinch_or_spread" then
    return value
  end
  return "off"
end

local function twoFingerFeatureEnabled()
  return startSelectTouchMode() == "pinch_or_spread"
end

local function gestureDistance(a, b)
  if not a or not b then return nil end
  local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
  return math.sqrt(dx * dx + dy * dy)
end

-- Public input.pointer supplies the contacts and mod.input supplies the GB
-- buttons. Zoom is touched only as a compatibility guard: mobile builds can
-- synthesize pinch as zoom/wheel input outside the pointer hook, so a reserved
-- two-finger gesture must be able to veto that one presentation shortcut.
local function zoomModule()
  if state.zoomModule ~= nil then
    return state.zoomModule ~= false and state.zoomModule or nil
  end
  local ok, z = pcall(require, "src.render.Zoom")
  state.zoomModule = ok and z or false
  return ok and z or nil
end

local function nativeZoomSuppressionAlive()
  local z = state.nativeZoomSuppression
  if not z or not z.block then return false end
  if z.rawActive then return true end
  return state.tick <= (z.untilTick or -1)
end

local function captureNativeZoomSuppression(game, forceBlock)
  local existing = state.nativeZoomSuppression
  if existing and (existing.rawActive or state.tick <= (existing.untilTick or -1)) then
    existing.rawActive = true
    existing.untilTick = math.max(existing.untilTick or 0,
                                  state.tick + PINCH_ZOOM_GRACE_TICKS)
    if forceBlock ~= nil then existing.block = forceBlock and true or false end
    return existing
  end

  local z = zoomModule()
  local opts = game and game.save and game.save.options
  local suppression = {
    zoomOffset = z and z.offset or nil,
    zoomOption = opts and opts.zoom or nil,
    rawActive = true,
    untilTick = state.tick + PINCH_ZOOM_GRACE_TICKS,
    block = forceBlock and true or false,
    dirty = false,
  }
  state.nativeZoomSuppression = suppression
  return suppression
end

local function setNativeZoomSuppressionBlock(game, block)
  local suppression = state.nativeZoomSuppression
  if not suppression then
    suppression = captureNativeZoomSuppression(game, block)
  else
    suppression.block = block and true or false
  end
  if suppression.block and restoreNativeZoomSuppression then
    restoreNativeZoomSuppression(game)
  end
end

restoreNativeZoomSuppression = function(game)
  local suppression = state.nativeZoomSuppression
  if not nativeZoomSuppressionAlive() then
    if suppression and not suppression.rawActive
        and state.tick > (suppression.untilTick or -1) then
      state.nativeZoomSuppression = nil
    end
    return false
  end

  local changed = false
  local z = zoomModule()
  if z and suppression.zoomOffset ~= nil and z.offset ~= suppression.zoomOffset then
    z.offset = suppression.zoomOffset
    changed = true
  end
  local opts = game and game.save and game.save.options
  if opts and suppression.zoomOption ~= nil and opts.zoom ~= suppression.zoomOption then
    opts.zoom = suppression.zoomOption
    changed = true
  end
  if changed then
    suppression.dirty = true
    state.stats.pinchZoomSuppressed =
      (state.stats.pinchZoomSuppressed or 0) + 1
  end
  return changed
end

local function installZoomGestureGuard(game)
  if state.zoomGuardInstalled or not game or type(game.zoomStep) ~= "function" then
    return
  end
  local original = game.zoomStep
  state.zoomGuardOriginal = original
  game.zoomStep = function(self, delta)
    if nativeZoomSuppressionAlive() then
      state.stats.pinchZoomSuppressed =
        (state.stats.pinchZoomSuppressed or 0) + 1
      return
    end
    local gesture = state.twoFingerGesture
    if gesture and gesture.blockZoom then
      state.stats.pinchZoomSuppressed =
        (state.stats.pinchZoomSuppressed or 0) + 1
      return
    end
    return original(self, delta)
  end
  state.zoomGuardInstalled = true
end

local function captureGestureZoom(game, gesture)
  if not gesture then return end
  -- Raw touch tracking captures the baseline before TouchControls and before
  -- input.pointer. Reuse that earlier baseline when available, otherwise fall
  -- back to the historical per-gesture snapshot.
  local suppression = state.nativeZoomSuppression
  if suppression then
    gesture.zoomOffset = suppression.zoomOffset
    gesture.zoomOption = suppression.zoomOption
    return
  end
  local z = zoomModule()
  gesture.zoomOffset = z and z.offset or nil
  gesture.zoomOption = game and game.save and game.save.options
      and game.save.options.zoom or nil
end

local function restoreGestureZoom(game, gesture)
  if not gesture or not gesture.blockZoom then return false end
  local changed = false
  -- Prefer the raw-touch baseline because it is captured before any native
  -- touch consumer can mutate survey zoom.
  if state.nativeZoomSuppression then
    setNativeZoomSuppressionBlock(game, true)
    changed = restoreNativeZoomSuppression(game) or changed
  else
    local z = zoomModule()
    if z and gesture.zoomOffset ~= nil and z.offset ~= gesture.zoomOffset then
      z.offset = gesture.zoomOffset
      changed = true
    end
    local opts = game and game.save and game.save.options
    if opts and gesture.zoomOption ~= nil and opts.zoom ~= gesture.zoomOption then
      opts.zoom = gesture.zoomOption
      changed = true
    end
  end
  if changed then gesture.zoomDirty = true end
  return changed
end

local function rawTouchCount()
  local count = 0
  for _ in pairs(state.rawZoomTouches or {}) do count = count + 1 end
  return count
end

local function rawGestureIds()
  local ids = {}
  for id in pairs(state.rawZoomTouches or {}) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  return ids
end

local function suppressRawGesturePointer(id)
  local p = id and state.pointers[id]
  if not p then return end
  p.gestureSuppressed = "two_finger_gesture"
  p.manualSuppressed = true
  p.ignored = true
end

-- Raw game touches are the authoritative mobile gesture stream.  They arrive
-- before TouchControls gets first refusal, which matters because the second
-- finger may land over a virtual control and therefore never reach
-- input.pointer.  v1.2.2 already used this layer to suppress native zoom; from
-- v1.2.3 the START/SELECT remaps use the same exact contact pair as well.
local function beginRawTwoFingerGesture(game)
  if state.twoFingerGesture or not twoFingerFeatureEnabled() then return false end
  local ids = rawGestureIds()
  if #ids < 2 then return false end
  local a, b = state.rawZoomTouches[ids[1]], state.rawZoomTouches[ids[2]]
  local dist = gestureDistance(a, b)
  if not dist then return false end

  local gesture = {
    id1 = ids[1], id2 = ids[2], startDistance = dist, lastDistance = dist,
    direction = nil, fired = false, ended = false, blockZoom = true,
    raw = true,
  }
  state.twoFingerGesture = gesture
  captureGestureZoom(game, gesture)
  suppressRawGesturePointer(gesture.id1)
  suppressRawGesturePointer(gesture.id2)
  for _, gid in ipairs({ gesture.id1, gesture.id2 }) do
    local dt = state.dialogTouches and state.dialogTouches[gid]
    if dt then
      if dt.bFired then gesture.actionSuppressed = true end
      dt.suppressed = true
    end
    local bt = state.battleTouches and state.battleTouches[gid]
    if bt then
      if bt.bFired then gesture.actionSuppressed = true end
      bt.suppressed = true
    end
    local ph = state.playerHoldTouches and state.playerHoldTouches[gid]
    if ph then ph.cancelled = true; ph.cancelReason = "two_finger" end
    -- A bottom-edge reservation may have swallowed the first finger before
    -- input.pointer. Once a true two-finger gesture owns that contact, keep
    -- the reservation swallowed through release so it cannot replay a stray
    -- tap after START/SELECT fires.
    local edge = state.systemEdgeTouches and state.systemEdgeTouches[gid]
    if edge then edge.systemGesture = true; edge.twoFingerSuppressed = true end
    -- The first overworld finger may still be inside the short pairing grace
    -- window and therefore has not reached Tap to Move at all. Claim it now so
    -- its later release can never replay a single-touch route underneath the
    -- two-finger START/SELECT gesture.
    local grace = state.pinchGraceTouches and state.pinchGraceTouches[gid]
    if grace then
      grace.suppressed = true
      grace.suppressReason = "two_finger_gesture"
    end
  end
  state.stats.pinchGracePairsClaimed =
    (state.stats.pinchGracePairsClaimed or 0) + 1
  if state.nav then cancelRoute("two_finger_gesture") end
  state.stats.twoFingerGestures = (state.stats.twoFingerGestures or 0) + 1
  return true
end

local function classifyRawTwoFingerGesture(game)
  local gesture = state.twoFingerGesture
  if not gesture or not gesture.raw or gesture.ended or gesture.direction then return end
  local a = state.rawZoomTouches and state.rawZoomTouches[gesture.id1]
  local b = state.rawZoomTouches and state.rawZoomTouches[gesture.id2]
  local dist = gestureDistance(a, b)
  if not dist then return end
  gesture.lastDistance = dist
  local threshold = math.max(TWO_FINGER_TRIGGER_UNITS,
                             (gesture.startDistance or dist) * TWO_FINGER_TRIGGER_RATIO)
  local delta = dist - (gesture.startDistance or dist)
  if math.abs(delta) < threshold then
    restoreGestureZoom(game, gesture)
    return
  end

  local direction = delta > 0 and "spread" or "pinch"
  gesture.direction = direction
  -- PINCH OR SPREAD owns the complete two-finger gesture. While selected,
  -- native pinch/spread zoom is disabled and the classified gesture is mapped
  -- directly to the corresponding Game Boy button.
  gesture.blockZoom = twoFingerFeatureEnabled()
  if state.nativeZoomSuppression then
    setNativeZoomSuppressionBlock(game, gesture.blockZoom)
  end
  if gesture.blockZoom then restoreGestureZoom(game, gesture) end

  if not gesture.actionSuppressed
      and twoFingerFeatureEnabled() and direction == "spread" then
    mod.input:tap(game, "start")
    gesture.fired = true
    state.stats.gestureStartTriggers =
      (state.stats.gestureStartTriggers or 0) + 1
  elseif not gesture.actionSuppressed
      and twoFingerFeatureEnabled() and direction == "pinch" then
    mod.input:tap(game, "select")
    gesture.fired = true
    state.stats.gestureSelectTriggers =
      (state.stats.gestureSelectTriggers or 0) + 1
  end
end

local function finishRawTwoFingerGesture(game, id)
  local gesture = state.twoFingerGesture
  if not gesture or not gesture.raw
      or (id ~= gesture.id1 and id ~= gesture.id2) then return end
  gesture.ended = true
  restoreGestureZoom(game, gesture)
  -- Raw zoom suppression deliberately outlives the contact pair.  Do not clear
  -- it here: delayed native pinch callbacks are still blocked by the grace
  -- latch established in noteRawTouchReleased.
  gesture.blockZoom = false
end

local function maybeClearRawTwoFingerGesture(game)
  local gesture = state.twoFingerGesture
  if not gesture or not gesture.raw then return end
  if state.rawZoomTouches[gesture.id1] or state.rawZoomTouches[gesture.id2] then
    return
  end
  local suppression = state.nativeZoomSuppression
  if (gesture.zoomDirty or (suppression and suppression.dirty))
      and game and type(game.writeOptions) == "function" then
    pcall(function() game:writeOptions() end)
    if suppression then suppression.dirty = false end
  end
  state.twoFingerGesture = nil
end

local function noteRawTouchPressed(game, id, x, y)
  if id == nil or id == "mouse" then return end
  state.rawZoomTouches = state.rawZoomTouches or {}
  state.rawZoomTouches[id] = { x = x, y = y }
  if rawTouchCount() >= 2 and twoFingerFeatureEnabled() then
    installZoomGestureGuard(game)
    -- Before the direction is classified we reserve zoom provisionally, which
    -- matches the original behaviour of the remap recognizer. PINCH OR
    -- SPREAD therefore blocks native zoom immediately from second-finger down.
    captureNativeZoomSuppression(game, true)
    restoreNativeZoomSuppression(game)
    beginRawTwoFingerGesture(game)
    local gesture = state.twoFingerGesture
    if gesture and gesture.raw then
      suppressRawGesturePointer(gesture.id1)
      suppressRawGesturePointer(gesture.id2)
    end
  end
end

local function noteRawTouchMoved(game, id, x, y)
  local t = state.rawZoomTouches and state.rawZoomTouches[id]
  if not t then return end
  t.x, t.y = x, y
  local suppression = state.nativeZoomSuppression
  if suppression and rawTouchCount() >= 2 then
    suppression.rawActive = true
    suppression.untilTick = state.tick + PINCH_ZOOM_GRACE_TICKS
    restoreNativeZoomSuppression(game)
  end
  local gesture = state.twoFingerGesture
  if gesture and gesture.raw then
    suppressRawGesturePointer(gesture.id1)
    suppressRawGesturePointer(gesture.id2)
    classifyRawTwoFingerGesture(game)
    restoreGestureZoom(game, gesture)
  end
end

local function noteRawTouchReleased(game, id)
  if not (state.rawZoomTouches and state.rawZoomTouches[id]) then return end
  finishRawTwoFingerGesture(game, id)
  state.rawZoomTouches[id] = nil
  local suppression = state.nativeZoomSuppression
  if suppression and rawTouchCount() < 2 then
    suppression.rawActive = false
    suppression.untilTick = state.tick + PINCH_ZOOM_GRACE_TICKS
    restoreNativeZoomSuppression(game)
  end
  maybeClearRawTwoFingerGesture(game)
end

local function installRawPinchZoomGuard(game)
  if state.rawZoomGuardInstalled or not game then return false end
  if type(game.touchpressed) ~= "function" or type(game.touchmoved) ~= "function"
      or type(game.touchreleased) ~= "function" then
    return false
  end

  installZoomGestureGuard(game)
  local pressed, moved, released = game.touchpressed, game.touchmoved, game.touchreleased
  state.rawZoomGuardOriginal = {
    touchpressed = pressed, touchmoved = moved, touchreleased = released,
  }

  -- Everything below the bottom-edge reservation goes through these three
  -- dispatchers. This lets a reserved contact be replayed into the SAME
  -- dialogue/battle/player-hold/native path once we know it was not an OS
  -- navigation swipe, without re-entering raw two-finger tracking twice.
  local function dispatchPress(self, id, x, y, dx, dy, pressure)
    state.rawDispatchedTouches = state.rawDispatchedTouches or {}
    state.rawDispatchedTouches[id] = true
    local battleOwned = id ~= nil and id ~= "mouse"
        and ControlsFree.battleTouchFeatureEnabled(self)
    if battleOwned then
      state.battleCameraOwnedTouches = state.battleCameraOwnedTouches or {}
      state.battleCameraOwnedTouches[id] = true
      state.stats.battleCameraTouchesSuppressed =
        (state.stats.battleCameraTouchesSuppressed or 0) + 1
    end

    if state.dialogTouches and state.dialogTouches[id] then return true end
    if state.battleTouches and state.battleTouches[id] then return true end
    if not state.twoFingerGesture and ControlsFree.beginDialogTouch(self, id, x, y) then
      return true
    end
    if not state.twoFingerGesture and ControlsFree.beginBattleTouch(self, id, x, y) then
      return true
    end

    if not (state.playerHoldTouches and state.playerHoldTouches[id]) then
      ControlsFree.beginPlayerHoldTouch(self, id, x, y)
    end
    if battleOwned then return true end
    return pressed(self, id, x, y, dx, dy, pressure)
  end

  local function dispatchMove(self, id, x, y, dx, dy, pressure)
    if ControlsFree.moveDialogTouch(id, x, y) then return true end
    if ControlsFree.moveBattleTouch(id, x, y) then return true end
    ControlsFree.movePlayerHoldTouch(id, x, y)
    if state.battleCameraOwnedTouches and state.battleCameraOwnedTouches[id] then
      return true
    end
    return moved(self, id, x, y, dx, dy, pressure)
  end

  local function dispatchRelease(self, id, x, y, dx, dy, pressure)
    if state.rawDispatchedTouches then state.rawDispatchedTouches[id] = nil end
    local battleOwned = state.battleCameraOwnedTouches
        and state.battleCameraOwnedTouches[id] == true

    if state.dialogTouches and state.dialogTouches[id] then
      ControlsFree.finishDialogTouch(self, id, x, y, false)
      if state.battleCameraOwnedTouches then state.battleCameraOwnedTouches[id] = nil end
      ControlsFree.finishPlayerHoldTouch(id)
      return true
    end
    if state.battleTouches and state.battleTouches[id] then
      ControlsFree.finishBattleTouch(self, id, x, y, false)
      if state.battleCameraOwnedTouches then state.battleCameraOwnedTouches[id] = nil end
      ControlsFree.finishPlayerHoldTouch(id)
      return true
    end

    if battleOwned then
      state.battleCameraOwnedTouches[id] = nil
      ControlsFree.finishPlayerHoldTouch(id)
      return true
    end

    local result = released(self, id, x, y, dx, dy, pressure)
    ControlsFree.finishPlayerHoldTouch(id)
    return result
  end

  -- Expose only these already-sanitized dispatch closures to the fixed-step
  -- grace promoter. They bypass THIS raw wrapper (so raw gesture bookkeeping
  -- is not counted twice) but still flow through TouchControls + input.pointer
  -- exactly as a normal single touch would have.
  state.rawTouchDispatchPress = dispatchPress
  state.rawTouchDispatchMove = dispatchMove
  state.rawTouchDispatchRelease = dispatchRelease

  game.touchpressed = function(self, id, x, y, dx, dy, pressure)
    -- A lifecycle interruption can swallow the previous release. Any NEW press
    -- with the same host touch id is authoritative and retires stale ownership.
    if state.nativeControlOwnedTouches then state.nativeControlOwnedTouches[id] = nil end

    -- Absolute priority for Gen1Recomp's visible virtual controls. Ownership is
    -- decided only at touch-DOWN: a finger that starts on A/B/D-pad/START/SELECT
    -- bypasses every Tap-to-Move/dialog/battle/pinch/system-edge classifier and
    -- rides the native TouchControls lifecycle unchanged. A world finger that
    -- merely crosses over a control later remains a world/hold gesture.
    if id ~= nil and id ~= "mouse" and ControlsFree.rawTouchControlHit(self, x, y) then
      state.nativeControlOwnedTouches = state.nativeControlOwnedTouches or {}
      state.nativeControlOwnedTouches[id] = true
      state.stats.nativeControlTouchesBypassed =
        (state.stats.nativeControlTouchesBypassed or 0) + 1
      return pressed(self, id, x, y, dx, dy, pressure)
    end

    noteRawTouchPressed(self, id, x, y)

    -- The second finger can create the raw gesture before it ever reaches
    -- TouchControls/input.pointer. Once that happens, neither participant may
    -- leak a synthetic single-touch press into gameplay.
    local rawGesture = state.twoFingerGesture
    if rawGesture and rawGesture.raw
        and (id == rawGesture.id1 or id == rawGesture.id2) then
      restoreNativeZoomSuppression(self)
      return true
    end

    -- Reserve bottom-edge WORLD contacts before input.pointer. Visible native
    -- controls have already bypassed the mod above, and systemEdgeGuardEnabled
    -- limits this reservation to the bare overworld, so this suppresses only a
    -- possible false Tap-to-Move command rather than disabling app controls.
    if ControlsFree.beginSystemEdgeTouch(self, id, x, y) then
      -- Preserve HOLD PLAYER SPRITE: the edge guard suppresses only world
      -- movement. A stationary avatar hold may still intentionally fire START.
      ControlsFree.beginPlayerHoldTouch(self, id, x, y)
      restoreNativeZoomSuppression(self)
      return true
    end

    -- PINCH OR SPREAD needs a short first-finger pairing window on the free
    -- overworld. Tap to Move used to act on press immediately, so a human
    -- placing finger #2 a few frames later could get one walking step plus
    -- START/SELECT. During this grace the first touch is not forwarded at all.
    if ControlsFree.beginPinchGraceTouch(self, id, x, y, dx, dy, pressure) then
      restoreNativeZoomSuppression(self)
      return true
    end

    local result = dispatchPress(self, id, x, y, dx, dy, pressure)
    restoreNativeZoomSuppression(self)
    return result
  end

  game.touchmoved = function(self, id, x, y, dx, dy, pressure)
    if state.nativeControlOwnedTouches and state.nativeControlOwnedTouches[id] then
      return moved(self, id, x, y, dx, dy, pressure)
    end

    noteRawTouchMoved(self, id, x, y)

    local rawGesture = state.twoFingerGesture
    if rawGesture and rawGesture.raw
        and (id == rawGesture.id1 or id == rawGesture.id2) then
      ControlsFree.movePinchGraceTouch(id, x, y, dx, dy, pressure)
      restoreNativeZoomSuppression(self)
      return true
    end

    if ControlsFree.movePinchGraceTouch(id, x, y, dx, dy, pressure) then
      restoreNativeZoomSuppression(self)
      return true
    end

    local edgeStatus = state.systemEdgeTouches and state.systemEdgeTouches[id]
        and "pending" or nil
    if edgeStatus then
      edgeStatus = ControlsFree.moveSystemEdgeTouch(self, id, x, y)
      ControlsFree.movePlayerHoldTouch(id, x, y)
      if edgeStatus == "promote" then
        local edge = state.systemEdgeTouches[id]
        state.systemEdgeTouches[id] = nil
        dispatchPress(self, id, edge.startX, edge.startY, 0, 0, pressure)
        local result = dispatchMove(self, id, x, y, dx, dy, pressure)
        restoreNativeZoomSuppression(self)
        return result
      end
      restoreNativeZoomSuppression(self)
      return true
    end

    local result = dispatchMove(self, id, x, y, dx, dy, pressure)
    restoreNativeZoomSuppression(self)
    return result
  end

  game.touchreleased = function(self, id, x, y, dx, dy, pressure)
    if state.nativeControlOwnedTouches and state.nativeControlOwnedTouches[id] then
      -- Keep the ownership flag set while the original Game path calls the
      -- TouchControls fallback wrapper, so that wrapper can forward the native
      -- release instead of mistaking it for battle-camera suppression.
      local result = released(self, id, x, y, dx, dy, pressure)
      state.nativeControlOwnedTouches[id] = nil
      return result
    end

    local rawGesture = state.twoFingerGesture
    if rawGesture and rawGesture.raw
        and (id == rawGesture.id1 or id == rawGesture.id2) then
      if state.pinchGraceTouches then state.pinchGraceTouches[id] = nil end
      -- If this finger had already left the grace window before finger #2
      -- arrived, it owns a real Game/TouchControls press that still requires
      -- its matching release for cleanup. Gesture suppression above guarantees
      -- that this release cannot start another route or A/D-pad action.
      if state.rawDispatchedTouches and state.rawDispatchedTouches[id] then
        dispatchRelease(self, id, x, y, dx, dy, pressure)
      else
        -- Grace/system-edge contacts were never sent into Game. Retire any
        -- provisional classifier state directly instead of manufacturing a
        -- release for a press that never existed.
        if state.systemEdgeTouches then state.systemEdgeTouches[id] = nil end
        if state.dialogTouches then state.dialogTouches[id] = nil end
        if state.battleTouches then state.battleTouches[id] = nil end
        ControlsFree.finishPlayerHoldTouch(id)
      end
      noteRawTouchReleased(self, id)
      restoreNativeZoomSuppression(self)
      return true
    end

    local grace = state.pinchGraceTouches and state.pinchGraceTouches[id]
    if grace then
      state.pinchGraceTouches[id] = nil
      local result
      if not grace.suppressed then
        -- A quick ordinary tap can end before the 0.20 s timer. Replay press +
        -- release now; this preserves normal Tap to Move semantics while still
        -- guaranteeing there was no press-time movement available to a pinch.
        dispatchPress(self, id, grace.startX, grace.startY, 0, 0, grace.pressure)
        result = dispatchRelease(self, id, x, y, dx, dy, pressure)
        state.stats.pinchGraceReleaseReplays =
          (state.stats.pinchGraceReleaseReplays or 0) + 1
      else
        result = true
      end
      noteRawTouchReleased(self, id)
      restoreNativeZoomSuppression(self)
      return result
    end

    local edge = state.systemEdgeTouches and state.systemEdgeTouches[id]
    if edge then
      local edgeStatus = ControlsFree.moveSystemEdgeTouch(self, id, x, y)
      edge = state.systemEdgeTouches[id]
      state.systemEdgeTouches[id] = nil
      local ph = state.playerHoldTouches and state.playerHoldTouches[id]

      if edgeStatus == "system" or (ph and ph.fired) then
        noteRawTouchReleased(self, id)
        ControlsFree.finishPlayerHoldTouch(id)
        restoreNativeZoomSuppression(self)
        return true
      end

      -- It was merely a tap/other gesture that happened to START near the
      -- system edge. Replay the deferred press at its original point, then
      -- release at the real endpoint so normal A/swipe/navigation semantics
      -- are preserved without any press-time false movement.
      dispatchPress(self, id, edge.startX, edge.startY, 0, 0, pressure)
      local result = dispatchRelease(self, id, x, y, dx, dy, pressure)
      noteRawTouchReleased(self, id)
      restoreNativeZoomSuppression(self)
      return result
    end

    local result = dispatchRelease(self, id, x, y, dx, dy, pressure)
    noteRawTouchReleased(self, id)
    restoreNativeZoomSuppression(self)
    return result
  end

  state.rawZoomGuardInstalled = true
  return true
end

local function suppressGesturePointer(id)
  local p = id and state.pointers[id]
  if not p then return end
  p.gestureSuppressed = "two_finger_gesture"
  p.manualSuppressed = true
end

local function beginTwoFingerGesture(game)
  if state.twoFingerGesture or not twoFingerFeatureEnabled() then return false end
  local ids = {}
  for id in pairs(state.gestureTouches or {}) do ids[#ids + 1] = id end
  if #ids < 2 then return false end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  local a, b = state.gestureTouches[ids[1]], state.gestureTouches[ids[2]]
  local dist = gestureDistance(a, b)
  if not dist then return false end

  installZoomGestureGuard(game)
  local gesture = {
    id1 = ids[1], id2 = ids[2], startDistance = dist, lastDistance = dist,
    direction = nil, fired = false, ended = false, blockZoom = true,
  }
  state.twoFingerGesture = gesture
  captureGestureZoom(game, gesture)
  suppressGesturePointer(gesture.id1)
  suppressGesturePointer(gesture.id2)
  if state.nav then cancelRoute("two_finger_gesture") end
  state.stats.twoFingerGestures = (state.stats.twoFingerGestures or 0) + 1
  return true
end

local function classifyTwoFingerGesture(game)
  local gesture = state.twoFingerGesture
  if not gesture or gesture.ended or gesture.direction then return end
  local a = state.gestureTouches[gesture.id1]
  local b = state.gestureTouches[gesture.id2]
  local dist = gestureDistance(a, b)
  if not dist then return end
  gesture.lastDistance = dist
  local threshold = math.max(TWO_FINGER_TRIGGER_UNITS,
                             (gesture.startDistance or dist) * TWO_FINGER_TRIGGER_RATIO)
  local delta = dist - (gesture.startDistance or dist)
  if math.abs(delta) < threshold then
    restoreGestureZoom(game, gesture)
    return
  end

  local direction = delta > 0 and "spread" or "pinch"
  gesture.direction = direction
  -- PINCH OR SPREAD owns the complete two-finger gesture. While selected,
  -- native pinch/spread zoom is disabled and the classified gesture is mapped
  -- directly to the corresponding Game Boy button.
  gesture.blockZoom = twoFingerFeatureEnabled()
  if state.nativeZoomSuppression then
    setNativeZoomSuppressionBlock(game, gesture.blockZoom)
  end
  if gesture.blockZoom then restoreGestureZoom(game, gesture) end

  if twoFingerFeatureEnabled() and direction == "spread" then
    mod.input:tap(game, "start")
    gesture.fired = true
    state.stats.gestureStartTriggers =
      (state.stats.gestureStartTriggers or 0) + 1
  elseif twoFingerFeatureEnabled() and direction == "pinch" then
    mod.input:tap(game, "select")
    gesture.fired = true
    state.stats.gestureSelectTriggers =
      (state.stats.gestureSelectTriggers or 0) + 1
  end
end

local function finishTwoFingerGesture(game, id)
  local gesture = state.twoFingerGesture
  if not gesture or (id ~= gesture.id1 and id ~= gesture.id2) then return end
  gesture.ended = true
  restoreGestureZoom(game, gesture)
  -- Do not drop the raw suppression latch here. Some platforms deliver the
  -- actual survey-zoom command after the touch release. raw touch tracking
  -- keeps the captured baseline alive for PINCH_ZOOM_GRACE_TICKS.
  gesture.blockZoom = false
end

local function maybeClearTwoFingerGesture(game)
  local gesture = state.twoFingerGesture
  if not gesture then return end
  if state.gestureTouches[gesture.id1] or state.gestureTouches[gesture.id2] then
    return
  end
  local suppression = state.nativeZoomSuppression
  if (gesture.zoomDirty or (suppression and suppression.dirty))
      and game and type(game.writeOptions) == "function" then
    pcall(function() game:writeOptions() end)
    if suppression then suppression.dirty = false end
  end
  state.twoFingerGesture = nil
end

local function trackTwoFingerPointer(game, ev)
  if not ev or ev.source ~= "touch" then return end
  -- Real mobile touches are already classified at Game:touch* before
  -- TouchControls can swallow either contact. Keep input.pointer only as a
  -- compatibility fallback if that raw bridge could not be installed.
  if state.rawZoomGuardInstalled then return end
  if not twoFingerFeatureEnabled() and not state.twoFingerGesture then return end
  state.gestureTouches = state.gestureTouches or {}
  local id = ev.id
  if ev.phase == "pressed" then
    state.gestureTouches[id] = { x = ev.x, y = ev.y }
    if state.twoFingerGesture then
      suppressGesturePointer(id)
    else
      beginTwoFingerGesture(game)
    end
  elseif ev.phase == "moved" then
    local t = state.gestureTouches[id]
    if t then t.x, t.y = ev.x, ev.y end
    if state.twoFingerGesture then
      suppressGesturePointer(id)
      classifyTwoFingerGesture(game)
      restoreGestureZoom(game, state.twoFingerGesture)
    end
  elseif ev.phase == "released" or ev.phase == "cancelled" then
    finishTwoFingerGesture(game, id)
    state.gestureTouches[id] = nil
    maybeClearTwoFingerGesture(game)
  end
end

-- Exact dialogue recognition. TextBox exposes isTextBox on its class, so this
-- does not guess from screen geometry or overworld lock state. An anchored
-- YES/NO ChoiceBox is also part of dialogue when a TextBox is immediately
-- underneath it on the stack.
function ControlsFree.dialogueActive(game)
  local stack = game and game.stack
  if not stack or type(stack.top) ~= "function" then return false end
  local ok, top = pcall(stack.top, stack)
  if not ok or not top then return false end
  if top.isTextBox == true then return true end
  local states = stack.states
  if top.anchor == "bottom" and type(states) == "table" and #states >= 2 then
    local under = states[#states - 1]
    if under and under.isTextBox == true then return true end
  end
  return false
end

function ControlsFree.hostOS()
  if not (love and love.system and type(love.system.getOS) == "function") then
    return nil
  end
  local ok, name = pcall(love.system.getOS)
  return ok and name or nil
end

function ControlsFree.mobileHost()
  local osName = ControlsFree.hostOS()
  return osName == "Android" or osName == "iOS"
end

function ControlsFree.desktopHost()
  local osName = ControlsFree.hostOS()
  return osName ~= "Android" and osName ~= "iOS" and osName ~= "NX"
end

-- PINCH OR SPREAD uses raw Game:touch* input so it can see both contacts before
-- TouchControls or input.pointer consume them. The first overworld finger is
-- therefore held briefly in a pairing grace window. This prevents the classic
-- race where Tap to Move starts walking on finger #1 and finger #2 then turns
-- the same physical gesture into START/SELECT.
function ControlsFree.rawTouchControlHit(game, x, y)
  local tc = game and game.touchControls
  if type(tc) ~= "table" or type(tc.hitTest) ~= "function" then return false end
  if type(tc.visible) == "function" then
    local okVisible, visible = pcall(tc.visible, tc)
    if okVisible and not visible then return false end
  end
  local ok, hit = pcall(tc.hitTest, tc, x, y)
  return ok and hit ~= nil
end

function ControlsFree.beginPinchGraceTouch(game, id, x, y, dx, dy, pressure)
  if id == nil or id == "mouse" or not ControlsFree.mobileHost()
      or not twoFingerFeatureEnabled() or state.twoFingerGesture
      or rawTouchCount() ~= 1 then
    return false
  end
  local free = overworldGate(game)
  if not free then return false end
  -- Do not add latency to the visible virtual D-pad/A/B/etc. Pinch tolerance is
  -- specifically for the world surface where Tap to Move would otherwise act
  -- immediately on the first finger.
  if ControlsFree.rawTouchControlHit(game, x, y) then return false end

  state.pinchGraceTouches = state.pinchGraceTouches or {}
  state.pinchGraceTouches[id] = {
    startX = x, startY = y, x = x, y = y,
    dx = dx or 0, dy = dy or 0, pressure = pressure,
    startedTick = state.tick, suppressed = false,
  }
  state.stats.pinchGraceCandidates = (state.stats.pinchGraceCandidates or 0) + 1
  return true
end

function ControlsFree.movePinchGraceTouch(id, x, y, dx, dy, pressure)
  local t = state.pinchGraceTouches and state.pinchGraceTouches[id]
  if not t then return false end
  t.x, t.y = x, y
  t.dx, t.dy = dx or t.dx or 0, dy or t.dy or 0
  if pressure ~= nil then t.pressure = pressure end
  return true
end

function ControlsFree.promotePinchGraceTouches(game)
  if not state.pinchGraceTouches or next(state.pinchGraceTouches) == nil then return end
  local press = state.rawTouchDispatchPress
  local move = state.rawTouchDispatchMove
  if type(press) ~= "function" then return end

  for id, t in pairs(state.pinchGraceTouches) do
    if t.suppressed then
      -- Keep the record until physical release so the raw wrapper knows this
      -- contact must stay swallowed for the whole two-finger gesture.
    elseif state.twoFingerGesture then
      t.suppressed = true
      t.suppressReason = "two_finger_gesture"
    elseif state.tick - (t.startedTick or state.tick) + 1
        >= ControlsFree.PINCH_FIRST_TOUCH_GRACE_TICKS then
      local free = overworldGate(game)
      if not free then
        t.suppressed = true
        t.suppressReason = "overworld_not_free"
      else
        state.pinchGraceTouches[id] = nil
        press(game, id, t.startX, t.startY, 0, 0, t.pressure)
        if type(move) == "function" and (t.x ~= t.startX or t.y ~= t.startY) then
          move(game, id, t.x, t.y, t.x - t.startX, t.y - t.startY, t.pressure)
        end
        state.stats.pinchGracePromotions =
          (state.stats.pinchGracePromotions or 0) + 1
      end
    end
  end
end

function ControlsFree.prunePinchGraceTouches()
  if not state.pinchGraceTouches or next(state.pinchGraceTouches) == nil then return end
  local touch = love and love.touch
  if type(touch) ~= "table" or type(touch.getTouches) ~= "function" then return end
  local ok, ids = pcall(touch.getTouches)
  if not ok or type(ids) ~= "table" then return end
  local active = {}
  for _, id in ipairs(ids) do active[id] = true end
  for id in pairs(state.pinchGraceTouches) do
    if not active[id] then
      state.pinchGraceTouches[id] = nil
      if state.rawZoomTouches then state.rawZoomTouches[id] = nil end
      state.stats.pinchGraceCancelled = (state.stats.pinchGraceCancelled or 0) + 1
    end
  end
end

-- There is no portable LÖVE callback that says "the OS has claimed this touch".
-- Instead, reserve only bare-overworld WORLD touches that START in the phone's
-- bottom system-gesture strip. A strongly upward, vertically dominant move is
-- discarded as a probable OS navigation gesture. Visible native controls are
-- detected earlier and bypass this guard entirely; UI/battle states do not enter
-- it. Other world contacts are promoted back into the normal Gen1Recomp path.
function ControlsFree.systemEdgeGuardEnabled(game)
  -- This guard exists only to prevent a probable phone Home/app-switch swipe
  -- from becoming a Tap-to-Move WORLD command. It must never reserve the
  -- application's own virtual controls or generic UI touches. Native controls
  -- are bypassed before this function is reached; overlays/battles fail the
  -- bare-overworld gate here and keep their normal touch stream.
  local free = overworldGate(game)
  return ControlsFree.mobileHost()
      and option("enabled", true) ~= false
      and free == true
end

function ControlsFree.touchWindowHeight()
  local h = state.frame and tonumber(state.frame.wh) or nil
  if (not h or h <= 0) and love and love.graphics
      and type(love.graphics.getDimensions) == "function" then
    local ok, _, gh = pcall(love.graphics.getDimensions)
    if ok then h = tonumber(gh) end
  end
  return h
end

function ControlsFree.beginSystemEdgeTouch(game, id, x, y)
  if id == nil or id == "mouse" or not ControlsFree.systemEdgeGuardEnabled(game) then
    return false
  end
  local h = ControlsFree.touchWindowHeight()
  if not h or h <= 0 then return false end
  local band = math.max(ControlsFree.SYSTEM_EDGE_START_BAND_MIN_UNITS,
    math.min(ControlsFree.SYSTEM_EDGE_START_BAND_MAX_UNITS,
      h * ControlsFree.SYSTEM_EDGE_START_BAND_RATIO))
  if y < h - band then return false end
  state.systemEdgeTouches = state.systemEdgeTouches or {}
  state.systemEdgeTouches[id] = {
    startX = x, startY = y, x = x, y = y, startedTick = state.tick,
    systemGesture = false,
  }
  state.stats.systemEdgeCandidates = (state.stats.systemEdgeCandidates or 0) + 1
  return true
end

-- Returns nil when this id is not reserved, otherwise "pending", "system"
-- or "promote". Promotion is intentionally conservative: a strong sideways
-- or downward move is clearly not the phone's bottom-up navigation gesture and
-- can be returned to gameplay immediately. Upward-ish motion stays reserved
-- until it either crosses the OS threshold or releases.
function ControlsFree.moveSystemEdgeTouch(game, id, x, y)
  local t = state.systemEdgeTouches and state.systemEdgeTouches[id]
  if not t then return nil end
  t.x, t.y = x, y
  if t.systemGesture then return "system" end
  local dx, dy = x - t.startX, y - t.startY
  local up = -dy
  local side = math.abs(dx)
  if up >= ControlsFree.SYSTEM_EDGE_UP_TRIGGER_UNITS
      and up >= side * ControlsFree.SYSTEM_EDGE_AXIS_RATIO then
    t.systemGesture = true
    local ph = state.playerHoldTouches and state.playerHoldTouches[id]
    if ph then ph.cancelled = true; ph.cancelReason = "system_edge_swipe" end
    state.stats.systemEdgeSwipesSuppressed =
      (state.stats.systemEdgeSwipesSuppressed or 0) + 1
    if state.nav then cancelRoute("system_edge_swipe") end
    return "system"
  end
  if dy >= ControlsFree.SYSTEM_EDGE_UP_TRIGGER_UNITS
      or (side >= ControlsFree.SYSTEM_EDGE_SIDE_ESCAPE_UNITS and side > math.max(0, up)) then
    state.stats.systemEdgeTouchesPromoted =
      (state.stats.systemEdgeTouchesPromoted or 0) + 1
    return "promote"
  end
  return "pending"
end

-- If the host/OS cancels a touch without routing a normal release callback,
-- LÖVE's active-touch list still lets us retire the reservation instead of
-- keeping stale state around. This is intentionally cleanup-only: disappearance
-- is treated as cancellation and never replays gameplay input.
function ControlsFree.pruneSystemEdgeTouches()
  if not state.systemEdgeTouches or next(state.systemEdgeTouches) == nil then return end
  local touch = love and love.touch
  if type(touch) ~= "table" or type(touch.getTouches) ~= "function" then return end
  local ok, ids = pcall(touch.getTouches)
  if not ok or type(ids) ~= "table" then return end
  local active = {}
  for _, id in ipairs(ids) do active[id] = true end
  for id in pairs(state.systemEdgeTouches) do
    if not active[id] then
      state.systemEdgeTouches[id] = nil
      local ph = state.playerHoldTouches and state.playerHoldTouches[id]
      if ph then ph.cancelled = true; ph.cancelReason = "touch_cancelled" end
      ControlsFree.finishPlayerHoldTouch(id)
    end
  end
end

-- DIALOG TOUCH CONTROL is intentionally broader than literal TextBox dialogue.
-- It is the mobile fallback controller for every game UI/state except the two
-- contexts that already have their own touch semantics:
--   * free overworld -> Tap to Move / Hold to Steer
--   * any BattleState in the stack -> BATTLE TOUCH CONTROL / native battle touch
-- This fail-open coverage means newly added menus, choice screens and overlays
-- automatically inherit release-A + swipe D-pad without needing a hard-coded
-- state-name allowlist.
function ControlsFree.dialogTouchSurfaceActive(game)
  local stack = game and game.stack
  if not stack or type(stack.top) ~= "function" then return false end

  -- A battle remains a battle even when a Party/Item/Choice/TextBox state is
  -- pushed above BattleState. DIALOG TOUCH CONTROL must never steal those.
  local states = stack.states
  if type(states) == "table" then
    for i = #states, 1, -1 do
      local st = states[i]
      if st and st.isBattle == true then return false end
    end
  end

  local ok, top = pcall(stack.top, stack)
  if not ok or not top then return false end
  if top.isBattle == true then return false end

  -- Only the bare overworld is excluded. Any overlay pushed above it is a UI
  -- surface and is deliberately covered by this catch-all control.
  if game.overworld and top == game.overworld then return false end
  return true
end

function ControlsFree.dialogTouchFeatureEnabled(game)
  return option("dialog_touch_control", false) == true
      and ControlsFree.mobileHost()
      and ControlsFree.dialogTouchSurfaceActive(game)
end


-- A BattleState can be covered by its own message box, choice box, party menu
-- or item screen.  The user is still "in battle" in all of those cases, so
-- inspect the complete state stack instead of only the top state.
function ControlsFree.battleActive(game)
  local stack = game and game.stack
  if not stack then return false end
  local states = stack.states
  if type(states) == "table" then
    for i = #states, 1, -1 do
      local st = states[i]
      if st and st.isBattle == true then return true end
    end
  end
  if type(stack.top) == "function" then
    local ok, top = pcall(stack.top, stack)
    if ok and top and top.isBattle == true then return true end
  end
  return false
end

function ControlsFree.battleTouchFeatureEnabled(game)
  return option("battle_touch_control", false) == true
      and ControlsFree.mobileHost()
      and ControlsFree.battleActive(game)
end

local function voxelCanvasToWindow(voxel3d, p)
  if not p then return nil end
  local frame = state.frame or {}
  local cw, ch
  if voxel3d and type(voxel3d.canvas) == "function" then
    local okC, canvas = pcall(voxel3d.canvas)
    if okC and canvas then
      local okW, w = pcall(canvas.getWidth, canvas)
      local okH, h = pcall(canvas.getHeight, canvas)
      if okW and okH then cw, ch = tonumber(w), tonumber(h) end
    end
  end
  cw, ch = cw or tonumber(frame.pw), ch or tonumber(frame.ph)
  local ww, wh = tonumber(frame.ww), tonumber(frame.wh)
  if not (cw and ch and ww and wh and cw > 0 and ch > 0 and ww > 0 and wh > 0) then
    return nil
  end
  local sy = p[2]
  if love and love.system and type(love.system.getOS) == "function" then
    local okOS, osName = pcall(love.system.getOS)
    if okOS and osName == "iOS" then sy = ch - sy end
  end
  return p[1] * ww / cw, sy * wh / ch
end

-- Hit the visible player rather than merely his world cell.  Flat rendering
-- uses the same live camera transform as tap targeting; Voxel mode projects a
-- short vertical segment through the player's cell so the whole billboard/body
-- is a practical one-second hold target, not only the feet pixel.
function ControlsFree.playerScreenHit(game, x, y)
  -- Hit-testing the avatar is useful beyond HOLD PLAYER SPRITE: short taps use
  -- the same visual hitbox to proxy the interaction surface directly in front
  -- of the player. The caller decides whether the hit means START-hold or tap.
  -- Keep this host-agnostic so desktop mouse Tap to Move gets the same occlusion
  -- fix; beginPlayerHoldTouch itself remains real-touch/mobile-only in practice.
  local free = overworldGate(game)
  if not free then return false end
  local cur = mod.world and mod.world:current()
  if not cur then return false end

  local scene = voxelContext()
  if scene and scene.voxel3d then
    local wx = (cur.x + 0.5) * TILE_SIZE
    local wz = (cur.y + 0.5) * TILE_SIZE
    local foot = projectedPoint(scene.voxel3d, wx, wz, 0.5)
    local head = projectedPoint(scene.voxel3d, wx, wz, 28)
    local fx, fy = voxelCanvasToWindow(scene.voxel3d, foot)
    local hx, hy = voxelCanvasToWindow(scene.voxel3d, head)
    if fx and hx then
      -- 24 LOVE units is large enough for a thumb but still local to the
      -- character.  Distance-to-segment naturally follows camera tilt/scale.
      if pointSegmentDistance2(x, y, fx, fy, hx, hy) <= 24 * 24 then return true end
    end
  end

  local view = state.view
  if view then
    local ppx, ppy = playerPixel(game, cur)
    local ow = game and game.overworld
    local cameraX = ow and ow.camera and tonumber(ow.camera.x)
      or (ppx - (view.worldW / 2 - 16))
    local cameraY = ow and ow.camera and tonumber(ow.camera.y)
      or (ppy - (view.worldH / 2 - 8))
    local canvasX = cur.x * TILE_SIZE + TILE_SIZE / 2 - cameraX
    local canvasY = cur.y * TILE_SIZE + TILE_SIZE / 2 - cameraY
    local cx = (view.ox + canvasX * view.scale) / math.max(view.dpiX or 1, 1e-6)
    local cy = (view.oy + canvasY * view.scale) / math.max(view.dpiY or 1, 1e-6)
    local tileW = TILE_SIZE * view.scale / math.max(view.dpiX or 1, 1e-6)
    local tileH = TILE_SIZE * view.scale / math.max(view.dpiY or 1, 1e-6)
    -- The sprite extends above its cell centre, so bias the hitbox upward.
    cy = cy - tileH * 0.35
    local halfW = math.max(16, tileW * 0.85)
    local halfH = math.max(22, tileH * 1.35)
    if math.abs(x - cx) <= halfW and math.abs(y - cy) <= halfH then return true end
  end

  -- Last compatibility fallback: if the renderer's exact screen transform is
  -- unavailable but the tap resolver still maps the contact to the player's
  -- current cell, treat it as the player.
  local tx, ty, tapCur = targetFromTap(game, x, y)
  return tapCur ~= nil and tapCur.mapId == cur.mapId and tx == cur.x and ty == cur.y
end

-- START-menu tap semantics: the menu is a generic Menu with startCloses=true
-- and an edge anchor. A release tap INSIDE its actually rendered box means A;
-- a tap OUTSIDE means B/close. Return nil for every other UI state so the
-- catch-all DIALOG behavior stays release-A there.
function ControlsFree.startMenuTapInside(game, x, y)
  local stack = game and game.stack
  if not stack or type(stack.top) ~= "function" then return nil end
  local okTop, top = pcall(stack.top, stack)
  if not okTop or type(top) ~= "table" or top.startCloses ~= true then return nil end
  local tx, ty, tw, th = tonumber(top.tx), tonumber(top.ty), tonumber(top.tw), tonumber(top.th)
  if not (tx and ty and tw and th and tw > 0 and th > 0) then return nil end

  local r = game.renderer
  local frame = state.frame or {}
  local ww, wh = tonumber(frame.ww), tonumber(frame.wh)
  if (not ww or not wh) and love and love.graphics
      and type(love.graphics.getDimensions) == "function" then
    local okDims, gw, gh = pcall(love.graphics.getDimensions)
    if okDims then ww, wh = tonumber(gw), tonumber(gh) end
  end
  if not (r and ww and wh and ww > 0 and wh > 0) then return nil end

  local dpiX, dpiY = tonumber(frame.dpiX) or 1, tonumber(frame.dpiY) or 1
  if dpiX <= 0 then dpiX = 1 end
  if dpiY <= 0 then dpiY = 1 end
  local up
  if type(r.uiScale) == "function" then
    local okScale, v = pcall(r.uiScale, r)
    if okScale then up = tonumber(v) end
  end
  if not up or up <= 0 then
    if type(r.fitScale) == "function" then
      local okScale, v = pcall(r.fitScale, r)
      if okScale then up = tonumber(v) end
    end
  end
  if not up or up <= 0 then return nil end

  local uiw, uih = 160, 144
  if type(r.uiSize) == "function" then
    local okSize, w, h = pcall(r.uiSize, r)
    if okSize and tonumber(w) and tonumber(h) then uiw, uih = tonumber(w), tonumber(h) end
  end
  local ux, uy = up / dpiX, up / dpiY
  local bx, by, bw, bh = tx * 8, ty * 8, tw * 8, th * 8
  local dx, dy
  if top.anchor == "topright" and not r.uiCentered and not r.uiAnchorHold then
    local gapR = (uiw - (bx + bw)) * ux
    dx = ww - gapR - bw * ux
    dy = by * uy
  else
    local pw = tonumber(frame.pw) or ww * dpiX
    local ph = tonumber(frame.ph) or wh * dpiY
    local uox = math.floor((pw - uiw * up) / 2) / dpiX
    local uoy = math.floor((ph - uih * up) / 2) / dpiY
    dx, dy = uox + bx * ux, uoy + by * uy
  end
  return x >= dx and y >= dy and x < dx + bw * ux and y < dy + bh * uy
end

function ControlsFree.beginDialogTouch(game, id, x, y)
  if id == nil or id == "mouse" or state.twoFingerGesture
      or not ControlsFree.dialogTouchFeatureEnabled(game) then
    return false
  end
  state.dialogTouches = state.dialogTouches or {}
  state.dialogTouches[id] = {
    startX = x, startY = y, x = x, y = y, startedTick = state.tick,
    suppressed = false, holdBCancelled = false, bFired = false,
  }
  return true
end

local function dialogSwipeDirection(dx, dy)
  if math.abs(dx) >= math.abs(dy) then
    return dx >= 0 and "right" or "left"
  end
  return dy >= 0 and "down" or "up"
end

function ControlsFree.moveDialogTouch(id, x, y)
  local t = state.dialogTouches and state.dialogTouches[id]
  if not t then return false end
  t.x, t.y = x, y
  if t.bFired then return true end
  local dx, dy = x - t.startX, y - t.startY
  if not t.holdBCancelled
      and dx * dx + dy * dy > ControlsFree.TOUCH_HOLD_B_MOVE_SLOP_UNITS * ControlsFree.TOUCH_HOLD_B_MOVE_SLOP_UNITS then
    -- Long-hold B is intentionally stricter than swipe. Once the finger has
    -- meaningfully wandered, returning near the origin later must not resurrect
    -- a B candidate.
    t.holdBCancelled = true
  end
  if not t.swipeDirection then
    if dx * dx + dy * dy >= DIALOG_SWIPE_TRIGGER_UNITS * DIALOG_SWIPE_TRIGGER_UNITS then
      -- Classification latches the instant a deliberate swipe is recognized.
      -- Returning the finger toward its start point later must never turn that
      -- already-recognized swipe back into an A tap on release.
      t.swipeDirection = dialogSwipeDirection(dx, dy)
    end
  end
  return true
end

function ControlsFree.finishDialogTouch(game, id, x, y, cancelled)
  local t = state.dialogTouches and state.dialogTouches[id]
  if not t then return false end
  state.dialogTouches[id] = nil
  t.x, t.y = x or t.x, y or t.y
  if cancelled or t.suppressed or not ControlsFree.dialogTouchFeatureEnabled(game) then return true end
  if t.bFired then return true end

  local dx, dy = (t.x or t.startX) - t.startX, (t.y or t.startY) - t.startY
  if not t.swipeDirection
      and dx * dx + dy * dy >= DIALOG_SWIPE_TRIGGER_UNITS * DIALOG_SWIPE_TRIGGER_UNITS then
    -- Some hosts can coalesce touch-move events; classify from the release
    -- displacement too so a fast swipe is not mistaken for a tap.
    t.swipeDirection = dialogSwipeDirection(dx, dy)
  end
  if t.swipeDirection then
    local btn = t.swipeDirection
    mod.input:tap(game, btn)
    state.stats.dialogSwipes = (state.stats.dialogSwipes or 0) + 1
    local statKey = "dialogSwipe" .. btn:sub(1, 1):upper() .. btn:sub(2)
    state.stats[statKey] = (state.stats[statKey] or 0) + 1
    return true
  end

  local insideStartMenu = ControlsFree.startMenuTapInside(game, t.startX, t.startY)
  if insideStartMenu == false then
    mod.input:tap(game, "b")
    state.stats.startMenuOutsideBTaps = (state.stats.startMenuOutsideBTaps or 0) + 1
    return true
  end
  mod.input:tap(game, "a")
  state.stats.dialogATaps = (state.stats.dialogATaps or 0) + 1
  if insideStartMenu == true then
    state.stats.startMenuInsideATaps = (state.stats.startMenuInsideATaps or 0) + 1
  end
  return true
end


-- BATTLE TOUCH CONTROL intentionally mirrors DIALOG TOUCH CONTROL: no Game
-- Boy input on touch-down, a stationary one-second hold can fire B, otherwise
-- sticky swipe/tap classification resolves exactly one action on release.  The raw Game:touch* bridge additionally owns the whole
-- contact while the battle is present, which is what prevents a 3D camera
-- drag from receiving the same swipe.
function ControlsFree.beginBattleTouch(game, id, x, y)
  if id == nil or id == "mouse" or state.twoFingerGesture
      or not ControlsFree.battleTouchFeatureEnabled(game) then
    return false
  end
  -- DIALOG TOUCH CONTROL excludes BattleState by contract, so there is no
  -- semantic overlap here. Keep this guard as a defensive single-owner check.
  if ControlsFree.dialogTouchFeatureEnabled(game) then return false end
  state.battleTouches = state.battleTouches or {}
  state.battleTouches[id] = {
    startX = x, startY = y, x = x, y = y, startedTick = state.tick,
    suppressed = false, holdBCancelled = false, bFired = false,
  }
  return true
end

function ControlsFree.moveBattleTouch(id, x, y)
  local t = state.battleTouches and state.battleTouches[id]
  if not t then return false end
  t.x, t.y = x, y
  if t.bFired then return true end
  local dx, dy = x - t.startX, y - t.startY
  if not t.holdBCancelled
      and dx * dx + dy * dy > ControlsFree.TOUCH_HOLD_B_MOVE_SLOP_UNITS * ControlsFree.TOUCH_HOLD_B_MOVE_SLOP_UNITS then
    t.holdBCancelled = true
  end
  if not t.swipeDirection then
    if dx * dx + dy * dy >= DIALOG_SWIPE_TRIGGER_UNITS * DIALOG_SWIPE_TRIGGER_UNITS then
      t.swipeDirection = dialogSwipeDirection(dx, dy)
    end
  end
  return true
end

function ControlsFree.finishBattleTouch(game, id, x, y, cancelled)
  local t = state.battleTouches and state.battleTouches[id]
  if not t then return false end
  state.battleTouches[id] = nil
  t.x, t.y = x or t.x, y or t.y
  if cancelled or t.suppressed or not ControlsFree.battleActive(game) then return true end
  if t.bFired then return true end

  local dx, dy = (t.x or t.startX) - t.startX, (t.y or t.startY) - t.startY
  if not t.swipeDirection
      and dx * dx + dy * dy >= DIALOG_SWIPE_TRIGGER_UNITS * DIALOG_SWIPE_TRIGGER_UNITS then
    t.swipeDirection = dialogSwipeDirection(dx, dy)
  end
  if t.swipeDirection then
    local btn = t.swipeDirection
    mod.input:tap(game, btn)
    state.stats.battleSwipes = (state.stats.battleSwipes or 0) + 1
    local statKey = "battleSwipe" .. btn:sub(1, 1):upper() .. btn:sub(2)
    state.stats[statKey] = (state.stats[statKey] or 0) + 1
    return true
  end

  mod.input:tap(game, "a")
  state.stats.battleATaps = (state.stats.battleATaps or 0) + 1
  return true
end

-- A stationary one-finger hold is the B counterpart to release-A. The two
-- contexts keep separate touch tables and counters, so enabling DIALOG does
-- not affect battles and enabling BATTLE does not affect non-battle UI.
function ControlsFree.fireHoldBForTouches(game, touches, active, statKey)
  for _, t in pairs(touches or {}) do
    if not t.bFired and not t.suppressed and not t.holdBCancelled then
      if not active(game) or state.twoFingerGesture then
        t.holdBCancelled = true
      elseif state.tick - (t.startedTick or state.tick) + 1 >= ControlsFree.TOUCH_HOLD_B_TICKS then
        mod.input:tap(game, "b")
        t.bFired = true
        state.stats[statKey] = (state.stats[statKey] or 0) + 1
      end
    end
  end
end

function ControlsFree.holdBTouchTick(game)
  ControlsFree.fireHoldBForTouches(game, state.dialogTouches,
    ControlsFree.dialogTouchFeatureEnabled, "dialogBHoldTriggers")
  ControlsFree.fireHoldBForTouches(game, state.battleTouches,
    ControlsFree.battleTouchFeatureEnabled, "battleBHoldTriggers")
end

function ControlsFree.beginPlayerHoldTouch(game, id, x, y)
  if id == nil or id == "mouse"
      or startSelectTouchMode() ~= "hold_player_sprite"
      or ControlsFree.dialogueActive(game) or state.twoFingerGesture then
    return false
  end
  if not ControlsFree.playerScreenHit(game, x, y) then return false end
  state.playerHoldTouches = state.playerHoldTouches or {}
  state.playerHoldTouches[id] = {
    startX = x, startY = y, x = x, y = y, pressTick = state.tick,
    cancelled = false, fired = false,
  }
  return true
end

function ControlsFree.movePlayerHoldTouch(id, x, y)
  local t = state.playerHoldTouches and state.playerHoldTouches[id]
  if not t then return false end
  t.x, t.y = x, y
  if not t.cancelled and not t.fired then
    local dx, dy = x - t.startX, y - t.startY
    if dx * dx + dy * dy > PLAYER_HOLD_MOVE_SLOP_UNITS * PLAYER_HOLD_MOVE_SLOP_UNITS then
      t.cancelled = true
      t.cancelReason = "moved"
    end
  end
  return true
end

function ControlsFree.finishPlayerHoldTouch(id)
  local t = state.playerHoldTouches and state.playerHoldTouches[id]
  if not t then return false end
  state.playerHoldTouches[id] = nil
  return true
end

function ControlsFree.playerHoldStartTick(game)
  if startSelectTouchMode() ~= "hold_player_sprite" then return end
  for id, t in pairs(state.playerHoldTouches or {}) do
    if not t.cancelled and not t.fired
        and state.tick - (t.pressTick or state.tick) + 1 >= PLAYER_HOLD_START_TICKS then
      local free = overworldGate(game)
      if not free or state.twoFingerGesture then
        t.cancelled = true
        t.cancelReason = "busy"
      else
        mod.input:tap(game, "start")
        t.fired = true
        state.stats.playerHoldStartTriggers =
          (state.stats.playerHoldStartTriggers or 0) + 1
        local p = state.pointers and state.pointers[id]
        if p then
          p.playerHoldCandidate = false
          p.gestureSuppressed = "player_hold_start"
          p.manualSuppressed = true
        end
        if state.nav then cancelRoute("player_hold_start") end
      end
    end
  end
end

-- Compatibility fallback for builds where the raw Game:touch* bridge cannot
-- be installed. Current Gen1Recomp is handled earlier by installRawPinchZoomGuard;
-- this TouchControls seam preserves the same release-only tap/swipe semantics
-- for catch-all non-overworld UI and battle control if a future/older host
-- routes a virtual-control-zone touch here first.
function ControlsFree.installTouchDialogueBridge(game)
  if state.touchDialogueBridgeInstalled or not game then return false end
  local tc = game.touchControls
  if type(tc) ~= "table" or type(tc.touchpressed) ~= "function"
      or type(tc.touchmoved) ~= "function" or type(tc.touchreleased) ~= "function" then
    return false
  end
  local pressed0, moved0, released0 = tc.touchpressed, tc.touchmoved, tc.touchreleased
  state.touchDialogueBridgeOriginal = {
    touchpressed = pressed0, touchmoved = moved0, touchreleased = released0,
  }
  tc.touchpressed = function(self, id, x, y)
    -- Fallback parity with the raw Game bridge: a contact that STARTS on a
    -- visible virtual control belongs to native TouchControls, never this mod.
    if ControlsFree.rawTouchControlHit(game, x, y) then
      state.nativeControlOwnedTouches = state.nativeControlOwnedTouches or {}
      if id ~= nil then state.nativeControlOwnedTouches[id] = true end
      return pressed0(self, id, x, y)
    end
    if ControlsFree.beginDialogTouch(game, id, x, y) then return true end
    if ControlsFree.beginBattleTouch(game, id, x, y) then return true end
    if ControlsFree.battleTouchFeatureEnabled(game) and id ~= nil and id ~= "mouse" then
      return true
    end
    return pressed0(self, id, x, y)
  end
  tc.touchmoved = function(self, id, x, y)
    if state.nativeControlOwnedTouches and state.nativeControlOwnedTouches[id] then
      return moved0(self, id, x, y)
    end
    if ControlsFree.moveDialogTouch(id, x, y) then return true end
    if ControlsFree.moveBattleTouch(id, x, y) then return true end
    if ControlsFree.battleTouchFeatureEnabled(game) and id ~= nil and id ~= "mouse" then
      return true
    end
    return moved0(self, id, x, y)
  end
  tc.touchreleased = function(self, id, x, y)
    if state.nativeControlOwnedTouches and state.nativeControlOwnedTouches[id] then
      local result = released0(self, id, x, y)
      state.nativeControlOwnedTouches[id] = nil
      return result
    end
    if state.dialogTouches and state.dialogTouches[id] then
      ControlsFree.finishDialogTouch(game, id, x, y, false)
      return true
    end
    if state.battleTouches and state.battleTouches[id] then
      ControlsFree.finishBattleTouch(game, id, x, y, false)
      return true
    end
    if ControlsFree.battleTouchFeatureEnabled(game) and id ~= nil and id ~= "mouse" then
      return true
    end
    return released0(self, id, x, y)
  end
  state.touchDialogueBridgeInstalled = true
  return true
end

function ControlsFree.shakeState()
  if state.shake then return state.shake end
  state.shake = {
    backend = nil, attempted = false, unavailableCounted = false,
    accel = nil, gyro = nil, gravity = nil, warmup = 0,
    impulseArmed = true, lastImpulse = nil, cooldownUntil = 0,
    lastStrength = 0,
  }
  return state.shake
end

function ControlsFree.initLoveSensorBackend(sh)
  local sensor = love and love.sensor
  if type(sensor) ~= "table" or type(sensor.hasSensor) ~= "function"
      or type(sensor.setEnabled) ~= "function"
      or type(sensor.getData) ~= "function" then
    return false
  end
  local function enable(kind)
    local okHas, has = pcall(sensor.hasSensor, kind)
    if not okHas or not has then return false end
    local okEnable = pcall(sensor.setEnabled, kind, true)
    return okEnable
  end
  local accel = enable("accelerometer")
  local gyro = enable("gyroscope")
  if not accel and not gyro then return false end
  sh.backend = "love.sensor"
  sh.loveSensor = sensor
  sh.accelAvailable = accel
  sh.gyroAvailable = gyro
  return true
end

-- LÖVE 11.5 has no love.sensor module. Gen1Recomp also intentionally sets
-- t.accelerometerjoystick=false on Android, so reopening the old joystick
-- path would resurrect the tilt-to-walk bug. SDL2 already ships a separate
-- sensor subsystem; initialize only that subsystem and read it directly.
function ControlsFree.initSdlSensorBackend(sh)
  if ControlsFree.hostOS() ~= "Android" then return false end
  local okFfi, ffi = pcall(require, "ffi")
  if not okFfi or not ffi then return false end
  pcall(ffi.cdef, [[
    typedef struct TTM_SDL_Sensor TTM_SDL_Sensor;
    int SDL_InitSubSystem(unsigned int flags);
    int SDL_NumSensors(void);
    int SDL_SensorGetDeviceType(int device_index);
    TTM_SDL_Sensor *SDL_SensorOpen(int device_index);
    int SDL_SensorGetData(TTM_SDL_Sensor *sensor, float *data, int num_values);
    void SDL_SensorUpdate(void);
    void SDL_SensorClose(TTM_SDL_Sensor *sensor);
  ]])
  local okInit, rc = pcall(function()
    return tonumber(ffi.C.SDL_InitSubSystem(ControlsFree.SDL_INIT_SENSOR))
  end)
  if not okInit or not rc or rc < 0 then return false end

  local okCount, count = pcall(function() return tonumber(ffi.C.SDL_NumSensors()) end)
  if not okCount or not count or count <= 0 then return false end
  local accel, gyro
  for i = 0, count - 1 do
    local okType, typ = pcall(function()
      return tonumber(ffi.C.SDL_SensorGetDeviceType(i))
    end)
    if okType and typ == ControlsFree.SDL_SENSOR_ACCEL and accel == nil then
      local okOpen, ptr = pcall(function() return ffi.C.SDL_SensorOpen(i) end)
      if okOpen and ptr ~= nil then accel = ptr end
    elseif okType and typ == ControlsFree.SDL_SENSOR_GYRO and gyro == nil then
      local okOpen, ptr = pcall(function() return ffi.C.SDL_SensorOpen(i) end)
      if okOpen and ptr ~= nil then gyro = ptr end
    end
  end
  if accel == nil and gyro == nil then return false end
  sh.backend = "SDL2 sensor FFI"
  sh.ffi = ffi
  sh.accel = accel
  sh.gyro = gyro
  sh.accelBuf = accel ~= nil and ffi.new("float[3]") or nil
  sh.gyroBuf = gyro ~= nil and ffi.new("float[3]") or nil
  sh.accelAvailable = accel ~= nil
  sh.gyroAvailable = gyro ~= nil
  return true
end

function ControlsFree.ensureMotionSensors()
  local sh = ControlsFree.shakeState()
  if sh.backend then return true end
  if sh.attempted then return false end
  sh.attempted = true
  state.stats.sensorInitAttempts = (state.stats.sensorInitAttempts or 0) + 1
  if ControlsFree.initLoveSensorBackend(sh) or ControlsFree.initSdlSensorBackend(sh) then
    return true
  end
  if not sh.unavailableCounted then
    sh.unavailableCounted = true
    state.stats.sensorUnavailable = (state.stats.sensorUnavailable or 0) + 1
  end
  return false
end

function ControlsFree.readMotionSensors()
  local sh = ControlsFree.shakeState()
  if not sh.backend and not ControlsFree.ensureMotionSensors() then return nil, nil end
  local accel, gyro
  if sh.backend == "love.sensor" then
    if sh.accelAvailable then
      local ok, x, y, z = pcall(sh.loveSensor.getData, "accelerometer")
      if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        accel = { x, y, z }
      end
    end
    if sh.gyroAvailable then
      local ok, x, y, z = pcall(sh.loveSensor.getData, "gyroscope")
      if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        gyro = { x, y, z }
      end
    end
  elseif sh.backend == "SDL2 sensor FFI" then
    local ffi = sh.ffi
    pcall(function() ffi.C.SDL_SensorUpdate() end)
    if sh.accel ~= nil and sh.accelBuf then
      local ok, rc = pcall(function()
        return tonumber(ffi.C.SDL_SensorGetData(sh.accel, sh.accelBuf, 3))
      end)
      if ok and rc == 0 then
        accel = { tonumber(sh.accelBuf[0]), tonumber(sh.accelBuf[1]),
                  tonumber(sh.accelBuf[2]) }
      end
    end
    if sh.gyro ~= nil and sh.gyroBuf then
      local ok, rc = pcall(function()
        return tonumber(ffi.C.SDL_SensorGetData(sh.gyro, sh.gyroBuf, 3))
      end)
      if ok and rc == 0 then
        gyro = { tonumber(sh.gyroBuf[0]), tonumber(sh.gyroBuf[1]),
                 tonumber(sh.gyroBuf[2]) }
      end
    end
  end
  return accel, gyro
end

function ControlsFree.vecMagnitude(v)
  if not v then return 0 end
  return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
end

function ControlsFree.normalizedVec(v, mag)
  if not v or not mag or mag <= 0 then return nil end
  return { v[1] / mag, v[2] / mag, v[3] / mag }
end

function ControlsFree.vecDot(a, b)
  if not a or not b then return 1 end
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

function ControlsFree.shakeInputTick(game)
  if option("shake_b", true) == false or not ControlsFree.mobileHost() then return end
  local accel, gyro = ControlsFree.readMotionSensors()
  if not accel and not gyro then return end
  local sh = ControlsFree.shakeState()

  local linearAccel
  if accel then
    if not sh.gravity then
      sh.gravity = { accel[1], accel[2], accel[3] }
    else
      local a = ControlsFree.SHAKE_GRAVITY_ALPHA
      for i = 1, 3 do
        sh.gravity[i] = sh.gravity[i] * (1 - a) + accel[i] * a
      end
    end
    linearAccel = {
      accel[1] - sh.gravity[1], accel[2] - sh.gravity[2],
      accel[3] - sh.gravity[3],
    }
  end

  sh.warmup = (sh.warmup or 0) + 1
  local accelMag = ControlsFree.vecMagnitude(linearAccel)
  local gyroMag = ControlsFree.vecMagnitude(gyro)
  local accelScore = accelMag / ControlsFree.SHAKE_ACCEL_THRESHOLD
  local gyroScore = gyroMag / ControlsFree.SHAKE_GYRO_THRESHOLD
  local source, motion, mag, score
  if gyroScore >= accelScore and gyro then
    source, motion, mag, score = "gyro", gyro, gyroMag, gyroScore
  else
    source, motion, mag, score = "accel", linearAccel, accelMag, accelScore
  end
  sh.lastStrength = score or 0

  if (score or 0) < ControlsFree.SHAKE_RESET_RATIO then sh.impulseArmed = true end
  if sh.warmup < ControlsFree.SHAKE_WARMUP_TICKS then return end
  if state.tick < (sh.cooldownUntil or 0) then return end

  local last = sh.lastImpulse
  if last and state.tick - last.tick > ControlsFree.SHAKE_MAX_IMPULSE_TICKS then
    sh.lastImpulse = nil
    last = nil
  end
  if (score or 0) < 1 or not sh.impulseArmed or not motion or mag <= 0 then return end
  sh.impulseArmed = false
  local impulse = {
    tick = state.tick, source = source,
    vector = ControlsFree.normalizedVec(motion, mag), strength = score,
  }

  if last and last.source == impulse.source then
    local dt = impulse.tick - last.tick
    if dt >= ControlsFree.SHAKE_MIN_IMPULSE_TICKS and dt <= ControlsFree.SHAKE_MAX_IMPULSE_TICKS
        and ControlsFree.vecDot(last.vector, impulse.vector) <= ControlsFree.SHAKE_REVERSAL_DOT then
      mod.input:tap(game, "b")
      state.stats.shakeBTriggers = (state.stats.shakeBTriggers or 0) + 1
      sh.cooldownUntil = state.tick + ControlsFree.SHAKE_COOLDOWN_TICKS
      sh.lastImpulse = nil
      return
    end
  end
  sh.lastImpulse = impulse
end

local function pointerOverTouchControl(game, x, y)
  local tc = game and game.touchControls
  if not tc or type(tc.hitTest) ~= "function" then return false end
  if type(tc.visible) == "function" then
    local okVisible, visible = pcall(tc.visible, tc)
    if okVisible and not visible then return false end
  end
  local ok, hit = pcall(tc.hitTest, tc, x, y)
  return ok and hit ~= nil
end

local function suppressCurrentGesture(reason)
  local id = state.tapOwner
  local p = id and state.pointers[id]
  if not p or p.ignored then return false end
  p.gestureSuppressed = reason or true
  p.manualSuppressed = true
  return true
end

pointerForGesture = function(gestureId)
  if gestureId == nil then return nil end
  for _, p in pairs(state.pointers) do
    if p and not p.ignored and p.gestureId == gestureId then return p end
  end
  return nil
end

gestureIsDown = function(gestureId)
  return pointerForGesture(gestureId) ~= nil
end

-- An interaction may be selected on the initial press so movement begins
-- immediately. Hold promotion keeps NPC interactions armed (A is release-gated)
-- but converts fixed surfaces such as PCs/signs into movement-only approaches.
-- Subsequent continuous samples can still select an NPC as a semantic target.
local function disarmInteractionForGesture(gestureId, reason)
  local nav = state.nav
  if not nav or gestureId == nil or nav.interactionGestureId ~= gestureId then
    return false
  end

  local changed = false
  -- NPCs are now valid semantic Hold-to-Steer targets. Reaching one while
  -- the finger is down waits for release, so there is no risk of an unwanted
  -- A press. Fixed surfaces (PC/sign/etc.) keep the old movement-only hold
  -- behavior.
  if nav.interaction and nav.interaction.kind == "entity" then
    return false
  end
  if nav.interaction then
    nav.interaction = nil
    nav.goalKind = "move"
    -- buildInteractionPath already chose a legal approach cell as targetX/Y.
    -- Keep walking there; the actual entity/surface is no longer an A target.
    nav.requestedMapId = nav.mapId
    nav.requestedX, nav.requestedY = nav.targetX, nav.targetY
    changed = true
  end
  if nav.crossInteraction then
    if nav.crossInteraction.kind == "entity" then return false end
    nav.crossInteraction = nil
    if nav.goalKind == "cross_interact" then nav.goalKind = "cross_move" end
    changed = true
  end

  nav.interactionGestureId = nil
  nav.interactionRequiresRelease = nil
  if changed then
    state.stats.interactionHoldDisarms =
      (state.stats.interactionHoldDisarms or 0) + 1
    if nav.phase == "WAITING_INTERACTION_RELEASE" then
      setPhase(nav, "WALKING", reason or "interaction_disarmed")
    end
  end
  return changed
end

-- Gameplay touch/mouse outside virtual controls. TouchControls has first
-- refusal in Game before input.pointer, so its D-pad/A/B/START/SELECT cannot
-- become destinations. One world pointer owns navigation at a time.
--
-- test11 changes the gesture model fundamentally: PRESS starts navigation
-- immediately. The old TAP/HOLD delay no longer postpones movement; it only
-- decides when a still-held pointer starts continuous screen-space retargeting.
-- Interactive destinations are armed on press but may fire A only after this
-- exact gesture has been released.
mod.hooks:wrap("input.pointer", function(nextFn, game, ev)
  state.game = game or state.game
  local result = nextFn(game, ev)
  if not ev then return result end
  -- Respect another pointer consumer deeper in the chain. If it claims this
  -- contact, retire any local gesture record rather than responding as well.
  if result == true then
    -- A claimed non-left mouse button is unrelated to an LMB navigation
    -- gesture even though Gen1Recomp reports both under id "mouse".
    if ev.source == "mouse" and ev.button and ev.button ~= 1 then
      return result
    end
    -- If another pointer consumer takes over mid-gesture, retire our
    -- two-finger bookkeeping too. Otherwise a swallowed release could leave
    -- the zoom guard armed after the contact belongs to somebody else.
    if state.gestureTouches and state.gestureTouches[ev.id] then
      finishTwoFingerGesture(game, ev.id)
      state.gestureTouches[ev.id] = nil
      maybeClearTwoFingerGesture(game)
    end
    state.pointers[ev.id] = nil
    if state.tapOwner == ev.id then state.tapOwner = nil end
    return result
  end
  if option("enabled", true) == false then return result end

  -- Mouse shortcuts are independent from mouse walking. Only LMB is ever
  -- allowed into navigation pointer state. Gen1Recomp exposes every physical
  -- mouse button under the same pointer id ("mouse"), so non-left releases
  -- must return before generic pointer cleanup or they could cancel an LMB walk.
  if ev.source == "mouse" and ev.button and ev.button ~= 1 then
    if ev.button == 4 or ev.button == 5 then
      local mode = tostring(option("mouse_side_buttons", "off") or "off")
      if mode ~= "off" then
        if ev.phase == "pressed" then
          local mapped
          if mode == "on_flipped" then
            mapped = ev.button == 5 and "select" or "start"
          else
            -- Normal: MOUSE 5 = START, MOUSE 4 = SELECT.
            mapped = ev.button == 5 and "start" or "select"
          end
          mod.input:tap(game, mapped)
          state.stats.mouseSideButtonTaps =
            (state.stats.mouseSideButtonTaps or 0) + 1
          state.stats["mouseSide_" .. mapped] =
            (state.stats["mouseSide_" .. mapped] or 0) + 1
          return true
        elseif ev.phase == "released" then
          return true
        end
      end
      return result
    end

    if ev.button == 2 and ControlsFree.desktopHost()
        and option("desktop_mouse_ab", false) == true then
      if ev.phase == "pressed" then
        mod.input:tap(game, "b")
        state.stats.desktopBTaps = (state.stats.desktopBTaps or 0) + 1
        return true
      elseif ev.phase == "released" then
        return true
      end
    end
    return result
  end

  -- Optional desktop click mapping: LMB=A on UI; bare-overworld LMB remains
  -- independently controlled by MOUSE WALK CONTROL.
  if ev.phase == "pressed" and ev.source == "mouse" and ev.button == 1
      and ControlsFree.desktopHost()
      and option("desktop_mouse_ab", false) == true then
    local stack = game and game.stack
    local top = stack and type(stack.top) == "function" and stack:top() or nil
    if top and top ~= game.overworld then
      mod.input:tap(game, "a")
      state.stats.desktopATaps = (state.stats.desktopATaps or 0) + 1
      return true
    end
  end

  local eligible = ev.source == "touch"
    or (ev.source == "mouse" and ev.button == 1 and option("mouse", false) == true)
  local id = ev.id

  if ev.phase == "pressed" then
    if eligible then
      local owns = state.tapOwner == nil and state.twoFingerGesture == nil
      if owns then state.tapOwner = id end
      if owns then state.gestureSerial = (state.gestureSerial or 0) + 1 end
      local p = {
        startX = ev.x, startY = ev.y,
        x = ev.x, y = ev.y,
        pressTick = state.tick,
        lastRetargetTick = state.tick,
        holdActive = false,
        feedbackShown = owns,
        ignored = not owns,
        gestureId = owns and state.gestureSerial or nil,
      }
      state.pointers[id] = p
      local playerHold = state.playerHoldTouches and state.playerHoldTouches[id]
      if playerHold and not playerHold.cancelled and not playerHold.fired then
        p.playerHoldCandidate = true
        p.feedbackShown = false
      end
      trackTwoFingerPointer(game, ev)
      if state.twoFingerGesture then
        suppressGesturePointer(id)
        owns = false
        p.ignored = true
      end

      -- The first route is acquired NOW, not after TAP/HOLD delay or release,
      -- except for a touch that began on the visible player: that one reserves
      -- one second for HOLD PLAYER -> START and becomes normal navigation only
      -- if the finger moves far enough to cancel the hold candidate.
      -- A target may carry an interaction, but interactionAtDestination gates
      -- A on this gesture no longer being down.
      if owns and not p.playerHoldCandidate
          and not pointerOverTouchControl(game, ev.x, ev.y) then
        local accepted = startRoute(game, ev.x, ev.y, false, true, p.gestureId)
        p.initialAccepted = accepted and true or false
        if accepted then
          state.stats.immediatePressRoutes =
            (state.stats.immediatePressRoutes or 0) + 1
        end
      end
    end
  elseif ev.phase == "moved" then
    local p = state.pointers[id]
    if p then p.x, p.y = ev.x, ev.y end
    trackTwoFingerPointer(game, ev)
    if p and p.playerHoldCandidate then
      local ph = state.playerHoldTouches and state.playerHoldTouches[id]
      if not ph or ph.cancelled then
        p.playerHoldCandidate = false
        p.pressTick = state.tick
        p.lastRetargetTick = state.tick
        if not p.ignored and not p.gestureSuppressed
            and not pointerOverTouchControl(game, ev.x, ev.y) then
          local accepted = startRoute(game, ev.x, ev.y, false, true, p.gestureId)
          p.initialAccepted = accepted and true or false
          if accepted then
            state.stats.immediatePressRoutes =
              (state.stats.immediatePressRoutes or 0) + 1
          end
        end
      end
    end
  elseif ev.phase == "released" then
    local p = state.pointers[id]
    if p then p.x, p.y = ev.x, ev.y end
    trackTwoFingerPointer(game, ev)
    if p and not p.ignored and not p.gestureSuppressed then
      -- HOLD PLAYER SPRITE reserves a stationary avatar touch for START. If it
      -- is released before the one-second START threshold, reinterpret that
      -- short touch now as an ordinary avatar tap. startRoute's avatar proxy
      -- can then target the interaction/door directly in front of the player.
      if p.playerHoldCandidate then
        local ph = state.playerHoldTouches and state.playerHoldTouches[id]
        if ph and not ph.fired and not ph.cancelled
            and not pointerOverTouchControl(game, p.startX, p.startY) then
          local accepted = startRoute(game, p.startX, p.startY, false, true, p.gestureId)
          p.initialAccepted = accepted and true or false
          if accepted then
            state.stats.immediatePressRoutes =
              (state.stats.immediatePressRoutes or 0) + 1
          end
        end
      elseif p.holdActive and not state.exitJourney and not p.stickySemantic then
        -- Pin an ordinary steering gesture to its final screen position.
        -- A semantic door/NPC selection is different: RELEASE is not another
        -- steering sample, it only ends the gesture (and for NPCs authorizes
        -- the already-armed interaction). Periodic held-input ticks are what
        -- may replace a sticky door with a genuinely legal movement target.
        if not pointerOverTouchControl(game, ev.x, ev.y) then
          startRoute(game, ev.x, ev.y, true, false, p.gestureId)
        end
      end
      -- Non-hold release intentionally does NOT start a second route. The
      -- press already did that; removing the pointer is itself the signal that
      -- an armed interaction may execute when its approach cell is reached.
    end
    state.pointers[id] = nil
    if state.tapOwner == id then state.tapOwner = nil end
  elseif ev.phase == "cancelled" then
    local p = state.pointers[id]
    trackTwoFingerPointer(game, ev)
    if state.playerHoldTouches and state.playerHoldTouches[id] then
      state.playerHoldTouches[id] = nil
    end
    state.pointers[id] = nil
    if state.tapOwner == id then state.tapOwner = nil end
    -- A cancelled OS gesture is neither a tap nor a deliberate hold release.
    -- Do not let disappearing pointer state accidentally authorize A.
    if p and not p.ignored and state.nav then
      cancelRoute("pointer_cancelled")
    end
  end

  return result
end)

local function pointerSteeringTick(game)
  -- A semantic "leave this interior" command owns its route across internal
  -- floors. The original held finger must not reinterpret the new room camera
  -- every performance tick and accidentally replace that journey. A fresh
  -- pointer press still supersedes it immediately in startRoute.
  if state.exitJourney then return end
  if option("hold_steer", true) == false then return end
  local id = state.tapOwner
  local p = id and state.pointers[id]
  if not p or p.ignored or p.manualSuppressed or p.gestureSuppressed then return end
  if p.playerHoldCandidate then return end
  if pointerOverTouchControl(game, p.x, p.y) then return end
  local age = state.tick - (p.pressTick or state.tick)
  local startTicks = holdSteerDelayTicks()
  if age < startTicks then return end

  -- HOLD STEER DELAY controls only when continuous steering begins. The
  -- initial destination has already been walking since pointer press.
  if p.holdActive then
    if state.tick - (p.lastRetargetTick or p.pressTick or 0)
        < holdRefreshTicks() then
      return
    end
  else
    p.holdActive = true
    disarmInteractionForGesture(p.gestureId, "hold_steer")
  end

  p.lastRetargetTick = state.tick
  local accepted = startRoute(game, p.x, p.y, true, false, p.gestureId)
  if accepted then
    state.stats.holdRetargets = state.stats.holdRetargets + 1
  end
end

-- Fixed-step input seam: directions pressed here affect the same gameplay tick.
mod.hooks:wrap("input.step", function(nextFn, game, dt)
  restoreNativeZoomSuppression(game)
  if state.twoFingerGesture then
    restoreGestureZoom(game, state.twoFingerGesture)
  end
  if option("enabled", true) ~= false then
    ControlsFree.shakeInputTick(game)
  end
  -- Clean up raw reservations if the mobile OS consumed/cancelled a physical
  -- touch without a normal release callback.
  ControlsFree.pruneSystemEdgeTouches()
  ControlsFree.prunePinchGraceTouches()
  -- Let an ordinary first world touch through once the PINCH OR SPREAD pairing
  -- tolerance expires. If a second finger arrived, beginRawTwoFingerGesture has
  -- already marked the candidate suppressed and nothing is replayed.
  ControlsFree.promotePinchGraceTouches(game)
  -- DIALOG/BATTLE TOUCH CONTROL each include their own stationary 1-second
  -- hold -> B gesture. This is independent from overworld Tap to Move.
  ControlsFree.holdBTouchTick(game)
  -- START/SELECT TOUCH CONTROL is independent from the TAP TO MOVE switch.
  -- Its own OFF/HOLD/PINCH-SPREAD choice is authoritative.
  ControlsFree.playerHoldStartTick(game)
  pointerSteeringTick(game)
  navigationTick(game)
  return nextFn(game, dt)
end)

-- Observe the FINAL collision verdict.  Dynamic NPCs are temporary obstacles;
-- stationary entities become blocked cells; static tile/elevation failures are
-- learned as directed edges.  Every case replans instead of repeatedly bonking.
mod.hooks:wrap("movement.collision", function(nextFn, allowed, ctx)
  local result = nextFn(allowed, ctx)
  local nav = state.nav
  local game = state.game
  if not nav or not ctx or not game or not game.overworld then return result end

  local player = game.overworld.player
  if ctx.mover ~= player then return result end

  -- A different direction reaching the player's collision path means another
  -- input source won.  Manual control always has priority over autowalk.
  if nav.holdDir and ctx.dir ~= nav.holdDir then
    cancelRoute("manual_override")
    return result
  end

  -- Some Gen I exit warp records sit on collision cells that are not in the
  -- tileset's ordinary walkable list. mapOverview therefore reports them as
  -- blank/solid and vanilla Collision.canMove returns reason="tile" when the
  -- player tries to WALK BACK onto the source after leaving it. A validated
  -- Tap-to-Move EXIT route may override only that exact final step.
  --
  -- Safety constraints:
  --   * exact active EXIT goal only (never an intermediate node),
  --   * an actual warp record must exist on the destination cell,
  --   * only the engine's non-walkable-tile rejection is bypassed,
  --   * entity/bounds failures and tile-pair/elevation failures remain final.
  if result == false and ctx.reason == "tile"
      and nav.goalKind == "exit" and nav.exitIntent ~= nil
      and nav.exitDir ~= nil
      and nav.holdDir == ctx.dir
      and nav.targetX == ctx.toX and nav.targetY == ctx.toY
      and nav.expectedX == ctx.toX and nav.expectedY == ctx.toY then
    local map = game.overworld.map
    local hasWarp = map and type(map.warpAtCell) == "function"
      and map:warpAtCell(ctx.toX, ctx.toY) ~= nil
    local ordinaryWalkable = map and type(map.isWalkableCell) == "function"
      and map:isWalkableCell(ctx.toX, ctx.toY) == true
    if hasWarp and not ordinaryWalkable then
      state.stats.exitGoalCollisionOverrides =
        (state.stats.exitGoalCollisionOverrides or 0) + 1
      ctx.reason = "tap_to_move_exit_goal"
      return true
    end
  end

  if result == false and nav.holdDir == ctx.dir
      and nav.expectedX == ctx.toX and nav.expectedY == ctx.toY then
    state.stats.collisions = state.stats.collisions + 1
    releaseHold(nav)

    if ctx.reason == "entity" then
      local _, dynamic = liveOccupancy(game)
      local targetKey = key(ctx.toX, ctx.toY)
      if dynamic[targetKey] then
        nav.tempBlocked[targetKey] = state.tick + ENTITY_BLOCK_TICKS
      else
        nav.blockedCells[targetKey] = true
      end
    else
      nav.blockedEdges[edgeKey(ctx.fromX, ctx.fromY, ctx.toX, ctx.toY)] = true
    end
    requestReplan(nav, "collision_" .. tostring(ctx.reason or "unknown"))
  end

  return result
end)

-- Gen1Recomp normally maps the mouse wheel to survey zoom. OFF preserves that
-- native behavior; ON/ON FLIPPED claim vertical wheel events and emit one real
-- GB D-pad tap instead. Hook the live Game method so launcher/editor scrolling
-- is untouched.
function ControlsFree.installMouseWheelBridge(game)
  if state.mouseWheelBridgeInstalled or not game
      or type(game.wheelmoved) ~= "function" then
    return false
  end
  state.mouseWheelOriginal = game.wheelmoved
  game.wheelmoved = function(self, dx, dy)
    local mode = tostring(option("mouse_wheel_control", "off") or "off")
    if option("enabled", true) ~= false and mode ~= "off"
        and type(dy) == "number" and dy ~= 0 then
      local mapped = dy > 0 and "up" or "down"
      if mode == "on_flipped" then
        mapped = mapped == "up" and "down" or "up"
      end
      mod.input:tap(self, mapped)
      state.stats.mouseWheelTaps = (state.stats.mouseWheelTaps or 0) + 1
      state.stats["mouseWheel_" .. mapped] =
        (state.stats["mouseWheel_" .. mapped] or 0) + 1
      return true
    end
    return state.mouseWheelOriginal(self, dx, dy)
  end
  state.mouseWheelBridgeInstalled = true
  return true
end

-- Immediate lifecycle release, before the next fixed input tick.  These public
-- events close the two most important transition races: entering a new map
-- while a direction is held, and a battle beginning from a walking step.
mod.events:on("game.ready", function(ev)
  local game = ev and ev.game or nil
  if game then
    state.game = game
    installRawPinchZoomGuard(game)
    ControlsFree.installTouchDialogueBridge(game)
    ControlsFree.installMouseWheelBridge(game)
  end
end)

mod.events:on("world.interacted", function(ev)
  local pending = state.pendingInteraction
  if not pending then return end
  if state.tick - pending.tick <= 3 then
    state.stats.interactionsConfirmed = state.stats.interactionsConfirmed + 1
    state.lastStop = {
      reason = "interaction_confirmed", tick = state.tick,
      mapId = ev and ev.mapId or pending.mapId,
      targetX = pending.x, targetY = pending.y,
    }
    state.pendingInteraction = nil
  end
end)

local function mapDefIsOutdoor(def)
  if type(def) ~= "table" then return nil end
  if def.outdoor ~= nil then return def.outdoor == true end
  return defLooksOutdoor(def)
end

-- "Non-outdoor" is much broader than "entered a building" in Gen I. Route
-- gates, forest gates, caves, tunnels, ship ports and other technical map
-- segments are separate mapIds too, but a held destination should continue
-- through those transitions. Only room-style building tilesets get the
-- release-and-press-again safety boundary.
local BUILDING_INTERIOR_TILESETS = {
  REDS_HOUSE_1 = true, REDS_HOUSE_2 = true,
  MART = true, POKECENTER = true, GYM = true, HOUSE = true,
  DOJO = true, MUSEUM = true, CEMETERY = true, INTERIOR = true,
  LOBBY = true, MANSION = true, LAB = true, CLUB = true,
  FACILITY = true,
}

function ControlsFree.mapDefIsBuildingInterior(def)
  if type(def) ~= "table" then return false end
  -- Mod-authored maps can opt in explicitly instead of borrowing a vanilla
  -- tileset merely to communicate semantics.
  if def.building ~= nil then return def.building == true end
  if def.indoorBuilding ~= nil then return def.indoorBuilding == true end
  return BUILDING_INTERIOR_TILESETS[tostring(def.tileset or "")] == true
end

-- Is this blocked overview cell part of the blank shell surrounding a normal
-- room-style building? WorldAPI intentionally exposes only a compact collision
-- alphabet, so the safest semantic split available to a mod is topological:
-- flood-fill blocked " " cells from the map boundary. Anything reached is the
-- exterior/void shell; isolated blocked islands remain furniture/interior walls
-- and continue to use nearest-legal movement. Cache by the exact overview rows
-- because map scripts/mods can replace blocks without changing mapId.
function ControlsFree.exteriorVoidCell(game, overview, x, y)
  if not overview or cellChar(overview, x, y) ~= " " then return false end
  local map = game and game.overworld and game.overworld.map
  if not map or not ControlsFree.mapDefIsBuildingInterior(map.def) then return false end
  local w, h = tonumber(overview.width), tonumber(overview.height)
  if not w or not h or w < 1 or h < 1 or type(overview.rows) ~= "table" then
    return false
  end

  local signature = tostring(overview.mapId) .. ":" .. tostring(w) .. "x"
    .. tostring(h) .. ":" .. table.concat(overview.rows, "\n")
  local cache = state.exteriorVoidCache
  if not cache or cache.signature ~= signature then
    local cells, queue = {}, {}
    local function add(cx, cy)
      if cx < 0 or cy < 0 or cx >= w or cy >= h then return end
      if cellChar(overview, cx, cy) ~= " " then return end
      local k = key(cx, cy)
      if cells[k] then return end
      cells[k] = true
      queue[#queue + 1] = k
    end

    for cx = 0, w - 1 do
      add(cx, 0)
      if h > 1 then add(cx, h - 1) end
    end
    for cy = 1, h - 2 do
      add(0, cy)
      if w > 1 then add(w - 1, cy) end
    end

    local head = 1
    while head <= #queue do
      local cx, cy = parseKey(queue[head])
      head = head + 1
      add(cx + 1, cy)
      add(cx - 1, cy)
      add(cx, cy + 1)
      add(cx, cy - 1)
    end

    cache = { signature = signature, cells = cells }
    state.exteriorVoidCache = cache
  end
  return cache.cells[key(x, y)] == true
end

-- A held screen-space destination is meaningful across route/town seams and
-- across technical map segmentation. A real doorway from outside into a
-- room-style building is different: the camera snaps to a new room while the
-- old finger is still down, and reusing that coordinate commonly sends the
-- player straight back to the exit. Consume the gesture ONLY for that case.
local function enteringBuildingInterior(ev)
  if not ev or ev.via ~= "warp" or not ev.fromMapId then return false end
  local game = state.game
  local maps = game and game.data and game.data.maps
  local fromDef = maps and maps[ev.fromMapId] or nil
  local toDef = ev.map and ev.map.def or (maps and maps[ev.mapId])
  return mapDefIsOutdoor(fromDef) == true and ControlsFree.mapDefIsBuildingInterior(toDef)
end

mod.events:on("map.entered", function(ev)
  state.view = nil
  state.exteriorVoidCache = nil
  invalidateLoadedMapOverviewCache()
  invalidateVoxelCandidateCache()
  if ev and ev.via ~= "connection" then invalidateLedgeTopologyCache() end
  if enteringBuildingInterior(ev) and suppressCurrentGesture("building_entry") then
    state.stats.entryGestureSuppressions = state.stats.entryGestureSuppressions + 1
  end
  local nav = state.nav
  if nav and nav.cross and not nav.cross.crossed and ev
      and ev.via == "connection" and ev.mapId == nav.cross.destMapId then
    releaseHold(nav)
    nav.cross.crossed = true
    nav.mapId = ev.mapId
    nav.targetX, nav.targetY = nav.cross.targetX, nav.cross.targetY
    nav.path, nav.index = nil, 1
    nav.lastX, nav.lastY = nav.cross.entryX, nav.cross.entryY
    nav.connectionEnteredTick = state.tick
    setPhase(nav, "WAITING_CONNECTION_STEP", "seam_step")
  elseif nav and nav.exitJourney and ev and ev.via == "warp" then
    -- An off-map exit request is one semantic command even when the building
    -- spans several mapIds/floors. Internal stairs/doors therefore retire only
    -- the current leg; once the warp transition clears, navigationTick plans
    -- the next leg automatically. Reaching an outdoor map ends the journey.
    releaseHold(nav)
    state.nav = nil
    local maps = state.game and state.game.data and state.game.data.maps
    local toDef = ev.map and ev.map.def or (maps and maps[ev.mapId])
    if defLooksOutdoor(toDef) then
      state.stats.routesArrived = state.stats.routesArrived + 1
      markStop("exited_interior", nav)
      state.exitJourney = nil
    else
      local journey = state.exitJourney or { startedTick = state.tick, legs = 1, visited = {} }
      journey.pendingMapId = ev.mapId
      journey.pendingTick = state.tick
      state.exitJourney = journey
      state.stats.exitJourneyTransitions = state.stats.exitJourneyTransitions + 1
      markStop("exit_leg_warped", nav)
    end
  else
    cancelRoute("map_entered")
  end
  local resume = state.battleResume
  if resume and ev and ev.mapId and ev.mapId ~= resume.mapId then
    dropBattleResume("map_changed")
  end
end)

mod.events:on("battle.started", function(ev)
  local nav = state.nav
  local battle = ev and ev.battle
  if option("battle_resume", false) == true and nav and nav.goalKind == "move"
      and battle and battle.kind == "wild" then
    state.battleResume = {
      mapId = nav.mapId, x = nav.requestedX or nav.targetX,
      y = nav.requestedY or nav.targetY, battle = battle,
      startedTick = state.tick, ready = false,
    }
  else
    state.battleResume = nil
  end
  cancelRoute("battle_started")
  state.pendingInteraction = nil
end)

mod.events:on("battle.ended", function(ev)
  local resume = state.battleResume
  if not resume then return end
  local battle = ev and ev.battle
  local result = ev and ev.result
  if not battle or battle ~= resume.battle or battle.kind ~= "wild" then
    dropBattleResume("battle_mismatch")
    return
  end
  if result == "lose" or result == "nuzlocke_game_over" then
    dropBattleResume("loss")
    return
  end
  resume.battle = nil
  resume.ready = true
  resume.endedTick = state.tick
  -- One fixed tick gives the battle's onFinish/afterBattle chain priority to
  -- install any post-battle state before we ask whether the overworld is free.
  resume.readyTick = state.tick + 1
end)


mod.events:on("battle.ended", function()
  -- Never emit a late A/D-pad after the battle disappeared under a held
  -- finger. Keep battleCameraOwnedTouches until each physical contact releases
  -- so a late drag still cannot leak into whatever state the battle revealed.
  for _, t in pairs(state.battleTouches or {}) do t.suppressed = true end
end)

mod.events:on("save.loading", function()
  cancelRoute("save_loading")
  invalidateLedgeTopologyCache()
  invalidateLoadedMapOverviewCache()
  invalidateVoxelCandidateCache()
  state.pointers = {}
  state.gestureTouches = {}
  state.rawZoomTouches = {}
  state.dialogTouches = {}
  state.battleTouches = {}
  state.battleCameraOwnedTouches = {}
  state.playerHoldTouches = {}
  state.systemEdgeTouches = {}
  state.pinchGraceTouches = {}
  state.rawDispatchedTouches = {}
  state.nativeControlOwnedTouches = {}
  state.twoFingerGesture = nil
  state.tapOwner = nil
  state.pendingInteraction = nil
  state.battleResume = nil
  state.exitJourney = nil
end)

-- Small Game Boy-friendly screen-space feedback.  Accepted destinations get a
-- ring; invalid targets get an X.  No persistent route is painted over the map.
local function drawFeedback()
  local p = state.pulse
  if not p or state.tick > p.untilTick or not (love and love.graphics) then
    if p and state.tick > p.untilTick then state.pulse = nil end
    return
  end

  local life = math.max(0, p.untilTick - state.tick)
  local alpha = math.min(1, life / 10)
  local radius = 5 + (15 - life) * 0.45
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.setLineWidth(2)
  if p.kind == "invalid" then
    local r = radius * 0.7
    love.graphics.line(p.x - r, p.y - r, p.x + r, p.y + r)
    love.graphics.line(p.x + r, p.y - r, p.x - r, p.y + r)
  else
    love.graphics.circle("line", p.x, p.y, radius)
    if p.kind == "interaction" then
      love.graphics.circle("fill", p.x, p.y, math.max(1.5, radius * 0.16))
    end
  end
  love.graphics.pop()
end

local function worldCellToScreen(game, x, y)
  local view = state.view
  local cur = mod.world and mod.world:current()
  if not view or not cur then return nil end
  local ppx, ppy = playerPixel(game, cur)
  local cameraX = ppx - (view.worldW / 2 - 16)
  local cameraY = ppy - (view.worldH / 2 - 8)
  local canvasX = x * TILE_SIZE + TILE_SIZE / 2 - cameraX
  local canvasY = y * TILE_SIZE + TILE_SIZE / 2 - cameraY
  local px = view.ox + canvasX * view.scale
  local py = view.oy + canvasY * view.scale
  local right = view.ox + view.worldW * view.scale
  local bottom = view.oy + view.worldH * view.scale
  if px < view.ox or py < view.oy or px >= right or py >= bottom then return nil end
  return px / view.dpiX, py / view.dpiY
end

-- Forward projection for HUD overlays while a render pipeline owns the world.
-- Voxel3D.project returns coordinates in the Voxel framebuffer canvas; the HUD
-- is drawn in LOVE window units, so invert the same canvas/window mapping used
-- by framebufferPoint().  This deliberately reads the live Voxel canvas instead
-- of guessing from dpi alone.
local PREVIEW_MAX_FULL_DOTS = 48

-- Build the Voxel preview transform once per rendered frame/path pass. test7
-- rebuilt candidate-map, canvas-size, DPI and TileShape state for EVERY dot;
-- FULL preview under a continuously retargeting hold could therefore turn a
-- 50-cell route into thousands of redundant table walks/projections per second.
local function voxelPreviewContext(game, scene, mapId)
  local voxel3d = scene and scene.voxel3d
  if not voxel3d or type(voxel3d.project) ~= "function" then return nil end

  local overview = mod.world and mod.world:mapOverview()
  local entry
  for _, cand in ipairs(voxelCandidateMaps(game, overview)) do
    if cand.mapId == mapId then entry = cand break end
  end
  if not entry then return nil end

  local frame = state.frame or {}
  local cw, ch
  if type(voxel3d.canvas) == "function" then
    local okC, canvas = pcall(voxel3d.canvas)
    if okC and canvas then
      local okW, w = pcall(canvas.getWidth, canvas)
      local okH, h = pcall(canvas.getHeight, canvas)
      if okW and okH then cw, ch = tonumber(w), tonumber(h) end
    end
  end
  cw, ch = cw or tonumber(frame.pw), ch or tonumber(frame.ph)
  if not (cw and ch and cw > 0 and ch > 0) then return nil end

  local ww, wh = tonumber(frame.ww), tonumber(frame.wh)
  if not ww then ww = cw / math.max(tonumber(frame.dpiX) or 1, 1e-6) end
  if not wh then wh = ch / math.max(tonumber(frame.dpiY) or 1, 1e-6) end
  if not (ww and wh and ww > 0 and wh > 0) then return nil end

  local flipY = false
  if love and love.system and type(love.system.getOS) == "function" then
    local okOS, osName = pcall(love.system.getOS)
    flipY = okOS and osName == "iOS"
  end

  local shapes
  if scene.tileShape and type(scene.tileShape.forMap) == "function" then
    local okS, value = pcall(scene.tileShape.forMap, entry.map)
    if okS and type(value) == "table" then shapes = value end
  end

  return {
    voxel3d = voxel3d, entry = entry, shapes = shapes,
    cw = cw, ch = ch, ww = ww, wh = wh, flipY = flipY,
  }
end

local function voxelPreviewGroundHeight(ctx, x, y)
  local map, shapes = ctx.entry.map, ctx.shapes
  if not (map and shapes and type(map.cellTile) == "function") then return 0 end
  if type(map.inBounds) == "function" then
    local ok, inside = pcall(map.inBounds, map, x, y)
    if ok and not inside then return 0 end
  end
  local okT, tile = pcall(map.cellTile, map, x, y)
  if not okT then return 0 end
  local shape = shapes[tile]
  if type(shape) ~= "table" or shape.art == "stair" then return 0 end
  local h = tonumber(shape.h) or 0
  return h > 0 and h or 0
end

local function voxelPathCellToScreen(ctx, x, y)
  local entry, voxel3d = ctx.entry, ctx.voxel3d
  local wx = entry.ox + (x + 0.5) * TILE_SIZE
  local wz = entry.oy + (y + 0.5) * TILE_SIZE
  local h = voxelPreviewGroundHeight(ctx, x, y) + 0.5
  local p = projectedPoint(voxel3d, wx, wz, h)
  if not p then return nil end
  if p[1] < 0 or p[2] < 0 or p[1] >= ctx.cw or p[2] >= ctx.ch then
    return nil
  end
  local sy = ctx.flipY and (ctx.ch - p[2]) or p[2]
  return p[1] * ctx.ww / ctx.cw, sy * ctx.wh / ctx.ch, p[3]
end

local function drawPathPreview(game)
  local mode = option("path_preview", "off")
  local nav = state.nav
  if mode == "off" or not nav or not nav.previewUntil
      or state.tick > nav.previewUntil or not (love and love.graphics) then
    state.previewCache = nil
    return
  end

  local path = nav.path or {}
  local first = nav.index or 1
  local last = #path
  if mode ~= "full" then last = math.min(last, first + 5) end
  if last < first then
    state.previewCache = nil
    return
  end

  -- FULL still shows the WHOLE route, but a very long route does not need one
  -- circle for every single cell to communicate its shape. Cap the marker
  -- count and sample evenly; always draw the final node below. This bounds
  -- projection work independently of the selected performance preset.
  local stride = 1
  if mode == "full" then
    local count = last - first + 1
    if count > PREVIEW_MAX_FULL_DOTS then
      stride = math.max(1, math.ceil((count - 1) / (PREVIEW_MAX_FULL_DOTS - 1)))
    end
  end

  local life = math.max(0, nav.previewUntil - state.tick)
  local alpha = math.min(0.75, life / 12)
  local scene = voxelContext()
  local points

  if scene then
    -- The expensive part of a Voxel preview is not drawing a few cached
    -- circles; it is rebuilding map/shape context and projecting every node
    -- through the live 3D camera. VOXEL PATH RATE throttles that work while
    -- cached screen points are still drawn every HUD frame, so very low rates
    -- can be tested without making the preview blink on/off.
    local cache = state.previewCache
    local frame = state.frame or {}
    local refreshEvery = previewRefreshTicks()
    -- Path identity is intentionally NOT part of the immediate-refresh key.
    -- A held pointer can replace nav.path every input sample; if that forced a
    -- projection each time, a 1/s setting would secretly still reproject at
    -- the hold rate. Between scheduled refreshes the last projected route is
    -- deliberately allowed to lag -- exactly what this tuning option exists
    -- to let the player evaluate on real hardware.
    local sameScene = cache
      and cache.scene == scene
      and cache.mapId == nav.mapId
      and cache.mode == mode
      and cache.pw == frame.pw and cache.ph == frame.ph
      and cache.ww == frame.ww and cache.wh == frame.wh
      and cache.dpiX == frame.dpiX and cache.dpiY == frame.dpiY
    local due = not sameScene
      or (state.tick - (cache.projectTick or -1000000) >= refreshEvery)

    if due then
      local vctx = voxelPreviewContext(game, scene, nav.mapId)
      local projected = {}
      if vctx then
        local function addNode(node)
          local sx, sy, scale = voxelPathCellToScreen(vctx, node.x, node.y)
          if sx then
            local r = 1.8 * math.max(0.70, math.min(1.35, scale or 1))
            projected[#projected + 1] = { x = sx, y = sy, r = r }
          end
        end
        local lastDrawn
        for i = first, last, stride do
          addNode(path[i])
          lastDrawn = i
        end
        if lastDrawn ~= last then addNode(path[last]) end
      end
      cache = {
        scene = scene, path = path, mapId = nav.mapId, mode = mode,
        first = first, last = last, stride = stride,
        pw = frame.pw, ph = frame.ph, ww = frame.ww, wh = frame.wh,
        dpiX = frame.dpiX, dpiY = frame.dpiY,
        projectTick = state.tick, points = projected,
      }
      state.previewCache = cache
      state.stats.previewProjectionRefreshes =
        (state.stats.previewProjectionRefreshes or 0) + 1
    else
      state.stats.previewProjectionCacheHits =
        (state.stats.previewProjectionCacheHits or 0) + 1
    end
    points = cache and cache.points or nil
  else
    state.previewCache = nil
  end

  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setColor(1, 1, 1, alpha)

  if points then
    for _, p in ipairs(points) do
      love.graphics.circle("fill", p.x, p.y, p.r)
    end
  elseif not scene then
    -- Flat rendering is cheap enough to follow the camera every frame.
    local lastDrawn
    for i = first, last, stride do
      local node = path[i]
      local sx, sy = worldCellToScreen(game, node.x, node.y)
      if sx then love.graphics.circle("fill", sx, sy, 1.8) end
      lastDrawn = i
    end
    if lastDrawn ~= last then
      local node = path[last]
      local sx, sy = worldCellToScreen(game, node.x, node.y)
      if sx then love.graphics.circle("fill", sx, sy, 1.8) end
    end
  end
  love.graphics.pop()
end

local function drawDebug()
  if option("debug", false) ~= true or not (love and love.graphics) then return end
  local nav = state.nav
  local lines = {
    "TAP TO MOVE " .. VERSION,
    ("HOLD DELAY %dMS  PERF %s"):format(
      tonumber(option("tap_hold_ms", DEFAULT_HOLD_STEER_DELAY_MS)) or DEFAULT_HOLD_STEER_DELAY_MS,
      (select(1, performanceInputProfile()).label)),
    ("INPUT %dMS  PREVIEW /%d"):format(
      select(1, performanceInputProfile()).holdMs, previewRefreshTicks()),
    "TICK " .. tostring(state.tick),
    ("VOXEL %d  RAY %d  COLUMN %d"):format(
      state.stats.voxelTargets or 0, state.stats.voxelRayTargets or 0,
      state.stats.voxelColumnTargets or 0),
    ("V-OUT %d  EXACT-VOID %d  CARPET-DOWN %d"):format(
      state.stats.voxelRayOutside or 0,
      state.stats.voxelExactVoidExitIntents or 0,
      state.stats.carpetDownIntents or 0),
    ("EXIT-GOAL PASS %d"):format(
      state.stats.exitGoalCollisionOverrides or 0),
    ("V-TILE %s  %s  @%s,%s"):format(
      tostring(state.lastVoxelPick and state.lastVoxelPick.tile or "-"),
      tostring(state.lastVoxelPick and state.lastVoxelPick.class or "-"),
      tostring(state.lastVoxelPick and state.lastVoxelPick.tx or "-"),
      tostring(state.lastVoxelPick and state.lastVoxelPick.ty or "-")),
    ("TOPO %d/%d  OVR %d/%d  ENTRY %d"):format(
      state.stats.topologyCacheHits or 0, state.stats.topologyCacheMisses or 0,
      state.stats.overviewCacheHits or 0, state.stats.overviewCacheMisses or 0,
      state.stats.entryGestureSuppressions or 0),
  }
  if nav then
    lines[#lines + 1] = "STATE " .. tostring(nav.phase)
    lines[#lines + 1] = ("TARGET %s %d,%d"):format(
      tostring(nav.mapId), nav.targetX or -1, nav.targetY or -1)
    lines[#lines + 1] = ("PATH %d/%d HOLD %s"):format(
      nav.index or 0, #(nav.path or {}), tostring(nav.holdDir or "-"))
    if nav.phaseReason then lines[#lines + 1] = "WHY " .. tostring(nav.phaseReason) end
  else
    lines[#lines + 1] = "STATE IDLE"
    if state.lastStop then lines[#lines + 1] = "LAST " .. tostring(state.lastStop.reason) end
  end

  love.graphics.push("all")
  love.graphics.origin()
  local y = 6
  for _, text in ipairs(lines) do
    love.graphics.setColor(0, 0, 0, 0.8)
    love.graphics.print(text, 7, y + 1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(text, 6, y)
    y = y + 14
  end
  love.graphics.pop()
end

mod.hooks:wrap("render.hud", function(nextFn, game, viewport)
  local result = nextFn(game, viewport)
  drawPathPreview(game)
  drawFeedback()
  drawDebug()
  return result
end)

local function diagnostics()
  local nav = state.nav
  local perf, perfName = performanceInputProfile()
  local out = {
    version = VERSION,
    tick = state.tick,
    active = nav ~= nil,
    performance = { mode = perfName, label = perf.label, holdMs = perf.holdMs },
    voxelPathRate = {
      value = tostring(option("voxel_path_rate", DEFAULT_VOXEL_PATH_RATE)
                       or DEFAULT_VOXEL_PATH_RATE),
      ticks = previewRefreshTicks(),
    },
    controlsFree = {
      dialogTouchControl = option("dialog_touch_control", false) == true,
      battleTouchControl = option("battle_touch_control", false) == true,
      startSelectTouchControl = startSelectTouchMode(),
      dialogue = option("dialog_touch_control", false) == true,
      dialogueSwipe = option("dialog_touch_control", false) == true,
      battle = option("battle_touch_control", false) == true,
      battleSwipe = option("battle_touch_control", false) == true,
      battleCameraTouchSuppression = option("battle_touch_control", false) == true,
      holdPlayerStart = startSelectTouchMode() == "hold_player_sprite",
      pinchSpreadStartSelect = startSelectTouchMode() == "pinch_or_spread",
      pinchFirstTouchGraceTicks = ControlsFree.PINCH_FIRST_TOUCH_GRACE_TICKS,
      mouseWalk = option("mouse", false) == true,
      desktopMouseAB = option("desktop_mouse_ab", false) == true,
      mouseWheelControl = tostring(option("mouse_wheel_control", "off") or "off"),
      mouseSideButtons = tostring(option("mouse_side_buttons", "off") or "off"),
      shakeB = option("shake_b", true) ~= false,
      sensorBackend = state.shake and state.shake.backend or nil,
      sensorStrength = state.shake and state.shake.lastStrength or nil,
    },
    stats = copyFlat(state.stats),
    lastStop = state.lastStop and copyFlat(state.lastStop) or nil,
  }
  if nav then
    out.navigation = {
      phase = nav.phase,
      phaseReason = nav.phaseReason,
      goalKind = nav.goalKind,
      mapId = nav.mapId,
      targetX = nav.targetX,
      targetY = nav.targetY,
      requestedMapId = nav.requestedMapId,
      requestedX = nav.requestedX,
      requestedY = nav.requestedY,
      pathIndex = nav.index,
      pathLength = #(nav.path or {}),
      holdDir = nav.holdDir,
    }
    if nav.cross then
      out.navigation.cross = {
        sourceMapId = nav.cross.sourceMapId, destMapId = nav.cross.destMapId,
        dir = nav.cross.dir, sourceX = nav.cross.sourceX, sourceY = nav.cross.sourceY,
        entryX = nav.cross.entryX, entryY = nav.cross.entryY,
        crossed = nav.cross.crossed and true or false,
        ledgeSeam = nav.cross.ledgeSeam and true or false,
      }
    end
    if nav.interaction then
      out.navigation.interaction = {
        kind = nav.interaction.kind,
        entityId = nav.interaction.entityId,
        targetX = nav.interaction.targetX,
        targetY = nav.interaction.targetY,
        faceDir = nav.interaction.faceDir,
        counter = nav.interaction.counter and true or false,
      }
    end
  end
  if state.pendingInteraction then
    out.pendingInteraction = copyFlat(state.pendingInteraction)
  end
  if state.battleResume then
    out.battleResume = {
      mapId = state.battleResume.mapId, x = state.battleResume.x,
      y = state.battleResume.y, ready = state.battleResume.ready and true or false,
    }
  end
  return out
end

mod.exports.cancel = function() return cancelRoute("external_cancel") end
mod.exports.findPath = findPath
mod.exports.diagnostics = diagnostics
mod.exports.version = VERSION
