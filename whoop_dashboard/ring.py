"""Render a small recovery-ring PNG for the menu-bar status item.

Draws a faint track circle plus a colored arc proportional to the recovery score,
in the recovery-zone color — the WHOOP-style ring, native in the macOS menu bar.
Pure Cocoa (PyObjC, already a dependency via rumps); fails safe (returns False) so
the app can fall back to a text/emoji title if drawing ever fails.
"""

from __future__ import annotations


def zone_rgb(score):
    if score is None:
        return (0.55, 0.55, 0.60)
    if score >= 67:
        return (0.20, 0.83, 0.60)   # green
    if score >= 34:
        return (0.98, 0.75, 0.14)   # yellow
    return (0.97, 0.44, 0.44)       # red


def render_ring(score, path, size: int = 18, line: float = 2.6) -> bool:
    """Draw a WHOOP-style recovery badge — a zone-colored ring next to the score in big,
    legible, zone-colored numerals — to `path` as a PNG. The image is sized to the menu bar
    (height `size`, width auto). Returns True on success, False on any failure."""
    try:
        from AppKit import (NSImage, NSBezierPath, NSColor, NSBitmapImageRep, NSFont,
                            NSFontAttributeName, NSForegroundColorAttributeName)
        from Foundation import NSMakeRect, NSMakePoint, NSMakeSize, NSAttributedString

        r, g, b = zone_rgb(score)
        color = NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, b, 1.0)

        # Measure the score text first, so we can size the canvas to fit ring + number.
        astr = None
        if score is not None:
            astr = NSAttributedString.alloc().initWithString_attributes_(
                str(int(score)),
                {NSFontAttributeName: NSFont.systemFontOfSize_weight_(size * 0.72, 0.5),
                 NSForegroundColorAttributeName: color},
            )
        gap = size * 0.18
        text_w = astr.size().width if astr else 0.0
        width = size + (gap + text_w + size * 0.06 if astr else 0.0)

        img = NSImage.alloc().initWithSize_(NSMakeSize(width, size))
        img.lockFocus()

        cx = cy = size / 2.0
        radius = (size - line) / 2.0 - 0.5
        track = NSBezierPath.bezierPathWithOvalInRect_(
            NSMakeRect(cx - radius, cy - radius, radius * 2, radius * 2)
        )
        track.setLineWidth_(line)
        NSColor.colorWithCalibratedWhite_alpha_(1.0, 0.22).setStroke()
        track.stroke()

        if score and score > 0:
            arc = NSBezierPath.bezierPath()
            arc.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_clockwise_(
                NSMakePoint(cx, cy), radius, 90.0, 90.0 - 360.0 * min(100.0, float(score)) / 100.0, True
            )
            arc.setLineWidth_(line)
            arc.setLineCapStyle_(1)  # round caps
            color.setStroke()
            arc.stroke()

        if astr is not None:
            astr.drawAtPoint_(NSMakePoint(size + gap, cy - astr.size().height / 2.0))

        img.unlockFocus()

        rep = NSBitmapImageRep.imageRepWithData_(img.TIFFRepresentation())
        png = rep.representationUsingType_properties_(4, None)  # 4 = PNG
        return bool(png.writeToFile_atomically_(str(path), True))
    except Exception:
        return False
