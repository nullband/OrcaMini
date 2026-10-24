# OrcaMini

A small [Orca](https://github.com/hundredrabbits/Orca) for iPad and iPhone, as an **AUv3 MIDI plugin** you load in AUM, Drambo or any AUv3 host.
The host owns tempo and transport. OrcaMini sends MIDI out to your instruments.

## Please read first: this is shared as-is

This is a finished hobby project that is being given away for anyone to use, learn from and change. It comes **as-is, with no support, no updates and no promise that it will work on your device or setup.**

If something doesn't work, or you find a bug, working it out is up to you. That is part of the deal, and the code is small and open so you can: the source is about 2,000 lines, `CUSTOMISE.md` shows where things live, and AI coding tools are good at this sort of change. You are warmly encouraged to fix it, improve it, and share your own version.

There is nobody behind this to ask. Please don't expect replies to questions, bug reports or requests. Have fun with it.

**Independent project. Not affiliated with, or endorsed by, Hundred Rabbits.** Orca is by Hundred Rabbits (MIT licence, included in `Licenses/`).
The operators, grid and MIDI output follow Orca's own interpreter; the shipped patches were checked against it frame by frame.

## What you need

- A Mac with Xcode 16 or newer (built here with Xcode 27.1)
- An iPad or iPhone and a cable. It is built for iOS 17 or newer and has been tested on iOS 26/27 only; the project builds for 17 but older systems have not been tried
- A free Apple ID is enough
- An AUv3 host on the device: AUM, Drambo, etc.

## Build it, step by step

1. Open `Config/Config.xcconfig` in any text editor and set two lines:
   - `TEAM_ID` is your Apple team ID. Find it in Xcode: **Settings > Accounts > your Apple ID**, or in the project: **OrcaMini target > Signing & Capabilities > Team**.
   - `BUNDLE_ID_PREFIX` must be unique to you, for example `com.yourname.orcamini`.
2. Double-click `OrcaMini.xcodeproj`.
3. Choose your iPad or iPhone at the top of Xcode (plug it in and unlock it; turn on **Settings > Privacy & Security > Developer Mode** the first time).
4. Press **Run** (the play button).
5. On the device, if it says "Untrusted Developer": **Settings > General > VPN & Device Management**, tap your Apple ID, **Trust**.
6. Open the OrcaMini app once, then open your AUv3 host, add a **MIDI plugin** and choose **OrcaMini**.

A free Apple ID installs expire after **7 days** and allow **3 apps** at a time. Press Run again in Xcode to renew.
A paid Apple developer account removes the 7-day limit.

If Xcode says it can't create a profile, the bundle ID is probably taken: change `BUNDLE_ID_PREFIX` to something more unusual.

To try it without a device, build for an iOS Simulator (leave `TEAM_ID` empty). Plugins can only be loaded inside a host app, so on a simulator you only see the small launcher screen.

## Using it

- Tap a cell to move the cursor. Pinch to zoom, double-tap to reset the zoom.
- **⌨︎** shows or hides the on-screen keyboard (glyph keys, arrows, copy, paste, and so on).
- `<` `>` change how fast the grid runs relative to the host tempo.
- **FILE** has New, Save, Load, Export and Import.
- Load the example patches: **FILE > Import...** and choose files from the `Patches/` folder (put them in the Files app first, for example by AirDrop or iCloud).

Notes on the differences from desktop Orca:
- `;` (UDP), `=` (OSC) and `$` send nothing. Those cells are still locked the same way, so patches behave the same.
- Tempo comes from the host. Orca's frame counter restarts when the host starts.
- Stopping the host sends All Notes Off.
- The grid is at most 128 x 96. Larger patches are cut off.

## Patches

`Patches/` has a few small examples. They are plain Orca `.orca` files and also open in desktop Orca.

## Changing the name

The name shown on the home screen and in the host list is set by `APP_DISPLAY_NAME` and `AU_MAKER_NAME` in `Config/Config.xcconfig`.

## Licence

MIT, see `LICENSE`. Orca (c) Hundredrabbits, MIT, see `Licenses/Orca-LICENSE.md`.
