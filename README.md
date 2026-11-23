# Squats

A Mac menu-bar app that asks for a set of squats every 30 minutes of laptop time, counts them
with the built-in camera, and adds anything skipped to the next set.

## Build and install

```bash
scripts/bundle.sh
cp -R build/Squats.app /Applications/
open /Applications/Squats.app
```

Needs macOS 15 or later, Xcode command-line tools, and an Apple Development certificate in the
keychain for signing. Allow notifications and camera access when asked.

## Use

- The menu-bar icon shows how many squats you owe. A notification arrives when a set is due.
- **Start** (or "Do squats now") opens the counter. Stand about 1.5 m from the screen with your
  head and shoulders in frame, stand still for a second, then squat.
- Skipping does nothing: the squats stay owed and the next set stacks on top, up to the
  carry-over cap. The count clears at the start of each day.
- During a video call no notification appears; it arrives when the call ends.

## Tuning

- **Squat depth** slider: how far your shoulders must drop, in shoulder widths (default 0.77,
  measured from a recording). Lower it if squats are missed, raise it if small movements count.
- Time away: more than 5 minutes without keyboard or mouse input pauses the timer. Change with
  `defaults write local.squats idleMinutes -int 10`.

## Privacy

The camera is on only while the counter window is open. Frames are processed in memory by
macOS's own pose model. Nothing is recorded, saved or sent, and the app makes no network requests.

## Tests

`swift test` runs the ledger and counter tests, including a recorded clip of ten real squats.
