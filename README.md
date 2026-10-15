# Cellar Escape (milestone 1)

An audio-and-haptics exploration game for iPhone with no gameplay graphics. You wake in a dark basement and find the way out by sound, touch and memory. The world has five connected spaces plus a safe dead end: a dripping pump room, a wooden corridor, a humming vent room, a junction, a buzzing storeroom (the wrong turn), and a stairwell with a cold draft leading outside.

- Design assessment, risks, controls, architecture: [docs/DESIGN.md](docs/DESIGN.md)
- Eyes-closed device playtest checklist: [docs/PLAYTEST.md](docs/PLAYTEST.md)
- Floor plan (developer view): [docs/basement-plan.svg](docs/basement-plan.svg)
- Rough listening preview of an autopilot run: [docs/preview-walkthrough.wav](docs/preview-walkthrough.wav) (simple stereo panning, *not* the iPhone's HRTF rendering)

## Status: what is built and what is verified

| Part | Built | Verified how |
|---|---|---|
| World, collisions, footsteps, thresholds, turning, sound-through-openings, gestures, session/pause/menu/practice, procedural sounds | ✅ | **47 automated tests pass** (`swift test`, Swift 5.10 on Linux). They include a 60,000-frame random walk that never passes a wall, an autopilot that plays to the exit via both wrong turns, continuity of sound across every threshold, and pause/resume with no position jump. |
| World geometry | ✅ | An independent Python check (`tools/validate_world.py`) confirms every room and the exit are reachable on foot. |
| iOS app layer (spatial audio, haptics, speech, interruptions, dev map) | ✅ written | ⚠️ **Not yet compiled.** No macOS or Xcode was available (see "Blocker"). Checked by careful review against the documented APIs only. |
| Simulator self-test, unsigned IPA | ✅ workflow written | ⚠️ Not yet run (same blocker). |
| Feel on a real iPhone: haptics, front/back clarity, comfort | — | Needs a person: [docs/PLAYTEST.md](docs/PLAYTEST.md) |

### Blocker

iOS apps can only be compiled with Apple's Xcode on macOS. This repo's GitHub Actions workflow (`.github/workflows/ios.yml`) does exactly that: core tests, a simulator self-test where the autopilot plays the real app to the exit, and an unsigned IPA. But **every Actions job in this repository, including a plain Linux job, is refused by GitHub within 2 seconds, before any machine starts.** That pattern usually means Actions is disabled for the repo, or the account has a billing problem or a spending limit, or has used up its minutes. To fix it: on GitHub, open **Settings → Actions → General** for the repo and allow actions, then check **Billing → Spending limits / Actions usage** for the account. Then re-run the "Build and test" workflow.

Installing on an iPhone also needs **Apple code signing**: an Apple ID with a free or paid ($99/year) developer account. An unsigned IPA cannot be installed directly.

## Build and install

**Option A: a Mac with Xcode 16 or later (simplest).**
1. Open `CellarEscape.xcodeproj`.
2. Select the CellarEscape target → Signing & Capabilities → choose your Team (a free Apple ID works for your own phone). If the bundle id `com.cellarescape.game` is taken, change it.
3. Plug in the iPhone, select it, press Run.

**Option B: GitHub Actions (no Mac), once the blocker is fixed.** Push, or run the "Build and test" workflow. Download `CellarEscape-unsigned-ipa` from the run's artifacts. Then sign and install it with a sideloading tool (for example Sideloadly or AltStore, which need a computer once), or extend the workflow with your signing certificate.

**Option C: TestFlight (best for directing from an iPhone).** This needs a paid Apple Developer account and an App Store Connect API key stored as GitHub secrets. A signing and upload step can then be added to the workflow. Uploads need Xcode 26 / the iOS 26 SDK. Not set up yet.

## Controls

The game explains these in a short spoken practice in the starting room.

| Gesture | Action |
|---|---|
| Hold one finger still | Walk forward (drag sideways while walking to steer) |
| Lift | Stop and listen |
| Drag left/right (starting with a drag) | Turn on the spot (never walks) |
| Two-finger swipe left/right | Turn 90° to face along the walls |
| Two-finger swipe down | Turn around |
| Two-finger tap | Sense surroundings (spoken) |
| Two-finger hold | Pause menu / resume |
| Pause menu: swipe left/right, double-tap | Options: resume, controls, vibration, wall sense, turning speed, skip practice, restart, developer map |
| After escaping: double-tap | Play again |

## Running the checks without Xcode

```sh
swift test                                    # 47 core tests (macOS or Linux, Swift 5.9 or later)
python3 tools/validate_world.py Content/basement.json --svg docs/basement-plan.svg
swift run -c release CellarPreview . preview.wav   # regenerate the listening preview
```

## Changing the world or sounds

- **Rooms, openings, surfaces, sound sources:** edit `Content/basement.json`. Rooms are rectangles. Openings must lie on an edge both rooms share. Validation rejects overlaps, narrow openings, disconnected rooms and stray sources. Run `swift test` and the Python validator afterwards.
- **Replace a sound:** add an audio file named after the sound id to `Content/Sounds/` (for example `drip.wav`, `ventHum.caf`, `step.woodBoards.0.wav`; ids are listed in `SoundSynth.swift`). Then run `python3 tools/gen_xcodeproj.py`. Bundled files override the procedural sound automatically.
- **Add source files:** run `python3 tools/gen_xcodeproj.py` to regenerate the Xcode project.
- **Developer map:** pause menu → "Developer map". Gameplay never depends on it. Launch argument `-selftest` makes the autopilot play to the exit and print `SELFTEST PASS`.

No earlier engine source (for example "CellarAdventureEngine V0.2.6") was in this repository, so nothing was reused from it.
