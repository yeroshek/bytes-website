# Bytes website

The website for [Bytes](https://github.com/yeroshek/bytes), and the feature videos it shows.

## Videos

Each `videos/bytes-video-*.sh` records one feature from a Debug build of Bytes ("Bytes Dev"),
never the installed Bytes.app, over a demo vault it writes to `/tmp/bytes-video/vault`.

1. Build: `xcodebuild build -project apps/apple/Bytes.xcodeproj -scheme Bytes -configuration Debug -derivedDataPath /tmp/bytes-video/dd` in a Bytes checkout.
2. Grant Accessibility and Screen Recording to the app that runs the script; `brew install cliclick`.
3. Run `videos/bytes-video-rollover.sh` once to get `check.png`, find the "→ 3" button, then
   `BUTTON=x,y videos/bytes-video-rollover.sh` to record `rollover.mov`.

Abort at any time: `pkill -f "Bytes Dev"; pkill -x screencapture`.
