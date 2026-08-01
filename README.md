# DDCVolumeKeys

DDCVolumeKeys is a small native macOS menu bar app that routes the standard
volume and mute media keys to the speakers of one compatible external display.
It uses DDC (Display Data Channel) to control the display directly instead of
changing the selected macOS audio output.

Normal key presses change the volume by one step. Repeated presses accelerate
up to four steps. If exactly one compatible display is not available, the app
fails closed and leaves media-key handling to macOS.

## Quick start

On an Apple Silicon Mac:

```sh
brew install m1ddc
./build.sh
ditto dist/DDCVolumeKeys.app /Applications/DDCVolumeKeys.app
open /Applications/DDCVolumeKeys.app
```

On first launch, allow DDCVolumeKeys under **System Settings → Privacy &
Security → Accessibility**. The app then appears as `DDC` in the menu bar.
It handles the media keys only when it finds exactly one external display whose
volume can be read through DDC.

## Features

- Automatically discovers volume-capable DDC displays
- Filters internal and pseudo displays without DDC volume support
- Supports volume up, volume down, and mute
- Never changes the macOS audio output device
- Runs as a lightweight menu bar agent
- Can launch automatically at login
- English interface with automatic German localization on German systems
- Uses two-second timeouts for every `m1ddc` invocation
- Stores no telemetry and makes no network requests

## Requirements

- Apple Silicon Mac
- macOS 13 or later
- [`m1ddc`](https://github.com/waydabber/m1ddc)
- An external display whose audio controls work through DDC

Install `m1ddc` with Homebrew:

```sh
brew install m1ddc
```

## Build

The project intentionally has one build entry point. It runs the verification
suite, compiles a release binary, assembles the app bundle, and verifies its
signature:

```sh
./build.sh
```

The app is written to `dist/DDCVolumeKeys.app`.

To use a stable signing identity, pass its Keychain name:

```sh
DDC_VOLUME_KEYS_SIGN_IDENTITY="Apple Development: Your Name" ./build.sh
```

Without that variable, the app is ad-hoc signed. Ad-hoc signatures are suitable
for local testing, but macOS may require Accessibility permission again after
each rebuild.

If `m1ddc` is installed somewhere other than `/opt/homebrew/bin/m1ddc` or
`/usr/local/bin/m1ddc`, configure its path before launching the app:

```sh
defaults write de.mlemors.DDCVolumeKeys M1DDCPath /path/to/m1ddc
```

Restart DDCVolumeKeys after changing this setting.

## Install

Copy the built app to `/Applications` and launch it:

```sh
ditto dist/DDCVolumeKeys.app /Applications/DDCVolumeKeys.app
open /Applications/DDCVolumeKeys.app
```

On first launch, enable DDCVolumeKeys under **System Settings → Privacy &
Security → Accessibility**.

If a rebuilt app cannot reuse an old Accessibility entry, quit the app and
reset that permission once:

```sh
tccutil reset Accessibility de.mlemors.DDCVolumeKeys
```

Then launch the newly built app and enable it again. A stable signing identity
prevents this from recurring during normal development.

If MonitorControl continues to manage brightness, disable its volume-key
handling so only one app intercepts those keys.

## Troubleshooting

- **No response from the volume keys:** make sure Accessibility permission is
  enabled and that no other utility, such as MonitorControl, is also handling
  the volume keys.
- **No DDC display found:** confirm that `m1ddc display list` works in Terminal
  and that the display exposes a readable audio volume through DDC.
- **Multiple DDC displays found:** the app intentionally stays inactive rather
  than guessing which display should receive the command.
- **Commands time out:** DDCVolumeKeys limits every `m1ddc` invocation to two
  seconds and fails safely when the display does not respond.

## Project layout

```text
Sources/DDCVolumeKeys/              Core DDC and command logic
Sources/DDCVolumeKeysApp/           AppKit menu bar application
Sources/DDCVolumeKeysVerification/  Executable verification suite
Resources/                          Metadata, app icon, and localizations
.github/workflows/                  Continuous integration
build.sh                            Build, verify, package, and sign
```

## Privacy and security

DDCVolumeKeys runs entirely on the local Mac. It does not collect telemetry,
contact remote services, or change the selected macOS audio device. The local
diagnostic report shows display names but does not expose stable display
identifiers. Display identifiers are not persisted by the app.

Please report vulnerabilities according to [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a pull request.

## License

DDCVolumeKeys is available under the [MIT License](LICENSE).
