#!/bin/zsh
# Records the Roll Over Tasks video (~14 s) from the Bytes Dev build. Runs once, no loops.
# Needs: Accessibility and Screen Recording for the app running this script; cliclick (brew install cliclick).
# Usage: BUTTON=x,y videos/bytes-video-rollover.sh   (x,y: the "→ 3" button in screen points, from a check screenshot)
# Abort: pkill -f "Bytes Dev"; pkill -x screencapture
set -eu
APP="${APP:-/tmp/bytes-video/dd/Build/Products/Debug/Bytes Dev.app/Contents/MacOS/Bytes Dev}"
OUT="${OUT:-/tmp/bytes-video}"
VAULT="$OUT/vault"
today=$(date +%F); yesterday=$(date -v-1d +%F)

# The demo vault, dated so yesterday's open tasks roll over into today.
rm -rf "$VAULT"; mkdir -p "$VAULT/Daily"
cat > "$VAULT/Daily/$yesterday.md" <<NOTE
# $(date -v-1d +%A)

- [x] Reply to Ana about the launch
- [ ] Draft the website hero copy
- [ ] Record feature videos
  - [ ] Rollover
  - [ ] Go to Note
- [x] Fix the toolbar spacing
- [ ] Book train to Valencia
NOTE
cat > "$VAULT/Daily/$today.md" <<NOTE
# $(date +%A)

- [ ] Morning run
- [ ] Read 20 pages
NOTE
printf '# Website\n\nHero: plain Markdown notes, fast on every Mac.\n\n- Feature videos for each section\n- Pricing page draft\n' > "$VAULT/Website.md"
printf '# Spanish words\n\n- **madrugar** — to get up early\n- **sobremesa** — the talk after a meal\n- **estrenar** — to use something for the first time\n' > "$VAULT/Spanish words.md"
printf '# Reading list\n\n- The Timeless Way of Building\n- A Pattern Language\n- Shape Up\n' > "$VAULT/Reading list.md"

# Ignore saved windows: a restored one keeps its own vault and BYTES_VAULT is skipped.
BYTES_VAULT="$VAULT" "$APP" -ApplePersistenceIgnoreState YES >"$OUT/app.log" 2>&1 &
sleep 4
osascript <<OSA
tell application "System Events" to tell (first process whose bundle identifier is "md.bytes.app.dev")
  set frontmost to true
  set position of window 1 to {80, 60}
  set size of window 1 to {1280, 800}
  keystroke "o" using command down
  delay 0.5
  keystroke "$today"
  delay 0.5
  key code 36
end tell
OSA
sleep 1.5
screencapture -x "$OUT/check.png"
[[ -z "${BUTTON:-}" ]] && { echo "Check $OUT/check.png, then rerun with BUTTON=x,y"; exit 0; }

screencapture -v -V 14 -R 80,60,1280,800 "$OUT/rollover.mov" &
sleep 1.5
cliclick -e 400 m:"$BUTTON" w:200 c:.
sleep 2
osascript <<OSA
tell application "System Events" to tell (first process whose bundle identifier is "md.bytes.app.dev")
  keystroke return using command down
  delay 2
  keystroke "o" using command down
  delay 0.5
  keystroke "$yesterday"
  delay 0.5
  key code 36
end tell
OSA
wait
echo "Recorded $OUT/rollover.mov"
