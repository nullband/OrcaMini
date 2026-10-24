# Changing OrcaMini

The code is small (about 2,000 lines of Swift and C++ in total) and split by job, so it suits AI-assisted editing: open the folder in Xcode, or in an AI coding tool, and name the file below in your request.

| You want to change | Where | Notes |
|---|---|---|
| Starting grid size | `OrcaMiniExtension/Runtime/OrcaRuntime.swift`, `static let gridW = 36, gridH = 16` | One line. |
| Biggest allowed grid | same file, `static let maxW = 128, maxH = 96` | Larger grids use more CPU. Test on a real device. |
| How big the cells look | `OrcaMiniExtension/UI/OrcaMiniExtensionMainView.swift`, `cellSize()` | Cell width and height, multiplied by the zoom. |
| Colours, buttons, keyboard layout, menus | the same `OrcaMiniExtensionMainView.swift` | Plain SwiftUI. Most visible changes happen here. |
| The home-screen icon | replace `OrcaMini/Assets.xcassets/AppIcon.appiconset/icon-1024.png` | A 1024 x 1024 PNG, no transparency. |
| App name | `Config/Config.xcconfig` | `APP_DISPLAY_NAME`. |
| Saving, loading, copy/paste | `OrcaMiniExtension/Runtime/OrcaRuntime.swift` | |
| Clock and MIDI timing | `OrcaMiniExtension/DSP/OrcaMiniExtensionDSPKernel.hpp` (C++) | Real-time code. Change only if you are comfortable, and test carefully. |
| What the operators do | `OrcaMiniExtension/Core/Orca.swift` | This is a port of Orca's interpreter. If you change an operator, your patches will no longer match desktop Orca. |

Tips for working with an AI tool:
- Give it the file name and one change at a time ("in OrcaRuntime.swift change the starting grid to 48 x 24").
- After each change, build and try it on the device before the next one.
- Keep your own copy of the original folder so you can go back.
