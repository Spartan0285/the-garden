/*
 * GDGridView - the store's browsing surface: one or more shelves, each a
 * heading plus a wrap-around grid of tiles.  Tiles are either items
 * (GDItem: picture, title, category, stars, compatibility badge) or
 * categories (NSDictionary {name, path, section}).  A shelf can end in a
 * "More" button, or carry a "See All" link in its heading.
 *
 * NSCollectionView is Leopard-only, so this lays out and draws by hand.
 */
#import <Cocoa/Cocoa.h>

@class GDGridView, GDItem;

@interface GDShelf : NSObject
{
@public
    NSString *title;
    NSString *subtitle;
    NSMutableArray *entries;    /* GDItem or NSDictionary (category) */
    BOOL categories;
    BOOL hasMore;               /* show a "More" button after the tiles */
    BOOL loading;
    NSString *seeAll;           /* heading link text, or nil */
    int tag;
    BOOL letterBar;             /* A-Z strip under the heading */
    NSString *letter;           /* selected letter, nil = all */
    NSMutableDictionary *state; /* owner's paging state */
}
+ (GDShelf *) shelfWithTitle:(NSString *)t;
@end

@interface NSObject (GDGridViewDelegate)
- (void) gridView:(GDGridView *)g openItem:(GDItem *)item;
- (void) gridView:(GDGridView *)g openCategory:(NSDictionary *)cat;
- (void) gridView:(GDGridView *)g moreForShelf:(GDShelf *)shelf;
- (void) gridView:(GDGridView *)g seeAllForShelf:(GDShelf *)shelf;
- (void) gridView:(GDGridView *)g shelf:(GDShelf *)shelf pickLetter:(NSString *)letter;
@end

@interface GDGridView : NSView
{
    NSMutableArray *shelves;
    id delegate;
    BOOL onlyRunnable;
    NSMutableArray *hits;       /* {rect, kind, object, shelf} for clicks */
    NSString *message;          /* shown when there is nothing else */
    int trackTag;
}
- (void) setDelegate:(id)d;
- (void) setShelves:(NSArray *)s;
- (NSMutableArray *) shelves;
- (void) setOnlyRunnable:(BOOL)f;
- (void) setMessage:(NSString *)m;
- (void) reload;               /* relayout + redraw after model changes */
@end
