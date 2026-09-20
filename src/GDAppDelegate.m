#import "GDAppDelegate.h"
#import "GDStoreController.h"
#import "GDInstaller.h"
#import "GDGarden.h"
#import "GDCatalog.h"
#import "GDAccelerator.h"
#import "GDSelfUpdate.h"
#import "GDStyle.h"

static NSMenu *addSubmenu(NSMenu *bar, NSString *title)
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""] autorelease];
    NSMenu *m = [[[NSMenu alloc] initWithTitle:title] autorelease];
    [item setSubmenu:m];
    [bar addItem:item];
    return m;
}

static NSMenuItem *addItem(NSMenu *m, NSString *title, SEL action, NSString *key)
{
    NSMenuItem *it = [[[NSMenuItem alloc] initWithTitle:title action:action
                                          keyEquivalent:key ?: @""] autorelease];
    [m addItem:it];
    return it;
}

@implementation GDAppDelegate

- (void) buildMainMenu
{
    NSMenu *bar = [[[NSMenu alloc] initWithTitle:@"MainMenu"] autorelease];
    NSMenu *m;
    NSMenuItem *it;

    [NSApp setMainMenu:bar];
    m = addSubmenu(bar, @"The Garden");
    addItem(m, @"About The Garden", @selector(orderFrontStandardAboutPanel:), nil);
    [m addItem:[NSMenuItem separatorItem]];
    addItem(m, GDU("Check for Updates\xE2\x80\xA6"), @selector(checkForUpdates:), nil);
    [m addItem:[NSMenuItem separatorItem]];
    addItem(m, @"Hide The Garden", @selector(hide:), @"h");
    it = addItem(m, @"Hide Others", @selector(hideOtherApplications:), @"h");
    [it setKeyEquivalentModifierMask:NSCommandKeyMask | NSAlternateKeyMask];
    addItem(m, @"Show All", @selector(unhideAllApplications:), nil);
    [m addItem:[NSMenuItem separatorItem]];
    addItem(m, @"Quit The Garden", @selector(terminate:), @"q");
    /* Without a nib, Tiger only treats this as the application menu once told. */
    if ([NSApp respondsToSelector:@selector(setAppleMenu:)])
        [NSApp performSelector:@selector(setAppleMenu:) withObject:m];

    m = addSubmenu(bar, @"File");
    addItem(m, @"Close Window", @selector(performClose:), @"w");

    m = addSubmenu(bar, @"Edit");
    addItem(m, @"Undo", @selector(undo:), @"z");
    addItem(m, @"Redo", @selector(redo:), @"Z");
    [m addItem:[NSMenuItem separatorItem]];
    addItem(m, @"Cut", @selector(cut:), @"x");
    addItem(m, @"Copy", @selector(copy:), @"c");
    addItem(m, @"Paste", @selector(paste:), @"v");
    addItem(m, @"Select All", @selector(selectAll:), @"a");

    m = addSubmenu(bar, @"Store");
    addItem(m, @"Featured", @selector(showFeatured:), @"1");
    addItem(m, @"Applications", @selector(showApps:), @"2");
    addItem(m, @"Games", @selector(showGames:), @"3");
    addItem(m, @"Categories", @selector(showCategories:), @"4");
    addItem(m, @"Library", @selector(showLibrary:), @"5");
    addItem(m, @"Updates", @selector(showUpdates:), @"6");
    [m addItem:[NSMenuItem separatorItem]];
    addItem(m, @"Back", @selector(goBack:), @"[");
    addItem(m, @"Forward", @selector(goForward:), @"]");
    addItem(m, @"Search", @selector(focusSearch:), @"f");
    addItem(m, @"Reload", @selector(reloadPage:), @"r");
    addItem(m, @"View Page on Macintosh Garden", @selector(viewOnSite:), @"l");

    m = addSubmenu(bar, @"View");
    addItem(m, @"Only Show Software That Runs on This Mac", @selector(toggleOnlyRunnable:), @"R");

    m = addSubmenu(bar, @"Window");
    addItem(m, @"Minimize", @selector(performMiniaturize:), @"m");
    addItem(m, @"Zoom", @selector(performZoom:), nil);
    addItem(m, @"Store Window", @selector(showStoreWindow:), @"0");
    [NSApp setWindowsMenu:m];
}

- (void) applicationDidFinishLaunching:(NSNotification *)n
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *debugPage = [d stringForKey:@"GDDebugPage"];
    /* Look for PowerEmu's Web Accelerator; nothing waits on the answer. */
    [GDAccelerator start];
    /* And for a newer Garden, once a day, quietly. */
    if ([d boolForKey:@"GDDebugUpdate"])
        [[GDSelfUpdate sharedUpdater] performSelector:@selector(checkAndInstallNow)
                                           withObject:nil afterDelay:3.0];
    else
        [[GDSelfUpdate sharedUpdater] performSelector:@selector(checkInBackground)
                                           withObject:nil afterDelay:5.0];
    store = [[GDStoreController alloc] init];
    [store showWindow];
    [NSApp activateIgnoringOtherApps:YES];

    /* Test hook: open a page, wait until it has settled, write a PNG of the
     * window and optionally quit.  Used over ssh by scripts/remote-run.sh. */
    if ([debugPage length]) {
        if ([debugPage hasPrefix:@"/"])
            [store go:[NSDictionary dictionaryWithObjectsAndKeys:@"item", @"kind", debugPage, @"path",
                          @"", @"title", nil]];
        else if ([debugPage hasPrefix:@"search:"])
            [store go:[NSDictionary dictionaryWithObjectsAndKeys:@"search", @"kind",
                          [debugPage substringFromIndex:7], @"keys", @"Search", @"title", nil]];
        else if ([debugPage isEqualToString:@"apps"]) [store showApps:nil];
        else if ([debugPage isEqualToString:@"games"]) [store showGames:nil];
        else if ([debugPage isEqualToString:@"categories"]) [store showCategories:nil];
        else if ([debugPage isEqualToString:@"library"]) [store showLibrary:nil];
        else if ([debugPage isEqualToString:@"updates"]) [store showUpdates:nil];
    }
    if ([d stringForKey:@"GDDebugSnapshotPath"])
        debugTimer = [[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(debugTick:)
                                                     userInfo:nil repeats:YES] retain];
}

- (IBAction) checkForUpdates:(id)sender
{
    [[GDSelfUpdate sharedUpdater] checkForUpdates:sender];
}

- (void) debugTick:(NSTimer *)t
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    static int ticks;
    NSString *get = [d stringForKey:@"GDDebugInstallFile"];
    ticks++;
    {
        NSArray *jobs = [[GDInstaller sharedInstaller] jobs];
        unsigned k, active = 0;
        for (k = 0; k < [jobs count]; k++)
            if ([[jobs objectAtIndex:k] isActive])
                active++;
        debugQuiet = ([store pendingRequests] == 0 && [[GDCatalog sharedCatalog] pendingLoads] == 0 &&
                      active == 0 && (get == nil || debugInstallStarted)) ? debugQuiet + 1 : 0;
    }
    /* Optional: Add to Dock for the first Library entry. */
    if ([d boolForKey:@"GDDebugDock"] && ticks == 4 && [[[GDInstaller sharedInstaller] library] count])
        NSLog(@"The Garden: addToDock -> %d",
              [[GDInstaller sharedInstaller] addToDock:[[[GDInstaller sharedInstaller] library] objectAtIndex:0]]);
    /* Optional: press Update on the first available update. */
    if ([get isEqualToString:@"update"] && ticks >= 6 && !debugInstallStarted &&
        [[[GDInstaller sharedInstaller] updates] count]) {
        [[GDInstaller sharedInstaller] installUpdate:[[[GDInstaller sharedInstaller] updates] objectAtIndex:0]];
        debugInstallStarted = YES;
        debugQuiet = 0;
    }
    /* Optional: start the install of file N of the item page once loaded. */
    if (get && ![get isEqualToString:@"update"] && ticks >= 6 && !debugInstallStarted) {
        NSView *v = [[[store window] contentView] documentView];
        if ([v respondsToSelector:@selector(detail)]) {
            GDItemDetail *det = [v performSelector:@selector(detail)];
            int idx = [get intValue];
            GDFile *f = nil;
            if (det && [get isEqualToString:@"best"])
                [GDCompat verdictForItem:det bestFile:&f];
            else if (det && [get rangeOfString:@"."].location != NSNotFound) {
                unsigned k;                     /* a file name */
                for (k = 0; k < [[det files] count]; k++)
                    if ([[[[det files] objectAtIndex:k] name] isEqualToString:get])
                        f = [[det files] objectAtIndex:k];
            } else if (det && idx < (int)[[det files] count])
                f = [[det files] objectAtIndex:idx];
            if (f) {
                [[GDInstaller sharedInstaller] installFile:f ofItem:det];
                debugInstallStarted = YES;
                debugQuiet = 0;
                ticks = MIN(ticks, 6);
            }
        }
    }
    /* Optional: open the page on the site in a web view, and snapshot that
     * window instead (the WebKit bridge, GDWebProtocol). */
    if ([d boolForKey:@"GDDebugViewOnSite"]) {
        static int webTicks;
        if (!debugWebOpened && debugQuiet >= 4) {
            [store viewOnSite:nil];
            debugWebOpened = YES;
            webTicks = 0;
        }
        if (debugWebOpened)
            debugQuiet = (++webTicks >= 12) ? 4 : 0;
    }
    if ((debugQuiet >= 4 && ticks >= [d integerForKey:@"GDDebugMinSeconds"]) || ticks > 240) {
        NSWindow *win = (debugWebOpened && [NSApp keyWindow] != nil) ? [NSApp keyWindow] : [store window];
        NSView *view = [[win contentView] superview];
        NSBitmapImageRep *bm;
        [debugTimer invalidate];
        [debugTimer release];
        debugTimer = nil;
        if ([d integerForKey:@"GDDebugScroll"] &&
            [[win contentView] isKindOfClass:[NSScrollView class]]) {
            NSScrollView *sv = (NSScrollView *)[win contentView];
            [[sv documentView] scrollPoint:NSMakePoint(0, [d integerForKey:@"GDDebugScroll"])];
            [win display];
        }
        [win displayIfNeeded];
        bm = [view bitmapImageRepForCachingDisplayInRect:[view bounds]];
        [view cacheDisplayInRect:[view bounds] toBitmapImageRep:bm];
        [[bm representationUsingType:NSPNGFileType properties:nil]
            writeToFile:[d stringForKey:@"GDDebugSnapshotPath"] atomically:YES];
        /* and the Dock icon as it is drawn now (badge, progress) */
        [[[NSApp applicationIconImage] TIFFRepresentation]
            writeToFile:[[d stringForKey:@"GDDebugSnapshotPath"] stringByAppendingString:@".icon.tiff"] atomically:YES];
        if ([[win contentView] isKindOfClass:[NSScrollView class]]) {
            NSView *doc = [(NSScrollView *)[win contentView] documentView];
            NSLog(@"The Garden: snapshot written after %ds; doc %@ frame %@ visible %@ subviews %d",
                  ticks, [doc class], NSStringFromRect([doc frame]),
                  NSStringFromRect([doc visibleRect]), (int)[[doc subviews] count]);
            if ([doc respondsToSelector:@selector(shelves)]) {
                NSArray *sh = [doc performSelector:@selector(shelves)];
                unsigned k;
                for (k = 0; k < [sh count]; k++) {
                    id s = [sh objectAtIndex:k];
                    NSLog(@"The Garden:  shelf %@", [s description]);
                }
            }
        }
        if ([d boolForKey:@"GDDebugQuit"])
            [NSApp terminate:nil];
    }
}

- (void) showStoreWindow:(id)sender { [store showWindow]; }

- (BOOL) applicationShouldHandleReopen:(NSApplication *)a hasVisibleWindows:(BOOL)v
{
    [store showWindow];
    return YES;
}

/* Menu actions for the store go to the controller. */
- (id) forwardingTargetForSelector:(SEL)s { return store; }
- (BOOL) respondsToSelector:(SEL)s
{
    return [super respondsToSelector:s] || [store respondsToSelector:s];
}
- (NSMethodSignature *) methodSignatureForSelector:(SEL)s
{
    return [super methodSignatureForSelector:s] ?: [store methodSignatureForSelector:s];
}
- (void) forwardInvocation:(NSInvocation *)inv
{
    if ([store respondsToSelector:[inv selector]])
        [inv invokeWithTarget:store];
    else
        [super forwardInvocation:inv];
}
- (BOOL) validateMenuItem:(NSMenuItem *)m
{
    if ([store respondsToSelector:[m action]])
        return [store validateMenuItem:m];
    return YES;
}

- (NSApplicationTerminateReply) applicationShouldTerminate:(NSApplication *)a
{
    NSArray *jobs = [[GDInstaller sharedInstaller] jobs];
    unsigned i, active = 0;
    for (i = 0; i < [jobs count]; i++)
        if ([[jobs objectAtIndex:i] isActive])
            active++;
    if (active && ![[NSUserDefaults standardUserDefaults] boolForKey:@"GDDebugQuit"]) {
        int r = NSRunAlertPanel(@"Downloads are in progress.",
                                @"Quitting now stops them.", @"Quit", @"Cancel", nil);
        if (r != NSAlertDefaultReturn)
            return NSTerminateCancel;
    }
    return NSTerminateNow;
}

@end
