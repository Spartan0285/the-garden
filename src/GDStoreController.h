/*
 * GDStoreController - the store window: toolbar (back/forward, sections,
 * search), a scroll view whose document is the current page, and the
 * navigation history.  A page is described by a dictionary:
 *   {kind: featured|apps|games|categories|library|list|search|item, ...}
 */
#import <Cocoa/Cocoa.h>

@class GDGridView, GDShelf;

@interface GDStoreController : NSObject
{
    NSWindow *window;
    NSScrollView *scroll;
    NSSegmentedControl *navControl;
    NSSegmentedControl *sectionControl;
    NSSearchField *searchField;

    NSMutableArray *history;
    int historyIndex;
    NSDictionary *page;
    NSView *pageView;
    NSMutableArray *requests;   /* in flight for the current page */
    NSString *searchToken;
    NSWindow *shotWindow;
    BOOL onlyRunnable;
    NSImage *dockIcon;
    double lastDockDraw;
    BOOL dockDrawn;
}
- (void) showWindow;
- (NSWindow *) window;
- (void) go:(NSDictionary *)p;
- (int) pendingRequests;
/* The page on screen, in a few words, for a feedback report. */
- (NSString *) currentPageDescription;

/* menu / toolbar actions */
- (IBAction) goBack:(id)sender;
- (IBAction) goForward:(id)sender;
- (IBAction) showFeatured:(id)sender;
- (IBAction) showApps:(id)sender;
- (IBAction) showGames:(id)sender;
- (IBAction) showCategories:(id)sender;
- (IBAction) showLibrary:(id)sender;
- (IBAction) showUpdates:(id)sender;
- (IBAction) focusSearch:(id)sender;
- (IBAction) reloadPage:(id)sender;
- (IBAction) toggleOnlyRunnable:(id)sender;
- (IBAction) viewOnSite:(id)sender;
- (BOOL) onlyRunnable;
@end
