#!/usr/bin/env python3
"""Polish a raw recording of Bytes windows into a website clip.

  python3 videos/polish.py raw/rollover.mov raw/rollover.json site/videos/rollover.mp4

The JSON comes from the recording script, all coordinates in screen points:

  {"region": [x, y, w, h], "scale": 2, "windows": [[x, y, w, h], ...], "radius": 26,
   "background": "#rrggbb", "text": "#rrggbb",
   "events": [{"t": 1.2, "x": 300, "y": 400, "kind": "move" | "click" | "key"}, ...]}

Each window is cut out of the recording with its rounded corners and laid on a ground taken from
the theme (its page colour, mixed a little toward its text colour), with a soft shadow. The camera
zooms only around the cursor while something happens (clicks and keys, and the cursor moves right
after them), and follows it there; zoom and pan move on springs. Needs ffmpeg, numpy and Pillow.
"""

import argparse, json, math, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT_W, OUT_H, FPS = 1920, 1080, 60
PAD = 0.05            # scene padding around the windows, as a fraction of their width
ZOOM = 1.3            # how far the camera zooms in on the cursor
LEAD = 0.45           # seconds the zoom starts before the first click of a burst
TAIL = 1.4            # seconds it stays after the last thing that happened
GAP = 2.5             # clicks and keys closer than this stay one zoom
SPRING = (170.0, 26.0)  # stiffness, damping (mass 1): a quick move with a hint of overshoot


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def probe(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                                   "-show_entries", "stream=width,height:format=duration",
                                   "-of", "json", path])
    info = json.loads(out)
    s = info["streams"][0]
    return s["width"], s["height"], float(info["format"]["duration"])


def frames(path, w, h):
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-i", path, "-vf", f"fps={FPS}",
                             "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    size = w * h * 3
    while True:
        buf = proc.stdout.read(size)
        if len(buf) < size:
            break
        yield np.frombuffer(buf, np.uint8).reshape(h, w, 3)
    proc.wait()


class Spring:
    def __init__(self, value):
        self.value, self.velocity = value, 0.0

    def step(self, target, dt):
        k, c = SPRING
        for _ in range(4):
            h = dt / 4
            force = k * (target - self.value) - c * self.velocity
            self.velocity += force * h
            self.value += self.velocity * h
        return self.value


def bursts(events, duration):
    """Spans of time the camera is zoomed: clicks and keys closer than GAP, plus the cursor moves
    that follow within TAIL, from LEAD before the first to TAIL after the last."""
    acts = sorted(e["t"] for e in events if e["kind"] in ("click", "key"))
    spans = []
    for t in acts:
        if spans and t - spans[-1][1] < GAP:
            spans[-1][1] = t
        else:
            spans.append([t, t])
    moves = sorted(e["t"] for e in events if e["kind"] == "move")
    out = []
    for first, last in spans:
        end = last
        for t in moves:
            if end < t <= end + TAIL:
                end = t
        out.append((max(0.0, first - LEAD), min(duration - 0.9, end + TAIL)))
    return out


def cursor_at(events, t):
    """The cursor's position at t, between the logged steps."""
    before = [e for e in events if e["t"] <= t]
    after = [e for e in events if e["t"] > t]
    if not before:
        return (after[0]["x"], after[0]["y"]) if after else None
    a = before[-1]
    if not after:
        return a["x"], a["y"]
    b = after[0]
    f = (t - a["t"]) / max(1e-6, b["t"] - a["t"])
    return a["x"] + (b["x"] - a["x"]) * f, a["y"] + (b["y"] - a["y"]) * f


def main():
    p = argparse.ArgumentParser()
    p.add_argument("raw"); p.add_argument("log"); p.add_argument("out")
    a = p.parse_args()

    log = json.load(open(a.log))
    src_w, src_h, duration = probe(a.raw)
    rx, ry, rw, rh = log["region"]
    scale = src_w / rw  # what the recording really is, whatever the log says
    radius = log.get("radius", 26) * scale
    windows = [[(x - rx) * scale, (y - ry) * scale, w * scale, h * scale] for x, y, w, h in log["windows"]]
    windows = [[round(v) for v in win] for win in windows]

    # The scene: the windows where they stood, with padding, widened to 16:9.
    left = min(w[0] for w in windows); top = min(w[1] for w in windows)
    right = max(w[0] + w[2] for w in windows); bottom = max(w[1] + w[3] for w in windows)
    pad = (right - left) * PAD
    scene_w, scene_h = right - left + 2 * pad, bottom - top + 2 * pad
    if scene_w / scene_h < OUT_W / OUT_H:
        scene_w = scene_h * OUT_W / OUT_H
    else:
        scene_h = scene_w * OUT_H / OUT_W
    scene_w, scene_h = round(scene_w), round(scene_h)
    ox = (scene_w - (right - left)) / 2 - left
    oy = (scene_h - (bottom - top)) / 2 - top
    to_scene = lambda x, y: ((x - rx) * scale + ox, (y - ry) * scale + oy)

    # Ground and shadows, once.
    page = hex_rgb(log["background"]) if "background" in log else None
    if page is None:
        first = next(frames(a.raw, src_w, src_h))
        wx, wy, ww, wh = windows[0]
        page = tuple(int(v) for v in first[wy + wh // 2, wx + ww - 20])
    ink = hex_rgb(log.get("text", "#000000"))
    ground = tuple(round(pv + (iv - pv) * 0.07) for pv, iv in zip(page, ink))
    bg = Image.new("RGB", (scene_w, scene_h), ground)
    shadow = Image.new("L", (scene_w, scene_h), 0)
    draw = ImageDraw.Draw(shadow)
    for x, y, w, h in windows:
        sx, sy = x + ox, y + oy
        draw.rounded_rectangle([sx, sy + 0.012 * scene_h, sx + w, sy + h + 0.012 * scene_h], radius, fill=70)
    shadow = shadow.filter(ImageFilter.GaussianBlur(0.012 * scene_w))
    bg.paste(tuple(round(v * 0.45) for v in ink), (0, 0), shadow)
    bg = np.asarray(bg).astype(np.float32)
    masks = []
    for x, y, w, h in windows:
        m = Image.new("L", (w, h), 0)
        # Drawn at 4x and shrunk, so the corners are smooth.
        big = Image.new("L", (w * 4, h * 4), 0)
        ImageDraw.Draw(big).rounded_rectangle([0, 0, w * 4 - 1, h * 4 - 1], radius * 4, fill=255)
        m = big.resize((w, h), Image.LANCZOS)
        masks.append(np.asarray(m).astype(np.float32)[..., None] / 255)

    events = log["events"]
    spans = bursts(events, duration)
    print("zoom spans:", [(round(s, 2), round(e, 2)) for s, e in spans], file=sys.stderr)

    enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                            "-s", f"{OUT_W}x{OUT_H}", "-r", str(FPS), "-i", "-",
                            "-c:v", "libx264", "-crf", "20", "-preset", "medium",
                            "-pix_fmt", "yuv420p", "-movflags", "+faststart", a.out],
                           stdin=subprocess.PIPE)
    zoom, cx, cy = Spring(1.0), Spring(scene_w / 2), Spring(scene_h / 2)
    dt = 1 / FPS
    for i, frame in enumerate(frames(a.raw, src_w, src_h)):
        t = i * dt
        canvas = bg.copy()
        for (x, y, w, h), m in zip(windows, masks):
            sx, sy = round(x + ox), round(y + oy)
            part = frame[y:y + h, x:x + w].astype(np.float32)
            region = canvas[sy:sy + h, sx:sx + w]
            canvas[sy:sy + h, sx:sx + w] = part * m + region * (1 - m)

        active = any(s <= t <= e for s, e in spans)
        pos = cursor_at(events, t) if active else None
        if pos:
            px, py = to_scene(*pos)
            z_target, x_target, y_target = ZOOM, px, py
        else:
            z_target, x_target, y_target = 1.0, scene_w / 2, scene_h / 2
        z = max(1.0, zoom.step(z_target, dt))
        view_w, view_h = scene_w / z, scene_h / z
        x = cx.step(x_target, dt)
        y = cy.step(y_target, dt)
        x0 = min(max(x - view_w / 2, 0), scene_w - view_w)
        y0 = min(max(y - view_h / 2, 0), scene_h - view_h)
        image = Image.fromarray(canvas.astype(np.uint8))
        image = image.resize((OUT_W, OUT_H), Image.LANCZOS, box=(x0, y0, x0 + view_w, y0 + view_h))
        enc.stdin.write(image.tobytes())
    enc.stdin.close()
    enc.wait()


if __name__ == "__main__":
    sys.exit(main())
