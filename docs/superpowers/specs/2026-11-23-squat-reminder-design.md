# Squats — design and implementation plan

Date: 2026-11-23. Status: waiting for approval. Nothing is built yet.

## Why

Sitting at the laptop all day in the office makes the back, legs and glutes hurt.
The app nudges a short set of squats every half hour of laptop time, uses the
laptop camera to check they were really done, and rolls anything missed into the
next set so a busy stretch is repaid instead of forgotten.

## Goals

- Every 30 minutes (adjustable) of time at the laptop, ask for a set of squats
  (default 10, adjustable; the request was "5–10, customizable").
- Count the squats with the built-in camera. Only counted squats pay off a set.
- A skipped, ignored or half-done set is added to the next one.
- Low friction: lives in the menu bar, starts at login, no account, no network.

## Non-goals

Other exercises, form coaching, history or charts, Windows/Linux, phone or watch
apps, sync, and policing cheating (it is your own tool).

## Anti-goals (would make it a failure even if it "works")

- The camera being on at any time other than while counting squats.
- A camera window or banner appearing over a video call.
- Carried-over squats growing to an absurd number after a day of meetings.
- Anything from the camera being saved or leaving the machine.
- Miscounts frequent enough that you stop trusting the counter.

## Constraints

- macOS 27.2 on Apple silicon, built-in FaceTime HD camera, Xcode 27.2 and
  Swift 6.4 already installed.
- The camera sits on a desk and tilts slightly upward. At a normal standing
  distance it sees head, shoulders and chest, usually not knees or ankles.
- Office setting: the nudge should be visible but not disruptive.

## What the research found

1. **Pose detection is built into macOS.** Apple's Vision framework has
   `DetectHumanBodyPoseRequest` (macOS 15+). It takes camera frames directly and
   returns body joints with a confidence each. No model download, no dependency.
2. **The usual squat counter does not suit a laptop camera.** Most webcam squat
   counters measure the knee angle (hip–knee–ankle) and count with two
   thresholds so a rep is only counted on the way back up. That works from the
   side with the whole body in view. From the front the knees bend toward the
   camera, so the angle barely changes on screen, and a laptop camera rarely
   sees knees at all. A second family tracks how far the body drops instead of
   an angle; that is the one that fits here.
3. **Fixed thresholds break across bodies and distances**, so the drop has to be
   measured relative to the body's own size, with a tuning knob left in.
4. **"At the laptop" does not need the camera.** macOS reports the time since
   the last keyboard or mouse input (`CGEventSource.secondsSinceLastEventType`),
   and whether another app is using the camera
   (`kCMIODevicePropertyDeviceIsRunningSomewhere`), which is a good "in a video
   call" signal.
5. **Closest existing app: Vibe Reps** (Electron menu-bar app, MediaPipe, 13
   exercises including squats). It triggers exercise while Claude Code is
   working, not on a sitting timer, and has no carry-over.
6. **MediaPipe for Python** currently ships a wheel that installs on this Mac,
   so a Python version is possible, just heavier.

## Approaches considered

**A. Native Mac menu-bar app in Swift — picked.** SwiftUI menu-bar item, the
built-in camera through AVFoundation, Apple Vision for the pose, system
notifications. Zero third-party dependencies, the pose model ships with the OS,
camera permission is requested under the app's own name, start-at-login is a
system feature, and it is light on battery. Cost: Mac only, and it must be
packaged as an app bundle.

**B. Python script (menu-bar helper + OpenCV + MediaPipe).** Quick to hack on,
good 33-point pose model. Cost: several hundred MB of dependencies, camera
permission is granted to Terminal/Python rather than to the app, notifications
and autostart are bolted on, and it is more fragile across OS and Python
updates.

**C. Fork Vibe Reps.** Already counts squats. Cost: its core is the Claude Code
trigger; the timer, presence detection and carry-over would all be new, on top
of an Electron runtime.

A browser-tab web app was dropped early: background tabs are throttled and
cannot see whether you are at the machine, so both the timer and presence would
be unreliable.

A was picked because every piece it needs is already on this Mac, and it is the
only option where permissions, notifications and start-at-login behave like a
normal app. This is my call; the request left the "how" open.

## Design

### One number: `owed`

- Every `interval` (30 min) of time at the laptop: `owed += perSet`, capped at
  `maxOwed` (default 30).
- Every counted squat: `owed -= 1`, never below 0.
- Skip, ignore or stop halfway: nothing special happens. `owed` stays, and the
  next interval adds to it. That one rule is the whole carry-over feature.
- When a session brings `owed` to 0, the 30-minute countdown restarts from that
  moment. If squats are still owed, it keeps running.
- First tick of a new calendar day: `owed` resets to 0 and `doneToday` to 0.

Example: 10:00 set of 10 skipped (owed 10) → 10:30 owed 20, you do 12 (owed 8)
→ 11:00 owed 18.

### Time at the laptop

Checked every 30 seconds. You count as present if the last keyboard or mouse
input was under `idleMinutes` (5) ago, **or** another app is using the camera
(you are in a call, sitting, even if not typing). Present adds 30 seconds to the
countdown; not present pauses it. Sleep and lock pause it for free, because
neither produces input or ticks.

The camera-in-use check is skipped while the app's own squat window is open,
since that signal is also true for the app's own camera session.

### The nudge

- When `owed` goes up: a notification, "Time for 10 squats" or "20 squats — 10
  carried over", with **Start** and **Skip** buttons. Skip only dismisses.
- The menu-bar item shows a figure icon plus the owed count whenever it is
  above 0, so it stays visible if Focus hides the banner.
- During a call (camera in use by another app) no notification is sent. Squats
  still accrue, and the notification goes out when the call ends.
- No repeat nagging between intervals.
- Clicking the banner itself does the same as Start.
- Only one notification exists at a time; a new one replaces the old one with
  the updated total.
- If an interval comes due while the squat window is open, `owed` goes up
  quietly with no notification. The target on screen stays what it was when the
  window opened, and the extra shows in the menu bar afterwards.

### The squat window

Opened by **Start** or from the menu ("Do squats now"). A small always-on-top
window:

```
┌───────────────────────────────┐
│  [ mirrored camera preview,   │
│    dots on tracked joints ]   │
│                               │
│            7 / 20             │
│   Keep going                  │
│                [Done for now] │
└───────────────────────────────┘
```

1. Camera starts (built-in camera explicitly, not an iPhone or external one).
2. Status reads "Step back until your head and shoulders are in frame", then
   "Stand still…" for about a second while your standing position is recorded.
3. Each squat bumps the number and plays a short tick (sound can be turned off).
4. At the target: a success sound, the window closes, the camera turns off.
5. "Done for now" or closing the window keeps the squats already counted.

With nothing owed, the target is one normal set and the countdown restarts when
it is finished.

### Counting a squat

Per frame, Vision returns the joints. The signal is how far the upper body has
dropped from the recorded standing position, in units of your own shoulder
width:

`drop = (standingHeight − currentHeight) / standingShoulderWidth`

A squat is counted when `drop` goes above a "down" threshold and then comes back
below an "up" threshold (starting guesses 0.7 and 0.2, replaced by measured
values from the spike). Frames with low joint confidence are ignored, the signal
is lightly smoothed, and a rep must take at least about half a second.

One knob stays in settings, "squat depth", because cameras, desks and bodies
differ. Known limit: anything that lowers and raises your shoulders that far
counts, including sitting down and standing up.

### Privacy

The camera is on only while the squat window is open, and the green light shows
it. Frames are processed in memory by the OS's own model. Nothing is recorded,
saved or sent. The app makes no network requests.

### Settings and storage

In the menu-bar popover: squats per set (1–30, default 10), interval in minutes
(default 30), carry-over cap (default 30), sound on/off, squat depth, start at
login, plus "Do squats now", today's total and Quit. Everything is stored in the
standard macOS preferences store. No database, no files.

## Implementation plan

Each phase ends with something that can be checked.

**Phase 0 — camera spike (throwaway).** Answers the one real unknown: on this
laptop, on this desk, which joints stay visible through a squat and what does
the signal look like? A single-file window with the preview and joint dots that
logs joint positions and confidences per frame to a CSV. You do 5 squats at
roughly 1 m, 1.5 m and 2 m with the lid at its usual angle, then one clip of
ordinary movement (shifting, reaching, looking around; no sitting, since
sitting down and standing up legitimately counts) and one of walking to the
laptop and back. Outcome: which point to
track (shoulders, neck or nose), measured thresholds, the distance to stand at,
and two or three recordings kept as test data. If the head leaves the frame at a
comfortable distance, the fallback is tracking the face box, or tilting the lid.
*Needs about ten minutes of you in front of the camera.*

The spike decides only how squats are detected. If neither the upper-body
signal nor the fallbacks give a clean signal, work stops before Phase 3 and
comes back to you. The ledger half of Phase 1 and all of Phase 2 do not depend
on the spike, so they can be built while the recordings are pending; only the
rep counter's thresholds and its recording-based tests wait for them.

**Phase 1 — the two pieces of logic, with tests.** The `owed` ledger (accrual,
cap, carry-over, countdown restart, day reset) and the rep counter (the
down/up thresholds). Check: `swift test` passes, including the spike recordings
giving exactly the number of squats done and the ordinary-movement recording
giving zero.

**Phase 2 — app shell.** Swift package, a short script that assembles and signs
`Squats.app` (camera usage text, menu-bar-only flag), the menu-bar item with
count and settings, the 30-second presence tick using input idle time, and the
notification with Start and Skip. Check, with the interval set to 1 minute: the
count climbs while typing, pauses after hands-off for the idle time, the
notification appears, Skip leaves the count alone, and a relaunch keeps state.

**Phase 3 — squat window.** Camera permission, preview, Vision feeding the rep
counter feeding the ledger, the stand-still step, sounds, auto-close. Check: a
real set counts correctly, the camera light goes off on close, and a half-done
set leaves the remainder owed with the next interval added on top.

**Phase 4 — call awareness and start at login.** Camera-in-use-by-another-app
counts as present and holds the notification. Start-at-login toggle. Check: with
Photo Booth open through an interval there is no notification and the count
grows; quitting Photo Booth delivers it. Toggle the login item and log back in.

**Phase 5 — a day of real use**, then adjust thresholds and defaults.

Expected size: a few hundred lines of Swift in a handful of files.

## Left out on purpose

History and charts, other exercises, form feedback, a harder-to-ignore floating
reminder, scheduled pause or working hours, detecting audio-only calls, choosing
a different camera. Each is easy to add later if a day of use shows it is
missed.

## Calls I made that you did not

- Native Swift Mac app rather than Python.
- "At the laptop" means recent keyboard/mouse input or being in a video call.
  Reading with no input for over 5 minutes pauses the countdown.
- Being away pauses the countdown rather than restarting it.
- Carry-over is capped at 30 squats and cleared at the start of each day.
- Default set is 10 squats.
- The nudge is a notification plus a menu-bar count, not something that blocks
  the screen.
- Squats are measured by how far your upper body drops, not knee angle, so you
  do not have to stand far enough back for your legs to be in frame.
- Squats that come due while you are already doing a set are added quietly
  rather than raising the target mid-set.
- Yesterday's unpaid squats are wiped silently on the first use of a new day,
  including after the laptop slept overnight.

## Left to the builder

File layout, visual styling, frame rate and smoothing, which upper-body point to
track (decided by the spike), and Swift language mode. Sign with the Apple
Development certificate already in this Mac's keychain, so camera and
notification permissions survive rebuilds (an ad-hoc-signed build may ask
again each time). Verify during the build rather than assume: the exact
joint accessors and coordinate origin of the Vision result, and that reading the
input idle time needs no extra permission.

## Sources

- Apple, DetectHumanBodyPoseRequest: https://developer.apple.com/documentation/vision/detecthumanbodyposerequest
- Apple, HumanBodyPoseObservation: https://developer.apple.com/documentation/vision/humanbodyposeobservation
- Create with Swift, body poses in a live video feed: https://www.createwithswift.com/detecting-body-poses-in-a-live-video-feed/
- Apple, CGEventSource: https://developer.apple.com/documentation/coregraphics/cgeventsource
- Apple, kCMIODevicePropertyDeviceIsRunningSomewhere: https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertydeviceisrunningsomewhere
- Apple, MenuBarExtra: https://developer.apple.com/documentation/swiftui/menubarextra
- SunFounder, hip-position squat counter: https://docs.sunfounder.com/projects/ai-lab-kit/en/latest/mediapipe/mp_8_pose_squat.html
- Hugging Face forum, rep counting with a state machine: https://discuss.huggingface.co/t/real-time-exercise-form-analysis-with-mediapipe-looking-for-advice/175699
- FormCheck, four-state rep counter: https://github.com/ctsc/FormCheck
- Vibe Reps: https://github.com/Flow-Club/vibereps
- MediaPipe on PyPI: https://pypi.org/project/mediapipe/
