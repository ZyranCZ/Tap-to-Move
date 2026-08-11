# Tap to Move

Modern touch controls and pathfinding for **Pokémon Gen1Recomp**.

Tap anywhere in the overworld and your character will automatically navigate there using real game movement and collision rules.

## Features

- **Tap to Move** — automatic collision-aware pathfinding.
- **Hold to Steer** — keep holding to continuously redirect movement.
- **Smart Interactions** — tap NPCs, PCs, signs, items, doors and other interactive objects.
- **Smart Exits** — automatically navigate through doors, carpets, directional warps and compatible interior exits.
- **Touch UI Controls** — Tap = A, Hold = B, Swipe = D-pad in menus, dialogue and battles.
- **START / SELECT Gestures** — optional hold or pinch/spread controls.
- **Path Preview** — optional visual route preview.
- **Resume After Wild Encounter** — optionally continue your route after battle.
- **Mouse Controls** — optional desktop mouse shortcuts.
- **Dramatic Shape / Voxel Support** — native 3D target picking and navigation.
- **EXPERIMENTAL: Simple Mode** — renderer-independent fallback movement for incompatible visual mods.

## Simple Mode

If another visual or Voxel mod is incompatible with normal Tap to Move, enable:

**EXPERIMENTAL: Simple Mode**

Instead of reading the rendered world, movement is determined only by your finger's direction relative to the player.

Simple Mode also includes:

- Tap player → **A**
- Hold player → **START**
- Hold elsewhere → **B**
- Configurable movement deadzones and direction dominance

## On-Screen Controls

A small controller button in the top-right corner can hide or restore Gen1Recomp's original on-screen controls at any time.

This allows the game to be played without permanent virtual buttons while always keeping them available as a fallback.

## Compatibility

Designed for **Pokémon Gen1Recomp**.

**Dramatic Shape** is supported directly. Other visual/Voxel mods can use **EXPERIMENTAL: Simple Mode** when normal world targeting is incompatible.
