#!/usr/bin/env python3
"""Polish a raw window recording into a website clip: a soft background from the theme's tokens,
rounded corners, a shadow, and planned zooms. Needs ffmpeg and Pillow.

  python3 videos/polish.py raw.mov out.mp4 [--zoom START,END,X,Y,SCALE ...] [--trim START,END]

X and Y are where to zoom, as fractions of the window (0..1). The zoom eases in over 0.6 s at START
and back out at END.
"""

import argparse, json, subprocess, sys, tempfile, os
from PIL import Image, ImageDraw, ImageFilter

W, H = 3840, 2160          # canvas, rendered at 2x then downscaled for a crisp, steady zoom
OUT_W, OUT_H = 1920, 1080
FPS = 30
BOX_W, BOX_H = 3200, 1840  # the window fits in this box, centred
RADIUS = 36                # window corner radius on the 2x canvas
RAMP = 0.6

# Background from packages/theme/tokens.json, light scheme: selectionMuted → selection.
TOP, BOTTOM = (227, 240, 255), (179, 215, 255)


def probe(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                   "-show_entries", "stream=width,height:format=duration",
                                   "-of", "json", path])
    info = json.loads(out)
    s = info["streams"][0]
    return s["width"], s["height"], float(info["format"]["duration"])


def background(win_w, win_h, x, y, path):
    bg = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(bg)
    for row in range(H):
        f = row / (H - 1)
        draw.line([(0, row), (W, row)], fill=tuple(round(a + (b - a) * f) for a, b in zip(TOP, BOTTOM)))
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, y + 40, x + win_w, y + 40 + win_h], RADIUS, fill=90)
    shadow = shadow.filter(ImageFilter.GaussianBlur(60))
    bg.paste((20, 30, 50), (0, 0), shadow)
    bg.save(path)


def mask(win_w, win_h, path):
    m = Image.new("L", (win_w, win_h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, win_w - 1, win_h - 1], RADIUS, fill=255)
    m.save(path)


def ease(a, b):
    """0 before a, smoothstep up to 1 over RAMP, 1 until b, back to 0 over RAMP."""
    up = f"clip((it-{a})/{RAMP},0,1)"
    down = f"clip((it-{b})/{RAMP},0,1)"
    return f"(({up})*({up})*(3-2*({up})) - ({down})*({down})*(3-2*({down})))"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("raw"); p.add_argument("out")
    p.add_argument("--zoom", action="append", default=[])
    p.add_argument("--trim")
    a = p.parse_args()

    src_w, src_h, duration = probe(a.raw)
    scale = min(BOX_W / src_w, BOX_H / src_h)
    win_w, win_h = round(src_w * scale) // 2 * 2, round(src_h * scale) // 2 * 2
    x, y = (W - win_w) // 2, (H - win_h) // 2 - 20

    tmp = tempfile.mkdtemp()
    bg, mk = os.path.join(tmp, "bg.png"), os.path.join(tmp, "mask.png")
    background(win_w, win_h, x, y, bg)
    mask(win_w, win_h, mk)

    # Zoom: z = 1 + Σ (scale-1)·ease; the focus point is the zoom-weighted focus of the active zoom.
    z, fx, fy = "1", f"{W/2}", f"{H/2}"
    for spec in a.zoom:
        s, e, zx, zy, zs = map(float, spec.split(","))
        k = ease(s, e)
        z += f"+{zs - 1}*{k}"
        px, py = x + zx * win_w, y + zy * win_h
        fx = f"({fx})+({px}-{W/2})*{k}"
        fy = f"({fy})+({py}-{H/2})*{k}"
    # zoompan's x,y are the top-left of the visible part, in input pixels; keep the focus centred,
    # clamped to the canvas.
    zx = f"clip(({fx})-iw/zoom/2,0,iw-iw/zoom)"
    zy = f"clip(({fy})-ih/zoom/2,0,ih-ih/zoom)"

    # The looped background and mask never end, so the output's length is set explicitly.
    trim, length = [], duration
    if a.trim:
        s, e = a.trim.split(",")
        trim, length = ["-ss", s, "-to", e], float(e) - float(s)

    graph = (
        f"[0:v]fps={FPS},scale={win_w}:{win_h}:flags=lanczos,format=rgba[v];"
        f"[2:v]format=gray[m];[v][m]alphamerge[win];"
        f"[1:v][win]overlay={x}:{y}:shortest=1,"
        f"zoompan=z='{z}':x='{zx}':y='{zy}':d=1:s={OUT_W}x{OUT_H}:fps={FPS},"
        f"format=yuv420p[out]"
    )
    cmd = ["ffmpeg", "-y", *trim, "-i", a.raw, "-loop", "1", "-i", bg, "-loop", "1", "-i", mk,
           "-filter_complex", graph, "-map", "[out]", "-an", "-t", f"{length:.3f}",
           "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-movflags", "+faststart", a.out]
    subprocess.run(cmd, check=True)


if __name__ == "__main__":
    sys.exit(main())
