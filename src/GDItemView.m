#import "GDItemView.h"
#import "GDCatalog.h"
#import "GDInstaller.h"
#import "GDStyle.h"
#import "GDHTTP.h"
#include <math.h>

#define LEFT_X 28
#define LEFT_W 220
#define RIGHT_X (LEFT_X + LEFT_W + 32)
#define SHOT_W 220
#define SHOT_H 150
#define MINI_W 124
#define MINI_H 150
#define REVIEWS_SHOWN 3

@interface GDItemView (Private)
- (void) rebuild;
- (float) layoutExtras:(float)width;
- (void) loadExtras;
- (void) drawExtras:(float)w;
- (void) link:(NSRect)r kind:(NSString *)kind object:(id)o;
- (void) fillGetMenu:(GDFile *)best;
- (void) getMenuChose:(id)sender;
@end

static NSDictionary *textAttrs(NSFont *f, NSColor *c)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:f, NSFontAttributeName, c, NSForegroundColorAttributeName, nil];
}

static float textHeight(NSString *s, NSFont *f, float w)
{
    NSAttributedString *a = [[[NSAttributedString alloc] initWithString:s ?: @""
                                                              attributes:textAttrs(f, [NSColor blackColor])] autorelease];
    return ceil([a boundingRectWithSize:NSMakeSize(w, 1.0e7) options:NSStringDrawingUsesLineFragmentOrigin].size.height);
}

@implementation GDItemView

- (id) initWithFrame:(NSRect)f path:(NSString *)p summary:(GDItem *)s
{
    if ((self = [super initWithFrame:f]) == nil)
        return nil;
    path = [p copy];
    summary = [s retain];
    shotRects = [[NSMutableArray alloc] init];
    fileButtons = [[NSMutableArray alloc] init];
    extraRequests = [[NSMutableArray alloc] init];
    links = [[NSMutableArray alloc] init];
    [self setAutoresizingMask:NSViewWidthSizable];

    getButton = [[NSButton alloc] initWithFrame:NSMakeRect(LEFT_X, 0, LEFT_W, 32)];
    [getButton setBezelStyle:NSRoundedBezelStyle];
    [getButton setFont:[NSFont boldSystemFontOfSize:13]];
    [getButton setTarget:self];
    [getButton setAction:@selector(getPressed:)];
    [self addSubview:getButton];

    /* The Garden suggests a download, but which one is right is often the
     * reader's call: a demo, a particular version, the disk image rather than
     * the archive.  So Get opens the list, with the suggestion at the top. */
    getMenu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(LEFT_X, 0, LEFT_W, 32) pullsDown:YES];
    [getMenu setBezelStyle:NSRoundedBezelStyle];
    [getMenu setFont:[NSFont boldSystemFontOfSize:13]];
    /* No action on the pop-up itself: each item carries its own, so a choice
     * cannot be delivered twice and start two downloads. */
    [getMenu setHidden:YES];
    [self addSubview:getMenu];

    bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(LEFT_X, 0, LEFT_W, 12)];
    [bar setStyle:NSProgressIndicatorBarStyle];
    [bar setControlSize:NSSmallControlSize];
    [bar setHidden:YES];
    [self addSubview:bar];

    descView = [[NSTextView alloc] initWithFrame:NSMakeRect(RIGHT_X, 0, 400, 100)];
    [descView setEditable:NO];
    [descView setSelectable:YES];
    [descView setDrawsBackground:NO];
    [descView setTextContainerInset:NSMakeSize(0, 0)];
    [[descView textContainer] setLineFragmentPadding:0];
    [descView setVerticallyResizable:YES];
    [self addSubview:descView];

    detail = [[[GDCatalog sharedCatalog] detailForPath:path] retain];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(detailLoaded:)
                                                 name:GDDetailLoadedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(imageLoaded:)
                                                 name:GDImageLoadedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(jobChanged:)
                                                 name:GDJobChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(jobChanged:)
                                                 name:GDLibraryChangedNotification object:nil];
    [self rebuild];
    return self;
}

- (void) dealloc
{
    unsigned k;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    for (k = 0; k < [extraRequests count]; k++) {
        [[extraRequests objectAtIndex:k] setDelegate:nil];
        [[extraRequests objectAtIndex:k] cancel];
    }
    [extraRequests release];
    [links release];
    [moreByAuthor release];
    [related release];
    [path release]; [summary release]; [detail release];
    [shotRects release]; [descView release]; [getButton release]; [getMenu release]; [bar release];
    [fileButtons release];
    [super dealloc];
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (void) setDelegate:(id)d { delegate = d; }
- (NSString *) path { return path; }
- (GDItemDetail *) detail { return detail; }

- (GDItem *) info { return detail ? (GDItem *)detail : summary; }

- (void) detailLoaded:(NSNotification *)n
{
    if (![[n object] isEqualToString:path])
        return;
    [detail release];
    detail = [[[GDCatalog sharedCatalog] detailForPath:path] retain];
    [self rebuild];
}

- (void) imageLoaded:(NSNotification *)n { [self setNeedsDisplay:YES]; }
- (void) jobChanged:(NSNotification *)n
{
    GDInstallJob *j = [n object];
    if (j == nil || ![j isKindOfClass:[GDInstallJob class]] || [[[j item] path] isEqualToString:path])
        [self rebuild];
}

- (float) rightWidth
{
    return MAX(360, NSWidth([self bounds]) - RIGHT_X - 28);
}

/* Lays out the subviews; drawing does the rest. */
- (void) rebuild
{
    GDInstaller *inst = [GDInstaller sharedInstaller];
    GDInstallJob *job = [inst jobForItemPath:path];
    NSDictionary *entry = [inst libraryEntryForPath:path];
    GDFile *best = nil;
    GDVerdict v = detail ? [GDCompat verdictForItem:detail bestFile:&best] : GDVerdictUnknown;
    NSMutableAttributedString *desc;
    float rw = [self rightWidth], y, h;
    unsigned i;

    /* Get button + progress */
    [getButton setFrame:NSMakeRect(LEFT_X, 28 + 150 + 16, LEFT_W, 32)];
    [getMenu setFrame:NSMakeRect(LEFT_X, 28 + 150 + 16, LEFT_W, 32)];
    [bar setFrame:NSMakeRect(LEFT_X + 4, NSMaxY([getButton frame]) + 4, LEFT_W - 8, 12)];
    if (job && [job isActive]) {
        [getButton setTitle:@"Cancel"];
        [getButton setEnabled:YES];
        [bar setHidden:NO];
        if ([job progress] < 0) {
            [bar setIndeterminate:YES];
            [bar startAnimation:nil];
        } else {
            [bar setIndeterminate:NO];
            [bar setDoubleValue:[job progress] * 100];
        }
    } else {
        [bar stopAnimation:nil];
        [bar setHidden:YES];
        if (entry && [entry objectForKey:@"launch"])
            [getButton setTitle:@"Open"];
        else if (entry)
            [getButton setTitle:@"Show in Finder"];
        else if (detail == nil)
            [getButton setTitle:@"Loading..."];
        else if (best == nil)
            [getButton setTitle:@"No Downloads"];
        else
            [getButton setTitle:[NSString stringWithFormat:GDU("Get  \xC2\xB7  %@"),
                                    [best sizeText] ?: @"Download"]];
        [getButton setEnabled:detail != nil && (best != nil || entry != nil)];
    }
    /* Nothing installed and something to get: offer the whole list. */
    {
        BOOL choose = !(job && [job isActive]) && entry == nil && detail != nil && best != nil;
        [getMenu setHidden:!choose];
        [getButton setHidden:choose];
        if (choose)
            [self fillGetMenu:best];
    }

    /* description text */
    desc = [[[NSMutableAttributedString alloc] initWithString:
                [detail descriptionText] ?: ([summary blurb] ?: @"")
                                                   attributes:[NSDictionary dictionaryWithObjectsAndKeys:
                    [NSFont systemFontOfSize:12], NSFontAttributeName,
                    [NSColor colorWithCalibratedWhite:0.15 alpha:1], NSForegroundColorAttributeName, nil]] autorelease];
    [[descView textStorage] setAttributedString:desc];
    [descView setFrame:NSMakeRect(RIGHT_X, 110, rw, 10)];
    [[descView textContainer] setContainerSize:NSMakeSize(rw, 1.0e7)];
    [[descView layoutManager] glyphRangeForTextContainer:[descView textContainer]];
    descHeight = ceil([[descView layoutManager] usedRectForTextContainer:[descView textContainer]].size.height);
    [descView setFrame:NSMakeRect(RIGHT_X, 110, rw, descHeight)];

    /* per-file Get buttons */
    for (i = 0; i < [fileButtons count]; i++)
        [[fileButtons objectAtIndex:i] removeFromSuperview];
    [fileButtons removeAllObjects];
    y = 110 + descHeight + 24;
    if ([[detail screenshots] count])
        y += 28 + SHOT_H + 20;
    y += 30;
    for (i = 0; i < [[detail files] count]; i++) {
        NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(RIGHT_X + rw - 98, y + 15, 88, 24)] autorelease];
        [b setBezelStyle:NSRoundedBezelStyle];
        [[b cell] setControlSize:NSSmallControlSize];
        [b setFont:[NSFont systemFontOfSize:11]];
        [b setTitle:(entry && [[[[detail files] objectAtIndex:i] name]
                                  isEqualToString:[entry objectForKey:@"file"]]) ? @"Get Again" : @"Get"];
        [b setTag:i];
        [b setTarget:self];
        [b setAction:@selector(getFilePressed:)];
        [b setEnabled:!(job && [job isActive])];
        [self addSubview:b];
        [fileButtons addObject:b];
        y += 62;
    }
    extrasTop = y + 14;
    if (detail) {
        [self loadExtras];
        y = extrasTop + [self layoutExtras:rw];
    }
    h = MAX(y + 30, 28 + 150 + 16 + 32 + 30 + 260);
    {
        NSScrollView *sv = [self enclosingScrollView];
        if (sv)
            h = MAX(h, NSHeight([[sv contentView] bounds]));
    }
    if (fabs(h - NSHeight([self frame])) > 0.5)
        [self setFrameSize:NSMakeSize(NSWidth([self frame]), h)];
    (void)v;
    [self setNeedsDisplay:YES];
}

- (void) resizeWithOldSuperviewSize:(NSSize)old
{
    [super resizeWithOldSuperviewSize:old];
    [self rebuild];
}

- (void) drawFact:(NSString *)label value:(NSString *)value y:(float *)y
{
    if ([value length] == 0)
        return;
    GDDrawText(label, NSMakeRect(LEFT_X, *y, 80, 15), [NSFont systemFontOfSize:10],
               GDSubtleTextColor(), YES);
    GDDrawText(value, NSMakeRect(LEFT_X + 80, *y, LEFT_W - 80, 30), [NSFont systemFontOfSize:11],
               [NSColor blackColor], NO);
    *y += [value length] > 26 ? 30 : 17;
}

- (void) drawRect:(NSRect)dirty
{
    GDCatalog *cat = [GDCatalog sharedCatalog];
    GDItem *it = [self info];
    NSImage *img = [cat imageForURL:[it thumbURL] ?: [summary thumbURL]];
    NSRect pic = NSMakeRect(LEFT_X, 28, LEFT_W, 150);
    float rw = [self rightWidth], y;
    GDFile *best = nil;
    GDVerdict v = detail ? [GDCompat verdictForItem:detail bestFile:&best] : GDVerdictUnknown;
    NSString *by;
    NSString *installedFile = [[[GDInstaller sharedInstaller] libraryEntryForPath:path] objectForKey:@"file"];
    unsigned i;

    [GDBackgroundColor() set];
    NSRectFill(dirty);

    /* ---- left column */
    [[NSColor colorWithCalibratedWhite:0 alpha:0.12] set];
    [GDRoundRect(NSOffsetRect(pic, 0, 2), 8) fill];
    [NSGraphicsContext saveGraphicsState];
    [GDRoundRect(pic, 8) addClip];
    if (img) {
        [[NSColor whiteColor] set];
        NSRectFill(pic);
        GDDrawImageFitted(img, pic, YES);
    } else {
        GDDrawPlaceholder(pic, [it title]);
    }
    [NSGraphicsContext restoreGraphicsState];

    y = NSMaxY([getButton frame]) + ([bar isHidden] ? 12 : 22);
    if (installedFile && [bar isHidden]) {
        GDDrawText([NSString stringWithFormat:@"Installed from %@", installedFile],
                   NSMakeRect(LEFT_X, y - 4, LEFT_W, 28), [NSFont systemFontOfSize:10], GDSubtleTextColor(), NO);
        y += 26;
    }
    {
        GDInstallJob *job = [[GDInstaller sharedInstaller] jobForItemPath:path];
        if (job && ([job isActive] || [job state] == GDJobFailed)) {
            GDDrawText([job status], NSMakeRect(LEFT_X, y, LEFT_W, 44), [NSFont systemFontOfSize:10],
                       [job state] == GDJobFailed ? GDBadgeColor(GDVerdictIncompatible) : GDSubtleTextColor(), NO);
            y += 46;
        }
    }
    if (detail) {
        GDDrawBadge(NSMakeRect(LEFT_X, y, LEFT_W, 16), v, YES);
        y += 22;
        GDDrawText([GDCompat explanation:v], NSMakeRect(LEFT_X, y, LEFT_W, 44),
                   [NSFont systemFontOfSize:10], GDSubtleTextColor(), NO);
        y += 44;
        /* ...and the Garden has that emulator: one click away. */
        if (v == GDVerdictNeedsEmulator) {
            NSString *name = [GDCompat emulatorNameForItem:detail];
            NSString *where = [GDCompat emulatorPathForItem:detail];
            NSString *t = [NSString stringWithFormat:GDU("Try with %@ \xE2\x80\xBA"), name];
            NSDictionary *la = textAttrs([NSFont systemFontOfSize:11], GDAccentColor());
            NSSize ts = [t sizeWithAttributes:la];
            NSRect lr = NSMakeRect(LEFT_X, y - 8, ts.width, ts.height);
            [t drawInRect:lr withAttributes:la];
            (void)where;
            [self link:lr kind:@"emulator" object:nil];
            y += 16;
        }
    }
    [[NSColor colorWithCalibratedWhite:0.84 alpha:1] set];
    NSRectFill(NSMakeRect(LEFT_X, y, LEFT_W, 1));
    y += 10;
    [self drawFact:@"Category" value:[it category] y:&y];
    [self drawFact:@"Released" value:[it year] y:&y];
    [self drawFact:@"Author" value:[it author] y:&y];
    if (detail) {
        [self drawFact:@"Publisher" value:[detail publisher] y:&y];
        [self drawFact:@"Runs on" value:[detail architecture] y:&y];
        [self drawFact:@"Downloads" value:[NSString stringWithFormat:@"%u", (unsigned)[[detail files] count]] y:&y];
    }
    [self drawFact:@"Your Mac" value:[GDCompat hostDescription] y:&y];

    /* ---- right column */
    GDDrawText([it title] ?: @"", NSMakeRect(RIGHT_X, 26, rw, 32), [NSFont boldSystemFontOfSize:24],
               [NSColor blackColor], YES);
    by = [it author] ?: @"";
    if ([[it category] length])
        by = [by length] ? [NSString stringWithFormat:GDU("%@  \xC2\xB7  %@"), by, [it category]] : [it category];
    GDDrawText(by, NSMakeRect(RIGHT_X, 60, rw, 16), [NSFont systemFontOfSize:12], GDSubtleTextColor(), YES);
    GDDrawStars(NSMakeRect(RIGHT_X, 82, 80, 14), [it rating]);
    GDDrawText([it votes] ? [NSString stringWithFormat:@"%.1f  (%d ratings)", [it rating], [it votes]]
                          : @"Not yet rated",
               NSMakeRect(RIGHT_X + 88, 81, 200, 16), [NSFont systemFontOfSize:11], GDSubtleTextColor(), YES);

    y = 110 + descHeight + 24;
    [shotRects removeAllObjects];
    if ([[detail screenshots] count]) {
        float x = RIGHT_X;
        GDDrawText(@"Screenshots", NSMakeRect(RIGHT_X, y, rw, 20), [NSFont boldSystemFontOfSize:14],
                   [NSColor blackColor], YES);
        y += 28;
        for (i = 0; i < [[detail screenshots] count] && x + SHOT_W <= RIGHT_X + rw + 1; i++) {
            NSString *u = [[detail screenshots] objectAtIndex:i];
            NSImage *s = [cat imageForURL:u];
            NSRect r = NSMakeRect(x, y, SHOT_W, SHOT_H);
            [[NSColor colorWithCalibratedWhite:0 alpha:0.10] set];
            [GDRoundRect(NSOffsetRect(r, 0, 2), 4) fill];
            [[NSColor whiteColor] set];
            [GDRoundRect(r, 4) fill];
            if (s)
                GDDrawImageFitted(s, NSInsetRect(r, 4, 4), NO);
            else
                GDDrawText(@"Loading...", NSInsetRect(r, 10, 60), [NSFont systemFontOfSize:10],
                           GDSubtleTextColor(), YES);
            [shotRects addObject:[NSArray arrayWithObjects:[NSValue valueWithRect:r], u, nil]];
            x += SHOT_W + 14;
        }
        y += SHOT_H + 20;
    }

    GDDrawText(detail ? @"Downloads" : @"Loading...", NSMakeRect(RIGHT_X, y, rw, 20),
               [NSFont boldSystemFontOfSize:14], [NSColor blackColor], YES);
    y += 30;
    for (i = 0; i < [[detail files] count]; i++) {
        GDFile *f = [[detail files] objectAtIndex:i];
        GDVerdict fv = [GDCompat verdictForFile:f architecture:[detail architecture]];
        NSRect row = NSMakeRect(RIGHT_X, y, rw, 54);
        NSString *meta = [NSString stringWithFormat:@"%@%@%@", [f sizeText] ?: @"",
                             [f date] ? GDU("  \xC2\xB7  ") : @"", [f date] ?: @""];
        [[NSColor whiteColor] set];
        [GDRoundRect(row, 6) fill];
        [[NSColor colorWithCalibratedWhite:0.86 alpha:1] set];
        [GDRoundRect(NSInsetRect(row, 0.5, 0.5), 6) stroke];
        GDDrawText([f name], NSMakeRect(row.origin.x + 10, y + 6, rw - 200, 16),
                   [NSFont boldSystemFontOfSize:11], [NSColor blackColor], YES);
        GDDrawText(meta, NSMakeRect(row.origin.x + 10, y + 22, rw - 200, 14),
                   [NSFont systemFontOfSize:10], GDSubtleTextColor(), YES);
        GDDrawText([f systems] ? [@"For " stringByAppendingString:[f systems]] : @"",
                   NSMakeRect(row.origin.x + 10, y + 36, rw - 200, 14),
                   [NSFont systemFontOfSize:10], GDSubtleTextColor(), YES);
        GDDrawBadge(NSMakeRect(NSMaxX(row) - 196, y + 15, 112, 14), fv, YES);
        if (installedFile && [[f name] isEqualToString:installedFile])
            GDDrawText(GDU("\xE2\x9C\x93 Installed"), NSMakeRect(NSMaxX(row) - 196, y + 32, 112, 12),
                       [NSFont boldSystemFontOfSize:9], GDBadgeColor(GDVerdictNative), YES);
        else if (f == best && i > 0)
            GDDrawText(@"best match", NSMakeRect(NSMaxX(row) - 196, y + 32, 112, 12),
                       [NSFont systemFontOfSize:9], GDSubtleTextColor(), YES);
        y += 62;
    }
    [links removeAllObjects];
    if (detail)
        [self drawExtras:rw];

    /* installed: the program's own icon on the picture */
    {
        NSDictionary *entry = [[GDInstaller sharedInstaller] libraryEntryForPath:path];
        NSImage *icon = entry ? [[GDInstaller sharedInstaller] iconForEntry:entry] : nil;
        if (icon) {
            NSRect ir = NSMakeRect(NSMaxX(pic) - 70, NSMaxY(pic) - 70, 62, 62);
            [[NSColor colorWithCalibratedWhite:1 alpha:0.9] set];
            [GDRoundRect(NSInsetRect(ir, -4, -4), 12) fill];
            GDDrawImageFitted(icon, ir, NO);
        }
    }
}

/* -------------------------------------------------- reviews and more */

- (void) loadExtras
{
    NSString *paths[2];
    int k;
    if ([extraRequests count] || detail == nil)
        return;
    paths[0] = [detail authorPath];
    paths[1] = [detail categoryPath];
    for (k = 0; k < 2; k++) {
        GDHTTPRequest *r;
        if ([paths[k] length] == 0)
            continue;
        r = [GDHTTPRequest requestWithURL:[GDGarden listURLForSection:[detail section] selector:paths[k] page:0]];
        [r setTag:k];
        [r setDelegate:self];
        [r setCacheTTL:86400];
        [extraRequests addObject:r];
        [r start];
    }
}

- (void) httpRequestDidFinish:(GDHTTPRequest *)r
{
    NSMutableArray *items = [NSMutableArray array];
    GDListing *L = [r error] ? nil : [GDGarden parseListing:[r data]];
    unsigned k;
    for (k = 0; k < [[L items] count]; k++) {
        GDItem *it = [[L items] objectAtIndex:k];
        if (![[it path] isEqualToString:path])
            [items addObject:it];
    }
    if ([r tag] == 0) {
        [moreByAuthor release];
        moreByAuthor = [items retain];
    } else {
        /* The description's own "see also" links first, then the category. */
        NSMutableArray *rel = [NSMutableArray arrayWithArray:[detail seeAlso]];
        NSMutableSet *seen = [NSMutableSet set];
        for (k = 0; k < [rel count]; k++)
            [seen addObject:[[rel objectAtIndex:k] path]];
        for (k = 0; k < [items count]; k++)
            if (![seen containsObject:[[items objectAtIndex:k] path]])
                [rel addObject:[items objectAtIndex:k]];
        [related release];
        related = [rel retain];
    }
    [self rebuild];
}

- (NSArray *) shownReviews
{
    NSArray *all = [detail reviews];
    if (showAllReviews || [all count] <= REVIEWS_SHOWN)
        return all;
    return [all subarrayWithRange:NSMakeRange(0, REVIEWS_SHOWN)];
}

- (int) miniColumns:(float)w
{
    return MAX(1, (int)((w + 14) / (MINI_W + 14)));
}

/* Height of everything below the downloads, for the given column width. */
- (float) layoutExtras:(float)w
{
    float h = 0;
    NSArray *rv = [self shownReviews];
    unsigned k;
    h += 34 + 26;                                   /* heading + rating line */
    if ([[detail reviews] count] == 0)
        h += 22;
    for (k = 0; k < [rv count]; k++)
        h += 18 + textHeight([[rv objectAtIndex:k] objectForKey:@"text"], [NSFont systemFontOfSize:11], w) + 16;
    if ([[detail reviews] count] > REVIEWS_SHOWN)
        h += 22;
    if ([moreByAuthor count])
        h += 16 + 30 + MINI_H;
    if ([related count])
        h += 16 + 30 + MINI_H;
    return h;
}

- (void) link:(NSRect)r kind:(NSString *)kind object:(id)o
{
    [links addObject:[NSArray arrayWithObjects:[NSValue valueWithRect:r], kind, o ?: @"", nil]];
}

- (void) drawMini:(GDItem *)it in:(NSRect)r
{
    GDCatalog *cat = [GDCatalog sharedCatalog];
    NSString *thumb = [it thumbURL] ?: [[cat detailForPath:[it path]] thumbURL];
    NSImage *img = [cat imageForURL:thumb];
    NSRect pic = NSMakeRect(r.origin.x, r.origin.y, r.size.width, 82);
    BOOL known;
    GDVerdict v = [cat verdictForPath:[it path] known:&known];
    [NSGraphicsContext saveGraphicsState];
    [GDRoundRect(pic, 6) addClip];
    if (img)
        GDDrawImageFitted(img, pic, YES);
    else
        GDDrawPlaceholder(pic, [it title]);
    [NSGraphicsContext restoreGraphicsState];
    GDDrawText([it title], NSMakeRect(r.origin.x, NSMaxY(pic) + 5, r.size.width, 30),
               [NSFont boldSystemFontOfSize:10], [NSColor blackColor], NO);
    GDDrawText([it year] ?: ([it category] ?: @""), NSMakeRect(r.origin.x, NSMaxY(pic) + 33, r.size.width, 13),
               [NSFont systemFontOfSize:9], GDSubtleTextColor(), YES);
    GDDrawBadge(NSMakeRect(r.origin.x, NSMaxY(r) - 14, r.size.width, 12), v, known);
    [self link:r kind:@"item" object:it];
}

- (float) drawShelf:(NSString *)title items:(NSArray *)items y:(float)y width:(float)w
         listing:(NSDictionary *)listing
{
    int cols = [self miniColumns:w], k;
    NSDictionary *ha = textAttrs([NSFont boldSystemFontOfSize:14], [NSColor blackColor]);
    NSString *more = GDU("See All \xE2\x80\xBA");
    NSDictionary *la = textAttrs([NSFont systemFontOfSize:11], GDAccentColor());
    NSSize ms = [more sizeWithAttributes:la];
    y += 16;
    [title drawInRect:NSMakeRect(RIGHT_X, y, w - ms.width - 20, 20) withAttributes:ha];
    if (listing) {
        NSRect mr = NSMakeRect(RIGHT_X + w - ms.width, y + 3, ms.width, ms.height);
        [more drawInRect:mr withAttributes:la];
        [self link:mr kind:@"listing" object:listing];
    }
    y += 30;
    for (k = 0; k < (int)[items count] && k < cols; k++)
        [self drawMini:[items objectAtIndex:k]
                    in:NSMakeRect(RIGHT_X + k * (MINI_W + 14), y, MINI_W, MINI_H - 10)];
    return y + MINI_H;
}

- (void) drawExtras:(float)w
{
    float y = extrasTop;
    NSArray *rv = [self shownReviews];
    unsigned k;
    NSFont *body = [NSFont systemFontOfSize:11];

    GDDrawText(@"Ratings & Reviews", NSMakeRect(RIGHT_X, y, w, 20), [NSFont boldSystemFontOfSize:14],
               [NSColor blackColor], YES);
    y += 34;
    GDDrawText([detail votes] ? [NSString stringWithFormat:@"%.1f", [detail rating]] : GDU("\xE2\x80\x94"),
               NSMakeRect(RIGHT_X, y - 6, 50, 26), [NSFont boldSystemFontOfSize:22], [NSColor blackColor], YES);
    GDDrawStars(NSMakeRect(RIGHT_X + 52, y, 80, 14), [detail rating]);
    GDDrawText([NSString stringWithFormat:@"%d ratings  %C  %u reviews", [detail votes], (unichar)0x00B7,
                   (unsigned)[[detail reviews] count]],
               NSMakeRect(RIGHT_X + 142, y, w - 142, 16), [NSFont systemFontOfSize:11], GDSubtleTextColor(), YES);
    y += 26;
    if ([[detail reviews] count] == 0) {
        GDDrawText(@"No reviews yet.", NSMakeRect(RIGHT_X, y, w, 16), body, GDSubtleTextColor(), YES);
        y += 22;
    }
    for (k = 0; k < [rv count]; k++) {
        NSDictionary *r = [rv objectAtIndex:k];
        NSString *who = [r objectForKey:@"author"], *when = [r objectForKey:@"date"];
        float th = textHeight([r objectForKey:@"text"], body, w);
        NSDictionary *wa = textAttrs([NSFont boldSystemFontOfSize:11], [NSColor blackColor]);
        [who drawAtPoint:NSMakePoint(RIGHT_X, y) withAttributes:wa];
        [when drawAtPoint:NSMakePoint(RIGHT_X + [who sizeWithAttributes:wa].width + 8, y)
           withAttributes:textAttrs([NSFont systemFontOfSize:10], GDSubtleTextColor())];
        y += 18;
        [[[[NSAttributedString alloc] initWithString:[r objectForKey:@"text"]
                                          attributes:textAttrs(body, [NSColor colorWithCalibratedWhite:0.15 alpha:1])] autorelease]
            drawWithRect:NSMakeRect(RIGHT_X, y, w, th) options:NSStringDrawingUsesLineFragmentOrigin];
        y += th + 8;
        [[NSColor colorWithCalibratedWhite:0.88 alpha:1] set];
        NSRectFill(NSMakeRect(RIGHT_X, y, w, 1));
        y += 8;
    }
    if ([[detail reviews] count] > REVIEWS_SHOWN) {
        NSString *t = showAllReviews ? GDU("Show Fewer \xE2\x80\xBA")
                                     : [NSString stringWithFormat:@"%@%@", [NSString stringWithFormat:@"Show All %u Reviews ",
                                           (unsigned)[[detail reviews] count]], GDU("\xE2\x80\xBA")];
        NSDictionary *la = textAttrs([NSFont systemFontOfSize:11], GDAccentColor());
        NSSize ts = [t sizeWithAttributes:la];
        NSRect lr = NSMakeRect(RIGHT_X, y, ts.width, ts.height);
        [t drawInRect:lr withAttributes:la];
        [self link:lr kind:@"reviews" object:nil];
        y += 22;
    }
    if ([moreByAuthor count])
        y = [self drawShelf:[NSString stringWithFormat:@"More by %@", [detail author]] items:moreByAuthor y:y width:w
                    listing:[NSDictionary dictionaryWithObjectsAndKeys:@"list", @"kind", [detail section], @"section",
                                [detail authorPath], @"selector", [detail author] ?: @"", @"title", nil]];
    if ([related count])
        y = [self drawShelf:@"Related" items:related y:y width:w
                    listing:[detail categoryPath] ? [NSDictionary dictionaryWithObjectsAndKeys:@"list", @"kind",
                                [detail section], @"section", [detail categoryPath], @"selector",
                                [detail category] ?: @"", @"title", nil] : nil];
    [[self window] invalidateCursorRectsForView:self];
}

- (void) mouseUp:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    unsigned i;
    for (i = 0; i < [links count]; i++) {
        NSArray *l = [links objectAtIndex:i];
        NSString *kind = [l objectAtIndex:1];
        if (!NSPointInRect(p, [[l objectAtIndex:0] rectValue]))
            continue;
        if ([kind isEqualToString:@"reviews"]) {
            showAllReviews = !showAllReviews;
            [self rebuild];
        } else if ([kind isEqualToString:@"item"] && [delegate respondsToSelector:@selector(itemView:openItem:)]) {
            [delegate itemView:self openItem:[l objectAtIndex:2]];
        } else if ([kind isEqualToString:@"listing"] && [delegate respondsToSelector:@selector(itemView:openListing:)]) {
            [delegate itemView:self openListing:[l objectAtIndex:2]];
        } else if ([kind isEqualToString:@"emulator"] &&
                   [delegate respondsToSelector:@selector(itemView:tryEmulator:)]) {
            [delegate itemView:self tryEmulator:detail];
        }
        return;
    }
    for (i = 0; i < [shotRects count]; i++) {
        NSArray *s = [shotRects objectAtIndex:i];
        if (NSPointInRect(p, [[s objectAtIndex:0] rectValue]) &&
            [delegate respondsToSelector:@selector(itemView:showScreenshot:)])
            [delegate itemView:self showScreenshot:[s objectAtIndex:1]];
    }
}

- (void) resetCursorRects
{
    unsigned i;
    for (i = 0; i < [links count]; i++)
        [self addCursorRect:[[[links objectAtIndex:i] objectAtIndex:0] rectValue] cursor:[NSCursor pointingHandCursor]];
    for (i = 0; i < [shotRects count]; i++)
        [self addCursorRect:[[[shotRects objectAtIndex:i] objectAtIndex:0] rectValue]
                     cursor:[NSCursor pointingHandCursor]];
}

- (void) getPressed:(id)sender
{
    GDInstaller *inst = [GDInstaller sharedInstaller];
    GDInstallJob *job = [inst jobForItemPath:path];
    NSDictionary *entry = [inst libraryEntryForPath:path];
    GDFile *best = nil;
    if (job && [job isActive]) {
        [inst cancel:job];
        return;
    }
    if (entry) {
        if ([delegate respondsToSelector:@selector(itemView:openInstalled:)])
            [delegate itemView:self openInstalled:entry];
        return;
    }
    [GDCompat verdictForItem:detail bestFile:&best];
    if (best && [delegate respondsToSelector:@selector(itemView:getFile:ofItem:)])
        [delegate itemView:self getFile:best ofItem:detail];
}

/* The downloads, the suggested one first and named as such.  A pull-down's
 * first item is its title, never chosen, so the files start at index 2. */
- (void) fillGetMenu:(GDFile *)best
{
    NSMenu *m = [[[NSMenu alloc] initWithTitle:@"Get"] autorelease];
    NSArray *files = [detail files];
    unsigned i;

    [m addItemWithTitle:[NSString stringWithFormat:GDU("Get  \xC2\xB7  %@"),
                            [best sizeText] ?: @"Download"]
                 action:NULL keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];
    for (i = 0; i < [files count]; i++) {
        GDFile *f = [files objectAtIndex:i];
        GDVerdict v = [GDCompat verdictForFile:f architecture:[detail architecture]];
        NSString *title = [NSString stringWithFormat:GDU("%@  \xC2\xB7  %@  \xC2\xB7  %@"),
                              [f name] ?: @"Download", [f sizeText] ?: @"",
                              [GDCompat shortLabel:v]];
        NSMenuItem *it;
        if (f == best)
            title = [title stringByAppendingString:@"   (suggested)"];
        it = [m addItemWithTitle:title action:@selector(getMenuChose:) keyEquivalent:@""];
        [it setTarget:self];
        [it setTag:(int)i];
    }
    /* A pull-down shows its first item as the button, so that one carries the
     * suggestion's size and is never chosen. */
    [getMenu setMenu:m];
}

- (void) getMenuChose:(id)sender
{
    int t = [sender tag];
    if (t >= 0 && t < (int)[[detail files] count] &&
        [delegate respondsToSelector:@selector(itemView:getFile:ofItem:)])
        [delegate itemView:self getFile:[[detail files] objectAtIndex:t] ofItem:detail];
}

- (void) getFilePressed:(id)sender
{
    GDFile *f = [[detail files] objectAtIndex:[sender tag]];
    if ([delegate respondsToSelector:@selector(itemView:getFile:ofItem:)])
        [delegate itemView:self getFile:f ofItem:detail];
}

@end
