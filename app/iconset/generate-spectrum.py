#!/usr/bin/env python3
"""Render the "Spectrum" app icon at 1024×1024 from the design handoff spec.

Geometry comes from `design_handoff_jamf_reports_app/README.md`:
- Dark slab background (#181B21 → #0E0F12, 160deg gradient with top-left sheen)
- Four horizontal compliance bands of decreasing length (verified, compliant,
  at-risk, critical) on a 200×200 viewBox, scaled up
- Five 2×6 tick markers at the bottom
- macOS 26 squircle (cornerRadius ≈ 22.37% of side — for 1024 that's ~229px)

Output: `AppIcon-1024.png`. Run `build-icon.sh` to slice into all sizes and
package as `AppIcon.icns`.
"""

from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path

SIZE = 1024
VIEWBOX = 200
SCALE = SIZE / VIEWBOX

# Squircle approximation — true superellipse is overkill for v1; a continuous
# rounded-rect at 22.37% radius reads identically at all icon sizes.
SQUIRCLE_RADIUS = int(SIZE * 0.2237)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def linear_gradient(size, start_color, end_color, angle_deg=160):
    """Render a linear gradient as an RGBA image. Angle measured clockwise from up."""
    import math
    w, h = size
    img = Image.new("RGBA", size)
    px = img.load()
    rad = math.radians(angle_deg)
    dx, dy = math.sin(rad), -math.cos(rad)
    # Project each pixel onto the gradient axis, normalize.
    proj_min = min(0 * dx + 0 * dy, w * dx + 0 * dy, 0 * dx + h * dy, w * dx + h * dy)
    proj_max = max(0 * dx + 0 * dy, w * dx + 0 * dy, 0 * dx + h * dy, w * dx + h * dy)
    span = proj_max - proj_min
    for y in range(h):
        for x in range(w):
            t = ((x * dx + y * dy) - proj_min) / span
            px[x, y] = (*lerp(start_color, end_color, t), 255)
    return img


def vertical_gradient_band(width, height, top_color, bottom_color):
    """Vertical gradient inside a band, rounded corners."""
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    px = img.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        c = (*lerp(top_color, bottom_color, t), 255)
        for x in range(width):
            px[x, y] = c
    return img


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


def render():
    bg = linear_gradient((SIZE, SIZE), (0x18, 0x1B, 0x21), (0x0E, 0x0F, 0x12), angle_deg=160)

    # Top-left sheen — radial highlight to give the slab depth.
    sheen = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    for r, alpha in [(SIZE * 0.55, 28), (SIZE * 0.40, 36), (SIZE * 0.25, 44)]:
        sd.ellipse(
            (
                int(SIZE * 0.05 - r),
                int(SIZE * 0.05 - r),
                int(SIZE * 0.05 + r),
                int(SIZE * 0.05 + r),
            ),
            fill=(255, 255, 255, alpha),
        )
    sheen = sheen.filter(ImageFilter.GaussianBlur(radius=SIZE * 0.08))
    bg = Image.alpha_composite(bg, sheen)

    canvas = bg.copy()
    # Bands: (x, y, w, h, top_color, bottom_color), all in viewBox units.
    bands = [
        # (verified — longest)
        (30, 50,  140, 22, (0x2A, 0x6B, 0x6B), (0x1A, 0x48, 0x48)),
        # (compliant)
        (30, 78,  110, 22, (0xF5, 0xC9, 0x37), (0xC9, 0x97, 0x0A)),
        # (at risk)
        (30, 106, 80,  22, (0xE0, 0x80, 0x20), (0xA4, 0x58, 0x10)),
        # (critical — shortest)
        (30, 134, 50,  22, (0xC0, 0x40, 0x40), (0x82, 0x20, 0x20)),
    ]
    for (x, y, w, h, top, bot) in bands:
        bw, bh = int(w * SCALE), int(h * SCALE)
        band = vertical_gradient_band(bw, bh, top, bot)
        # Round band corners (rx=6 in viewBox → ~30px at 1024).
        m = rounded_mask((bw, bh), int(6 * SCALE))
        band.putalpha(m)
        canvas.alpha_composite(band, dest=(int(x * SCALE), int(y * SCALE)))

    # Tick markers — five 2×6 marks at y=166.
    tick_color = (0x3A, 0x3F, 0x49, 255)
    tick_w, tick_h = max(1, int(2 * SCALE)), int(6 * SCALE)
    for tx in [44, 72, 100, 128, 156]:
        d = ImageDraw.Draw(canvas)
        cx, cy = int(tx * SCALE), int(166 * SCALE)
        d.rounded_rectangle(
            (cx - tick_w // 2, cy - tick_h // 2, cx + tick_w // 2, cy + tick_h // 2),
            radius=tick_w,
            fill=tick_color,
        )

    # Apply squircle mask so the dark slab respects the macOS app icon shape.
    mask = rounded_mask((SIZE, SIZE), SQUIRCLE_RADIUS)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(canvas, (0, 0), mask)

    return out


def main():
    out_dir = Path(__file__).resolve().parent
    img = render()
    target = out_dir / "AppIcon-1024.png"
    img.save(target, "PNG")
    print(f"wrote {target} ({target.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
