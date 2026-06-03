# Rest Guardian

Rest Guardian is a tiny macOS rest-enforcement app for people who want work time to feel scarce and rest time to feel protected.

It stays as a small floating timer near the top of the screen. When work time ends, it covers the screen with a translucent rest overlay. You can extend work only one minute at a time, capped by a hard 50-minute continuous-work ceiling.

This is an early alpha built for personal use first.

## Features

- Floating top timer for work/rest status.
- GUI settings panel for work minutes, rest minutes, and continuous-work cap.
- Hard maximum continuous work cap of 50 minutes.
- `+1` work extension button, capped by your configured limit.
- Short playful reminders when adding work time.
- Translucent rest overlay.
- Rest suggestion carousel with low-pressure prompts.
- Optional “rest five more minutes” button.
- Return-to-work button only after at least five minutes of rest.

## Download

Download the latest macOS zip from GitHub Releases, unzip it, and open `Rest Guardian.app`.

The alpha build is currently unsigned and not notarized. macOS may require right-clicking the app and choosing Open the first time.

## Build From Source

```zsh
./build.sh
open "build/Rest Guardian.app"
```

The build script uses the local Command Line Tools Swift compiler. On this machine it prefers `MacOSX15.4.sdk` because the default SDK has a Swift module version mismatch.

## Local Data

Settings and logs are stored under:

```text
~/Library/Application Support/Rest Guardian/
```

The log records app events such as start, rest start, rest completion, and settings changes. It does not record screen content.

## License

MIT
