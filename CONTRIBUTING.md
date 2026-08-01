# Contributing

Thanks for considering a contribution to DDCVolumeKeys.

## Development setup

You need macOS 13 or later, Swift 6, and an Apple Silicon Mac. Install
[`m1ddc`](https://github.com/waydabber/m1ddc) to test against a physical
DDC-capable display.

Build the app and run all checks with:

```sh
./build.sh
```

The resulting application is written to `dist/DDCVolumeKeys.app`.

## Pull requests

- Keep changes focused and explain the user-facing behavior.
- Add or update verification coverage when changing core behavior.
- Run `./build.sh` before opening the pull request.
- Do not commit build output, signing certificates, or machine-specific files.

By contributing, you agree that your contribution is licensed under the MIT
License.
