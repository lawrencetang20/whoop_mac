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


def render_ring(score, path, size: int = 18, line: float = 3.0) -> bool:
    """Draw the ring to `path` as PNG. Returns True on success, False on any failure."""
    try:
        from AppKit import NSImage, NSBezierPath, NSColor, NSBitmapImageRep
        from Foundation import NSMakeRect, NSMakePoint, NSMakeSize

        img = NSImage.alloc().initWithSize_(NSMakeSize(size, size))
        img.lockFocus()

        cx = cy = size / 2.0
        radius = (size - line) / 2.0 - 0.5

        track = NSBezierPath.bezierPathWithOvalInRect_(
            NSMakeRect(cx - radius, cy - radius, radius * 2, radius * 2)
        )
        track.setLineWidth_(line)
        NSColor.colorWithCalibratedWhite_alpha_(1.0, 0.18).setStroke()
        track.stroke()

        if score and score > 0:
            r, g, b = zone_rgb(score)
            start = 90.0                                          # 12 o'clock
            end = 90.0 - 360.0 * min(100.0, float(score)) / 100.0  # clockwise
            arc = NSBezierPath.bezierPath()
            arc.appendBezierPathWithArcWithCenter_radius_startAngle_endAngle_clockwise_(
                NSMakePoint(cx, cy), radius, start, end, True
            )
            arc.setLineWidth_(line)
            arc.setLineCapStyle_(1)  # round caps
            NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, b, 1.0).setStroke()
            arc.stroke()

        img.unlockFocus()

        rep = NSBitmapImageRep.imageRepWithData_(img.TIFFRepresentation())
        png = rep.representationUsingType_properties_(4, None)  # 4 = PNG
        return bool(png.writeToFile_atomically_(str(path), True))
    except Exception:
        return False
