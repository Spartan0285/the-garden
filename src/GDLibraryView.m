#import "GDLibraryView.h"
#import "GDInstaller.h"
#import "GDCatalog.h"
#import "GDStyle.h"
#include <math.h>

#define MARGIN 24
#define ROW_H 64
#define BTN_W 116

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
        [self reload];
    }
    return self;
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [controls release];
    [rows release];
    [super dealloc];
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (void) setDelegate:(id)d { delegate = d; }
- (void) imageChanged:(NSNotification *)n { [self setNeedsDisplay:YES]; }

- (void) changed:(NSNotification *)n
{
    GDInstallJob *j = [n object];
    /* Progress ticks only need the bars updated, not a relayout. */
    if ([j isKindOfClass:[GDInstallJob class]] && [j state] == GDJobDownloading) {
        unsigned i;
        for (i = 0; i < [rows count]; i++) {
            NSArray *r = [rows objectAtIndex:i];
            if ([r objectAtIndex:1] == j && [r count] > 3) {
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

- (void) reload
{
    GDInstaller *inst = [GDInstaller sharedInstaller];
    NSArray *jobs = [inst jobs], *lib = [inst library];
    float w = NSWidth([self bounds]), y = 16 + 40, h;
    int i;
    unsigned k;

    for (k = 0; k < [controls count]; k++)
        [[controls objectAtIndex:k] removeFromSuperview];
    [controls removeAllObjects];
    [rows removeAllObjects];

    if ([jobs count]) {
        y += 4;
        for (i = (int)[jobs count] - 1; i >= 0; i--) {
            GDInstallJob *j = [jobs objectAtIndex:i];
            NSRect r = NSMakeRect(MARGIN, y, w - 2 * MARGIN, ROW_H);
            NSMutableArray *row = [NSMutableArray arrayWithObjects:@"job", j, [NSValue valueWithRect:r], nil];
            float bx = NSMaxX(r) - BTN_W - 6;
            if ([j isActive]) {
                NSProgressIndicator *bar = [[[NSProgressIndicator alloc] initWithFrame:
                                                NSMakeRect(r.origin.x + 84, y + 42, w - 2 * MARGIN - 200, 12)] autorelease];
                [bar setStyle:NSProgressIndicatorBarStyle];
                [bar setControlSize:NSSmallControlSize];
                if ([j progress] < 0) {
                    [bar setIndeterminate:YES];
                    [bar startAnimation:nil];
                } else {
                    [bar setIndeterminate:NO];
                    [bar setDoubleValue:[j progress] * 100];
                }
                [self addSubview:bar];
                [controls addObject:bar];
                [row addObject:bar];
                [self button:@"Cancel" at:NSMakeRect(bx, y + 18, BTN_W, 24) action:@selector(cancelJob:) tag:i];
            } else if ([j state] == GDJobDone) {
                if ([j launchPath])
                    [self button:@"Open" at:NSMakeRect(bx, y + 8, BTN_W, 24) action:@selector(openJob:) tag:i];
                [self button:@"Show in Finder" at:NSMakeRect(bx, y + 34, BTN_W, 24) action:@selector(revealJob:) tag:i];
            } else {
                [self button:@"Try Again" at:NSMakeRect(bx, y + 8, BTN_W, 24) action:@selector(retryJob:) tag:i];
                if ([j revealPath])
                    [self button:@"Show in Finder" at:NSMakeRect(bx, y + 34, BTN_W, 24) action:@selector(revealJob:) tag:i];
            }
            [rows addObject:row];
            y += ROW_H + 8;
        }
        y += 12 + 40;      /* room for the "Installed" heading */
    }

    for (k = 0; k < [lib count]; k++) {
        NSDictionary *e = [lib objectAtIndex:k];
        NSRect r = NSMakeRect(MARGIN, y, w - 2 * MARGIN, ROW_H);
        float bx = NSMaxX(r) - BTN_W - 6;
        if ([e objectForKey:@"launch"])
            [self button:@"Open" at:NSMakeRect(bx, y + 4, BTN_W, 22) action:@selector(openEntry:) tag:k];
        [self button:@"Show in Finder" at:NSMakeRect(bx, y + 22, BTN_W, 22) action:@selector(revealEntry:) tag:k];
        [self button:@"Move to Trash" at:NSMakeRect(bx, y + 40, BTN_W, 22) action:@selector(trashEntry:) tag:k];
        [rows addObject:[NSArray arrayWithObjects:@"entry", e, [NSValue valueWithRect:r], nil]];
        y += ROW_H + 8;
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
    return [[row objectAtIndex:0] isEqualToString:@"job"]
        ? [[[row objectAtIndex:1] item] path] : [[row objectAtIndex:1] objectForKey:@"path"];
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

- (void) drawRect:(NSRect)dirty
{
    GDInstaller *inst = [GDInstaller sharedInstaller];
    float w = NSWidth([self bounds]);
    BOOL anyJobs = [[inst jobs] count] > 0, drewInstalledHead = NO;
    unsigned i;

    [GDBackgroundColor() set];
    NSRectFill(dirty);
    GDDrawText(anyJobs ? @"Downloads" : @"Installed", NSMakeRect(MARGIN, 22, w - 2 * MARGIN, 26),
               [NSFont boldSystemFontOfSize:19], [NSColor blackColor], YES);
    if (!anyJobs)
        drewInstalledHead = YES;

    for (i = 0; i < [rows count]; i++) {
        NSArray *row = [rows objectAtIndex:i];
        NSRect r = [[row objectAtIndex:2] rectValue];
        [[NSColor whiteColor] set];
        [GDRoundRect(r, 6) fill];
        [[NSColor colorWithCalibratedWhite:0.86 alpha:1] set];
        [GDRoundRect(NSInsetRect(r, 0.5, 0.5), 6) stroke];
        if ([[row objectAtIndex:0] isEqualToString:@"job"]) {
            GDInstallJob *j = [row objectAtIndex:1];
            NSColor *c = [j state] == GDJobFailed ? GDBadgeColor(GDVerdictIncompatible) : GDSubtleTextColor();
            [self drawThumb:[[j item] thumbURL] title:[[j item] title] in:thumbRect(r)];
            GDDrawText([[j item] title], titleRect(r), [NSFont boldSystemFontOfSize:12], [NSColor blackColor], YES);
            [linkText() drawInRect:linkRect(r) withAttributes:linkAttrs()];
            GDDrawText([[j file] name], NSMakeRect(r.origin.x + 84, r.origin.y + 22, r.size.width - 200, 14),
                       [NSFont systemFontOfSize:10], GDSubtleTextColor(), YES);
            if (![j isActive] || [j state] != GDJobDownloading)
                GDDrawText([j status], NSMakeRect(r.origin.x + 84, r.origin.y + 38, r.size.width - 200, 26),
                           [NSFont systemFontOfSize:10], c, NO);
            else
                GDDrawText([j status], NSMakeRect(r.origin.x + 84, r.origin.y + 54, r.size.width - 200, 12),
                           [NSFont systemFontOfSize:9], c, YES);
        } else {
            NSDictionary *e = [row objectAtIndex:1];
            NSDate *d = [e objectForKey:@"date"];
            NSArray *inst2 = [e objectForKey:@"installed"];
            if (!drewInstalledHead) {
                GDDrawText(@"Installed", NSMakeRect(MARGIN, r.origin.y - 36, w - 2 * MARGIN, 26),
                           [NSFont boldSystemFontOfSize:19], [NSColor blackColor], YES);
                drewInstalledHead = YES;
            }
            [self drawThumb:[e objectForKey:@"thumb"] title:[e objectForKey:@"title"] in:thumbRect(r)];
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

- (GDInstallJob *) jobFor:(id)sender
{
    NSArray *jobs = [[GDInstaller sharedInstaller] jobs];
    int t = [sender tag];
    return t < (int)[jobs count] ? [jobs objectAtIndex:t] : nil;
}

- (NSDictionary *) entryFor:(id)sender
{
    NSArray *lib = [[GDInstaller sharedInstaller] library];
    int t = [sender tag];
    return t < (int)[lib count] ? [lib objectAtIndex:t] : nil;
}

- (void) cancelJob:(id)s { [[GDInstaller sharedInstaller] cancel:[self jobFor:s]]; }
- (void) retryJob:(id)s { [[GDInstaller sharedInstaller] retry:[self jobFor:s]]; }
- (void) openJob:(id)s { [[NSWorkspace sharedWorkspace] openFile:[[self jobFor:s] launchPath]]; }
- (void) revealJob:(id)s
{
    NSString *p = [[self jobFor:s] revealPath];
    if (p)
        [[NSWorkspace sharedWorkspace] selectFile:p inFileViewerRootedAtPath:@""];
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

- (void) trashEntry:(id)s
{
    NSDictionary *e = [self entryFor:s];
    int r;
    if (e == nil)
        return;
    r = NSRunAlertPanel([NSString stringWithFormat:@"Move \"%@\" to the Trash?", [e objectForKey:@"title"]],
                        @"The installed copy is moved to the Trash. You can get it again from the Garden.",
                        @"Move to Trash", @"Cancel", nil);
    if (r == NSAlertDefaultReturn)
        [[GDInstaller sharedInstaller] removeLibraryEntry:e moveToTrash:YES];
}

@end
