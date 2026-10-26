# DAWless MIDI

A macOS patchbay for playing hardware without a DAW: route any MIDI input to any MIDI output, and choose exactly which devices receive MIDI clock.

By Ed Davis. Copyright © 2026 Ed Davis.

## What it does

**Routing matrix.** Inputs run down the side and outputs across the top. Click a square to send that input to that output. An input can go to any number of outputs, and an output can take any number of inputs, which are merged.

**Channels and filters.** Right-click a route to:
- listen to one channel only (or all)
- move everything to another channel (**Send On**)
- block notes, control changes, program changes, pitch bend, aftertouch or SysEx on that route

The square shows what's set, e.g. `1→10` for channel 1 moved to channel 10, and `•` when something is blocked.

**Clock.** The Clock row under the matrix decides which outputs get clock. Clock comes from one place, chosen at the top of the window:
- **Internal** – the app's own clock, with BPM, tap tempo, Start, Stop and Continue. *Clock while stopped* (on by default) keeps clock running while stopped, so arpeggiators, LFOs and delays stay in time.
- **From an input** – follow a device's clock (a drum machine or sequencer, say) and pass its clock, start, stop, continue and song position to the ticked outputs. Its tempo is shown at the top.
- **Off** – no clock is sent.

Clock never goes through the routes, only through the Clock row. Clock from any input that isn't the chosen source is dropped, so you never end up with two clocks fighting.

The internal clock hands Core MIDI each tick ahead of time with an exact timestamp, so its timing doesn't depend on the app being in front or the Mac being busy.

**Activity lights.** Each input and output has a light that flashes on MIDI, so you can see what's arriving and where it's going.

**Devices come and go.** Plug devices in and out freely. Routes to a device that isn't connected stay in the matrix (greyed out) and work again when it's plugged back in, even if macOS gives it a new ID. Right-click a greyed-out device to forget it.

**Runs in the background.** Close the window and routing carries on. The menu bar icon has Start/Stop, the tempo, All Notes Off and Quit.

**All Notes Off** sends sustain off, all sound off and all notes off on every channel of every output.

Your setup is saved as you go and restored when the app opens.

### Keyboard

| | |
|---|---|
| ⌘↩ | Start / Stop the internal clock |
| ⌘T | Tap tempo |
| ⌘= / ⌘- | Tempo up / down by 1 BPM |
| ⌘. | All Notes Off |

## Building

Needs macOS 13 or later and Xcode 15 or later (Swift 5.9).

```sh
swift test            # routing, filter and clock tests
./make-app.sh         # build/DAWless MIDI.app, ad-hoc signed
./make-dmg.sh         # a test DMG
./release.sh          # Developer ID signed and notarized DMG
```

Every push builds, tests, and keeps a test DMG as a workflow artifact. **Actions › Release › Run workflow** builds a signed, notarized DMG and publishes it as a GitHub release. It needs the secrets listed at the top of `.github/workflows/release.yml`.

## Layout

- `Sources/DAWlessCore` – the routing logic, with no Core MIDI in it: the MIDI stream parser, route filters, the saved setup and the clock and tempo maths. Tested in `Tests/DAWlessCoreTests`.
- `Sources/DAWlessMIDI` – the app: the Core MIDI engine, the internal clock thread and the SwiftUI window and menu bar item.
