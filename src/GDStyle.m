#import "GDStyle.h"
#include <math.h>

NSColor *GDAccentColor(void)
{
    return [NSColor colorWithCalibratedRed:0.16 green:0.45 blue:0.20 alpha:1];
}

NSColor *GDSubtleTextColor(void)
{
    return [NSColor colorWithCalibratedWhite:0.42 alpha:1];
}

NSColor *GDBackgroundColor(void)
{
    return [NSColor colorWithCalibratedWhite:0.975 alpha:1];
}

NSBezierPath *GDRoundRect(NSRect r, float rad)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    float minx = NSMinX(r), maxx = NSMaxX(r), miny = NSMinY(r), maxy = NSMaxY(r);
    rad = MIN(rad, MIN(r.size.width, r.size.height) / 2);
    [p moveToPoint:NSMakePoint(minx + rad, miny)];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(maxx, miny) toPoint:NSMakePoint(maxx, maxy) radius:rad];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(maxx, maxy) toPoint:NSMakePoint(minx, maxy) radius:rad];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(minx, maxy) toPoint:NSMakePoint(minx, miny) radius:rad];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(minx, miny) toPoint:NSMakePoint(maxx, miny) radius:rad];
    [p closePath];
    return p;
}

void GDFillVerticalGradient(NSRect r, NSColor *top, NSColor *bottom)
{
    /* Bands are cheap and look the same as a shading at these sizes. */
    NSColor *a = [top colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    NSColor *b = [bottom colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    int steps = MAX(2, MIN(48, (int)r.size.height / 2)), i;
    float h = r.size.height / steps;
    BOOL flipped = [[NSGraphicsContext currentContext] isFlipped];
    for (i = 0; i < steps; i++) {
        float t = (float)i / (steps - 1);
        NSRect band = NSMakeRect(r.origin.x, flipped ? r.origin.y + i * h : NSMaxY(r) - (i + 1) * h,
                                 r.size.width, ceil(h));
        [[a blendedColorWithFraction:t ofColor:b] set];
        NSRectFill(band);
    }
}

static NSBezierPath *starPath(NSPoint c, float R)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    BOOL flipped = [[NSGraphicsContext currentContext] isFlipped];
    int i;
    for (i = 0; i < 10; i++) {
        float rad = (i % 2) ? R * 0.45 : R;
        float a = M_PI / 2 + i * M_PI / 5;
        NSPoint q = NSMakePoint(c.x + rad * cos(a), c.y + (flipped ? -1 : 1) * rad * sin(a));
        if (i == 0) [p moveToPoint:q]; else [p lineToPoint:q];
    }
    [p closePath];
    return p;
}

void GDDrawStars(NSRect r, float rating)
{
    float w = r.size.width / 5, R = MIN(w, r.size.height) * 0.5;
    int i;
    for (i = 0; i < 5; i++) {
        NSPoint c = NSMakePoint(r.origin.x + w * i + w / 2, NSMidY(r));
        NSBezierPath *s = starPath(c, R);
        float fill = rating - i;
        [[NSColor colorWithCalibratedWhite:0.80 alpha:1] set];
        [s fill];
        if (fill > 0) {
            NSRect clip = NSMakeRect(c.x - R, c.y - R, 2 * R * MIN(fill, 1), 2 * R);
            [NSGraphicsContext saveGraphicsState];
            NSRectClip(clip);
            [[NSColor colorWithCalibratedRed:0.95 green:0.62 blue:0.10 alpha:1] set];
            [s fill];
            [NSGraphicsContext restoreGraphicsState];
        }
    }
}

NSColor *GDBadgeColor(GDVerdict v)
{
    switch (v) {
    case GDVerdictNative:  return [NSColor colorWithCalibratedRed:0.18 green:0.55 blue:0.22 alpha:1];
    case GDVerdictRosetta: return [NSColor colorWithCalibratedRed:0.20 green:0.42 blue:0.72 alpha:1];
    case GDVerdictClassic: return [NSColor colorWithCalibratedRed:0.45 green:0.32 blue:0.65 alpha:1];
    case GDVerdictNeedsClassic:
    case GDVerdictNeedsEmulator:
    case GDVerdictNeedsNewerOS: return [NSColor colorWithCalibratedRed:0.80 green:0.50 blue:0.08 alpha:1];
    case GDVerdictIncompatible: return [NSColor colorWithCalibratedRed:0.70 green:0.20 blue:0.18 alpha:1];
    default: return [NSColor colorWithCalibratedWhite:0.55 alpha:1];
    }
}

void GDDrawBadge(NSRect r, GDVerdict v, BOOL known)
{
    NSString *t = known ? [GDCompat shortLabel:v] : @"Checking...";
    NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSFont boldSystemFontOfSize:9], NSFontAttributeName,
                          [NSColor whiteColor], NSForegroundColorAttributeName, nil];
    NSSize s = [t sizeWithAttributes:a];
    NSRect pill = NSMakeRect(r.origin.x, r.origin.y, MIN(s.width + 12, r.size.width), r.size.height);
    [(known ? GDBadgeColor(v) : [NSColor colorWithCalibratedWhite:0.72 alpha:1]) set];
    [GDRoundRect(pill, r.size.height / 2) fill];
    [t drawAtPoint:NSMakePoint(pill.origin.x + 6, NSMidY(pill) - s.height / 2) withAttributes:a];
}

void GDDrawImageFitted(NSImage *img, NSRect r, BOOL fill)
{
    NSSize s = [img size];
    NSRect src, dst = r;
    float sx, sy, k;
    if (s.width <= 0 || s.height <= 0)
        return;
    sx = r.size.width / s.width;
    sy = r.size.height / s.height;
    if (fill) {
        k = MAX(sx, sy);
        src.size = NSMakeSize(r.size.width / k, r.size.height / k);
        src.origin = NSMakePoint((s.width - src.size.width) / 2, (s.height - src.size.height) / 2);
    } else {
        k = MIN(sx, sy);
        src = NSMakeRect(0, 0, s.width, s.height);
        dst.size = NSMakeSize(s.width * k, s.height * k);
        dst.origin = NSMakePoint(NSMidX(r) - dst.size.width / 2, NSMidY(r) - dst.size.height / 2);
    }
    [NSGraphicsContext saveGraphicsState];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    if ([[NSGraphicsContext currentContext] isFlipped]) {
        /* NSImage draws upside down into flipped views unless told otherwise. */
        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:0 yBy:NSMaxY(dst)];
        [t scaleXBy:1 yBy:-1];
        [t concat];
        dst.origin.y = 0;
    }
    [img drawInRect:dst fromRect:src operation:NSCompositeSourceOver fraction:1];
    [NSGraphicsContext restoreGraphicsState];
}

void GDDrawPlaceholder(NSRect r, NSString *title)
{
    GDFillVerticalGradient(r, [NSColor colorWithCalibratedRed:0.86 green:0.91 blue:0.85 alpha:1],
                              [NSColor colorWithCalibratedRed:0.74 green:0.83 blue:0.73 alpha:1]);
    if ([title length]) {
        NSString *initial = [[title substringToIndex:1] uppercaseString];
        NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSFont boldSystemFontOfSize:r.size.height * 0.45], NSFontAttributeName,
                              [NSColor colorWithCalibratedWhite:1 alpha:0.85], NSForegroundColorAttributeName, nil];
        NSSize s = [initial sizeWithAttributes:a];
        [initial drawAtPoint:NSMakePoint(NSMidX(r) - s.width / 2, NSMidY(r) - s.height / 2) withAttributes:a];
    }
}

void GDDrawText(NSString *s, NSRect r, NSFont *f, NSColor *c, BOOL truncate)
{
    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    NSDictionary *a;
    [ps setLineBreakMode:truncate ? NSLineBreakByTruncatingTail : NSLineBreakByWordWrapping];
    a = [NSDictionary dictionaryWithObjectsAndKeys:f, NSFontAttributeName, c,
            NSForegroundColorAttributeName, ps, NSParagraphStyleAttributeName, nil];
    [s ?: @"" drawInRect:r withAttributes:a];
}
