#!/usr/bin/env python3
"""Renders the Unified Inbox / NEXUS app icon (dark glass, minimal).

Concept: three source apps (Teams purple, Outlook blue, WhatsApp green) orbiting and
feeding into one glowing ring: many streams, one hub.

Usage: python3 scripts/make_icon.py   → Resources/AppIcon.png + Resources/AppIcon.icns
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 4  # supersampling
N = 1024 * S
ROOT = os.path.join(os.path.dirname(__file__), "..", "Resources")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def squircle_mask(box, radius):
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def vertical_gradient(top, bottom):
    g = Image.new("RGBA", (1, N))
    for y in range(N):
        g.putpixel((0, y), lerp(top, bottom, y / (N - 1)))
    return g.resize((N, N))


def radial(center, radius, color, alpha):
    layer = Image.new("RGBA", (N, N), color + (0,))
    m = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(m)
    cx, cy = center
    steps = 60
    for i in range(steps, 0, -1):
        r = radius * i / steps
        a = int(alpha * (1 - i / steps) ** 1.6)
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=a)
    layer.putalpha(m)
    return layer


def render():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    # macOS icon grid: 824pt body inside 1024 canvas, ~185pt corner radius.
    pad = 100 * S
    box = (pad, pad, N - pad, N - pad)
    radius = 185 * S
    mask = squircle_mask(box, radius)

    # Drop shadow
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    sm = squircle_mask((box[0], box[1] + 14 * S, box[2], box[3] + 14 * S), radius)
    shadow.putalpha(sm.point(lambda v: int(v * 0.55)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22 * S))
    img = Image.alpha_composite(img, shadow)

    # Body: deep navy → near black, with an accent glow behind the hub
    body = vertical_gradient((30, 40, 66, 255), (6, 8, 16, 255))
    body = Image.alpha_composite(body, radial((N // 2, int(N * 0.52)), 430 * S, (140, 179, 255), 120))
    body.putalpha(mask)
    img = Image.alpha_composite(img, body)

    # Glass sheen on the upper half
    sheen = Image.new("RGBA", (N, N), (255, 255, 255, 0))
    sm2 = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(sm2)
    for y in range(box[1], N // 2):
        t = (y - box[1]) / (N // 2 - box[1])
        d.line([(0, y), (N, y)], fill=int(34 * (1 - t) ** 2))
    sheen.putalpha(ImageChops.multiply(sm2, mask))
    img = Image.alpha_composite(img, sheen)

    cx, cy = N // 2, int(N * 0.52)
    orbit = 268 * S
    sources = [  # angle (deg, 0 = right, counter-clockwise), colour
        (150, (93, 95, 199)),   # Teams
        (30, (0, 120, 212)),    # Outlook
        (270, (38, 173, 96)),   # WhatsApp
    ]

    hub_r = 150 * S

    # Orbit ring (very faint)
    od = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(od).ellipse((cx - orbit, cy - orbit, cx + orbit, cy + orbit),
                               outline=(255, 255, 255, 28), width=4 * S)
    img = Image.alpha_composite(img, od)

    # Hub: glowing ring
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((cx - hub_r, cy - hub_r, cx + hub_r, cy + hub_r),
                                 outline=(140, 179, 255, 220), width=46 * S)
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(26 * S)))
    ring = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse((cx - hub_r, cy - hub_r, cx + hub_r, cy + hub_r), outline=(196, 216, 255, 255), width=26 * S)
    # inner core
    core = 46 * S
    rd.ellipse((cx - core, cy - core, cx + core, cy + core), fill=(235, 242, 255, 255))
    img = Image.alpha_composite(img, ring)

    # Source orbs with soft glow + highlight
    for ang, col in sources:
        a = math.radians(ang)
        sx, sy = cx + orbit * math.cos(a), cy - orbit * math.sin(a)
        r = 62 * S
        g = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        ImageDraw.Draw(g).ellipse((sx - r * 1.5, sy - r * 1.5, sx + r * 1.5, sy + r * 1.5), fill=col + (150,))
        img = Image.alpha_composite(img, g.filter(ImageFilter.GaussianBlur(24 * S)))
        o = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        od2 = ImageDraw.Draw(o)
        od2.ellipse((sx - r, sy - r, sx + r, sy + r), fill=lerp(col, (255, 255, 255), 0.12) + (255,))
        img = Image.alpha_composite(img, o)
        # Soft top-left glass highlight, blurred so it reads as light, not a dent.
        h = Image.new("RGBA", (N, N), (0, 0, 0, 0))
        hr = r * 0.55
        ImageDraw.Draw(h).ellipse((sx - hr - r * 0.2, sy - hr - r * 0.35, sx + hr - r * 0.2, sy + hr - r * 0.35),
                                  fill=(255, 255, 255, 90))
        h = h.filter(ImageFilter.GaussianBlur(10 * S))
        orb_mask = Image.new("L", (N, N), 0)
        ImageDraw.Draw(orb_mask).ellipse((sx - r, sy - r, sx + r, sy + r), fill=255)
        h.putalpha(ImageChops.multiply(h.getchannel("A"), orb_mask))
        img = Image.alpha_composite(img, h)

    # Hairline border
    border = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(box, radius=radius, outline=(255, 255, 255, 46), width=4 * S)
    img = Image.alpha_composite(img, border)

    return img.resize((1024, 1024), Image.LANCZOS)


if __name__ == "__main__":
    os.makedirs(ROOT, exist_ok=True)
    icon = render()
    png = os.path.join(ROOT, "AppIcon.png")
    icon.save(png)
    icon.save(os.path.join(ROOT, "AppIcon.icns"),
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("wrote", png, "and AppIcon.icns")
