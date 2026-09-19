/*
 * GDStyle - shared drawing for the store (10.4-safe: no NSGradient, no
 * +bezierPathWithRoundedRect:xRadius:yRadius:, both Leopard-only).
 */
#import <Cocoa/Cocoa.h>
#import "GDCompat.h"

/* Non-ASCII text: Xcode 2.5 mangles it inside @"" literals. */
#define GDU(s) [NSString stringWithUTF8String:(s)]

NSBezierPath *GDRoundRect(NSRect r, float radius);
void GDFillVerticalGradient(NSRect r, NSColor *top, NSColor *bottom);
void GDDrawStars(NSRect r, float rating);          /* r: 5 stars wide */
void GDDrawBadge(NSRect r, GDVerdict v, BOOL known);
NSColor *GDBadgeColor(GDVerdict v);
void GDDrawImageFitted(NSImage *img, NSRect r, BOOL fill);  /* aspect fit or fill (cropped) */
void GDDrawPlaceholder(NSRect r, NSString *title);
void GDDrawText(NSString *s, NSRect r, NSFont *f, NSColor *c, BOOL truncate);

NSColor *GDAccentColor(void);
NSColor *GDSubtleTextColor(void);
NSColor *GDBackgroundColor(void);
