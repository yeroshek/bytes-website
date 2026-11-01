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

## Polish

`videos/polish.py raw.mov out.mp4` turns a raw window recording into a website clip: a soft
background from the Bytes theme tokens, rounded corners, a shadow and planned zooms, at 1920×1080.
Needs `ffmpeg` and Pillow (`pip install pillow`).

```sh
python3 videos/polish.py rollover.mov rollover.mp4 --zoom 1.5,5,0.85,0.95,1.6 --trim 0.5,13
```

`--zoom START,END,X,Y,SCALE` eases in at START and out at END (seconds), towards X,Y given as
fractions of the window; repeat it for more zooms.
