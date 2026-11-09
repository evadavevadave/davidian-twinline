# Davidian Twinline

A Davidian LV2 model of a bucket-brigade doubler, based on the circuit of a classic 1970s double-tracking pedal. The model has a BS170 boost stage, then the dry signal and a V3205 BBD delay are mixed by a Blend pot. A switch picks a short doubling delay or a longer slapback. Mono in and out, no latency on the dry path. Made with AI assistance; see [Use of AI](#use-of-ai).

## Download

Ready-made builds are on the [Releases](https://github.com/evadavevadave/davidian-twinline/releases) page:

| Download | For |
|---|---|
| `…-windows-x64.zip` | Windows 10/11, 64-bit hosts |
| `…-macos-universal.zip` | macOS 10.13 or later, Apple silicon and Intel |
| `…-linux-x64.zip` | 64-bit Intel/AMD Linux (glibc 2.35 or later) |
| `…-linux-arm64.zip` | 64-bit ARM Linux, e.g. Raspberry Pi 4/5 (glibc 2.35 or later) |

## Install

Unzip, then copy the whole `twinline.lv2` folder into your LV2 folder:

| System | Per-user folder | All users |
|---|---|---|
| Windows | `%APPDATA%\LV2` | `%COMMONPROGRAMFILES%\LV2` |
| macOS | `~/Library/Audio/Plug-Ins/LV2` | `/Library/Audio/Plug-Ins/LV2` |
| Linux | `~/.lv2` | `/usr/lib/lv2` or `/usr/local/lib/lv2` |

Create the folder if it doesn't exist. If your host doesn't scan it, add it to the host's LV2 search path or set the `LV2_PATH` environment variable. Close the host before copying and restart it afterwards. Replace any older copy instead of keeping two: when two bundles have the same URI, the loader uses one and ignores the other.

**macOS:** the plugin isn't notarized, so macOS may block files downloaded from the internet. After copying, run this once in Terminal:

```bash
xattr -dr com.apple.quarantine ~/Library/Audio/Plug-Ins/LV2/twinline.lv2
```

Look for **Davidian Twinline** in your host's plugin list. The plugin URI is `urn:davidian:twinline`.

## Build from source

The code is plain C (C99) with no dependencies beyond the system's own libraries. The LV2 interface is declared in the source, so no LV2 SDK is needed.

**Linux, BSD, macOS or MinGW:**

```bash
make
make test
make install
```

- Linux needs a C compiler and the X11 headers (`build-essential libx11-dev` on Debian/Ubuntu).
- macOS needs the Xcode command line tools. `make` builds a universal binary (Apple silicon and Intel).
- `make install` copies the bundle to your per-user LV2 folder. `make dist VERSION=x.y.z` zips it with the docs.

**Windows with Visual Studio** (the C++ tools; `build.bat` finds them itself):

```
build.bat
build.bat test
build.bat dist
```

The bundle ends up in `build/twinline.lv2`.

### Tests

- `test_host` loads the built plugin library directly and checks delay times, frequency response, BBD clock images, Blend and Level, block-size independence, overload and CPU use. It runs on every platform.
- `ui_render` renders the panel to a `.bmp` file without opening a window.
- `ui_check` (Windows) and `ui_check_mac` (macOS) host the GUI in a window and drive it with mouse input. `ui_load_check` (Linux) opens the X11 GUI, usually on a virtual display with `xvfb-run`.
- `lilv_check` (Windows) checks the bundle with the lilv LV2 parser borrowed from Ardour 9, if Ardour 9 is installed in `C:\Program Files\Ardour9`. On Linux, CI does the same check with `lv2info` and `lv2apply`.

GitHub Actions builds and tests on Windows, macOS and Linux (x64 and arm64) for every push. A `v*` tag also publishes the zips as a release.

## GUI

![GUI](docs/gui.png)

The bundle includes a native GUI (`twinline_ui`). Its look comes from a shared house style: `src/ui/style.h` (palette and text sizes), `font.h` (stroke font) and `canvas.h` (renderer). It draws with its own software renderer and puts the result in a native window: Win32 on Windows (`ui:WindowsUI`), X11 on Linux (`ui:X11UI`) and Cocoa on macOS (`ui:CocoaUI`).

- Drag a knob up or down to turn it. Hold Shift for fine control. Double-click resets it, and the mouse wheel works too.
- Click the upper or lower half of the Delay switch to pick Double or Slap.
- Click the footswitch to engage or bypass the pedal. Its red LED shows the state.
- The readout shows the name and value of the last control you touched.

The panel name, Twinline, is original. The panel uses none of the original unit's logo, wordmark or artwork.

## Controls

| Control | Range | Default | Circuit part |
|---|---|---|---|
| Level | 0 to +20 dB | 0 dB | C5K pot in the BS170 boost stage |
| Blend | 0–1 (dry to wet) | 0.75 | A10K pot. Audio taper, about 10% wet at noon |
| Delay | Double / Slap | Double | SPST delay switch on the CD4047 clock |
| Footswitch | on/off | on | The pedal's bypass switch. Off passes the input through untouched |
| Enabled | on/off | on | Host bypass (`lv2:enabled`), so the host's bypass button works |

Both bypasses fade over about 10 ms. The circuit keeps running while bypassed, so switching back in doesn't click. Flipping the Delay switch while a note is sounding bends its pitch, as changing the clock does on the real pedal.

## How the model works

- **Boost:** the input is scaled by Level, then soft-limited with a slight asymmetry for the MOSFET stage. A 5 Hz high-pass removes the resulting DC.
- **Wet path:** a 100 Hz high-pass, then 4× oversampling (2× at 88.2/96 kHz, none at 176.4 kHz and up) for the BBD section.
- **Pre-filter:** a 7 kHz two-pole low-pass.
- **BBD:** a 2048-cell buffer clocked at the CD4047 rate, not the host's sample rate. Samples are taken and held at the clock edges, so the delay time, the aliasing and the clock images all follow the real clock. A soft limit before the BBD stands in for its limited voltage swing.
- **Post-filter:** a Sallen-Key low-pass (7 kHz, Q 0.73) and a 4.8 kHz one-pole, then a Butterworth filter back down to the host rate.
- **Mix:** dry and wet are mixed by the Blend taper, then crossfaded with the clean input for bypass.

## Values read from the layout

| Item | Value | From |
|---|---|---|
| Clock, Slap | 22.7 kHz → 90.1 ms | CD4047, f = 1/(4.4 RC), R = 100K, C = 100p |
| Clock, Double | 65.0 kHz → 31.5 ms | 47K + 6K8 switched in parallel with the 100K |
| BBD length | 4096 stages = 2048 clock periods | V3205 |
| Post-filter | 7.0 kHz, Q 0.73 | Sallen-Key, 33K/33K with 1n/470p |
| Output RC | 4.8 kHz | 33K and 1n |
| Pre-filter | 7.2 kHz | 4K7 and 4n7 (taken as a matching 7 kHz stage) |

Measured from the built plugin, the onset of a burst arrives after 32.8 ms (Double) and 91.4 ms (Slap). That includes the filters' group delay. The wet signal is about 0.2 dB down at 1 kHz, 5 dB down at 5 kHz and 11–12 dB down at 7 kHz. With a 5 kHz tone on Slap, the BBD clock image is about 36 dB below the tone. CPU use is about 0.5% of one core at 48 kHz.

## Estimates

The layout doesn't show these, so they are guesses. Tune them by ear:

- **Boost range and clipping:** 0 to +20 dB, with the boost limiting around +8 dBFS. This assumes 0 dBFS = 1 V. Constants are at the top of `src/twinline.c`.
- **BBD headroom:** a soft limit at about 1.2 V.
- **Wet high-pass:** 100 Hz.
- **Blend direction:** clockwise is assumed to be more wet.
- **The clock reading itself:** the timing parts were traced from a small image, so the two delay times could be off if the switch wiring differs from how it was traced.

## Simplifications

- No BBD hiss or bias trimmer (TR1). The V3205 here has no compander, so the real pedal is noisier than the model.
- The op amp filters are ideal, apart from the soft limits above.
- The LED indicator isn't modelled. The GUI's footswitch LED shows the bypass state instead.

## Code layout

| File | Contents |
|---|---|
| `src/twinline.c` | DSP and LV2 entry points |
| `src/ports.h` | Port numbers shared by the plugin and the GUI |
| `src/lv2_abi.h` | The LV2 C interface, so no SDK is needed |
| `src/ui/panel.h` | GUI layout, drawing and mouse handling, with no platform code |
| `src/ui/style.h`, `canvas.h`, `font.h` | House style, software renderer and stroke font |
| `src/ui/ui_lv2.c` | LV2 UI entry points and the Win32, X11 and Cocoa window layers |
| `bundle/` | LV2 metadata. `manifest.ttl.in` gets each platform's library names and GUI type at build time |
| `Makefile` | Linux, BSD, macOS and MinGW build |
| `build.bat` | Windows build with Visual Studio |
| `.github/workflows/build.yml` | CI builds and tests, and releases on `v*` tags |
| `tests/test_host.c` | DSP checks on the built plugin library |
| `tests/lilv_check.c` | Checks the bundle with the lilv LV2 parser (Windows) |
| `tests/ui_check.c` | Hosts the built GUI and drives it with mouse messages (Windows) |
| `tests/ui_check_mac.m` | The same for the Cocoa GUI (macOS) |
| `tests/ui_load_check.c` | Opens the X11 GUI and runs its idle loop (Linux) |
| `tests/ui_render.c` | Renders the panel to a .bmp file |

## Use of AI

This project was made with AI assistance. The code, tests, LV2 metadata and this README were written by Claude (Anthropic's Claude Opus 5.5, through Claude Code), directed and reviewed by the author.

- **The author** supplied the circuit layout, the GUI house style, the names and the licensing choices. They also decided what to build and changed parts of the result themselves.
- **The AI** read component values off the layout image and worked out the clock rates and filter corners. It also wrote the DSP model, adapted the GUI to this panel, and wrote the test programs and documentation.
- **Checking:** the results are checked by the automated tests described above (delay times, frequency response, Ardour's LV2 parser, and the GUI driven by simulated mouse input). The values listed under [Estimates](#estimates) are the AI's guesses and haven't been checked against a real pedal.

## License

Copyright (C) 2026 Davidian

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.

## Third-party licences

| Component | Licence | How it's used |
|---|---|---|
| LV2 C interface (`lv2/core/lv2.h`, `lv2/ui/ui.h`) | ISC | Its declarations are re-stated in `src/lv2_abi.h`, the UI ABI block of `src/ui/ui_lv2.c` and five test programs, so no LV2 SDK is needed. Copyright and permission notice in [LICENSE-LV2](LICENSE-LV2). |
| LV2 vocabularies (`lv2core`, `ui`, `units`) | ISC | The `.ttl` files refer to them by URI. Nothing is copied. |
| lilv | ISC | `tests/lilv_check.c` loads the copy that ships with Ardour 9 at run time. Not included in this repository. |
| Ardour 9 | GPL-2.0-or-later | Used only as a test host and as the source of lilv for `lilv_check`. No Ardour code is included. |
| Microsoft C runtime | Visual Studio licence | `build.bat` links it statically (`/MT`) into the DLLs you build. It counts as a system library under the GPL, so this is allowed. No binaries are committed to this repository. |
| Xlib (Linux) | MIT/X11 | The Linux GUI links to the system's `libX11` at run time. Not included. |
| macOS frameworks (Cocoa, Core Graphics) | Apple SDK licence | The macOS GUI links to the system frameworks at run time. They are system libraries under the GPL. Not included. |
| GitHub Actions | GitHub terms | Builds the release zips. Nothing from it ends up in the binaries. |

Every source file starts with an SPDX licence line saying which of these applies.
