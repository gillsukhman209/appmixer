# AppMixer

AppMixer is a macOS menu bar per-app volume mixer built with SwiftUI and CoreAudio.

## What Is Implemented

- SwiftUI `MenuBarExtra` app with a dark Control Center style popover.
- Live CoreAudio process enumeration using `kAudioHardwarePropertyProcessObjectList`.
- Active audio app rows with app icon, app name, volume slider, mute button, and persisted bundle-ID settings.
- Real per-process audio control on macOS 14.2+ using:
  - `AudioHardwareCreateProcessTap`
  - `CATapMutedWhenTapped`
  - private aggregate tap devices
  - HAL output audio unit playback to the selected real output device
- Master gain and per-app mute/gain are applied to captured audio buffers before playback.
- Output device enumeration and selection.
- AudioServerPlugIn virtual output source for local experimentation outside the App Store target.
- Install/uninstall scripts kept in the repository, not bundled in the App Store-facing app.

## Build

```sh
cd /Users/sukhmansingh/Desktop/Coding/2026/AppMixer
xcodebuild -project AppMixer.xcodeproj -scheme AppMixer -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Or open:

```sh
open /Users/sukhmansingh/Desktop/Coding/2026/AppMixer/AppMixer.xcodeproj
```

## Run

1. Build and run the `AppMixer` scheme.
2. Start audio in another app.
3. Open the AppMixer menu bar icon.
4. Press `Start`.
5. Adjust per-app sliders or mute buttons.

On macOS 14.2+, the app uses real CoreAudio process taps and mutes the original process playback while the tap is being read, then plays the processed audio to the selected real output device.

## Virtual Device Install

The AudioServerPlugIn source lives in:

```sh
/Users/sukhmansingh/Desktop/Coding/2026/AppMixer/VirtualAudioPlugin
```

Install:

```sh
/Users/sukhmansingh/Desktop/Coding/2026/AppMixer/Scripts/install_driver.sh
```

Uninstall:

```sh
/Users/sukhmansingh/Desktop/Coding/2026/AppMixer/Scripts/uninstall_driver.sh
```

The install script builds `AppMixerVirtualAudio.driver`, copies it to `/Library/Audio/Plug-Ins/HAL`, ad-hoc signs it, and restarts `coreaudiod`.

The SwiftUI app target does not bundle or expose this installer in the main UI. App Store distribution should use the sandboxed process-tap path and avoid installing HAL plug-ins from inside the app.

## Architecture

- `AppMixerApp`: SwiftUI menu bar entry point.
- `MenuBarController`: accessory-app shell hook.
- `AudioEngine`: session polling, tap lifecycle, UI state.
- `VirtualAudioDevice`: virtual output lookup and selection.
- `ProcessAudioSession`: active app audio model.
- `AppVolumeStore`: persisted bundle-ID volume/mute/master settings.
- `OutputDeviceManager`: CoreAudio output device listing and default output selection.
- `PermissionsManager`: API availability checks.
- `InstallerHelper`: app-side install script launcher.
- `CoreAudioTapBridge.mm`: Objective-C++ process tap and HAL output implementation.
- `VirtualAudioPlugin/AppMixerAudioServerPlugIn.cpp`: HAL virtual output device source.

## Known macOS Limitations

See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md).
