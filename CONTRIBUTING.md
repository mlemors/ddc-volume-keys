# Contributing

Thanks for considering a contribution to DDCVolumeKeys.

## Development setup

You need macOS 13 or later, Swift 6, and an Apple Silicon Mac. Install
[`m1ddc`](https://github.com/waydabber/m1ddc) to test against a physical
DDC-capable display.

Build the app and run the portable unit/fail-safe checks with:

```sh
./build.sh
```

The resulting application is written to `dist/DDCVolumeKeys.app`.

With a full Xcode installation, the XCTest target can also be run directly and
is run automatically by `./build.sh`:

```sh
swift test
```

The standalone `swift test` command requires Xcode because the Command Line
Tools package does not include the XCTest framework headers.

## Pull requests

- Keep changes focused and explain the user-facing behavior.
- Add or update verification coverage when changing core behavior.
- Run `./build.sh` before opening the pull request.
- Do not commit build output, signing certificates, or machine-specific files.

By contributing, you agree that your contribution is licensed under the MIT
License.
