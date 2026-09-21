#import "GDStoreController.h"
#import "GDGridView.h"
#import "GDItemView.h"
#import "GDLibraryView.h"
#import "GDGarden.h"
#import "GDWebWindow.h"
#import "GDSheepShaver.h"
#import "GDAbout.h"
#import "GDHTTP.h"
#import "GDCatalog.h"
#import "GDInstaller.h"
#import "GDStyle.h"

static NSString *TBNav = @"nav", *TBSections = @"sections", *TBSearch = @"search";
static NSString *TBBalance = @"balance";   /* keeps the sections centred in the window */

enum { SegFeatured, SegApps, SegGames, SegCategories, SegLibrary, SegUpdates };

/* Request purposes (tag) */
enum { ReqShelf = 1, ReqSearchToken, ReqSearch, ReqFeed };

@interface GDStoreController (Private)
- (void) loadShelf:(GDShelf *)sh url:(NSURL *)u;
- (void) runSearch:(NSString *)keys page:(int)n shelf:(GDShelf *)sh;
- (GDHTTPRequest *) request:(NSURL *)u tag:(int)tag info:(id)info;
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
    [window setTitle:[GDAbout stage] ? [NSString stringWithFormat:@"The Garden (%@)",
                          [GDAbout stage]] : @"The Garden"];
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
    [sectionControl setSegmentCount:6];
    [sectionControl setLabel:@"Featured" forSegment:SegFeatured];
    [sectionControl setLabel:@"Apps" forSegment:SegApps];
    [sectionControl setLabel:@"Games" forSegment:SegGames];
    [sectionControl setLabel:@"Categories" forSegment:SegCategories];
    [sectionControl setLabel:@"Library" forSegment:SegLibrary];
    [sectionControl setLabel:@"Updates" forSegment:SegUpdates];
    {
        float widths[] = { 74, 52, 58, 80, 78, 82 };
        float total = 0;
        int k;
        for (k = 0; k < 6; k++) {
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
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(jobChanged:)
                                                 name:GDUpdatesChangedNotification object:nil];
    return self;
}

- (NSWindow *) window { return window; }

- (void) showWindow
{
    if (![window setFrameUsingName:@"GDStoreWindow"])
        [window center];
    [window makeKeyAndOrderFront:nil];
    if (page == nil) {
        [self showFeatured:nil];
        /* Look for updates to installed titles a little after launch. */
        [[GDInstaller sharedInstaller] performSelector:@selector(checkForUpdates) withObject:nil afterDelay:3];
    }
}

/* ----------------------------------------------------------------- toolbar */

- (NSArray *) toolbarAllowedItemIdentifiers:(NSToolbar *)t
{
    return [NSArray arrayWithObjects:TBNav, TBBalance, TBSections, TBSearch,
               NSToolbarFlexibleSpaceItemIdentifier, NSToolbarSpaceItemIdentifier, nil];
}

- (NSArray *) toolbarDefaultItemIdentifiers:(NSToolbar *)t
{
    /* Two flexible spaces centre the sections in what is left over, not in the
     * window: the search field is wider than the back/forward pair, so the
     * tabs sit left of centre by half that difference.  A fixed spacer on the
     * short side makes both ends weigh the same. */
    return [NSArray arrayWithObjects:TBNav, TBBalance, NSToolbarFlexibleSpaceItemIdentifier,
               TBSections, NSToolbarFlexibleSpaceItemIdentifier, TBSearch, nil];
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
    } else if ([ident isEqualToString:TBBalance]) {
        float d = NSWidth([searchField frame]) - NSWidth([navControl frame]);
        v = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, d > 0 ? d : 0, 25)] autorelease];
        [it setLabel:@""];
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
    else if ([kind isEqualToString:@"updates"]) seg = SegUpdates;
    if (seg >= 0)
        [sectionControl setSelectedSegment:seg];
    else {
        /* No tab for item and search pages.  In select-one mode Tiger keeps
         * one segment lit no matter what; select-any lets all go dark. */
        int i;
        [[sectionControl cell] setTrackingMode:NSSegmentSwitchTrackingSelectAny];
        for (i = 0; i < [sectionControl segmentCount]; i++)
            [sectionControl setSelected:NO forSegment:i];
        [[sectionControl cell] setTrackingMode:NSSegmentSwitchTrackingSelectOne];
    }
    {
        NSString *t = [page objectForKey:@"title"] ?: @"The Garden";
        NSString *stage = [GDAbout stage];
        NSString *suffix = stage ? [NSString stringWithFormat:@"The Garden (%@)", stage]
                                 : @"The Garden";
        /* On the front page, and on a page that arrived without one, the
         * title is the app's name and nothing else. */
        [window setTitle:([t length] == 0 || [t isEqualToString:@"The Garden"]) ? suffix :
            [NSString stringWithFormat:GDU("%@  \xE2\x80\x94  %@"), t, suffix]];
    }
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
        GDShelf *news = [GDShelf shelfWithTitle:@"New & Noteworthy"];
        news->subtitle = [@"Recently added to the Macintosh Garden" retain];
        [g setShelves:[NSArray arrayWithObjects:news, games, apps, nil]];
        [self setPageView:g];
        {
            GDHTTPRequest *r = [self request:[GDGarden feedURL] tag:ReqFeed info:news];
            news->loading = YES;
            [r setCacheTTL:3600];
            [r start];
        }
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
    } else if ([kind isEqualToString:@"library"] || [kind isEqualToString:@"updates"]) {
        GDLibraryView *l = [[[GDLibraryView alloc] initWithFrame:[[scroll contentView] bounds]] autorelease];
        [l setDelegate:self];
        [l setShowsUpdates:[kind isEqualToString:@"updates"]];
        if ([kind isEqualToString:@"updates"])
            [[GDInstaller sharedInstaller] checkForUpdates];
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

- (NSString *) currentPageDescription
{
    NSString *kind = [page objectForKey:@"kind"] ?: @"";
    NSString *path = [page objectForKey:@"path"];
    NSString *keys = [page objectForKey:@"keys"];
    if ([path length])
        return [NSString stringWithFormat:@"%@ %@", kind, path];
    if ([keys length])
        return [NSString stringWithFormat:@"search \"%@\"", keys];
    return kind;
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

/* The page being shown, as it stands on macintoshgarden.org: the site is the
 * whole point of the app, and some of it (comments, an account) is only there. */
- (IBAction) viewOnSite:(id)sender
{
    NSString *kind = [page objectForKey:@"kind"];
    NSURL *u = nil;

    if ([kind isEqualToString:@"item"])
        u = [GDGarden absoluteURL:[page objectForKey:@"path"]];
    else if ([kind isEqualToString:@"search"])
        u = [GDGarden searchResultsURL:[page objectForKey:@"keys"] page:0];
    else if ([kind isEqualToString:@"apps"] || [kind isEqualToString:@"games"])
        u = [GDGarden listURLForSection:kind selector:@"all" page:0];
    else if ([kind isEqualToString:@"list"])
        u = [GDGarden listURLForSection:[page objectForKey:@"section"]
                               selector:[page objectForKey:@"selector"] page:0];
    if (u == nil)
        u = [GDGarden absoluteURL:@"/"];
    [GDWebWindow openURL:u title:[page objectForKey:@"title"]];
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
    case SegUpdates: [self showUpdates:sender]; break;
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
- (IBAction) showUpdates:(id)s { [self go:pageOf(@"updates", @"Updates")]; }
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
    GDHTTPRequest *r;
    sh->loading = YES;
    [(GDGridView *)pageView reload];
    r = [self request:u tag:ReqShelf info:sh];
    [r setCacheTTL:6 * 3600];
    [r start];
}

- (void) runSearch:(NSString *)keys page:(int)n shelf:(GDShelf *)sh
{
    GDHTTPRequest *r;
    sh->loading = YES;
    [(GDGridView *)pageView reload];
    if (n > 0) {
        r = [self request:[GDGarden searchResultsURL:keys page:n] tag:ReqSearch info:sh];
        [r setCacheTTL:3600];
    } else if (searchToken == nil) {
        /* Drupal wants a form token and the session cookie that came with it. */
        r = [self request:[GDGarden listURLForSection:@"games" selector:@"all" page:0]
                      tag:ReqSearchToken info:sh];
        [r setUsesSession:YES];
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
    if ([r tag] == ReqFeed) {
        [sh->entries addObjectsFromArray:[r error] ? [NSArray array] : [GDGarden parseFeed:[r data]]];
        [(GDGridView *)pageView reload];
        return;
    }
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

- (void) itemView:(id)v openItem:(GDItem *)item
{
    [self gridView:nil openItem:item];
}

- (void) itemView:(id)v openListing:(NSDictionary *)p
{
    [self go:p];
}

/* "Try with SheepShaver": say plainly what SheepShaver is and what the Garden
 * is about to do, before it downloads anything or touches another program's
 * settings. */
- (void) itemView:(id)v tryEmulator:(GDItemDetail *)d
{
    NSString *name = [GDCompat emulatorNameForItem:d];
    NSString *where = [GDCompat emulatorPathForItem:d];
    NSString *title = [d title] ?: @"This title";
    NSString *folder;
    GDFile *best = nil;
    int answer;

    [GDCompat verdictForItem:d bestFile:&best];

    /* Basilisk II, or SheepShaver not installed: explain, and offer to get it. */
    if (where == nil || ![GDSheepShaver isInstalled]) {
        NSString *info = [NSString stringWithFormat:
            @"%@ was made for Mac OS 9, and this Mac has no Classic environment to run it in.\n\n"
             "%@ is an emulator: it runs an old Macintosh in a window, and Mac OS 9 software "
             "runs inside that. It needs a Mac OS ROM and a Mac OS 9 system of its own, which "
             "its page in the Garden has, with a guide.", title, name];
        answer = NSRunAlertPanel([NSString stringWithFormat:@"%@ runs Mac OS 9 software", name],
                                 info, [NSString stringWithFormat:@"Get %@", name], @"Cancel", nil);
        if (answer == NSAlertDefaultReturn) {
            if (where != nil)
                [self go:[NSDictionary dictionaryWithObjectsAndKeys:@"item", @"kind", where, @"path",
                             name, @"title", nil]];
            else
                [self go:[NSDictionary dictionaryWithObjectsAndKeys:@"list", @"kind", @"apps", @"section",
                             @"emulators", @"selector", @"Emulators", @"title", nil]];
        }
        return;
    }

    /* Installed, but sharing no folder with Mac OS 9 yet. */
    folder = [GDSheepShaver installFolder];
    if (folder == nil) {
        NSString *info = [NSString stringWithFormat:
            @"SheepShaver shows one folder of this Mac to Mac OS 9, as a disk. It is not showing "
             "any at the moment.\n\nThe Garden can set it to \"Applications (Mac OS 9)\" and install "
             "%@ there, where Mac OS 9 will see it. SheepShaver reads its settings when it starts, "
             "so it has to be started again%@. A copy of the settings as they are now is kept.",
            title, [GDSheepShaver isRunning] ? @" (it is running now)" : @""];
        answer = NSRunAlertPanel(@"Let SheepShaver see the software the Garden installs?",
                                 info, @"Share and Download", @"Cancel", nil);
        if (answer != NSAlertDefaultReturn)
            return;
        if (![GDSheepShaver shareFolder:@"/Applications (Mac OS 9)"]) {
            NSRunAlertPanel(@"SheepShaver's settings could not be changed",
                            @"The Garden could not write ~/.sheepshaver_prefs.", @"OK", nil, nil);
            return;
        }
        folder = [GDSheepShaver installFolder];
    } else {
        NSString *info = [NSString stringWithFormat:
            @"%@ was made for Mac OS 9, and will not open on this Mac by itself.\n\n"
             "SheepShaver shows \"%@\" to Mac OS 9 as a disk. The Garden will download %@ and "
             "install it there, ready to open inside SheepShaver.",
            title, [folder lastPathComponent], title];
        answer = NSRunAlertPanel(@"Install for SheepShaver?", info, @"Download", @"Cancel", nil);
        if (answer != NSAlertDefaultReturn)
            return;
    }
    if (best != nil)
        [[GDInstaller sharedInstaller] installFile:best ofItem:d];
}

- (void) itemView:(id)v openInstalled:(NSDictionary *)entry
{
    NSString *launch = [entry objectForKey:@"launch"];
    NSArray *inst = [entry objectForKey:@"installed"];
    NSString *where = [inst count] ? [inst objectAtIndex:0] : launch;

    if (launch && [[NSWorkspace sharedWorkspace] openFile:launch])
        return;
    /* Mac OS 9 software cannot be opened by this Mac: it lives in the folder
     * SheepShaver shows to Mac OS 9, so start SheepShaver and let the reader
     * open it in there. */
    if ([GDSheepShaver isInstalled] && [GDSheepShaver sharesPath:where]) {
        NSString *info = [NSString stringWithFormat:
            @"This Mac cannot open Mac OS 9 software itself. It is installed in \"%@\", "
             "which SheepShaver shows to Mac OS 9 as a disk: open it there.",
            [[where stringByDeletingLastPathComponent] lastPathComponent]];
        if (NSRunAlertPanel(@"Open it in SheepShaver?", info,
                            [GDSheepShaver isRunning] ? @"Bring SheepShaver Forward" : @"Start SheepShaver",
                            @"Show in Finder", nil) == NSAlertDefaultReturn) {
            [GDSheepShaver launch];
            return;
        }
    }
    if (where != nil)
        [[NSWorkspace sharedWorkspace] selectFile:where inFileViewerRootedAtPath:@""];
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

/* Labels on the Library/Updates tabs and the Dock icon: progress while
 * downloading, else the number of updates.  NSDockTile is Leopard-only, so
 * the application icon image itself is redrawn (works on Tiger too). */
- (void) updateBadges
{
    NSArray *jobs = [[GDInstaller sharedInstaller] jobs];
    int active = 0, nupd = (int)[[[GDInstaller sharedInstaller] updates] count];
    long long done = 0, total = 0;
    double now = CFAbsoluteTimeGetCurrent();
    unsigned i;
    NSImage *img;
    NSString *badge;
    NSRect r = NSMakeRect(0, 0, 128, 128);

    for (i = 0; i < [jobs count]; i++) {
        GDInstallJob *j = [jobs objectAtIndex:i];
        if ([j isActive]) {
            active++;
            done += j->bytesDone;
            total += j->bytesTotal > 0 ? j->bytesTotal : (long long)[[j file] sizeBytes];
        }
    }
    [sectionControl setLabel:active ? [NSString stringWithFormat:@"Library (%d)", active] : @"Library"
                  forSegment:SegLibrary];
    [sectionControl setLabel:nupd ? [NSString stringWithFormat:@"Updates (%d)", nupd] : @"Updates"
                  forSegment:SegUpdates];

    if (active && now - lastDockDraw < 0.5)
        return;
    lastDockDraw = now;
    if (dockIcon == nil)
        dockIcon = [[NSImage imageNamed:@"NSApplicationIcon"] copy];
    badge = active ? [NSString stringWithFormat:@"%d", active] : (nupd ? [NSString stringWithFormat:@"%d", nupd] : nil);
    if (!active && badge == nil) {
        if (dockDrawn)
            [NSApp setApplicationIconImage:dockIcon];
        dockDrawn = NO;
        return;
    }
    img = [[[NSImage alloc] initWithSize:r.size] autorelease];
    [img lockFocus];
    [dockIcon drawInRect:r fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
    if (active && total > 0) {
        NSRect bar = NSMakeRect(14, 10, 100, 14);
        [[NSColor colorWithCalibratedWhite:0.15 alpha:0.85] set];
        [GDRoundRect(bar, 7) fill];
        [[NSColor colorWithCalibratedRed:0.30 green:0.62 blue:1 alpha:1] set];
        [GDRoundRect(NSMakeRect(16, 12, 96.0 * MIN(1.0, (double)done / total), 10), 5) fill];
    }
    if (badge) {
        NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont boldSystemFontOfSize:26],
                              NSFontAttributeName, [NSColor whiteColor], NSForegroundColorAttributeName, nil];
        NSSize ts = [badge sizeWithAttributes:a];
        float w = MAX(40, ts.width + 20);
        NSRect b = NSMakeRect(128 - w - 2, 128 - 42, w, 40);
        [[NSColor colorWithCalibratedRed:0.88 green:0.12 blue:0.10 alpha:1] set];
        [GDRoundRect(b, 20) fill];
        [[NSColor whiteColor] set];
        [GDRoundRect(NSInsetRect(b, 1.5, 1.5), 18.5) stroke];
        [badge drawAtPoint:NSMakePoint(NSMidX(b) - ts.width / 2, NSMidY(b) - ts.height / 2) withAttributes:a];
    }
    [img unlockFocus];
    [NSApp setApplicationIconImage:img];
    dockDrawn = YES;
}

- (void) jobChanged:(NSNotification *)n
{
    [self updateBadges];
}

@end
