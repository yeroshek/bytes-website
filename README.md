# Bytes website

The website for [Bytes](https://github.com/yeroshek/bytes), and the feature videos it shows.

## Presentation vault

`vault/` holds the notes every video is recorded over. File names and text may use `{today}` and
`{yesterday}` (`2026-11-01`) and `{today:title}` (`Sun, 1 Nov 2026`); a run copies the vault to a
temporary folder with them filled in, so the dates are always current. Edit notes here, never in
the copy.

## Scenes

`scenes/<feature>.yaml` describes one video: the window (size, theme, sidebar, tabs and layout),
the steps (`wait`, `click`, `move`, `key`, aimed at elements by their text, not by pixels) and the
camera.

## Videos

Each `videos/bytes-video-*.sh` records one feature from a Debug build of Bytes ("Bytes Dev"),
never the installed Bytes.app, over a demo vault it writes to `/tmp/bytes-video/vault`.

1. Build: `xcodebuild build -project apps/apple/Bytes.xcodeproj -scheme Bytes -configuration Debug -derivedDataPath /tmp/bytes-video/dd` in a Bytes checkout.
2. Grant Accessibility and Screen Recording to the app that runs the script; `brew install cliclick`.
3. Run `videos/bytes-video-rollover.sh` once to get `check.png`, find the "→ 3" button, then
   `BUTTON=x,y videos/bytes-video-rollover.sh` to record `rollover.mov`.

Abort at any time: `pkill -f "Bytes Dev"; pkill -x screencapture`.

## Polish

`videos/polish.py raw.mov raw.json out.mp4` turns a raw recording and its events log into a
1920×1080, 60 fps clip: each window cut out with rounded corners on a ground from the Bytes theme,
with a soft shadow. The camera zooms only around the cursor while something happens (clicks, keys
and the moves right after), follows it there, and moves on springs. Needs `ffmpeg`, numpy and
Pillow. Trim long still endings from the raw recording first (`ffmpeg -i raw.mov -t 8.5 -c copy`).
