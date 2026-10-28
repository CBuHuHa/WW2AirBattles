# <Game title>

> <Pitch: You are X, doing Y, in order to Z.>

| | |
| --- | --- |
| Engine | <Phaser 4 / Three.js / Godot 4.x> |
| Platform | <web (desktop + mobile browsers) / desktop (Windows, macOS, Linux)> |
| View | <2D side-view / top-down / 3D third-person …> |
| Scope | <jam 48h / prototype / small release> |
| References | <game A (for …), game B (for …)> |

## Core loop

<What the player does every 5–30 seconds, and why they do it again. 3–5 lines.>

## First 30 seconds

1. <What's on screen at launch>
2. <First input and what it does>
3. <First challenge>
4. <First reward or failure>

## Controls

| Action | Keyboard | Gamepad | Touch |
| --- | --- | --- | --- |
| Move | WASD / arrows | left stick | virtual stick |
| <verb> | <key> | <button> | <gesture> |

## Mechanics

<One subsection per mechanic, with concrete numbers marked `(tune)`.>

### <Mechanic>

- <rule>
- <number (tune)>

## Win, fail, restart

- **Fail**: <condition> → <what happens>
- **Win**: <condition> → <what happens>
- **Restart**: <instant / checkpoint / main menu>

## Challenge and progression

<How difficulty ramps: what changes, on what curve. What persists between runs, if anything.>

## Game feel

<Screen shake, hit-stop, particles, tweening, camera. What happens on hit, death, pickup.>

## Art direction

- **Style**: <pixel art at 16 px / low-poly flat-shaded / …>
- **Palette**: `#……` background · `#……` player · `#……` enemies · `#……` pickups · `#……` UI
- **Readability**: <the rules that keep the game legible>
- **Resolution / camera**: <base resolution 320×180 scaled ×4 / FOV 60° …>
- **UI / HUD**: <what's on screen, where>

## Audio

- **Music**: <mood, or none>
- **SFX**: <list, matching the asset table>

## Assets

| Key | Description | Source | Status |
| --- | --- | --- | --- |
| player | <…> | kenney:<pack> / placeholder / generate | todo |

## Milestones

1. **M1: Core verb**: <the player can … on a blank screen>
2. **M2: Loop**: <fail and restart work; one enemy / obstacle>
3. **M3: Content**: <levels / waves / real assets>
4. **M4: Juice and ship**: <feel, audio, menus, build>

## Out of scope for v1

- <cut idea>

## Changelog

- <YYYY-MM-DD>: GDD created.
