#import "GDStoreController.h"
#import "GDGridView.h"
#import "GDItemView.h"
#import "GDLibraryView.h"
#import "GDGarden.h"
#import "GDHTTP.h"
#import "GDCatalog.h"
#import "GDInstaller.h"
#import "GDStyle.h"

static NSString *TBNav = @"nav", *TBSections = @"sections", *TBSearch = @"search";

enum { SegFeatured, SegApps, SegGames, SegCategories, SegLibrary };

/* Request purposes (tag) */
enum { ReqShelf = 1, ReqSearchToken, ReqSearch };

@interface GDStoreController (Private)
- (void) loadShelf:(GDShelf *)sh url:(NSURL *)u;
- (void) runSearch:(NSString *)keys page:(int)n shelf:(GDShelf *)sh;
@end

@implementation GDStoreController

- (id) init
{
    NSToolbar *tb;
    NSRect frame = NSMakeRect(0, 0, 1000, 700);
    if ((self = [super init]) == nil)
        return nil;
    history = [[NSMutableArray alloc] init];
    requests = [[NSMutableArray alloc] init];
    historyIndex = -1;
    /* Most of the Garden is Mac OS 9 software.  Where Classic can run it the
     * store filters to what runs; elsewhere the filter would leave little,
     * so everything is shown with its badge unless the user asks. */
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"GDOnlyRunnable"])
        onlyRunnable = [[NSUserDefaults standardUserDefaults] boolForKey:@"GDOnlyRunnable"];
    else
        onlyRunnable = [GDCompat hostHasClassic];

    window = [[NSWindow alloc] initWithContentRect:frame
                                         styleMask:NSTitledWindowMask | NSClosableWindowMask |
                                                   NSMiniaturizableWindowMask | NSResizableWindowMask |
                                                   NSUnifiedTitleAndToolbarWindowMask
                                           backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"The Garden"];
    [window setMinSize:NSMakeSize(720, 480)];
    [window setFrameAutosaveName:@"GDStoreWindow"];
    [window setReleasedWhenClosed:NO];

    scroll = [[NSScrollView alloc] initWithFrame:[[window contentView] bounds]];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutohidesScrollers:YES];
    [scroll setBorderType:NSNoBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [scroll setBackgroundColor:GDBackgroundColor()];
    [[scroll contentView] setCopiesOnScroll:YES];
    [window setContentView:scroll];

    navControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 64, 25)];
    [navControl setSegmentCount:2];
    [navControl setLabel:GDU("\xE2\x97\x80") forSegment:0];
    [navControl setLabel:GDU("\xE2\x96\xB6") forSegment:1];
    [navControl setWidth:28 forSegment:0];
    [navControl setWidth:28 forSegment:1];
    [[navControl cell] setTrackingMode:NSSegmentSwitchTrackingMomentary];
    [navControl setTarget:self];
    [navControl setAction:@selector(navClicked:)];

    sectionControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 420, 25)];
    [sectionControl setSegmentCount:5];
    [sectionControl setLabel:@"Featured" forSegment:SegFeatured];
    [sectionControl setLabel:@"Apps" forSegment:SegApps];
    [sectionControl setLabel:@"Games" forSegment:SegGames];
    [sectionControl setLabel:@"Categories" forSegment:SegCategories];
    [sectionControl setLabel:@"Library" forSegment:SegLibrary];
    {
        float widths[] = { 78, 58, 62, 86, 86 };
        float total = 0;
        int k;
        for (k = 0; k < 5; k++) {
            [sectionControl setWidth:widths[k] forSegment:k];
            total += widths[k];
        }
        [sectionControl setFrameSize:NSMakeSize(total + 12, 25)];
    }
    [sectionControl setTarget:self];
    [sectionControl setAction:@selector(sectionClicked:)];

    searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 0, 200, 22)];
    [[searchField cell] setPlaceholderString:@"Search the Garden"];
    [[searchField cell] setSendsWholeSearchString:YES];
    [searchField setTarget:self];
    [searchField setAction:@selector(searchEntered:)];

    tb = [[[NSToolbar alloc] initWithIdentifier:@"GDStoreToolbar"] autorelease];
    [tb setDelegate:self];
    [tb setDisplayMode:NSToolbarDisplayModeIconOnly];
    [tb setAllowsUserCustomization:NO];
    [window setToolbar:tb];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(jobChanged:)
                                                 name:GDJobChangedNotification object:nil];
    return self;
}

- (NSWindow *) window { return window; }

- (void) showWindow
{
    if (![window setFrameUsingName:@"GDStoreWindow"])
        [window center];
    [window makeKeyAndOrderFront:nil];
    if (page == nil)
        [self showFeatured:nil];
}

/* ----------------------------------------------------------------- toolbar */

- (NSArray *) toolbarAllowedItemIdentifiers:(NSToolbar *)t
{
    return [NSArray arrayWithObjects:TBNav, TBSections, TBSearch,
               NSToolbarFlexibleSpaceItemIdentifier, NSToolbarSpaceItemIdentifier, nil];
}

- (NSArray *) toolbarDefaultItemIdentifiers:(NSToolbar *)t
{
    return [NSArray arrayWithObjects:TBNav, NSToolbarFlexibleSpaceItemIdentifier, TBSections,
               NSToolbarFlexibleSpaceItemIdentifier, TBSearch, nil];
}

- (NSToolbarItem *) toolbar:(NSToolbar *)t itemForItemIdentifier:(NSString *)ident
  willBeInsertedIntoToolbar:(BOOL)flag
{
    NSToolbarItem *it = [[[NSToolbarItem alloc] initWithItemIdentifier:ident] autorelease];
    NSView *v = nil;
    if ([ident isEqualToString:TBNav]) {
        v = navControl;
        [it setLabel:@"Back/Forward"];
    } else if ([ident isEqualToString:TBSections]) {
        v = sectionControl;
        [it setLabel:@"Store"];
    } else if ([ident isEqualToString:TBSearch]) {
        v = searchField;
        [it setLabel:@"Search"];
    }
    [it setView:v];
    [it setMinSize:[v frame].size];
    [it setMaxSize:[v frame].size];
    return it;
}

/* --------------------------------------------------------------- navigation */

- (void) updateChrome
{
    NSString *kind = [page objectForKey:@"kind"];
    int seg = -1;
    [navControl setEnabled:historyIndex > 0 forSegment:0];
    [navControl setEnabled:historyIndex < (int)[history count] - 1 forSegment:1];
    if ([kind isEqualToString:@"featured"]) seg = SegFeatured;
    else if ([kind isEqualToString:@"apps"]) seg = SegApps;
    else if ([kind isEqualToString:@"games"]) seg = SegGames;
    else if ([kind isEqualToString:@"categories"]) seg = SegCategories;
    else if ([kind isEqualToString:@"library"]) seg = SegLibrary;
    if (seg >= 0)
        [sectionControl setSelectedSegment:seg];
    else {
        int i;
        for (i = 0; i < [sectionControl segmentCount]; i++)
            [sectionControl setSelected:NO forSegment:i];
    }
    [window setTitle:[page objectForKey:@"title"] ?: @"The Garden"];
}

- (void) cancelRequests
{
    unsigned i;
    for (i = 0; i < [requests count]; i++) {
        [[requests objectAtIndex:i] setDelegate:nil];
        [[requests objectAtIndex:i] cancel];
    }
    [requests removeAllObjects];
}

- (void) setPageView:(NSView *)v
{
    NSRect f = [[scroll contentView] bounds];
    [pageView autorelease];
    pageView = [v retain];
    [v setFrame:NSMakeRect(0, 0, f.size.width, f.size.height)];
    [scroll setDocumentView:v];
    [[scroll contentView] scrollToPoint:NSZeroPoint];
    [scroll reflectScrolledClipView:[scroll contentView]];
}

- (GDGridView *) newGrid
{
    GDGridView *g = [[[GDGridView alloc] initWithFrame:[[scroll contentView] bounds]] autorelease];
    [g setDelegate:self];
    [g setOnlyRunnable:onlyRunnable];
    return g;
}

- (void) show:(NSDictionary *)p
{
    NSString *kind = [p objectForKey:@"kind"];
    [self cancelRequests];
    [page autorelease];
    page = [p retain];
    [self updateChrome];

    if ([kind isEqualToString:@"featured"]) {
        GDGridView *g = [self newGrid];
        GDShelf *games = [GDShelf shelfWithTitle:@"Featured Games"];
        GDShelf *apps = [GDShelf shelfWithTitle:@"Featured Applications"];
        games->seeAll = [@"See All Games" retain];
        games->tag = SegGames;
        apps->seeAll = [@"See All Apps" retain];
        apps->tag = SegApps;
        games->subtitle = [@"Hand-picked by the Macintosh Garden community" retain];
        [g setShelves:[NSArray arrayWithObjects:games, apps, nil]];
        [self setPageView:g];
        [self loadShelf:games url:[GDGarden listURLForSection:@"games" selector:@"all" page:0]];
        [self loadShelf:apps url:[GDGarden listURLForSection:@"apps" selector:@"all" page:0]];
    } else if ([kind isEqualToString:@"apps"] || [kind isEqualToString:@"games"] ||
               [kind isEqualToString:@"list"]) {
        GDGridView *g = [self newGrid];
        NSString *section = [p objectForKey:@"section"] ?: kind;
        NSString *sel = [p objectForKey:@"selector"];
        GDShelf *sh = [GDShelf shelfWithTitle:[p objectForKey:@"title"]];
        sh->letterBar = ![kind isEqualToString:@"list"];
        sh->letter = [[p objectForKey:@"letter"] copy];
        sh->tag = 0;
        [g setShelves:[NSArray arrayWithObject:sh]];
        [self setPageView:g];
        if (sh->letter)
            sel = sh->letter;
        [self loadShelf:sh url:[GDGarden listURLForSection:section selector:sel ?: @"all" page:0]];
    } else if ([kind isEqualToString:@"categories"]) {
        GDGridView *g = [self newGrid];
        NSDictionary *cats = [NSDictionary dictionaryWithContentsOfFile:
                                 [[NSBundle mainBundle] pathForResource:@"Categories" ofType:@"plist"]];
        GDShelf *a = [GDShelf shelfWithTitle:@"Application Categories"];
        GDShelf *ga = [GDShelf shelfWithTitle:@"Game Categories"];
        a->categories = ga->categories = YES;
        [a->entries addObjectsFromArray:[cats objectForKey:@"apps"]];
        [ga->entries addObjectsFromArray:[cats objectForKey:@"games"]];
        [g setShelves:[NSArray arrayWithObjects:ga, a, nil]];
        [self setPageView:g];
    } else if ([kind isEqualToString:@"library"]) {
        GDLibraryView *l = [[[GDLibraryView alloc] initWithFrame:[[scroll contentView] bounds]] autorelease];
        [l setDelegate:self];
        [self setPageView:l];
        [l reload];
    } else if ([kind isEqualToString:@"search"]) {
        GDGridView *g = [self newGrid];
        GDShelf *sh = [GDShelf shelfWithTitle:[NSString stringWithFormat:GDU("Results for \xE2\x80\x9C%@\xE2\x80\x9D"),
                                                 [p objectForKey:@"keys"]]];
        [g setShelves:[NSArray arrayWithObject:sh]];
        [self setPageView:g];
        [searchField setStringValue:[p objectForKey:@"keys"]];
        [self runSearch:[p objectForKey:@"keys"] page:0 shelf:sh];
    } else if ([kind isEqualToString:@"item"]) {
        GDItemView *v = [[[GDItemView alloc] initWithFrame:[[scroll contentView] bounds]
                                                      path:[p objectForKey:@"path"]
                                                   summary:[p objectForKey:@"summary"]] autorelease];
        [v setDelegate:self];
        [self setPageView:v];
    }
}

- (void) go:(NSDictionary *)p
{
    while ((int)[history count] > historyIndex + 1)
        [history removeLastObject];
    [history addObject:p];
    if ([history count] > 50)
        [history removeObjectAtIndex:0];
    historyIndex = (int)[history count] - 1;
    [self show:p];
}

- (void) navClicked:(id)sender
{
    if ([sender selectedSegment] == 0)
        [self goBack:sender];
    else
        [self goForward:sender];
}

- (IBAction) goBack:(id)sender
{
    if (historyIndex > 0)
        [self show:[history objectAtIndex:--historyIndex]];
}

- (IBAction) goForward:(id)sender
{
    if (historyIndex < (int)[history count] - 1)
        [self show:[history objectAtIndex:++historyIndex]];
}

- (void) sectionClicked:(id)sender
{
    switch ([sender selectedSegment]) {
    case SegFeatured: [self showFeatured:sender]; break;
    case SegApps: [self showApps:sender]; break;
    case SegGames: [self showGames:sender]; break;
    case SegCategories: [self showCategories:sender]; break;
    case SegLibrary: [self showLibrary:sender]; break;
    }
}

static NSDictionary *pageOf(NSString *kind, NSString *title)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:kind, @"kind", title, @"title", nil];
}

- (IBAction) showFeatured:(id)s { [self go:pageOf(@"featured", @"The Garden")]; }
- (IBAction) showApps:(id)s { [self go:pageOf(@"apps", @"Applications")]; }
- (IBAction) showGames:(id)s { [self go:pageOf(@"games", @"Games")]; }
- (IBAction) showCategories:(id)s { [self go:pageOf(@"categories", @"Categories")]; }
- (IBAction) showLibrary:(id)s { [self go:pageOf(@"library", @"Library")]; }
- (IBAction) focusSearch:(id)s { [window makeFirstResponder:searchField]; }
- (IBAction) reloadPage:(id)s { if (page) [self show:page]; }
- (BOOL) onlyRunnable { return onlyRunnable; }

- (IBAction) toggleOnlyRunnable:(id)sender
{
    onlyRunnable = !onlyRunnable;
    [[NSUserDefaults standardUserDefaults] setBool:onlyRunnable forKey:@"GDOnlyRunnable"];
    if ([pageView isKindOfClass:[GDGridView class]])
        [(GDGridView *)pageView setOnlyRunnable:onlyRunnable];
}

- (BOOL) validateMenuItem:(NSMenuItem *)m
{
    if ([m action] == @selector(toggleOnlyRunnable:))
        [m setState:onlyRunnable ? NSOnState : NSOffState];
    if ([m action] == @selector(goBack:))
        return historyIndex > 0;
    if ([m action] == @selector(goForward:))
        return historyIndex < (int)[history count] - 1;
    return YES;
}

- (void) searchEntered:(id)sender
{
    NSString *k = [[searchField stringValue] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
    if ([k length])
        [self go:[NSDictionary dictionaryWithObjectsAndKeys:@"search", @"kind", k, @"keys",
                     @"Search", @"title", nil]];
}

/* ------------------------------------------------------------------ loading */

- (int) pendingRequests { return (int)[requests count]; }

- (GDHTTPRequest *) request:(NSURL *)u tag:(int)tag info:(id)info
{
    GDHTTPRequest *r = [GDHTTPRequest requestWithURL:u];
    [r setTag:tag];
    [r setUserInfo:info];
    [r setDelegate:self];
    [requests addObject:r];
    return r;
}

- (void) loadShelf:(GDShelf *)sh url:(NSURL *)u
{
    sh->loading = YES;
    [(GDGridView *)pageView reload];
    [[self request:u tag:ReqShelf info:sh] start];
}

- (void) runSearch:(NSString *)keys page:(int)n shelf:(GDShelf *)sh
{
    GDHTTPRequest *r;
    sh->loading = YES;
    [(GDGridView *)pageView reload];
    if (n > 0) {
        r = [self request:[GDGarden searchResultsURL:keys page:n] tag:ReqSearch info:sh];
    } else if (searchToken == nil) {
        /* Drupal wants a form token and the session cookie that came with it. */
        r = [self request:[GDGarden listURLForSection:@"games" selector:@"all" page:0]
                      tag:ReqSearchToken info:sh];
    } else {
        NSString *body = [NSString stringWithFormat:@"keys=%@&form_token=%@&form_id=search_form&op=Search",
                             GDFormEncode(keys), searchToken];
        r = [self request:[GDGarden absoluteURL:@"/search/node"] tag:ReqSearch info:sh];
        [r setPostBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [r start];
}

- (void) httpRequestDidFinish:(GDHTTPRequest *)r
{
    GDShelf *sh = [r userInfo];
    GDListing *L = nil;
    [[r retain] autorelease];
    [requests removeObject:r];
    if (![pageView isKindOfClass:[GDGridView class]] || ![[(GDGridView *)pageView shelves] containsObject:sh])
        return;

    if ([r tag] == ReqSearchToken) {
        searchToken = [[GDGarden parseFormToken:[r data]] retain];
        if (searchToken == nil) {
            sh->loading = NO;
            [(GDGridView *)pageView setMessage:@"The Garden's search is not answering. Try again later."];
            return;
        }
        [self runSearch:[page objectForKey:@"keys"] page:0 shelf:sh];
        return;
    }
    sh->loading = NO;
    if ([r error] == nil)
        L = [r tag] == ReqSearch ? [GDGarden parseSearch:[r data]] : [GDGarden parseListing:[r data]];
    if (L == nil) {
        [sh->subtitle autorelease];
        sh->subtitle = [[NSString stringWithFormat:@"Could not reach the Macintosh Garden (%@).",
                            [r error] ?: @"unexpected page"] retain];
        if ([r tag] == ReqSearch) {
            [searchToken release];     /* tokens expire with the session */
            searchToken = nil;
        }
    } else {
        [sh->entries addObjectsFromArray:[L items]];
        sh->hasMore = [L page] + 1 < [L pageCount] && sh->seeAll == nil;
        if (sh->hasMore) {
            NSMutableDictionary *st = [NSMutableDictionary dictionary];
            [st setObject:[NSNumber numberWithInt:[L page] + 1] forKey:@"next"];
            [st setObject:[[r url] absoluteString] forKey:@"url"];
            if (sh->state)
                [st setObject:[sh->state objectForKey:@"autoPulled"] ?: [NSNumber numberWithInt:0]
                       forKey:@"autoPulled"];
            [sh->state release];
            sh->state = [st retain];
        }
    }
    [(GDGridView *)pageView reload];
}

/* ------------------------------------------------------- grid delegate */

- (void) gridView:(GDGridView *)g openItem:(GDItem *)item
{
    [self go:[NSDictionary dictionaryWithObjectsAndKeys:@"item", @"kind", [item path], @"path",
                 item, @"summary", [item title] ?: @"", @"title", nil]];
}

- (void) gridView:(GDGridView *)g openCategory:(NSDictionary *)c
{
    NSString *path = [c objectForKey:@"path"];
    NSString *section = [[path pathComponents] objectAtIndex:1];
    [self go:[NSDictionary dictionaryWithObjectsAndKeys:@"list", @"kind", section, @"section",
                 path, @"selector", [c objectForKey:@"name"], @"title", nil]];
}

- (void) gridView:(GDGridView *)g seeAllForShelf:(GDShelf *)sh
{
    if (sh->tag == SegGames)
        [self showGames:nil];
    else
        [self showApps:nil];
}

- (void) gridView:(GDGridView *)g shelf:(GDShelf *)sh pickLetter:(NSString *)letter
{
    NSMutableDictionary *p = [[page mutableCopy] autorelease];
    if (letter)
        [p setObject:letter forKey:@"letter"];
    else
        [p removeObjectForKey:@"letter"];
    [self go:p];
}

- (void) gridView:(GDGridView *)g moreForShelf:(GDShelf *)sh
{
    NSDictionary *st = sh->state;
    int next = [[st objectForKey:@"next"] intValue];
    NSString *kind = [page objectForKey:@"kind"];
    if (st == nil)
        return;
    if ([kind isEqualToString:@"search"]) {
        [self runSearch:[page objectForKey:@"keys"] page:next shelf:sh];
    } else {
        NSString *section = [page objectForKey:@"section"] ?: kind;
        NSString *sel = [page objectForKey:@"letter"] ?: ([page objectForKey:@"selector"] ?: @"all");
        [self loadShelf:sh url:[GDGarden listURLForSection:section selector:sel page:next]];
    }
}

/* ------------------------------------------------------- item delegate */

- (void) itemView:(id)v getFile:(GDFile *)f ofItem:(GDItemDetail *)d
{
    GDVerdict verdict = [GDCompat verdictForFile:f architecture:[d architecture]];
    if (![GDCompat runsHere:verdict] || verdict == GDVerdictUnknown) {
        int r = NSRunAlertPanel([NSString stringWithFormat:GDU("\xE2\x80\x9C%@\xE2\x80\x9D may not run on this Mac."), [d title]],
                                @"%@ Download it anyway?", @"Download", @"Cancel", nil,
                                [GDCompat explanation:verdict]);
        if (r != NSAlertDefaultReturn)
            return;
    }
    [[GDInstaller sharedInstaller] installFile:f ofItem:d];
}

- (void) itemView:(id)v openInstalled:(NSDictionary *)entry
{
    NSString *launch = [entry objectForKey:@"launch"];
    NSArray *inst = [entry objectForKey:@"installed"];
    if (launch && [[NSWorkspace sharedWorkspace] openFile:launch])
        return;
    if ([inst count])
        [[NSWorkspace sharedWorkspace] selectFile:[inst objectAtIndex:0] inFileViewerRootedAtPath:@""];
}

- (void) itemView:(id)v showScreenshot:(NSString *)url
{
    NSImage *img = [[GDCatalog sharedCatalog] imageForURL:url];
    NSImageView *iv;
    NSSize s;
    if (img == nil)
        return;
    s = [img size];
    s.width = MIN(MAX(s.width, 320), 1000);
    s.height = MIN(MAX(s.height, 240), 740);
    if (shotWindow == nil) {
        shotWindow = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, s.width, s.height)
                                                styleMask:NSTitledWindowMask | NSClosableWindowMask |
                                                          NSResizableWindowMask | NSUtilityWindowMask
                                                  backing:NSBackingStoreBuffered defer:NO];
        [shotWindow setReleasedWhenClosed:NO];
        iv = [[[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, s.width, s.height)] autorelease];
        [iv setImageScaling:NSScaleProportionally];
        [iv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [shotWindow setContentView:iv];
    }
    [shotWindow setTitle:[[page objectForKey:@"title"] description]];
    [shotWindow setContentSize:s];
    [(NSImageView *)[shotWindow contentView] setImage:img];
    [shotWindow center];
    [shotWindow makeKeyAndOrderFront:nil];
}

/* ---------------------------------------------------- library delegate */

- (void) libraryView:(id)v openItemPath:(NSString *)path
{
    [self go:[NSDictionary dictionaryWithObjectsAndKeys:@"item", @"kind", path, @"path", @"", @"title", nil]];
}

- (void) jobChanged:(NSNotification *)n
{
    GDInstallJob *j = [n object];
    int active = 0;
    unsigned i;
    NSArray *jobs = [[GDInstaller sharedInstaller] jobs];
    for (i = 0; i < [jobs count]; i++)
        if ([[jobs objectAtIndex:i] isActive])
            active++;
    [sectionControl setLabel:active ? [NSString stringWithFormat:@"Library (%d)", active] : @"Library"
                  forSegment:SegLibrary];
    (void)j;
}

@end
