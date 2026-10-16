# Cellar Escape: design assessment (milestone 1)

## The concept

There are no gameplay graphics. You wake in a dark basement and find the way out by sound, touch and memory. In this milestone, exploring is the whole game. The aim is a place that holds together physically: walls are always where they were, sounds stay put as you turn, and sound only travels the way you could walk.

This is a strong premise because the world itself is the puzzle. Its main risk is that audio-only navigation fails in recognisable ways, and each of those has to be designed against. The risks are listed below.

## Main navigation risks and what this build does about them

| Risk | Mitigation in this build | Still needs a human test |
|---|---|---|
| **Front/back confusion.** HRTF on generic ears often can't tell a sound ahead from one behind. | Turning is the disambiguator: a sound ahead moves *the opposite way* to a sound behind as you turn. "Sense surroundings" (two-finger tap) names in-room sounds as "ahead to the left", "behind you" and so on. The offline preview also dulls rear sounds. | Yes. Results vary by person and headphone model. |
| **Getting lost / losing facing.** | Facing is limited to eight directions and each turn speaks the new direction. Rooms announce their name. A tiny tick marks facing along the walls. The cane tap gives the distance to the wall ahead. | Yes |
| **Hidden sources pulling you into walls.** | Sound travels only through openings. A source in another room is heard *from the opening it comes through*, at the loudness of the walking-path distance, and muffled by how sharply the path bends. Tests check that direction and level never jump while crossing a threshold. | Partly (whether it reads as "through the doorway") |
| **Exit audible everywhere.** | The draft and outside sounds reach the start room at about 3% of their level near the stairs (a test enforces < 30% of the junction level), arriving muffled from the doorway direction. | |
| **Can't find openings.** | Optional "wall sense": a soft hush from walls within ~2 m on the left, right and ahead. Walking along a wall, the hush drops away at an opening and the next room's sounds flow in. Brushing a wall gives a hand-scrape sound and a light tap. | Yes (is it subtle enough, and useful enough?) |
| **Accidental motion.** | Walking needs a still hold for 0.18 s. Finger drift while walking is ignored. A touch that moves first can only be a swipe. A second finger stops walking at once. | Yes |
| **Fatigue from holding.** | Rooms are small (the longest straight walk is about 12 m, roughly 10 s). Lifting stops instantly, with no penalty. | Yes |
| **Getting stuck on walls.** | Walking into a wall bounces you back a short step with a heavy knock (sound and vibration). Holding on bounces again about twice a second until you turn away, so a wall never feels like a silent dead stop. Glancing contact, including walking diagonally, slides you along the wall with a light tap each step. Walking roughly toward an opening guides you sideways into it. | Yes (does the bounce rhythm feel right?) |
| **Speech clutter.** | Speech only in the short practice, on request (two-finger tap), in the pause menu, and at completion. World audio ducks while speaking. | |

## Controls (revised after the first iPhone playtest)

The first build used continuous drag-to-turn and steering while walking. On the phone that proved confusing: finger drift steered you, and you couldn't tell how far you had turned. The controls are now discrete and say what happened:

| Gesture | Action |
|---|---|
| Hold one finger | Walk forward, always straight (finger drift is ignored) |
| Lift | Stop |
| Swipe left / right | Turn 45° (says the new direction, e.g. "north-east") |
| Swipe down | Turn around |
| Tap | Tap your cane: an echo from the wall ahead (quick echo = close, none = open space) |
| Two-finger tap | Where am I? (room, facing, nearby walls and openings, sounds in this room) |
| Two-finger hold | Pause menu / resume |
| Pause menu: swipe left/right, double-tap | Options: resume, controls, vibration, wall sense, 45°/90° turns, say direction, say room names, skip practice, restart, developer map |
| After escaping: double-tap | Play again |

- Facing is always one of eight directions (or four, in 90° mode), so walking is always straight and easy to retrace.
- Each turn speaks the new facing, which can be switched off. Rooms announce their short name on entry, which can also be switched off.
- The cane tap is real echolocation in the world model: a ray ahead finds the nearest wall within 8 m, and the echo plays from that point after an exaggerated delay (about 50 ms per metre). Through an opening, there is no echo.
- With VoiceOver on, the game view uses direct interaction so these gestures reach the game.

## Platform choice: native Swift on iOS

- **Audio: `AVAudioEngine` + `AVAudioEnvironmentNode`** with `.HRTFHQ` rendering on headphones (equal-power panning on the speaker), per-source `occlusion` for muffling, `reverbBlend`, and the environment reverb presets per room (crossfaded at thresholds). This framework is mature, offline, deterministic and easy to debug.
  - **PHASE** (iOS 15+) has geometry-aware occlusion. It was not chosen because its acoustic decisions are opaque. The requirement that a hidden source must not imply a direct route needs the explicit, testable "sound travels through openings" model in `Propagation.swift`.
  - **Head tracking:** since iOS 18, `AVAudioEnvironmentNode` can follow AirPods head pose (`isListenerHeadTrackingEnabled`, entitlement required). That could help front/back confusion and is a candidate for the next milestone. It is not enabled now: body facing comes from gestures, and mixing the two needs testing.
  - **System "Spatialize Stereo":** iOS can re-spatialise the app's already-binaural output. The playtest checklist says to turn it off for this app. Apple added an Info.plist opt-out for environment nodes in the 2024 SDK. Its exact key is not yet in the project (unverified here).
- **Haptics: Core Haptics** (`CHHapticEngine`, iPhone 8 and later), with a `UIImpactFeedbackGenerator` fallback. The vocabulary is five brief patterns: bump (heavy knock with rebound, repeats while you walk into the wall), brush (light tap, once per step while sliding along a wall), threshold (two soft dull pulses), aligned (tiny crisp tick) and completion (slow swell). Nothing vibrates continuously. Vibration never encodes left/right.
- **Speech:** `AVSpeechSynthesizer` in the app's audio session.
- **Deployment target:** iOS 16.0. Building needs Xcode 16 or later. Uploading to TestFlight/App Store has required Xcode 26 and the iOS 26 SDK since 28 April 2026.
- **No other engine needed.** Unity, Godot and the like would add a heavy runtime and no better spatial audio than the OS provides.

## Architecture

```
Content/basement.json        world content: rooms, openings, surfaces, sound sources, start, exit
Sources/CellarCore/          platform-independent, unit-tested (builds on Linux and macOS)
  Geometry, WorldDefinition, World      - geometry, validation, walls derived from rooms minus openings
  Collision, Simulation                  - circle-vs-wall sliding, footsteps, bumps, thresholds, turning
  Propagation, AudioScene                - sound through openings; per-frame voice parameters
  InputInterpreter                       - raw touches -> gesture vocabulary
  GameSession, Orientation, Settings     - practice / exploring / paused / completed; menus; spoken aid
  SoundSynth                             - procedural sound set (no downloaded assets)
  Autopilot                              - drives the session with player gestures (tests, self-test)
Sources/CellarPreview/       offline stereo walkthrough renderer (rough listening preview)
App/CellarEscape/            iOS presentation only
  SpatialAudioEngine, SoundBank          - AVAudioEngine / environment node, buffers, file overrides
  HapticsPlayer, SpeechGuide             - Core Haptics vocabulary, speech with ducking
  GameViewController                     - black screen, touches, game loop, interruptions, dev map
```

The core emits **cues** (footstep, bump, threshold, speak, and so on). The app maps cues to sound and haptics and holds no game rules. Future interaction systems (doors, objects) slot in as new world data, new `SimEvent`s and new cues. There are no characters or inventory.

## Interruptions and resume

- App backgrounded, phone call or Siri, or headphones unplugged → the session pauses, walking stops, and the world fades out. After a background or interruption pause, coming back says "Paused. Hold two fingers to resume." Unplugging headphones says "Headphones disconnected. Paused."
- Nothing auto-resumes. The player resumes with a two-finger hold.
- Frame time is clamped (50 ms max per step) and reset on foreground, so a stall can never become a jump in position. Tests cover a two-minute suspension and a 30-second frame gap.
- The audio engine is restarted after interruptions and configuration changes, and rebuilt after a media-services reset.
