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

`videos/bytes-video` runs a scene against Bytes Dev, a Debug build of Bytes, never the installed
Bytes.app. It sets the window up through the Accessibility tree (menu items by title, sidebar rows by
name), aims steps at elements by their text, and stops if anything but Bytes Dev comes to the front.

```
videos/bytes-video capture scenes/rollover.yaml   # writes the window block from Bytes Dev as you arranged it
videos/bytes-video watch   scenes/rollover.yaml   # on every save: fresh vault, set up, replay; ctrl-C stops
videos/bytes-video record  scenes/rollover.yaml   # set up, record, polish a preview; --full for full quality
videos/bytes-video setup   scenes/rollover.yaml   # only set the window up
videos/bytes-video check   scenes/rollover.yaml   # where each step aims in the Bytes Dev open now; no input
```

To set a scene up by hand: `setup` it (or launch Bytes Dev on `/tmp/bytes-video/vault`), arrange the
window, then `capture`. Capture reads the tabs from the panes on screen, so show them side by side.
`record` writes `raw/<scene>.mov`, `raw/<scene>.json` and `raw/<scene>-preview.mp4` (`<scene>.mp4`
with `--full`). Leave the Mac alone while `watch` replays or `record` runs.

Once: build Bytes Dev with `xcodebuild build -project apps/apple/Bytes.xcodeproj -scheme Bytes
-configuration Debug -derivedDataPath /tmp/bytes-video/dd` in a Bytes checkout (or point
`BYTES_DEV_APP` at its binary), give the app that runs the script Accessibility and Screen Recording,
and have ffmpeg, numpy and Pillow for the polish (`/tmp/bytes-video/venv` is used when present).

Abort at any time: `pkill -f "Bytes Dev"; pkill -x screencapture`.

## Polish

`videos/polish.py raw.mov raw.json out.mp4` turns a raw recording and its events log into a
1920×1080, 60 fps clip: each window cut out with rounded corners on a ground from the Bytes theme,
with a soft shadow. The camera zooms only around the cursor while something happens (clicks, keys
and the moves right after), follows it there, and moves on springs. Needs `ffmpeg`, numpy and
Pillow. Trim long still endings from the raw recording first (`ffmpeg -i raw.mov -t 8.5 -c copy`).
