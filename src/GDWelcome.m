#import "GDWelcome.h"
#import "GDCompat.h"
#import "GDStyle.h"

#define WEL_W 600.0
#define WEL_H 568.0
#define PAD 26.0
#define BADGE_W 150.0
#define TEXT_X (PAD + BADGE_W + 14)
#define ROW_H 36.0
#define SHOW_KEY @"GDWelcomeAtLaunch"

@interface GDWelcomeView : NSView
@end

@implementation GDWelcomeView

- (BOOL) isFlipped { return YES; }

- (void) drawRect:(NSRect)dirty
{
    float w = NSWidth([self bounds]), tw = w - TEXT_X - PAD, y;
    NSArray *all = [GDCompat allVerdicts];
    unsigned i;

    [[NSColor whiteColor] set];
    NSRectFill(dirty);

    GDDrawText(@"Welcome to The Garden", NSMakeRect(PAD, 24, w - 2 * PAD, 26),
               [NSFont boldSystemFontOfSize:18], [NSColor blackColor], YES);
    GDDrawText(@"A store for the Macintosh Garden's archive of old Macintosh software. "
                "Every item carries a badge saying how it stands with this Mac.",
               NSMakeRect(PAD, 56, w - 2 * PAD, 32), [NSFont systemFontOfSize:11],
               [NSColor blackColor], NO);

    [[NSColor colorWithCalibratedWhite:0.87 alpha:1] set];
    NSRectFill(NSMakeRect(PAD, 98, w - 2 * PAD, 1));

    GDDrawText(@"What the badges mean", NSMakeRect(PAD, 110, w - 2 * PAD, 20),
               [NSFont boldSystemFontOfSize:13], [NSColor blackColor], YES);

    y = 136;
    for (i = 0; i < [all count]; i++) {
        GDVerdict v = (GDVerdict)[[all objectAtIndex:i] intValue];
        GDDrawBadge(NSMakeRect(PAD, y, BADGE_W, 15), v, YES);
        GDDrawText([GDCompat explanation:v], NSMakeRect(TEXT_X, y - 2, tw, 32),
                   [NSFont systemFontOfSize:11], [NSColor blackColor], NO);
        y += ROW_H;
    }

    [[NSColor colorWithCalibratedWhite:0.87 alpha:1] set];
    NSRectFill(NSMakeRect(PAD, y + 4, w - 2 * PAD, 1));
    y += 16;

    /* The point of the whole window. */
    GDDrawText(@"A badge is about compatibility, not speed",
               NSMakeRect(PAD, y, w - 2 * PAD, 18), [NSFont boldSystemFontOfSize:12],
               [NSColor blackColor], YES);
    y += 22;
    GDDrawText([NSString stringWithFormat:
                   @"It says the software was made for this kind of Mac and this version of "
                    "Mac OS X. It does not say this Mac is fast enough, has memory enough, or "
                    "has the graphics a program wants. iWork '09 is compatible with Mac OS X on "
                    "a PowerPC Mac and is still far beyond a G3. When in doubt, read the item's "
                    "page: the Garden's own notes usually say what a program really needs.\n"
                    "This Mac: %@.", [GDCompat hostDescription]],
               NSMakeRect(PAD, y, w - 2 * PAD, 76), [NSFont systemFontOfSize:11],
               [NSColor blackColor], NO);
}

@end

/* ---- the window --------------------------------------------------------- */

@interface GDWelcome (Private)
- (void) showWindow;
@end

static GDWelcome *sharedWelcome;

@implementation GDWelcome

+ (BOOL) shouldShowAtLaunch
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    return [d objectForKey:SHOW_KEY] == nil || [d boolForKey:SHOW_KEY];
}

+ (void) show
{
    if (sharedWelcome == nil)
        sharedWelcome = [[self alloc] init];
    [sharedWelcome showWindow];
}

- (void) showWindow
{
    if (window == nil) {
        NSRect frame = NSMakeRect(0, 0, WEL_W, WEL_H);
        GDWelcomeView *view;
        NSButton *go;

        window = [[NSWindow alloc] initWithContentRect:frame
                      styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                        backing:NSBackingStoreBuffered defer:NO];
        [window setTitle:@"Welcome to The Garden"];
        [window setReleasedWhenClosed:NO];

        view = [[[GDWelcomeView alloc] initWithFrame:frame] autorelease];
        [window setContentView:view];

        showAgain = [[NSButton alloc] initWithFrame:
                        NSMakeRect(PAD, WEL_H - 38, WEL_W - 2 * PAD - 130, 20)];
        [showAgain setButtonType:NSSwitchButton];
        [showAgain setTitle:@"Show this when The Garden opens"];
        [showAgain setFont:[NSFont systemFontOfSize:11]];
        [showAgain setTarget:self];
        [showAgain setAction:@selector(toggleShowAgain:)];
        [view addSubview:showAgain];

        go = [[[NSButton alloc] initWithFrame:
                  NSMakeRect(WEL_W - PAD - 110, WEL_H - 42, 110, 28)] autorelease];
        [go setBezelStyle:NSRoundedBezelStyle];
        [go setTitle:@"Continue"];
        [go setKeyEquivalent:@"\r"];
        [go setTarget:self];
        [go setAction:@selector(close:)];
        [view addSubview:go];

        [window center];
    }
    [showAgain setState:[GDWelcome shouldShowAtLaunch] ? NSOnState : NSOffState];
    [window makeKeyAndOrderFront:nil];
}

- (void) toggleShowAgain:(id)sender
{
    [[NSUserDefaults standardUserDefaults] setBool:([showAgain state] == NSOnState)
                                            forKey:SHOW_KEY];
}

- (void) close:(id)sender { [window orderOut:nil]; }

@end
