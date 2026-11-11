Ready-made builds of the **Davidian Twinline** doubler in every plugin format it comes in: LV2, VST3 and (macOS) Audio Unit.

| Download | For | Formats |
|---|---|---|
| `…-windows-x64.zip` | Windows 10/11, 64-bit hosts | LV2, VST3 |
| `…-macos-universal.zip` | macOS 10.13 or later, Apple silicon and Intel | LV2, VST3, AU |
| `…-linux-x64.zip` | 64-bit Intel/AMD Linux (glibc 2.35 or later) | LV2, VST3 |
| `…-linux-arm64.zip` | 64-bit ARM Linux, e.g. Raspberry Pi 4/5 (glibc 2.35 or later) | LV2, VST3 |

**Install:** unzip, then copy the format your host uses into its plugin folder and restart the host:

| Format | Windows | macOS | Linux |
|---|---|---|---|
| `twinline.lv2` | `%APPDATA%\LV2` | `~/Library/Audio/Plug-Ins/LV2` | `~/.lv2` |
| `twinline.vst3` | `%COMMONPROGRAMFILES%\VST3` | `~/Library/Audio/Plug-Ins/VST3` | `~/.vst3` |
| `twinline.component` | | `~/Library/Audio/Plug-Ins/Components` | |

**macOS:** the plugins aren't notarized, so macOS may block files downloaded from the internet. After copying, run this once in Terminal for each one you installed, for example:

```
xattr -dr com.apple.quarantine ~/Library/Audio/Plug-Ins/Components/twinline.component
```

The LV2, VST3 (Windows, macOS) and Audio Unit versions have the GUI. The Linux VST3 shows the host's own controls. The VST3s pass Steinberg's validator and the Audio Unit passes Apple's auval.

Made with AI assistance. GPL-3.0-or-later; the VST3 C API header's BSD licence is in LICENSE-VST3.txt. See the README for the controls and what is modelled.
