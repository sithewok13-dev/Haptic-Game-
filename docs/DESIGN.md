# Cellar Escape: design assessment (milestone 1)

## The concept

There are no gameplay graphics. You wake in a dark basement and find the way out by sound, touch and memory. In this milestone, exploring is the whole game. The aim is a place that holds together physically: walls are always where they were, sounds stay put as you turn, and sound only travels the way you could walk.

This is a strong premise because the world itself is the puzzle. Its main risk is that audio-only navigation fails in recognisable ways, and each of those has to be designed against. The risks are listed below.

## Main navigation risks and what this build does about them

| Risk | Mitigation in this build | Still needs a human test |
|---|---|---|
| **Front/back confusion.** HRTF on generic ears often can't tell a sound ahead from one behind. | Turning is the disambiguator: a sound ahead moves *the opposite way* to a sound behind as you turn. "Sense surroundings" (two-finger tap) names in-room sounds as "ahead to the left", "behind you" and so on. The offline preview also dulls rear sounds. | Yes. Results vary by person and headphone model. |
| **Getting lost / losing facing.** | Facing snaps to the wall directions with a two-finger swipe. A tiny tick (felt, or a faint click if vibration is off) marks every time you face along the walls. The orientation aid gives a compass word. | Yes |
| **Hidden sources pulling you into walls.** | Sound travels only through openings. A source in another room is heard *from the opening it comes through*, at the loudness of the walking-path distance, and muffled by how sharply the path bends. Tests check that direction and level never jump while crossing a threshold. | Partly (whether it reads as "through the doorway") |
| **Exit audible everywhere.** | The draft and outside sounds reach the start room at about 3% of their level near the stairs (a test enforces < 30% of the junction level), arriving muffled from the doorway direction. | |
| **Can't find openings.** | Optional "wall sense": a soft hush from walls within ~2 m on the left, right and ahead. Walking along a wall, the hush drops away at an opening and the next room's sounds flow in. Brushing a wall gives a hand-scrape sound and a light tap. | Yes (is it subtle enough, and useful enough?) |
| **Accidental motion.** | Walking needs a *still* hold for 0.18 s. A touch that starts with a drag only turns and can never start walking. A second finger stops walking at once. | Yes |
| **Fatigue from holding.** | Rooms are small (the longest straight walk is about 12 m, roughly 10 s). Lifting stops instantly, with no penalty. | Yes |
| **Repetitive wall impacts.** | One bump per contact. It re-arms only after stepping away from the wall or standing still for 1.2 s. Pushing into a wall makes no footsteps. | |
| **Speech clutter.** | Speech only in the short practice, on request (two-finger tap), in the pause menu, and at completion. World audio ducks while speaking. | |

## Controls (evaluated and adjusted)

The proposal was: one finger held to walk, drag sideways to turn, lift to stop. That works. Taken literally, though, it starts walking on every touch and couples turning with walking. The adjusted vocabulary:

| Gesture | Action |
|---|---|
| Hold one finger still (about 0.2 s) | Walk forward. Drag sideways while walking to steer. |
| Lift the finger | Stop immediately. |
| Drag one finger left/right (starting with a drag) | Turn on the spot. This touch never walks. |
| Two-finger swipe left/right | Turn to face the next wall direction (90° steps, aligned with the walls) |
| Two-finger swipe down | Turn around |
| Two-finger tap | Sense surroundings (spoken) |
| Two-finger hold (about 0.8 s) | Pause menu / resume |
| *In the pause menu:* one-finger swipe left/right, double-tap | Move between options, choose |
| *After escaping:* double-tap | Play again |

There is no walking backwards. Moving away from a sound is "turn around, walk". That keeps the vocabulary small and avoids a second hold gesture that's easy to trigger by accident. Turning speed is adjustable (slow/normal/fast). With VoiceOver on, the game view uses *direct interaction*, so these gestures reach the game.

## Platform choice: native Swift on iOS

- **Audio: `AVAudioEngine` + `AVAudioEnvironmentNode`** with `.HRTFHQ` rendering on headphones (equal-power panning on the speaker), per-source `occlusion` for muffling, `reverbBlend`, and the environment reverb presets per room (crossfaded at thresholds). This framework is mature, offline, deterministic and easy to debug.
  - **PHASE** (iOS 15+) has geometry-aware occlusion. It was not chosen because its acoustic decisions are opaque. The requirement that a hidden source must not imply a direct route needs the explicit, testable "sound travels through openings" model in `Propagation.swift`.
  - **Head tracking:** since iOS 18, `AVAudioEnvironmentNode` can follow AirPods head pose (`isListenerHeadTrackingEnabled`, entitlement required). That could help front/back confusion and is a candidate for the next milestone. It is not enabled now: body facing comes from gestures, and mixing the two needs testing.
  - **System "Spatialize Stereo":** iOS can re-spatialise the app's already-binaural output. The playtest checklist says to turn it off for this app. Apple added an Info.plist opt-out for environment nodes in the 2024 SDK. Its exact key is not yet in the project (unverified here).
- **Haptics: Core Haptics** (`CHHapticEngine`, iPhone 8 and later), with a `UIImpactFeedbackGenerator` fallback. The vocabulary is five brief patterns: bump (firm knock), brush (the same knock, lighter), threshold (two soft dull pulses), aligned (tiny crisp tick) and completion (slow swell). Nothing vibrates continuously. Vibration never encodes left/right.
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
