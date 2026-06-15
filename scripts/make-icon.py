"""Generate icon/WHOOP.icns — a recovery-ring app icon (dark squircle + glowing ring).

Run:  arch -arm64 .venv/bin/python scripts/make-icon.py
Pure Cocoa drawing + macOS `sips`/`iconutil` to assemble the .icns.
"""

import os
import subprocess
import tempfile


def draw_master(path, size=1024):
    from AppKit import (NSImage, NSBezierPath, NSColor, NSGradient, NSBitmapImageRep,
                        NSShadow, NSGraphicsContext)
    from Foundation import NSMakeRect, NSMakePoint, NSMakeSize

    img = NSImage.alloc().initWithSize_(NSMakeSize(size, size))
    img.lockFocus()

    # Rounded-square background with a vertical dark gradient.
    corner = size * 0.225
    bg = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
        NSMakeRect(0, 0, size, size), corner, corner)
    top = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.10, 0.11, 0.14, 1.0)
    bot = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.03, 0.03, 0.045, 1.0)
    NSGradient.alloc().initWithStartingColor_endingColor_(top, bot).drawInBezierPath_angle_(bg, -90.0)

    cx = cy = size / 2.0
    radius = size * 0.30
    line = size * 0.085

    # Faint full track.
    track = NSBezierPath.bezierPathWithOvalInRect_(
        NSMakeRect(cx - radius, cy - radius, radius * 2, radius * 2))
    track.setLineWidth_(line)
    NSColor.colorWithCalibratedWhite_alpha_(1.0, 0.07).setStroke()
    track.stroke()

    # Glowing recovery arc (~78%), green.
    NSGraphicsContext.currentContext().saveGraphicsState()
    glow = NSShadow.alloc().init()
    glow.setShadowColor_(NSColor.colorWithCalibratedRed_green_blue_alpha_(0.20, 0.83, 0.60, 0.85))
    glow.setShadowBlurRadius_(size * 0.055)
    glow.setShadowOffset_(NSMakeSize(0, 0))
    glow.set()
    arc = NSBezierPath.bezierPath()
    arc.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_clockwise_(
        NSMakePoint(cx, cy), radius, 90.0, 90.0 - 360.0 * 0.78, True)
    arc.setLineWidth_(line)
    arc.setLineCapStyle_(1)
    NSColor.colorWithCalibratedRed_green_blue_alpha_(0.20, 0.86, 0.62, 1.0).setStroke()
    arc.stroke()
    NSGraphicsContext.currentContext().restoreGraphicsState()

    # Inner dot accent.
    dot_r = size * 0.045
    dot = NSBezierPath.bezierPathWithOvalInRect_(
        NSMakeRect(cx - dot_r, cy - dot_r, dot_r * 2, dot_r * 2))
    NSColor.colorWithCalibratedRed_green_blue_alpha_(0.18, 0.83, 0.74, 1.0).setFill()
    dot.fill()

    img.unlockFocus()
    rep = NSBitmapImageRep.imageRepWithData_(img.TIFFRepresentation())
    png = rep.representationUsingType_properties_(4, None)  # PNG
    png.writeToFile_atomically_(path, True)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    icondir = os.path.join(root, "icon")
    os.makedirs(icondir, exist_ok=True)
    master = os.path.join(icondir, "icon_1024.png")
    draw_master(master, 1024)

    iconset = os.path.join(tempfile.mkdtemp(), "WHOOP.iconset")
    os.makedirs(iconset, exist_ok=True)
    for s in (16, 32, 128, 256, 512):
        for scale, px in ((1, s), (2, s * 2)):
            name = f"icon_{s}x{s}{'@2x' if scale == 2 else ''}.png"
            subprocess.run(["sips", "-z", str(px), str(px), master, "--out",
                            os.path.join(iconset, name)], check=True, capture_output=True)
    icns = os.path.join(icondir, "WHOOP.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("wrote", icns)


if __name__ == "__main__":
    main()
