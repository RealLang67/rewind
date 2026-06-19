# Rewind

Rewind is a free, open-source macOS app for instantly clipping highlights of your gameplay. It sits quietly in your menu bar and is always ready to capture your best gaming moments with a simple hotkey.

## Features

- **Instant Replay Capture:** Save the last X seconds of your gameplay instantly (customizable duration).
- **Always Record Mode:** Optionally record continuously so you never miss a moment.
- **Customizable Quality:** Adjust resolution, frame rate, audio codec and container format to suit your needs.
- **Global Hotkeys:** Configure custom hotkeys for starting/stopping recording and saving replays.
- **Audio Feedback:** Hear customizable sound cues when a recording starts, stops, saves or if an error occurs.
- **Discord Rich Presence:** Show off what you're recording to your friends on Discord.

## Requirements

- macOS 14.0 (Ventura) or later
- At least 10 gb of free disk space

## Installation

You can download the latest pre-compiled version of Rewind from the [Releases](https://github.com/l1zov/rewind/releases) page.

If you prefer to build from source, follow the instructions below.

## Building from Source

Rewind is built using Swift and Swift Package Manager.

1. Clone the repository:
   ```bash
   git clone https://github.com/l1zov/rewind.git
   cd rewind
   ```

2. You can build and run the project using the command line:
   ```bash
   swift build
   swift run
   ```

## Permissions

For Rewind to capture your gameplay, it requires **Screen Recording** permissions. You will be prompted to grant this permission upon the first launch. You can manage this at any time in macOS `System Settings -> Privacy & Security -> Screen Recording`.

## Contact

Discord: https://discord.gg/4Dc9AgGC4e

## Donate

Ko-fi: https://ko-fi.com/l1zov

**Crypto:**
- USDT & USDC (Solana Network): `GhZQc8tGyNdGgSraq7KaLVzZH9EwJxESzKSf4bd7TkW1`
- USDT (TRON Network): `TYmyHtXYBJFgDsNjiM5gwMieemZG3KKJaq`
- LTC (LTC): `ltc1qpvwmcuhxucn07v6uql8af6wxnplt0mad07upsq`

## License

This project is licensed under the terms of the included [LICENSE](LICENSE) file.