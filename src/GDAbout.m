#import "GDAbout.h"
#import "GDStyle.h"
#import "GDWebLink.h"

#define ABOUT_W 460.0
#define ABOUT_H 430.0
#define PAD 28.0

/* Cytrus Software's lime, from the site, and the purple of the app's own
 * icon.  Lime takes dark text and purple takes white: the other way round is
 * unreadable on these screens. */
static NSColor *limeColor(void)
{
    return [NSColor colorWithCalibratedRed:0.659 green:0.847 blue:0.102 alpha:1];
}

static NSColor *limeTextColor(void)
{
    return [NSColor colorWithCalibratedRed:0.102 green:0.165 blue:0.0 alpha:1];
}

static NSColor *purpleColor(void)
{
    return [NSColor colorWithCalibratedRed:0.435 green:0.180 blue:0.494 alpha:1];
}

/* ---- a button with a colour of its own ---------------------------------
 * NSButton will not fill itself with an arbitrary colour on 10.4, so this
 * draws the whole thing: a rounded rectangle and centred bold text.
 */
@interface GDColorButton : NSButton
{
    NSColor *fill, *ink;
}
- (void) setFill:(NSColor *)f ink:(NSColor *)i;
@end

@implementation GDColorButton

- (void) setFill:(NSColor *)f ink:(NSColor *)i
{
    [fill autorelease]; fill = [f retain];
    [ink autorelease]; ink = [i retain];
    [self setNeedsDisplay:YES];
}

- (void) dealloc { [fill release]; [ink release]; [super dealloc]; }

- (void) drawRect:(NSRect)dirty
{
    NSRect r = NSInsetRect([self bounds], 0.5, 0.5);
    NSColor *c = fill ?: [NSColor grayColor];
    NSDictionary *attrs;
    NSSize size;

    if ([[self cell] isHighlighted])
        c = [c blendedColorWithFraction:0.25 ofColor:[NSColor blackColor]];
    [c set];
    [GDRoundRect(r, 6) fill];
    [[c blendedColorWithFraction:0.35 ofColor:[NSColor blackColor]] set];
    [GDRoundRect(r, 6) stroke];

    attrs = [NSDictionary dictionaryWithObjectsAndKeys:
                [NSFont boldSystemFontOfSize:12], NSFontAttributeName,
                ink ?: [NSColor whiteColor], NSForegroundColorAttributeName, nil];
    size = [[self title] sizeWithAttributes:attrs];
    [[self title] drawAtPoint:NSMakePoint(NSMidX(r) - size.width / 2,
                                          NSMidY(r) - size.height / 2)
               withAttributes:attrs];
}

@end

/* ---- the window's contents --------------------------------------------- */

@interface GDAboutView : NSView
{
    NSImage *appIcon, *logo;
}
@end

@implementation GDAboutView

- (id) initWithFrame:(NSRect)f
{
    if ((self = [super initWithFrame:f]) == nil)
        return nil;
    appIcon = [[NSApp applicationIconImage] retain];
    /* The exported logo, wordmark and all: the SVG's type is set in a face
     * these Macs do not have, so rasterising it here would lose it. */
    logo = [[NSImage alloc] initWithContentsOfFile:
               [[NSBundle mainBundle] pathForResource:@"cytruslogo" ofType:@"png"]];
    return self;
}

- (void) dealloc { [appIcon release]; [logo release]; [super dealloc]; }
- (BOOL) isFlipped { return YES; }

- (void) drawRect:(NSRect)dirty
{
    float w = NSWidth([self bounds]), y = PAD;
    NSString *stage = [GDAbout stage];

    [[NSColor whiteColor] set];
    NSRectFill(dirty);

    /* What this is, and which build. */
    if (appIcon != nil)
        GDDrawImageFitted(appIcon, NSMakeRect(PAD, y, 56, 56), NO);
    GDDrawText(@"The Garden", NSMakeRect(PAD + 70, y + 4, w - PAD - 70, 24),
               [NSFont boldSystemFontOfSize:18], [NSColor blackColor], YES);
    GDDrawText([GDAbout versionLine], NSMakeRect(PAD + 70, y + 30, w - PAD - 70, 16),
               [NSFont systemFontOfSize:11], GDSubtleTextColor(), YES);
    if ([stage length]) {
        NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSFont boldSystemFontOfSize:10], NSFontAttributeName,
                              [NSColor whiteColor], NSForegroundColorAttributeName, nil];
        NSSize s = [stage sizeWithAttributes:a];
        NSRect badge = NSMakeRect(PAD + 70, y + 46, s.width + 16, 16);
        [[NSColor colorWithCalibratedRed:0.80 green:0.35 blue:0.04 alpha:1] set];
        [GDRoundRect(badge, 8) fill];
        [stage drawAtPoint:NSMakePoint(badge.origin.x + 8, badge.origin.y + 1) withAttributes:a];
    }
    y += 76;

    [[NSColor colorWithCalibratedWhite:0.87 alpha:1] set];
    NSRectFill(NSMakeRect(PAD, y, w - 2 * PAD, 1));
    y += 14;

    GDDrawText(@"This is an alpha build. Expect rough edges, and please say when you "
                "find one.", NSMakeRect(PAD, y, w - 2 * PAD, 32),
               [NSFont boldSystemFontOfSize:11], [NSColor blackColor], NO);
    y += 34;

    GDDrawText(@"The Garden is not affiliated with the Macintosh Garden; it was made "
                "for fun. I hope you like it \xE2\x80\x94 feedback and feature requests "
                "are very welcome.",
               NSMakeRect(PAD, y, w - 2 * PAD, 52), [NSFont systemFontOfSize:11],
               [NSColor blackColor], NO);
    y += 54;

    GDDrawText(@"Cytrus Software (a.k.a. Cytrus Retro) is a personal side project by "
                "me, Adam Cipoletti, a Creative Director and Career Coach. You can find "
                "more of my vintage software and hardware projects at cytrusretro.com.",
               NSMakeRect(PAD, y, w - 2 * PAD, 64), [NSFont systemFontOfSize:11],
               [NSColor blackColor], NO);
    y += 62;

    /* The Cytrus Software logo, as it is drawn everywhere else. */
    if (logo != nil)
        GDDrawImageFitted(logo, NSMakeRect((w - 240) / 2, y, 240, 63), NO);
}

@end

/* ---- the window --------------------------------------------------------- */

@interface GDAbout (Private)
- (void) showWindow;
@end

static GDAbout *sharedAbout;

@implementation GDAbout

+ (NSString *) stage
{
    NSString *s = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"GDBuildStage"];
    return [s length] ? s : nil;
}

+ (NSString *) versionLine
{
    NSBundle *b = [NSBundle mainBundle];
    return [NSString stringWithFormat:@"Version %@ (build %@)",
               [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
               [b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
}

+ (void) show
{
    if (sharedAbout == nil)
        sharedAbout = [[self alloc] init];
    [sharedAbout showWindow];
}

- (void) showWindow
{
    if (window == nil) {
        NSRect frame = NSMakeRect(0, 0, ABOUT_W, ABOUT_H);
        GDAboutView *view;
        GDColorButton *a, *b;

        window = [[NSWindow alloc] initWithContentRect:frame
                      styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                        backing:NSBackingStoreBuffered defer:NO];
        [window setTitle:@"About The Garden"];
        [window setReleasedWhenClosed:NO];

        view = [[[GDAboutView alloc] initWithFrame:frame] autorelease];
        [window setContentView:view];

        a = [[[GDColorButton alloc] initWithFrame:
                 NSMakeRect(PAD, ABOUT_H - 24 - 34, (ABOUT_W - 2 * PAD - 16) / 2, 34)] autorelease];
        [a setBordered:NO];
        [a setTitle:@"cytrusretro.com"];
        [a setFill:limeColor() ink:limeTextColor()];
        [a setTarget:self];
        [a setAction:@selector(openCytrus:)];
        [view addSubview:a];

        b = [[[GDColorButton alloc] initWithFrame:
                 NSMakeRect(PAD + (ABOUT_W - 2 * PAD - 16) / 2 + 16, ABOUT_H - 24 - 34,
                            (ABOUT_W - 2 * PAD - 16) / 2, 34)] autorelease];
        [b setBordered:NO];
        [b setTitle:@"amcreativecoach.com"];
        [b setFill:purpleColor() ink:[NSColor whiteColor]];
        [b setTarget:self];
        [b setAction:@selector(openCoach:)];
        [view addSubview:b];

        [window center];
    }
    [window makeKeyAndOrderFront:nil];
}

/* GDWebLink decides where these go: their own browser when it can cope,
 * Captain Polliwog when it is there, and a recommendation when it is not. */
- (void) openCytrus:(id)sender
{
    [GDWebLink openURL:[NSURL URLWithString:@"https://www.cytrusretro.com/"]];
}

- (void) openCoach:(id)sender
{
    [GDWebLink openURL:[NSURL URLWithString:@"https://www.amcreativecoach.com/"]];
}

@end
