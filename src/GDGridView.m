#import "GDGridView.h"
#import "GDGarden.h"
#import "GDCatalog.h"
#import "GDStyle.h"
#include <math.h>

#define MARGIN 24
#define GAP 18
#define TILE_W 188
#define PIC_H 124
#define TILE_H 214
#define CAT_H 58
#define HEAD_H 40
#define LETTER_H 26

@implementation GDShelf
+ (GDShelf *) shelfWithTitle:(NSString *)t
{
    GDShelf *s = [[[GDShelf alloc] init] autorelease];
    s->title = [t copy];
    s->entries = [[NSMutableArray alloc] init];
    return s;
}
- (NSString *) description
{
    return [NSString stringWithFormat:@"<%@: %u entries, loading %d, more %d, sub %@>",
            title, (unsigned)[entries count], loading, hasMore, subtitle];
}
- (void) dealloc
{
    [title release]; [subtitle release]; [entries release]; [seeAll release]; [letter release]; [state release];
    [super dealloc];
}
@end

enum { HitItem, HitCategory, HitMore, HitSeeAll, HitLetter };

@interface GDGridView (Private)
- (void) drawItem:(GDItem *)it in:(NSRect)t;
- (void) drawCategory:(NSDictionary *)c in:(NSRect)t;
@end

@implementation GDGridView

- (id) initWithFrame:(NSRect)f
{
    if ((self = [super initWithFrame:f]) != nil) {
        shelves = [[NSMutableArray alloc] init];
        hits = [[NSMutableArray alloc] init];
        onlyRunnable = YES;
        [self setAutoresizingMask:NSViewWidthSizable];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(modelChanged:)
                                                     name:GDDetailLoadedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(imageChanged:)
                                                     name:GDImageLoadedNotification object:nil];
    }
    return self;
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [shelves release];
    [hits release];
    [message release];
    [super dealloc];
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (void) setDelegate:(id)d { delegate = d; }
- (NSMutableArray *) shelves { return shelves; }
- (void) setShelves:(NSArray *)s
{
    /* Tiger's -setArray: with the receiver itself empties it. */
    if (s != shelves)
        [shelves setArray:[[s copy] autorelease]];
    [self reload];
}
- (void) setOnlyRunnable:(BOOL)f { onlyRunnable = f; [self reload]; }
- (void) setMessage:(NSString *)m { [message autorelease]; message = [m copy]; [self reload]; }

- (BOOL) showsEntry:(id)e
{
    BOOL known;
    GDVerdict v;
    if (!onlyRunnable || ![e isKindOfClass:[GDItem class]])
        return YES;
    v = [[GDCatalog sharedCatalog] verdictForPath:[e path] known:&known];
    return !known || [GDCompat runsHere:v];
}

- (int) columns
{
    int c = (int)((NSWidth([self bounds]) - 2 * MARGIN + GAP) / (TILE_W + GAP));
    return MAX(c, 1);
}

/* Walks the layout; when draw is NO it only measures and records hit rects. */
- (float) layoutAndDraw:(BOOL)draw rect:(NSRect)dirty
{
    float y = 16, width = NSWidth([self bounds]);
    int cols = [self columns];
    float tileW = floor((width - 2 * MARGIN - (cols - 1) * GAP) / cols);
    unsigned s;

    if (!draw)
        [hits removeAllObjects];
    if (draw) {
        [GDBackgroundColor() set];
        NSRectFill(dirty);
    }
    for (s = 0; s < [shelves count]; s++) {
        GDShelf *sh = [shelves objectAtIndex:s];
        NSMutableArray *vis = [NSMutableArray array];
        unsigned i;
        float h = sh->categories ? CAT_H : TILE_H;

        for (i = 0; i < [sh->entries count]; i++)
            if ([self showsEntry:[sh->entries objectAtIndex:i]])
                [vis addObject:[sh->entries objectAtIndex:i]];

        /* heading */
        if (draw) {
            GDDrawText(sh->title, NSMakeRect(MARGIN, y + 6, width - 2 * MARGIN - 120, 26),
                       [NSFont boldSystemFontOfSize:19], [NSColor blackColor], YES);
            if (sh->subtitle)
                GDDrawText(sh->subtitle, NSMakeRect(MARGIN, y + 30, width - 2 * MARGIN, 16),
                           [NSFont systemFontOfSize:11], GDSubtleTextColor(), YES);
            [[NSColor colorWithCalibratedWhite:0.82 alpha:1] set];
            NSRectFill(NSMakeRect(MARGIN, y + HEAD_H - 1 + (sh->subtitle ? 10 : 0), width - 2 * MARGIN, 1));
        }
        if (sh->seeAll) {
            NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                                  [NSFont systemFontOfSize:12], NSFontAttributeName,
                                  GDAccentColor(), NSForegroundColorAttributeName, nil];
            NSString *t = [sh->seeAll stringByAppendingString:GDU(" \xE2\x80\xBA")];
            NSSize ts = [t sizeWithAttributes:a];
            NSRect r = NSMakeRect(width - MARGIN - ts.width, y + 12, ts.width, ts.height);
            if (draw)
                [t drawInRect:r withAttributes:a];
            else
                [hits addObject:[NSArray arrayWithObjects:[NSValue valueWithRect:r],
                                    [NSNumber numberWithInt:HitSeeAll], sh, sh, nil]];
        }
        y += HEAD_H + (sh->subtitle ? 10 : 0);

        if (sh->letterBar) {
            NSString *letters = @"All#ABCDEFGHIJKLMNOPQRSTUVWXYZ";
            float x = MARGIN;
            unsigned k;
            for (k = 0; k < [letters length]; ) {
                NSString *L = k == 0 ? @"All" : [letters substringWithRange:NSMakeRange(k, 1)];
                NSString *sel = k == 0 ? nil : ([L isEqualToString:@"#"] ? @"0" : [L lowercaseString]);
                BOOL on = (sel == nil && sh->letter == nil) || (sel && [sh->letter isEqualToString:sel]);
                NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                                      [NSFont boldSystemFontOfSize:11], NSFontAttributeName,
                                      on ? [NSColor whiteColor] : GDAccentColor(),
                                      NSForegroundColorAttributeName, nil];
                NSSize ts = [L sizeWithAttributes:a];
                NSRect r = NSMakeRect(x, y + 2, ts.width + 10, 18);
                if (draw) {
                    if (on) {
                        [GDAccentColor() set];
                        [GDRoundRect(r, 9) fill];
                    }
                    [L drawAtPoint:NSMakePoint(r.origin.x + 5, r.origin.y + 2) withAttributes:a];
                } else {
                    [hits addObject:[NSArray arrayWithObjects:[NSValue valueWithRect:r],
                                        [NSNumber numberWithInt:HitLetter], sel ?: @"", sh, nil]];
                }
                x += r.size.width + 2;
                k += (k == 0) ? 3 : 1;
            }
            y += LETTER_H;
        }

        if ([vis count] == 0 && !sh->loading && draw) {
            GDDrawText([sh->entries count] ? @"Nothing here runs on this Mac. Turn off \"Runs on This Mac\" in the View menu to see everything."
                                           : @"Nothing found.",
                       NSMakeRect(MARGIN, y + 8, width - 2 * MARGIN, 32),
                       [NSFont systemFontOfSize:12], GDSubtleTextColor(), NO);
        }
        if ([vis count] == 0)
            y += 40;

        for (i = 0; i < [vis count]; i++) {
            id e = [vis objectAtIndex:i];
            int col = i % cols, row = i / cols;
            NSRect t = NSMakeRect(MARGIN + col * (tileW + GAP), y + row * (h + GAP), tileW, h);
            if (!draw) {
                [hits addObject:[NSArray arrayWithObjects:[NSValue valueWithRect:t],
                                    [NSNumber numberWithInt:sh->categories ? HitCategory : HitItem],
                                    e, sh, nil]];
            } else if (NSIntersectsRect(t, dirty)) {
                if (sh->categories)
                    [self drawCategory:e in:t];
                else
                    [self drawItem:e in:t];
            }
        }
        if ([vis count])
            y += (([vis count] + cols - 1) / cols) * (h + GAP);

        if (sh->hasMore || sh->loading) {
            NSRect b = NSMakeRect(floor(width / 2 - 70), y + 4, 140, 26);
            if (draw) {
                NSString *t = sh->loading ? @"Loading..." : @"More";
                NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                                      [NSFont boldSystemFontOfSize:12], NSFontAttributeName,
                                      sh->loading ? GDSubtleTextColor() : GDAccentColor(),
                                      NSForegroundColorAttributeName, nil];
                NSSize ts = [t sizeWithAttributes:a];
                [[NSColor whiteColor] set];
                [GDRoundRect(b, 13) fill];
                [[NSColor colorWithCalibratedWhite:0.75 alpha:1] set];
                [GDRoundRect(NSInsetRect(b, 0.5, 0.5), 13) stroke];
                [t drawAtPoint:NSMakePoint(NSMidX(b) - ts.width / 2, NSMidY(b) - ts.height / 2)
                withAttributes:a];
            } else if (!sh->loading) {
                [hits addObject:[NSArray arrayWithObjects:[NSValue valueWithRect:b],
                                    [NSNumber numberWithInt:HitMore], sh, sh, nil]];
            }
            y += 46;
        }
        y += 12;
    }
    if ([shelves count] == 0 && message && draw)
        GDDrawText(message, NSMakeRect(MARGIN, 60, width - 2 * MARGIN, 60),
                   [NSFont systemFontOfSize:14], GDSubtleTextColor(), NO);
    return y + 20;
}

- (void) drawItem:(GDItem *)it in:(NSRect)t
{
    GDCatalog *cat = [GDCatalog sharedCatalog];
    GDItemDetail *d = [cat detailForPath:[it path]];
    NSString *thumb = [it thumbURL] ?: [d thumbURL];
    NSImage *img = [cat imageForURL:thumb];
    NSRect pic = NSMakeRect(t.origin.x, t.origin.y, t.size.width, PIC_H);
    NSString *category = [it category] ?: [d category];
    float rating = [it votes] ? [it rating] : [d rating];
    int votes = [it votes] ?: [d votes];
    BOOL known;
    GDVerdict v = [cat verdictForPath:[it path] known:&known];
    NSString *sub;

    /* card */
    [[NSColor colorWithCalibratedWhite:0 alpha:0.08] set];
    [GDRoundRect(NSOffsetRect(t, 0, 1), 6) fill];
    [[NSColor whiteColor] set];
    [GDRoundRect(t, 6) fill];

    [NSGraphicsContext saveGraphicsState];
    [GDRoundRect(NSInsetRect(pic, 0, 0), 6) addClip];
    NSRectClip(NSMakeRect(pic.origin.x, pic.origin.y, pic.size.width, pic.size.height));
    if (img) {
        [[NSColor colorWithCalibratedWhite:0.93 alpha:1] set];
        NSRectFill(pic);
        GDDrawImageFitted(img, pic, YES);
    } else {
        GDDrawPlaceholder(pic, [it title]);
    }
    [NSGraphicsContext restoreGraphicsState];

    GDDrawText([it title], NSMakeRect(t.origin.x + 8, NSMaxY(pic) + 6, t.size.width - 16, 32),
               [NSFont boldSystemFontOfSize:12], [NSColor blackColor], NO);
    sub = category ?: @"";
    if ([[it year] length])
        sub = [sub length] ? [NSString stringWithFormat:GDU("%@ \xC2\xB7 %@"), sub, [it year]] : [it year];
    GDDrawText(sub, NSMakeRect(t.origin.x + 8, NSMaxY(pic) + 38, t.size.width - 16, 15),
               [NSFont systemFontOfSize:10], GDSubtleTextColor(), YES);
    GDDrawStars(NSMakeRect(t.origin.x + 8, NSMaxY(pic) + 55, 60, 11), rating);
    if (votes)
        GDDrawText([NSString stringWithFormat:@"(%d)", votes],
                   NSMakeRect(t.origin.x + 72, NSMaxY(pic) + 53, 50, 14),
                   [NSFont systemFontOfSize:9], GDSubtleTextColor(), YES);
    GDDrawBadge(NSMakeRect(t.origin.x + 8, NSMaxY(t) - 20, t.size.width - 16, 14), v, known);
}

- (void) drawCategory:(NSDictionary *)c in:(NSRect)t
{
    static NSArray *tints;
    unsigned idx = [[c objectForKey:@"name"] hash] % 6;
    NSColor *tint;
    if (tints == nil)
        tints = [[NSArray alloc] initWithObjects:
                    [NSColor colorWithCalibratedRed:0.30 green:0.55 blue:0.32 alpha:1],
                    [NSColor colorWithCalibratedRed:0.25 green:0.45 blue:0.66 alpha:1],
                    [NSColor colorWithCalibratedRed:0.60 green:0.38 blue:0.62 alpha:1],
                    [NSColor colorWithCalibratedRed:0.78 green:0.48 blue:0.20 alpha:1],
                    [NSColor colorWithCalibratedRed:0.62 green:0.30 blue:0.30 alpha:1],
                    [NSColor colorWithCalibratedRed:0.30 green:0.55 blue:0.58 alpha:1], nil];
    tint = [tints objectAtIndex:idx];
    [NSGraphicsContext saveGraphicsState];
    [GDRoundRect(t, 8) addClip];
    GDFillVerticalGradient(t, [tint blendedColorWithFraction:0.35 ofColor:[NSColor whiteColor]], tint);
    [NSGraphicsContext restoreGraphicsState];
    GDDrawText([c objectForKey:@"name"], NSMakeRect(t.origin.x + 12, t.origin.y + 10, t.size.width - 24, 40),
               [NSFont boldSystemFontOfSize:13], [NSColor whiteColor], NO);
}

/* With the filter on, a page of ten may show one or two tiles.  Once every
 * verdict on a shelf is known, ask for further pages (a few at most) until
 * the shelf has something worth looking at. */
- (void) autoFill
{
    unsigned s, i;
    if (!onlyRunnable)
        return;
    for (s = 0; s < [shelves count]; s++) {
        GDShelf *sh = [shelves objectAtIndex:s];
        int visible = 0, unknown = 0, pulled;
        if (sh->categories || !sh->hasMore || sh->loading || sh->seeAll)
            continue;
        for (i = 0; i < [sh->entries count]; i++) {
            BOOL known;
            GDVerdict v = [[GDCatalog sharedCatalog] verdictForPath:[[sh->entries objectAtIndex:i] path]
                                                              known:&known];
            if (!known)
                unknown++;
            else if ([GDCompat runsHere:v])
                visible++;
        }
        pulled = [[sh->state objectForKey:@"autoPulled"] intValue];
        if (unknown == 0 && visible < 12 && pulled < 8 &&
            [delegate respondsToSelector:@selector(gridView:moreForShelf:)]) {
            [sh->state setObject:[NSNumber numberWithInt:pulled + 1] forKey:@"autoPulled"];
            [delegate gridView:self moreForShelf:sh];
        }
    }
}

- (void) reload
{
    float h = [self layoutAndDraw:NO rect:NSZeroRect];
    [self performSelector:@selector(autoFill) withObject:nil afterDelay:0];
    NSScrollView *sv = [self enclosingScrollView];
    if (sv)
        h = MAX(h, NSHeight([[sv contentView] bounds]));
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

- (void) drawRect:(NSRect)r
{
    [self layoutAndDraw:YES rect:r];
}

- (void) modelChanged:(NSNotification *)n
{
    /* A verdict arriving can hide or show tiles, which moves everything. */
    [self reload];
}

- (void) imageChanged:(NSNotification *)n
{
    [self setNeedsDisplay:YES];
}

- (NSArray *) hitAt:(NSPoint)p
{
    unsigned i;
    for (i = 0; i < [hits count]; i++) {
        NSArray *h = [hits objectAtIndex:i];
        if (NSPointInRect(p, [[h objectAtIndex:0] rectValue]))
            return h;
    }
    return nil;
}

- (void) mouseUp:(NSEvent *)e
{
    NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
    NSArray *h = [self hitAt:p];
    id obj;
    GDShelf *sh;
    if (h == nil)
        return;
    obj = [h objectAtIndex:2];
    sh = [h objectAtIndex:3];
    switch ([[h objectAtIndex:1] intValue]) {
    case HitItem:
        if ([delegate respondsToSelector:@selector(gridView:openItem:)])
            [delegate gridView:self openItem:obj];
        break;
    case HitCategory:
        if ([delegate respondsToSelector:@selector(gridView:openCategory:)])
            [delegate gridView:self openCategory:obj];
        break;
    case HitMore:
        if ([delegate respondsToSelector:@selector(gridView:moreForShelf:)])
            [delegate gridView:self moreForShelf:sh];
        break;
    case HitSeeAll:
        if ([delegate respondsToSelector:@selector(gridView:seeAllForShelf:)])
            [delegate gridView:self seeAllForShelf:sh];
        break;
    case HitLetter:
        if ([delegate respondsToSelector:@selector(gridView:shelf:pickLetter:)])
            [delegate gridView:self shelf:sh pickLetter:[obj length] ? obj : nil];
        break;
    }
}

- (void) resetCursorRects
{
    unsigned i;
    NSRect vis = [self visibleRect];
    for (i = 0; i < [hits count]; i++) {
        NSRect r = [[[hits objectAtIndex:i] objectAtIndex:0] rectValue];
        if (NSIntersectsRect(r, vis))
            [self addCursorRect:r cursor:[NSCursor pointingHandCursor]];
    }
}

@end
