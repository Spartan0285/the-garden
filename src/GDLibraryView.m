#import "GDLibraryView.h"
#import "GDInstaller.h"
#import "GDCatalog.h"
#import "GDStyle.h"
#include <math.h>

#define MARGIN 24
#define ROW_H 86           /* a past download: three buttons, and a failure
                            * worth reading takes two lines above the date */
#define UPD_H 76           /* an update: three lines and two buttons */
#define ENTRY_H 88         /* an installed title */
#define BTN_W 116
#define BTN_H 20

@interface GDLibraryView (Private)
- (GDInstallJob *) updateJobAt:(unsigned)k;
- (void) reload;
@end

@implementation GDLibraryView

- (id) initWithFrame:(NSRect)f
{
    if ((self = [super initWithFrame:f]) != nil) {
        controls = [[NSMutableArray alloc] init];
        rows = [[NSMutableArray alloc] init];
        [self setAutoresizingMask:NSViewWidthSizable];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:)
                                                     name:GDJobChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:)
                                                     name:GDLibraryChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(imageChanged:)
                                                     name:GDImageLoadedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changed:)
                                                     name:GDUpdatesChangedNotification object:nil];
        docked = [[NSMutableSet alloc] init];
        [self reload];
    }
    return self;
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [controls release];
    [rows release];
    [docked release];
    [super dealloc];
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (void) setDelegate:(id)d { delegate = d; }
- (void) setShowsUpdates:(BOOL)f { showsUpdates = f; [self reload]; }
- (void) imageChanged:(NSNotification *)n { [self setNeedsDisplay:YES]; }

/* The job behind a row, while this run of the app still has one.  A record
 * from an earlier launch has none, and the row is drawn from the record. */
- (GDInstallJob *) jobForRow:(NSArray *)row
{
    if (![[row objectAtIndex:0] isEqualToString:@"past"])
        return nil;
    return [[GDInstaller sharedInstaller] jobForHistoryEntry:[row objectAtIndex:1]];
}

- (void) changed:(NSNotification *)n
{
    GDInstallJob *j = [n object];
    /* Progress ticks only need the bars updated, not a relayout. */
    if ([j isKindOfClass:[GDInstallJob class]] && [j state] == GDJobDownloading) {
        unsigned i;
        for (i = 0; i < [rows count]; i++) {
            NSArray *r = [rows objectAtIndex:i];
            if ([self jobForRow:r] == j && [r count] > 3) {
                NSProgressIndicator *bar = [r objectAtIndex:3];
                if ([j progress] >= 0) {
                    [bar setIndeterminate:NO];
                    [bar setDoubleValue:[j progress] * 100];
                }
                [self setNeedsDisplayInRect:[[r objectAtIndex:2] rectValue]];
                return;
            }
        }
    }
    [self reload];
}

- (NSButton *) button:(NSString *)title at:(NSRect)r action:(SEL)a tag:(int)tag
{
    NSButton *b = [[[NSButton alloc] initWithFrame:r] autorelease];
    [b setBezelStyle:NSRoundedBezelStyle];
    [[b cell] setControlSize:NSSmallControlSize];
    [b setFont:[NSFont systemFontOfSize:11]];
    [b setTitle:title];
    [b setTarget:self];
    [b setAction:a];
    [b setTag:tag];
    [self addSubview:b];
    [controls addObject:b];
    return b;
}

- (NSProgressIndicator *) barFor:(GDInstallJob *)j at:(NSRect)r
{
    NSProgressIndicator *bar = [[[NSProgressIndicator alloc] initWithFrame:r] autorelease];
    [bar setStyle:NSProgressIndicatorBarStyle];
    [bar setControlSize:NSSmallControlSize];
    if (j == nil || [j progress] < 0) {
        [bar setIndeterminate:YES];
        [bar startAnimation:nil];
    } else {
        [bar setIndeterminate:NO];
        [bar setDoubleValue:[j progress] * 100];
    }
    [self addSubview:bar];
    [controls addObject:bar];
    return bar;
}

static BOOL exists(NSString *p)
{
    return [p length] && [[NSFileManager defaultManager] fileExistsAtPath:p];
}

/* Where a finished download can be opened and shown, whether or not the job
 * that fetched it is still in memory. */
static NSString *recordLaunch(NSDictionary *h, GDInstallJob *j)
{
    NSString *p = j != nil ? [j launchPath] : nil;
    return exists(p) ? p : (exists([h objectForKey:@"launch"]) ? [h objectForKey:@"launch"] : nil);
}

static NSString *recordReveal(NSDictionary *h, GDInstallJob *j)
{
    NSString *p = j != nil ? [j revealPath] : nil;
    if (exists(p))
        return p;
    if (exists([h objectForKey:@"reveal"]))
        return [h objectForKey:@"reveal"];
    return exists([h objectForKey:@"launch"]) ? [h objectForKey:@"launch"] : nil;
}

static BOOL recordFinished(NSDictionary *h)
{
    return [[h objectForKey:@"state"] isEqualToString:@"done"];
}

- (void) reload
{
    GDInstaller *inst = [GDInstaller sharedInstaller];
    NSArray *hist = [inst history], *lib = [inst library];
    float w = NSWidth([self bounds]), y = 16 + 40, h;
    unsigned k;

    for (k = 0; k < [controls count]; k++)
        [[controls objectAtIndex:k] removeFromSuperview];
    [controls removeAllObjects];
    [rows removeAllObjects];

    if (showsUpdates) {
        NSArray *ups = [inst updates];
        unsigned waiting = 0;
        for (k = 0; k < [ups count]; k++)
            if (![self updateJobAt:k])
                waiting++;
        if (waiting > 1)
            [self button:@"Update All" at:NSMakeRect(w - MARGIN - BTN_W, 22, BTN_W, 24)
                  action:@selector(updateAll:) tag:0];
        for (k = 0; k < [ups count]; k++) {
            NSRect r = NSMakeRect(MARGIN, y, w - 2 * MARGIN, UPD_H);
            GDInstallJob *j = [self updateJobAt:k];
            NSMutableArray *row = [NSMutableArray arrayWithObjects:@"update",
                                      [ups objectAtIndex:k], [NSValue valueWithRect:r], nil];
            float bx = NSMaxX(r) - BTN_W - 6;
            if (j != nil) {
                /* Being fetched now: the bar and Cancel, where Update was. */
                [row addObject:[self barFor:j at:NSMakeRect(r.origin.x + 84, y + 58,
                                                            w - 2 * MARGIN - 200, 12)]];
                [self button:@"Cancel" at:NSMakeRect(bx, y + 14, BTN_W, 22)
                      action:@selector(cancelUpdate:) tag:k];
            } else {
                [self button:@"Update" at:NSMakeRect(bx, y + 14, BTN_W, 22)
                      action:@selector(updateOne:) tag:k];
                [self button:@"Ignore" at:NSMakeRect(bx, y + 40, BTN_W, 22)
                      action:@selector(ignoreUpdate:) tag:k];
            }
            [rows addObject:row];
            y += UPD_H + 16;
        }
        lib = [NSArray array];
        hist = [NSArray array];
    }

    if ([hist count]) {
        [self button:@"Clear" at:NSMakeRect(w - MARGIN - BTN_W, 22, BTN_W, 24)
              action:@selector(clearDownloads:) tag:0];
        y += 4;
        for (k = 0; k < [hist count]; k++) {
            NSDictionary *e = [hist objectAtIndex:k];
            GDInstallJob *j = [inst jobForHistoryEntry:e];
            NSRect r = NSMakeRect(MARGIN, y, w - 2 * MARGIN, ROW_H);
            NSMutableArray *row = [NSMutableArray arrayWithObjects:@"past", e,
                                      [NSValue valueWithRect:r], nil];
            float bx = NSMaxX(r) - BTN_W - 6;
            if (j != nil && [j isActive]) {
                [row addObject:[self barFor:j at:NSMakeRect(r.origin.x + 84, y + 44,
                                                            w - 2 * MARGIN - 200, 12)]];
                [self button:@"Cancel" at:NSMakeRect(bx, y + 28, BTN_W, BTN_H)
                      action:@selector(cancelPast:) tag:k];
            } else if ([[e objectForKey:@"state"] isEqualToString:@"retrying"]) {
                [row addObject:[self barFor:nil at:NSMakeRect(r.origin.x + 84, y + 44,
                                                              w - 2 * MARGIN - 200, 12)]];
            } else if (recordFinished(e)) {
                int slot = 0;
                if (recordLaunch(e, j))
                    [self button:@"Open" at:NSMakeRect(bx, y + 6 + 22 * slot++, BTN_W, BTN_H)
                          action:@selector(openPast:) tag:k];
                if (recordReveal(e, j))
                    [self button:@"Show in Finder" at:NSMakeRect(bx, y + 6 + 22 * slot++, BTN_W, BTN_H)
                          action:@selector(revealPast:) tag:k];
                [self button:@"Remove" at:NSMakeRect(bx, y + 6 + 22 * slot, BTN_W, BTN_H)
                      action:@selector(removePast:) tag:k];
            } else {
                /* Failed, cancelled, or cut short by a crash: offer it again. */
                [self button:@"Try Again" at:NSMakeRect(bx, y + 6, BTN_W, BTN_H)
                      action:@selector(retryPast:) tag:k];
                [self button:@"Remove" at:NSMakeRect(bx, y + 28, BTN_W, BTN_H)
                      action:@selector(removePast:) tag:k];
                if (recordReveal(e, j))
                    [self button:@"Show in Finder" at:NSMakeRect(bx, y + 50, BTN_W, BTN_H)
                          action:@selector(revealPast:) tag:k];
            }
            [rows addObject:row];
            y += ROW_H + 8;
        }
        y += 12 + 40;      /* room for the "Installed" heading */
    }

    for (k = 0; k < [lib count]; k++) {
        NSDictionary *e = [lib objectAtIndex:k];
        NSRect r = NSMakeRect(MARGIN, y, w - 2 * MARGIN, ENTRY_H);
        float bx = NSMaxX(r) - BTN_W - 6;
        NSString *launch = [e objectForKey:@"launch"];
        if (launch) {
            NSButton *dock;
            [self button:@"Open" at:NSMakeRect(bx, y + 4, BTN_W, 22) action:@selector(openEntry:) tag:k];
            dock = [self button:[docked containsObject:launch] ? @"In the Dock" : @"Add to Dock"
                             at:NSMakeRect(bx, y + 24, BTN_W, 22) action:@selector(dockEntry:) tag:k];
            [dock setEnabled:![docked containsObject:launch]];
        }
        [self button:@"Show in Finder" at:NSMakeRect(bx, y + 44, BTN_W, 22) action:@selector(revealEntry:) tag:k];
        [self button:GDU("Remove\xE2\x80\xA6") at:NSMakeRect(bx, y + 64, BTN_W, 22)
              action:@selector(removeEntry:) tag:k];
        [rows addObject:[NSArray arrayWithObjects:@"entry", e, [NSValue valueWithRect:r], nil]];
        y += ENTRY_H + 8;
    }
    h = y + 60;
    if ([self enclosingScrollView])
        h = MAX(h, NSHeight([[[self enclosingScrollView] contentView] bounds]));
    if (fabs(h - NSHeight([self frame])) > 0.5)
        [self setFrameSize:NSMakeSize(NSWidth([self frame]), h)];
    [[self window] invalidateCursorRectsForView:self];
    [self setNeedsDisplay:YES];
}

- (void) resizeWithOldSuperviewSize:(NSSize)old
{
    [super resizeWithOldSuperviewSize:old];
    [self reload];
}

static NSDictionary *linkAttrs(void)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:11], NSFontAttributeName,
               GDAccentColor(), NSForegroundColorAttributeName, nil];
}

static NSString *linkText(void) { return GDU("View in Store \xE2\x80\xBA"); }

/* The "View in Store" link sits top right, left of the buttons. */
static NSRect linkRect(NSRect row)
{
    NSSize s = [linkText() sizeWithAttributes:linkAttrs()];
    return NSMakeRect(NSMaxX(row) - BTN_W - 6 - 14 - s.width, row.origin.y + 8, s.width, s.height);
}

static NSRect thumbRect(NSRect row) { return NSMakeRect(row.origin.x + 8, row.origin.y + 8, 66, 48); }

static NSRect titleRect(NSRect row)
{
    return NSMakeRect(row.origin.x + 84, row.origin.y + 6,
                      NSMinX(linkRect(row)) - 12 - (row.origin.x + 84), 18);
}

- (NSString *) pathForRow:(NSArray *)row
{
    NSString *kind = [row objectAtIndex:0];
    if ([kind isEqualToString:@"update"])
        return [[[row objectAtIndex:1] objectForKey:@"entry"] objectForKey:@"path"];
    return [[row objectAtIndex:1] objectForKey:@"path"];
}

- (void) drawThumb:(NSString *)url title:(NSString *)t in:(NSRect)r
{
    NSImage *img = [[GDCatalog sharedCatalog] imageForURL:url];
    [NSGraphicsContext saveGraphicsState];
    [GDRoundRect(r, 4) addClip];
    if (img)
        GDDrawImageFitted(img, r, YES);
    else
        GDDrawPlaceholder(r, t);
    [NSGraphicsContext restoreGraphicsState];
}

/* What a past download's row says under the file name, and in what colour. */
static NSString *pastLine(NSDictionary *h, GDInstallJob *j, NSColor **ink)
{
    NSString *state = [h objectForKey:@"state"];
    if (j != nil && [j isActive]) {
        *ink = GDSubtleTextColor();
        return [j status];
    }
    if ([state isEqualToString:@"done"]) {
        *ink = GDSubtleTextColor();
        return [h objectForKey:@"status"] ?: @"Installed";
    }
    if ([state isEqualToString:@"retrying"]) {
        *ink = GDSubtleTextColor();
        return [h objectForKey:@"status"] ?: @"Trying again...";
    }
    *ink = GDBadgeColor(GDVerdictIncompatible);
    if ([state isEqualToString:@"cancelled"])
        return [h objectForKey:@"status"] ?: @"Cancelled";
    if ([state isEqualToString:@"interrupted"])
        return [h objectForKey:@"status"] ?: @"The Garden stopped before this finished.";
    return [h objectForKey:@"status"] ?: @"This download did not finish.";
}

- (void) drawRect:(NSRect)dirty
{
    GDInstaller *inst = [GDInstaller sharedInstaller];
    float w = NSWidth([self bounds]);
    BOOL anyPast = [[inst history] count] > 0, drewInstalledHead = NO;
    unsigned i;

    [GDBackgroundColor() set];
    NSRectFill(dirty);
    if (showsUpdates) {
        unsigned n = (unsigned)[[inst updates] count];
        GDDrawText(@"Updates", NSMakeRect(MARGIN, 22, w - 2 * MARGIN, 26),
                   [NSFont boldSystemFontOfSize:19], [NSColor blackColor], YES);
        if (n == 0)
            GDDrawText([[inst library] count] ? @"All the software you got from the Garden is up to date."
                                              : @"Software you get from the Garden is checked for newer versions here.",
                       NSMakeRect(MARGIN, 64, w - 2 * MARGIN, 20), [NSFont systemFontOfSize:12],
                       GDSubtleTextColor(), YES);
        for (i = 0; i < [rows count]; i++) {
            NSArray *row = [rows objectAtIndex:i];
            NSDictionary *u = [row objectAtIndex:1], *e = [u objectForKey:@"entry"];
            GDFile *f = [u objectForKey:@"file"];
            NSRect r = [[row objectAtIndex:2] rectValue];
            NSImage *icon = [inst iconForEntry:e];
            [[NSColor whiteColor] set];
            [GDRoundRect(r, 6) fill];
            [[NSColor colorWithCalibratedWhite:0.86 alpha:1] set];
            [GDRoundRect(NSInsetRect(r, 0.5, 0.5), 6) stroke];
            if (icon)
                GDDrawImageFitted(icon, NSMakeRect(r.origin.x + 12, r.origin.y + 12, 56, 56), NO);
            else
                [self drawThumb:[e objectForKey:@"thumb"] title:[e objectForKey:@"title"] in:thumbRect(r)];
            GDDrawText([e objectForKey:@"title"], titleRect(r), [NSFont boldSystemFontOfSize:12],
                       [NSColor blackColor], YES);
            [linkText() drawInRect:linkRect(r) withAttributes:linkAttrs()];
            {
                GDInstallJob *j = [self updateJobAt:i];
                NSString *line = j != nil ? [j status]
                    : [NSString stringWithFormat:@"Installed: %@", [e objectForKey:@"file"]];
                GDDrawText(line, NSMakeRect(r.origin.x + 84, r.origin.y + 26, r.size.width - 220, 14),
                           [NSFont systemFontOfSize:10],
                           j != nil ? [NSColor blackColor] : GDSubtleTextColor(), YES);
            }
            GDDrawText([NSString stringWithFormat:@"New: %@  %@  %@", [f name], [f sizeText] ?: @"",
                           [f date] ?: @""],
                       NSMakeRect(r.origin.x + 84, r.origin.y + 42, r.size.width - 220, 14),
                       [NSFont boldSystemFontOfSize:10], GDBadgeColor(GDVerdictNative), YES);
            if ([self updateJobAt:i] == nil)
                GDDrawText(@"Your current copy moves to the Trash once the update is installed.",
                           NSMakeRect(r.origin.x + 84, r.origin.y + 58, r.size.width - 220, 14),
                           [NSFont systemFontOfSize:9], GDSubtleTextColor(), YES);
        }
        return;
    }
    GDDrawText(anyPast ? @"Downloads" : @"Installed", NSMakeRect(MARGIN, 22, w - 2 * MARGIN, 26),
               [NSFont boldSystemFontOfSize:19], [NSColor blackColor], YES);
    if (!anyPast)
        drewInstalledHead = YES;

    for (i = 0; i < [rows count]; i++) {
        NSArray *row = [rows objectAtIndex:i];
        NSRect r = [[row objectAtIndex:2] rectValue];
        [[NSColor whiteColor] set];
        [GDRoundRect(r, 6) fill];
        [[NSColor colorWithCalibratedWhite:0.86 alpha:1] set];
        [GDRoundRect(NSInsetRect(r, 0.5, 0.5), 6) stroke];
        if ([[row objectAtIndex:0] isEqualToString:@"past"]) {
            NSDictionary *e = [row objectAtIndex:1];
            GDInstallJob *j = [self jobForRow:row];
            NSColor *ink = GDSubtleTextColor();
            NSString *line = pastLine(e, j, &ink);
            BOOL busy = (j != nil && [j isActive]) ||
                        [[e objectForKey:@"state"] isEqualToString:@"retrying"];
            [self drawThumb:[e objectForKey:@"thumb"] title:[e objectForKey:@"title"] in:thumbRect(r)];
            GDDrawText([e objectForKey:@"title"], titleRect(r), [NSFont boldSystemFontOfSize:12],
                       [NSColor blackColor], YES);
            [linkText() drawInRect:linkRect(r) withAttributes:linkAttrs()];
            GDDrawText([e objectForKey:@"file"], NSMakeRect(r.origin.x + 84, r.origin.y + 24,
                                                           r.size.width - 200, 14),
                       [NSFont systemFontOfSize:10], GDSubtleTextColor(), YES);
            if (busy)
                /* Under the bar. */
                GDDrawText(line, NSMakeRect(r.origin.x + 84, r.origin.y + 58, r.size.width - 200, 12),
                           [NSFont systemFontOfSize:9], ink, YES);
            else {
                /* No bar in the way: two lines, for a failure worth reading. */
                GDDrawText(line, NSMakeRect(r.origin.x + 84, r.origin.y + 40, r.size.width - 200, 26),
                           [NSFont systemFontOfSize:10], ink, NO);
                if ([e objectForKey:@"date"])
                    GDDrawText([[e objectForKey:@"date"]
                                   descriptionWithCalendarFormat:@"%B %e, %Y at %I:%M %p"
                                                        timeZone:nil locale:nil],
                               NSMakeRect(r.origin.x + 84, r.origin.y + 68, r.size.width - 200, 14),
                               [NSFont systemFontOfSize:9], GDSubtleTextColor(), YES);
            }
        } else {
            NSDictionary *e = [row objectAtIndex:1];
            NSDate *d = [e objectForKey:@"date"];
            NSArray *inst2 = [e objectForKey:@"installed"];
            if (!drewInstalledHead) {
                GDDrawText(@"Installed", NSMakeRect(MARGIN, r.origin.y - 36, w - 2 * MARGIN, 26),
                           [NSFont boldSystemFontOfSize:19], [NSColor blackColor], YES);
                drewInstalledHead = YES;
            }
            {
                /* The installed program's own icon; the Garden screenshot if none. */
                NSImage *icon = [inst iconForEntry:e];
                if (icon)
                    GDDrawImageFitted(icon, NSMakeRect(r.origin.x + 12, r.origin.y + 12, 56, 56), NO);
                else
                    [self drawThumb:[e objectForKey:@"thumb"] title:[e objectForKey:@"title"] in:thumbRect(r)];
            }
            GDDrawText([e objectForKey:@"title"], titleRect(r), [NSFont boldSystemFontOfSize:12],
                       [NSColor blackColor], YES);
            [linkText() drawInRect:linkRect(r) withAttributes:linkAttrs()];
            GDDrawText([inst2 count] ? [[inst2 objectAtIndex:0] stringByAbbreviatingWithTildeInPath] : @"",
                       NSMakeRect(r.origin.x + 84, r.origin.y + 26, r.size.width - 200, 14),
                       [NSFont systemFontOfSize:10], GDSubtleTextColor(), YES);
            GDDrawText(d ? [d descriptionWithCalendarFormat:@"Installed %B %e, %Y" timeZone:nil locale:nil] : @"",
                       NSMakeRect(r.origin.x + 84, r.origin.y + 42, r.size.width - 200, 14),
                       [NSFont systemFontOfSize:10], GDSubtleTextColor(), YES);
        }
    }
    if (!drewInstalledHead)
        GDDrawText(@"Installed", NSMakeRect(MARGIN, NSMaxY([[[rows lastObject] objectAtIndex:2] rectValue]) + 24,
                                            w - 2 * MARGIN, 26),
                   [NSFont boldSystemFontOfSize:19], [NSColor blackColor], YES);
    if ([[inst library] count] == 0) {
        float y = [rows count] ? NSMaxY([[[rows lastObject] objectAtIndex:2] rectValue]) + 60 : 60;
        GDDrawText(@"Software you get from the Garden appears here.",
                   NSMakeRect(MARGIN, y, w - 2 * MARGIN, 20), [NSFont systemFontOfSize:12],
                   GDSubtleTextColor(), YES);
    }
}

- (void) mouseUp:(NSEvent *)e
{
    /* The link, the picture and the title open the item's store page; so
     * does a double-click anywhere on the row. */
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    unsigned i;
    for (i = 0; i < [rows count]; i++) {
        NSArray *row = [rows objectAtIndex:i];
        NSRect r = [[row objectAtIndex:2] rectValue];
        if (!NSPointInRect(p, r))
            continue;
        if ([e clickCount] >= 2 || NSPointInRect(p, linkRect(r)) || NSPointInRect(p, thumbRect(r)) ||
            NSPointInRect(p, titleRect(r))) {
            if ([delegate respondsToSelector:@selector(libraryView:openItemPath:)])
                [delegate libraryView:self openItemPath:[self pathForRow:row]];
        }
        return;
    }
}

- (void) resetCursorRects
{
    unsigned i;
    for (i = 0; i < [rows count]; i++) {
        NSRect r = [[[rows objectAtIndex:i] objectAtIndex:2] rectValue];
        [self addCursorRect:linkRect(r) cursor:[NSCursor pointingHandCursor]];
        [self addCursorRect:thumbRect(r) cursor:[NSCursor pointingHandCursor]];
        [self addCursorRect:titleRect(r) cursor:[NSCursor pointingHandCursor]];
    }
}

/* ---------------------------------------------------------------- actions */

/* The job installing update k, while it runs; nil when nothing is. */
- (GDInstallJob *) updateJobAt:(unsigned)k
{
    NSArray *ups = [[GDInstaller sharedInstaller] updates];
    NSDictionary *e;
    GDInstallJob *j;
    if (k >= [ups count])
        return nil;
    e = [[ups objectAtIndex:k] objectForKey:@"entry"];
    j = [[GDInstaller sharedInstaller] jobForItemPath:[e objectForKey:@"path"]];
    return (j != nil && [j isActive]) ? j : nil;
}

- (void) cancelUpdate:(id)s
{
    GDInstallJob *j = [self updateJobAt:(unsigned)[s tag]];
    if (j != nil)
        [[GDInstaller sharedInstaller] cancel:j];
}

- (NSDictionary *) recordFor:(id)sender
{
    NSArray *hist = [[GDInstaller sharedInstaller] history];
    int t = [sender tag];
    return t >= 0 && t < (int)[hist count] ? [hist objectAtIndex:t] : nil;
}

- (NSDictionary *) entryFor:(id)sender
{
    NSArray *lib = [[GDInstaller sharedInstaller] library];
    int t = [sender tag];
    return t >= 0 && t < (int)[lib count] ? [lib objectAtIndex:t] : nil;
}

- (void) cancelPast:(id)s
{
    NSDictionary *h = [self recordFor:s];
    GDInstallJob *j = h ? [[GDInstaller sharedInstaller] jobForHistoryEntry:h] : nil;
    if (j != nil)
        [[GDInstaller sharedInstaller] cancel:j];
}

- (void) retryPast:(id)s
{
    NSDictionary *h = [self recordFor:s];
    if (h != nil)
        [[GDInstaller sharedInstaller] retryHistoryEntry:h];
}

- (void) removePast:(id)s
{
    NSDictionary *h = [self recordFor:s];
    if (h != nil)
        [[GDInstaller sharedInstaller] removeHistoryEntry:h];
}

- (void) openPast:(id)s
{
    NSDictionary *h = [self recordFor:s];
    NSString *p = h ? recordLaunch(h, [[GDInstaller sharedInstaller] jobForHistoryEntry:h]) : nil;
    if (p == nil || ![[NSWorkspace sharedWorkspace] openFile:p])
        NSBeep();
}

- (void) revealPast:(id)s
{
    NSDictionary *h = [self recordFor:s];
    NSString *p = h ? recordReveal(h, [[GDInstaller sharedInstaller] jobForHistoryEntry:h]) : nil;
    if (p)
        [[NSWorkspace sharedWorkspace] selectFile:p inFileViewerRootedAtPath:@""];
}

/* "Clear" on the Downloads heading: the whole list but what is still running. */
- (void) clearDownloads:(id)s
{
    [[GDInstaller sharedInstaller] clearHistory];
}

- (void) updateOne:(id)s
{
    NSArray *ups = [[GDInstaller sharedInstaller] updates];
    int t = [s tag];
    if (t < (int)[ups count])
        [[GDInstaller sharedInstaller] installUpdate:[ups objectAtIndex:t]];
}

- (void) ignoreUpdate:(id)s
{
    NSArray *ups = [[GDInstaller sharedInstaller] updates];
    int t = [s tag];
    if (t < (int)[ups count])
        [[GDInstaller sharedInstaller] ignoreUpdate:[ups objectAtIndex:t]];
}

- (void) updateAll:(id)s
{
    NSArray *ups = [[[[GDInstaller sharedInstaller] updates] copy] autorelease];
    unsigned i;
    for (i = 0; i < [ups count]; i++)
        if ([self updateJobAt:i] == nil)
            [[GDInstaller sharedInstaller] installUpdate:[ups objectAtIndex:i]];
}

- (void) dockEntry:(id)s
{
    NSDictionary *e = [self entryFor:s];
    if (e && [[GDInstaller sharedInstaller] addToDock:e]) {
        [docked addObject:[e objectForKey:@"launch"]];
        [self reload];
    } else {
        NSBeep();
    }
}

- (void) openEntry:(id)s
{
    NSString *p = [[self entryFor:s] objectForKey:@"launch"];
    if (p && ![[NSWorkspace sharedWorkspace] openFile:p])
        NSBeep();
}

- (void) revealEntry:(id)s
{
    NSArray *p = [[self entryFor:s] objectForKey:@"installed"];
    if ([p count])
        [[NSWorkspace sharedWorkspace] selectFile:[p objectAtIndex:0] inFileViewerRootedAtPath:@""];
}

/* Two different things people want: get rid of the software, or just stop the
 * store listing it (when the copy has been moved, or is wanted where it is). */
- (void) removeEntry:(id)s
{
    NSDictionary *e = [self entryFor:s];
    int r;
    if (e == nil)
        return;
    r = NSRunAlertPanel([NSString stringWithFormat:GDU("Remove \xE2\x80\x9C%@\xE2\x80\x9D?"),
                            [e objectForKey:@"title"]],
                        @"Moving it to the Trash removes the installed copy. Removing it from "
                         "the Library only forgets it here and leaves the copy alone. Either "
                         "way you can get it again from the Garden.",
                        @"Move to Trash", @"Cancel", @"Remove from Library");
    if (r == NSAlertDefaultReturn)
        [[GDInstaller sharedInstaller] removeLibraryEntry:e moveToTrash:YES];
    else if (r == NSAlertOtherReturn)
        [[GDInstaller sharedInstaller] removeLibraryEntry:e moveToTrash:NO];
}

@end
