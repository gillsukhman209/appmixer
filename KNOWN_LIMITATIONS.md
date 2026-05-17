# Known Limitations

## macOS 14.2+

This is the best supported path. AppMixer uses public CoreAudio process taps. The sliders are not simulated: app audio is captured, the original tapped playback is muted while read, gain/mute is applied to buffers, and the result is played to the selected real output device.

Limitations:

- Some protected/system processes may not expose useful bundle identifiers or may reject tapping.
- DRM-protected or exclusive-mode audio can behave differently by app.
- The current mixer assumes stereo float tap buffers and a 48 kHz output unit. Devices with unusual formats may need format conversion/resampling.
- The simple ring buffer is meant for a working prototype, not low-latency production release quality.

## macOS 13.0-14.1

Apple does not expose `AudioHardwareCreateProcessTap` until macOS 14.2. For macOS 13, the closest real workaround is a HAL `AudioServerPlugIn` virtual output device.

Included:

- A virtual output plug-in source that publishes `AppMixer Virtual Output`.
- HAL client tracking through `AudioServerPlugInClientInfo`, including process ID and bundle ID when available.
- Per-client gain application in `DoIOOperation` for mix/process phases.
- A custom bundle-gain property (`'amgn'`) for app/helper control.
- Install/uninstall scripts.

Remaining production work for macOS 13:

- A privileged helper or IPC transport must drain the virtual device's mixed audio and write it to the selected physical output device.
- The SwiftUI app currently uses the process-tap backend for actual playback routing; on macOS 13 it surfaces the limitation and can install/select the virtual device.
- Production distribution needs a Developer ID signing/notarization flow and a hardened installer/helper.

The macOS 13 path is therefore a real HAL virtual-device implementation scaffold, but the fully routed per-app mixer behavior is only complete on macOS 14.2+ through public process taps.
