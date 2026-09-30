#import "GDSettings.h"
#import "GDInstaller.h"
#import "GDStyle.h"

NSString *GDSettingsChangedNotification = @"GDSettingsChanged";

#define SET_W 470.0
#define SET_H 248.0
#define PAD 24.0
#define HIDDEN_KEY @"GDUpdatesTabHidden"

/* ---- the window's contents ---------------------------------------------
 * The headings and the explanations are drawn; only what changes as the user
 * clicks is a control.
 */
@interface GDSettingsView : NSView
@end

@implementation GDSettingsView

- (BOOL) isFlipped { return YES; }

- (void) drawRect:(NSRect)dirty
{
    float w = NSWidth([self bounds]);

    [[NSColor whiteColor] set];
    NSRectFill(dirty);

    GDDrawText(@"Updates", NSMakeRect(PAD, 20, w - 2 * PAD, 20),
               [NSFont boldSystemFontOfSize:14], [NSColor blackColor], YES);
    GDDrawText(@"The Updates tab offers a newer version of anything you got from the "
                "Garden. Turn it off and The Garden leaves what you have installed alone.",
               NSMakeRect(PAD, 70, w - 2 * PAD, 32), [NSFont systemFontOfSize:11],
               GDSubtleTextColor(), NO);

    [[NSColor colorWithCalibratedWhite:0.87 alpha:1] set];
    NSRectFill(NSMakeRect(PAD, 114, w - 2 * PAD, 1));

    GDDrawText(@"Ignored Updates", NSMakeRect(PAD, 128, w - 2 * PAD, 20),
               [NSFont boldSystemFontOfSize:14], [NSColor blackColor], YES);
    GDDrawText(@"An update you ignore is not offered again. A version newer than the one "
                "you ignored still is.",
               NSMakeRect(PAD, 202, w - 2 * PAD, 32), [NSFont systemFontOfSize:11],
               GDSubtleTextColor(), NO);
}

@end

/* ---- the window --------------------------------------------------------- */

@interface GDSettings (Private)
- (void) showWindow;
- (void) refresh;
@end

static GDSettings *sharedSettings;

@implementation GDSettings

+ (void) show
{
    if (sharedSettings == nil)
        sharedSettings = [[self alloc] init];
    [sharedSettings showWindow];
}

+ (BOOL) updatesTabHidden
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:HIDDEN_KEY];
}

/* A label: a text field is used rather than drawn text, because this one
 * changes as the button next to it is clicked. */
- (NSTextField *) label:(NSRect)r
{
    NSTextField *t = [[[NSTextField alloc] initWithFrame:r] autorelease];
    [t setEditable:NO];
    [t setSelectable:NO];
    [t setBordered:NO];
    [t setDrawsBackground:NO];
    [t setFont:[NSFont systemFontOfSize:11]];
    return t;
}

- (void) showWindow
{
    if (window == nil) {
        NSRect frame = NSMakeRect(0, 0, SET_W, SET_H);
        GDSettingsView *view;

        window = [[NSWindow alloc] initWithContentRect:frame
                      styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                        backing:NSBackingStoreBuffered defer:NO];
        [window setTitle:@"Settings"];
        [window setReleasedWhenClosed:NO];

        view = [[[GDSettingsView alloc] initWithFrame:frame] autorelease];
        [window setContentView:view];

        updatesTabBox = [[NSButton alloc] initWithFrame:NSMakeRect(PAD, 44, SET_W - 2 * PAD, 20)];
        [updatesTabBox setButtonType:NSSwitchButton];
        [updatesTabBox setTitle:@"Show the Updates tab"];
        [updatesTabBox setFont:[NSFont systemFontOfSize:12]];
        [updatesTabBox setTarget:self];
        [updatesTabBox setAction:@selector(toggleUpdatesTab:)];
        [view addSubview:updatesTabBox];

        ignoredLine = [[self label:NSMakeRect(PAD, 156, SET_W - 2 * PAD - 190, 18)] retain];
        [view addSubview:ignoredLine];

        unignoreButton = [[NSButton alloc] initWithFrame:
                             NSMakeRect(SET_W - PAD - 180, 152, 180, 26)];
        [unignoreButton setBezelStyle:NSRoundedBezelStyle];
        [[unignoreButton cell] setControlSize:NSSmallControlSize];
        [unignoreButton setFont:[NSFont systemFontOfSize:11]];
        [unignoreButton setTitle:@"Stop Ignoring Them"];
        [unignoreButton setTarget:self];
        [unignoreButton setAction:@selector(stopIgnoring:)];
        [view addSubview:unignoreButton];

        [window center];
    }
    [self refresh];
    [window makeKeyAndOrderFront:nil];
}

- (void) refresh
{
    unsigned n = [[GDInstaller sharedInstaller] ignoredUpdateCount];
    [updatesTabBox setState:[GDSettings updatesTabHidden] ? NSOffState : NSOnState];
    [ignoredLine setStringValue:
        n == 0 ? @"No updates are being ignored."
               : (n == 1 ? @"One update is being ignored."
                         : [NSString stringWithFormat:@"%u updates are being ignored.", n])];
    [unignoreButton setEnabled:n > 0];
}

- (void) toggleUpdatesTab:(id)sender
{
    [[NSUserDefaults standardUserDefaults] setBool:([updatesTabBox state] != NSOnState)
                                            forKey:HIDDEN_KEY];
    [[NSNotificationCenter defaultCenter] postNotificationName:GDSettingsChangedNotification
                                                        object:self];
    [self refresh];
}

- (void) stopIgnoring:(id)sender
{
    [[GDInstaller sharedInstaller] clearIgnoredUpdates];
    [self refresh];
}

@end
